# In-App Apple ID Authentication Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the app log the server into Apple (including 2FA) over a new
opt-in HTTPS-only HTTP API, replacing the current SSH-and-attach-to-stdin
flow, and let the app find out when the saved session has gone stale.

**Architecture:** `pypush_gsa_icloud.py`'s blocking SRP+2FA call chain
(`input()`/`getpass()`) splits into non-blocking trigger/submit primitives.
`mh_endpoint.py` gains three new Basic-Auth-gated routes
(`POST /auth/apple/login`, `POST /auth/apple/verify`, `GET
/auth/apple/status`) backed by a single in-memory pending-login slot
(single-tenant server, no session IDs). The Flutter app gets a new service,
an opt-in Preferences switch, and a login wizard screen; the service
refuses to make any request over a non-HTTPS endpoint URL.

**Tech Stack:** Python 3 stdlib `http.server`, `requests`, `srp`/SRP
already in use; Flutter/Dart, `package:http`, `flutter_settings_screens`.

**Spec:** `docs/superpowers/specs/2026-09-13-inapp-apple-auth-design.md`

## Global Constraints

- HTTPS is enforced **client-side only**, for this feature's three
  endpoints. No server-side TLS-detection logic — the server can't tell
  from a plain `http.server` socket whether TLS terminated upstream.
- The three new endpoints go through the existing `do_GET`/`do_POST`
  dispatch so `ServerHandler.authenticate()` (Basic Auth) already gates
  them. No new auth mechanism.
- The Apple ID password is never written to disk and never logged (no
  `logger.debug`/`logger.info` of a raw request body or a `password`/`code`
  field) in any of the three new endpoint handlers.
- Pending login state is a single in-memory slot (no session IDs), replaced
  by any new `/login` call, expired after 10 minutes
  (`PENDING_LOGIN_TIMEOUT_SECONDS = 600`).
- Only a successful verify, a wrong code, or the 10-minute timeout clear
  pending state — a transient Apple/network error while verifying does
  not.
- The existing interactive CLI script (`apple_cryptography.registerDevice()`
  and anyone else calling `icloud_login_mobileme` directly) keeps working
  unchanged in behavior.
- Widget-level UI wiring (the new switch, the login screen) is manual-test
  only, matching this codebase's existing boundary — no automated Flutter
  widget tests for them.

---

### Task 1: Split GSA login into non-blocking primitives

**Files:**
- Modify: `endpoint/register/pypush_gsa_icloud.py`
- Modify: `endpoint/register/apple_cryptography.py`
- Modify: `endpoint/mh_endpoint.py:264-275` (the module's own `getAuth()`)
- Test: `endpoint/tests/test_gsa_authenticate.py` (new)
- Test: `endpoint/tests/test_mh_endpoint_apple_auth.py` (new — just the
  `getAuth()` regression test in this task; the HTTP routes come in later
  tasks)

**Interfaces:**
- Produces (used by later tasks and by `mh_endpoint.py`):
  - `class AppleAuthError(Exception)` — raised for bad credentials, a bad
    account status from Apple, or an unknown `au` challenge value.
  - `@dataclass class NeedsSecondFactor: method: str; dsid: str; idms_token: str`
  - `gsa_authenticate(username: str, password: str) -> dict | NeedsSecondFactor`
    — one non-blocking SRP round trip. Raises `AppleAuthError` on bad
    credentials or an unrecognized `au` value. Returns the final `spd`
    dict on success with no 2FA required, or a `NeedsSecondFactor` when
    Apple requires one.
  - `gsa_authenticate_interactive(username: str, password: str) -> dict` —
    blocking CLI wrapper: calls `gsa_authenticate`, and while it returns
    `NeedsSecondFactor`, calls the existing `_dispatch_second_factor(method,
    dsid, idms_token)` (unchanged, still blocks on `input()`) and retries.
  - `register_mobileme(g: dict, username: str) -> dict` — the mobileme
    device-registration POST, returning `{'dsid': str, 'searchPartyToken':
    str}`. Raises `AppleAuthError(status_message)` if Apple reports a
    non-zero account status.
  - `icloud_login_mobileme(username='', password='') -> dict` — same
    public signature as today, now implemented as
    `register_mobileme(gsa_authenticate_interactive(username, password),
    username)`. Return shape changes from the raw mobileme plist to
    `{'dsid': str, 'searchPartyToken': str}` — see call-site updates below.
- Consumes: nothing new from other tasks (this is the foundation task).

This task fixes a latent bug found while designing this feature:
`mh_endpoint.py`'s own `getAuth()` calls
`pypush_gsa_icloud.icloud_login_mobileme(username=mh_config.USER,
password=mh_config.PASS)` — `mh_config.USER`/`mh_config.PASS` don't exist
as module attributes (the real accessors are `mh_config.getUser()`/
`getPass()`). This path is unreachable today because `auth.json` already
exists by the time anything calls this `getAuth()`, but this feature makes
it reachable (a stale session clears `auth.json`-backed trust and this
same function gets called again with `regenerate=True`), so it's fixed
here rather than left as a landmine.

- [ ] **Step 1: Write the failing tests**

Create `endpoint/tests/test_gsa_authenticate.py`:

```python
from unittest.mock import MagicMock, patch

import pytest

from register import pypush_gsa_icloud as gsa


def _srp_user_mock(session_key_matches=True, challenge_ok=True):
    usr = MagicMock()
    usr.process_challenge.return_value = b"m1" if challenge_ok else None
    usr.authenticated.return_value = session_key_matches
    return usr


def test_gsa_authenticate_returns_spd_when_no_second_factor_required():
    init_resp = {"sp": "s2k", "s": b"salt", "i": 1024, "B": b"B", "c": "c-token"}
    complete_resp = {"M2": b"m2", "spd": b"encrypted-spd"}
    decrypted_plist = (
        b"<?xml version='1.0' encoding='UTF-8'?>"
        b"<!DOCTYPE plist PUBLIC '-//Apple//DTD PLIST 1.0//EN' "
        b"'http://www.apple.com/DTDs/PropertyList-1.0.dtd'>"
        b"<plist><dict><key>adsid</key><string>adsid-1</string></dict></plist>"
    )

    with patch.object(gsa.srp, "User") as mock_user_cls, \
            patch.object(gsa, "gsa_authenticated_request", side_effect=[init_resp, complete_resp]), \
            patch.object(gsa, "decrypt_cbc", return_value=decrypted_plist):
        mock_user = _srp_user_mock()
        mock_user.start_authentication.return_value = (None, "a-value")
        mock_user_cls.return_value = mock_user

        result = gsa.gsa_authenticate("user@example.com", "hunter2")

    assert result == {"adsid": "adsid-1"}


def test_gsa_authenticate_returns_needs_second_factor_for_trusted_device():
    init_resp = {"sp": "s2k", "s": b"salt", "i": 1024, "B": b"B", "c": "c-token"}
    complete_resp = {
        "M2": b"m2", "spd": b"encrypted-spd",
        "Status": {"au": "trustedDeviceSecondaryAuth"},
    }
    decrypted_plist = (
        b"<?xml version='1.0' encoding='UTF-8'?>"
        b"<!DOCTYPE plist PUBLIC '-//Apple//DTD PLIST 1.0//EN' "
        b"'http://www.apple.com/DTDs/PropertyList-1.0.dtd'>"
        b"<plist><dict>"
        b"<key>adsid</key><string>adsid-1</string>"
        b"<key>GsIdmsToken</key><string>token-1</string>"
        b"</dict></plist>"
    )

    with patch.object(gsa.srp, "User") as mock_user_cls, \
            patch.object(gsa, "gsa_authenticated_request", side_effect=[init_resp, complete_resp]), \
            patch.object(gsa, "decrypt_cbc", return_value=decrypted_plist):
        mock_user = _srp_user_mock()
        mock_user.start_authentication.return_value = (None, "a-value")
        mock_user_cls.return_value = mock_user

        result = gsa.gsa_authenticate("user@example.com", "hunter2")

    assert result == gsa.NeedsSecondFactor(
        method="trustedDeviceSecondaryAuth", dsid="adsid-1", idms_token="token-1",
    )


def test_gsa_authenticate_raises_on_failed_challenge():
    init_resp = {"sp": "s2k", "s": b"salt", "i": 1024, "B": b"B", "c": "c-token"}

    with patch.object(gsa.srp, "User") as mock_user_cls, \
            patch.object(gsa, "gsa_authenticated_request", return_value=init_resp):
        mock_user = _srp_user_mock(challenge_ok=False)
        mock_user.start_authentication.return_value = (None, "a-value")
        mock_user_cls.return_value = mock_user

        with pytest.raises(gsa.AppleAuthError):
            gsa.gsa_authenticate("user@example.com", "wrong-password")


def test_gsa_authenticate_raises_when_session_verification_fails():
    init_resp = {"sp": "s2k", "s": b"salt", "i": 1024, "B": b"B", "c": "c-token"}
    complete_resp = {"M2": b"m2", "spd": b"encrypted-spd"}

    with patch.object(gsa.srp, "User") as mock_user_cls, \
            patch.object(gsa, "gsa_authenticated_request", side_effect=[init_resp, complete_resp]), \
            patch.object(gsa, "decrypt_cbc", return_value=b"<plist><dict/></plist>"):
        mock_user = _srp_user_mock(session_key_matches=False)
        mock_user.start_authentication.return_value = (None, "a-value")
        mock_user_cls.return_value = mock_user

        with pytest.raises(gsa.AppleAuthError):
            gsa.gsa_authenticate("user@example.com", "hunter2")


def test_gsa_authenticate_interactive_dispatches_second_factor_then_retries():
    needs_2fa = gsa.NeedsSecondFactor(method="secondaryAuth", dsid="d-1", idms_token="t-1")
    with patch.object(gsa, "gsa_authenticate", side_effect=[needs_2fa, {"adsid": "a-1"}]) as mock_auth, \
            patch.object(gsa, "_dispatch_second_factor") as mock_dispatch:
        result = gsa.gsa_authenticate_interactive("user@example.com", "hunter2")

    mock_dispatch.assert_called_once_with("secondaryAuth", "d-1", "t-1")
    assert mock_auth.call_count == 2
    assert result == {"adsid": "a-1"}


def test_register_mobileme_returns_dsid_and_search_party_token():
    mobileme_plist = {
        "dsid": "dsid-1",
        "delegates": {"com.apple.mobileme": {
            "status": 0,
            "service-data": {"tokens": {"searchPartyToken": "spt-1"}},
        }},
    }
    g = {"t": {"com.apple.gs.idms.pet": {"token": "pet-1"}}, "adsid": "adsid-1"}
    resp = MagicMock()
    resp.content = b"<plist/>"
    resp.status_code = 200
    resp.text = ""
    resp.raise_for_status = MagicMock()
    resp.__enter__.return_value = resp
    resp.__exit__.return_value = False

    with patch.object(gsa, "generate_anisette_headers", return_value={}), \
            patch.object(gsa.requests, "post", return_value=resp), \
            patch.object(gsa.plist, "loads", return_value=mobileme_plist):
        result = gsa.register_mobileme(g, "user@example.com")

    assert result == {"dsid": "dsid-1", "searchPartyToken": "spt-1"}


def test_register_mobileme_raises_on_non_zero_status():
    mobileme_plist = {
        "dsid": "dsid-1",
        "delegates": {"com.apple.mobileme": {
            "status": 1,
            "status-message": "Account is blocking",
        }},
    }
    g = {"t": {"com.apple.gs.idms.pet": {"token": "pet-1"}}, "adsid": "adsid-1"}
    resp = MagicMock()
    resp.content = b"<plist/>"
    resp.status_code = 200
    resp.text = ""
    resp.raise_for_status = MagicMock()
    resp.__enter__.return_value = resp
    resp.__exit__.return_value = False

    with patch.object(gsa, "generate_anisette_headers", return_value={}), \
            patch.object(gsa.requests, "post", return_value=resp), \
            patch.object(gsa.plist, "loads", return_value=mobileme_plist):
        with pytest.raises(gsa.AppleAuthError, match="Account is blocking"):
            gsa.register_mobileme(g, "user@example.com")
```

Create `endpoint/tests/test_mh_endpoint_apple_auth.py`:

```python
from unittest.mock import patch

import mh_config
import mh_endpoint


def test_get_auth_regenerates_using_configured_user_and_pass(tmp_path, monkeypatch):
    monkeypatch.setattr(mh_config, "getConfigFile", lambda: str(tmp_path / "auth.json"))
    monkeypatch.setattr(mh_config, "getUser", lambda: "user@example.com")
    monkeypatch.setattr(mh_config, "getPass", lambda: "hunter2")

    with patch.object(
        mh_endpoint.pypush_gsa_icloud, "icloud_login_mobileme",
        return_value={"dsid": "dsid-1", "searchPartyToken": "spt-1"},
    ) as mock_login:
        dsid, token = mh_endpoint.getAuth(regenerate=True)

    mock_login.assert_called_once_with(username="user@example.com", password="hunter2")
    assert (dsid, token) == ("dsid-1", "spt-1")
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd endpoint && python -m pytest tests/test_gsa_authenticate.py tests/test_mh_endpoint_apple_auth.py -v`
Expected: FAIL — `AttributeError: module 'register.pypush_gsa_icloud' has no
attribute 'AppleAuthError'` (and similar for `NeedsSecondFactor`,
`gsa_authenticate_interactive`, `register_mobileme`), and the `getAuth`
test fails with a `TypeError`/`AttributeError` tracing back to
`mh_config.USER`.

- [ ] **Step 3: Implement**

In `endpoint/register/pypush_gsa_icloud.py`, add near the top (after the
existing imports, before `USER_ID = uuid.uuid4()`):

```python
from dataclasses import dataclass


class AppleAuthError(Exception):
    """Raised when a GSA login step fails in a way the caller must handle
    explicitly: bad credentials, a bad 2FA code, an unrecognized challenge
    type, or a non-zero account status from Apple."""


@dataclass
class NeedsSecondFactor:
    method: str
    dsid: str
    idms_token: str
```

Replace `gsa_authenticate` (lines 77-133) with:

```python
def gsa_authenticate(username, password):
    # Password is None as we'll provide it later
    usr = srp.User(username, bytes(), hash_alg=srp.SHA256, ng_type=srp.NG_2048)
    _, a = usr.start_authentication()
    logger.info("Authentication request initialization")
    r = gsa_authenticated_request(
        {"A2k": a, "ps": ["s2k", "s2k_fo"], "u": username, "o": "init"})

    if r["sp"] not in ["s2k", "s2k_fo"]:
        logger.warning(f"This implementation only supports s2k and sk2_fo. Server returned {r['sp']}")
        raise AppleAuthError(f"unsupported_protocol:{r['sp']}")

    # Change the password out from under the SRP library, as we couldn't calculate it without the salt.
    usr.p = encrypt_password(password, r["s"], r["i"], r["sp"])

    m = usr.process_challenge(r["s"], r["B"])

    # Make sure we processed the challenge correctly
    if m is None:
        logger.error("Failed to process challenge")
        raise AppleAuthError("invalid_credentials")
    logger.info("Authentication request completion")
    resp = gsa_authenticated_request(
        {"c": r["c"], "M1": m, "u": username, "o": "complete"})

    # Make sure that the server's session key matches our session key (and thus that they are not an imposter)
    if "M2" not in resp:
        logger.error("Error on authentication")
        logger.error(resp)
        raise AppleAuthError("invalid_credentials")
    usr.verify_session(resp["M2"])
    if not usr.authenticated():
        logger.error("Failed to verify session")
        raise AppleAuthError("invalid_credentials")

    spd = decrypt_cbc(usr, resp["spd"])
    # For some reason plistlib doesn't accept it without the header...
    PLISTHEADER = b"""\
<?xml version='1.0' encoding='UTF-8'?>
<!DOCTYPE plist PUBLIC '-//Apple//DTD PLIST 1.0//EN' 'http://www.apple.com/DTDs/PropertyList-1.0.dtd'>
"""
    spd = plist.loads(PLISTHEADER + spd)

    if "au" in resp["Status"]:
        au = resp["Status"]["au"]
        # Replace bytes with strings
        for k, v in spd.items():
            if isinstance(v, bytes):
                spd[k] = base64.b64encode(v).decode()
        if au not in ("trustedDeviceSecondaryAuth", "secondaryAuth"):
            logger.error(f"Unknown auth value {au}")
            raise AppleAuthError(f"unknown_auth_value:{au}")

        return NeedsSecondFactor(method=au, dsid=spd["adsid"], idms_token=spd["GsIdmsToken"])
    else:
        return spd


def gsa_authenticate_interactive(username, password):
    """Blocking CLI wrapper: retries gsa_authenticate through as many 2FA
    rounds as Apple requires, prompting on stdin via _dispatch_second_factor
    each time. Behaves exactly like the old gsa_authenticate did before it
    was split to support a non-blocking HTTP-driven login flow."""
    result = gsa_authenticate(username, password)
    while isinstance(result, NeedsSecondFactor):
        _dispatch_second_factor(result.method, result.dsid, result.idms_token)
        result = gsa_authenticate(username, password)
    return result
```

Replace `icloud_login_mobileme` (lines 38-74) with:

```python
def icloud_login_mobileme(username='', password=''):
    print("")  # Sometimes no output
    if not username:
        username = input('Apple ID: ')
    if not password:
        password = getpass('Password: ')

    g = gsa_authenticate_interactive(username, password)
    return register_mobileme(g, username)


def register_mobileme(g, username):
    """Registers this device against mobileme using the searchPartyToken
    pet from a completed GSA login `g`. Returns {'dsid', 'searchPartyToken'}
    ready to write to auth.json. Raises AppleAuthError if Apple reports a
    non-zero account status (e.g. the account needs a credit card on file)."""
    pet = g["t"]["com.apple.gs.idms.pet"]["token"]
    adsid = g["adsid"]

    data = {
        "apple-id": username,
        "delegates": {"com.apple.mobileme": {}},
        "password": pet,
        "client-id": str(USER_ID),
    }
    data = plist.dumps(data)
    headers = {
        "X-Apple-ADSID": adsid,
        "User-Agent": "com.apple.iCloudHelper/282 CFNetwork/1408.0.4 Darwin/22.5.0",
        "X-Mme-Client-Info": '<MacBookPro18,3> <Mac OS X;13.4.1;22F8> <com.apple.AOSKit/282 (com.apple.accountsd/113)>'
    }
    headers.update(generate_anisette_headers())

    logger.info("Registering device after login")
    with requests.post(
            "https://setup.icloud.com/setup/iosbuddy/loginDelegates",
            auth=(username, pet),
            data=data,
            headers=headers,
            verify=False,
    ) as resp:
        resp.raise_for_status()
    response = f"HTTP-Code: {resp.status_code}\n{resp.text}"
    logger.debug(response)
    mobileme = plist.loads(resp.content)

    status = mobileme['delegates']['com.apple.mobileme']['status']
    if status != 0:
        msg = mobileme['delegates']['com.apple.mobileme']['status-message']
        logger.error('Invalid status: ' + str(status))
        logger.error('Error message: ' + msg)
        if 'blocking' in msg:
            logger.error(
                'It seems your account score is not high enough. Log in to '
                'https://appleid.apple.com/ and add your credit card (nothing '
                'will be charged) or additional data to increase it.')
        raise AppleAuthError(msg)

    return {
        'dsid': mobileme['dsid'],
        'searchPartyToken': mobileme['delegates']['com.apple.mobileme']['service-data']['tokens']['searchPartyToken'],
    }
```

In `endpoint/register/apple_cryptography.py`, update the import and
`getAuth()` (the `from .pypush_gsa_icloud import icloud_login_mobileme`
line and the function body):

```python
from .pypush_gsa_icloud import AppleAuthError, icloud_login_mobileme
```

```python
def getAuth(regenerate=False):
    if os.path.exists(mh_config.getConfigFile()) and not regenerate:
        with open(mh_config.getConfigFile(), "r") as f:
            j = json.load(f)
    else:
        logger.info('Trying to login')
        try:
            j = icloud_login_mobileme(username=mh_config.getUser(), password=mh_config.getPass())
        except AppleAuthError:
            logger.error('Unable to proceed, program will be terminated.')
            sys.exit()
        with open(mh_config.getConfigFile(), "w") as f:
            json.dump(j, f)
    return (j['dsid'], j['searchPartyToken'])
```

In `endpoint/mh_endpoint.py`, replace the `getAuth` function (lines
264-275) with:

```python
def getAuth(regenerate=False, second_factor='sms'):
    if os.path.exists(mh_config.getConfigFile()) and not regenerate:
        with open(mh_config.getConfigFile(), "r") as f:
            j = json.load(f)
    else:
        j = pypush_gsa_icloud.icloud_login_mobileme(username=mh_config.getUser(), password=mh_config.getPass())
        with open(mh_config.getConfigFile(), "w") as f:
            json.dump(j, f)
    return j['dsid'], j['searchPartyToken']
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd endpoint && python -m pytest tests/test_gsa_authenticate.py tests/test_mh_endpoint_apple_auth.py -v`
Expected: PASS

- [ ] **Step 5: Run the full existing suite to confirm no regression**

Run: `cd endpoint && python -m pytest tests/ -v`
Expected: PASS (in particular `tests/test_gsa_2fa_dispatch.py`'s existing
tests, which exercise `_dispatch_second_factor` and
`trusted_device_second_factor` directly and are untouched by this task)

- [ ] **Step 6: Commit**

```bash
git add endpoint/register/pypush_gsa_icloud.py endpoint/register/apple_cryptography.py \
        endpoint/mh_endpoint.py endpoint/tests/test_gsa_authenticate.py \
        endpoint/tests/test_mh_endpoint_apple_auth.py
git commit -m "feat: split GSA login into non-blocking primitives, fix getAuth() config bug"
```

---

### Task 2: Split trusted-device 2FA into trigger/submit primitives

**Files:**
- Modify: `endpoint/register/pypush_gsa_icloud.py`
- Test: `endpoint/tests/test_gsa_2fa_dispatch.py`

**Interfaces:**
- Consumes: nothing new from Task 1.
- Produces (used by Task 4):
  - `request_trusted_device_code(dsid: str, idms_token: str) -> dict` —
    triggers the push, returns the `headers` dict needed to submit a code.
  - `submit_trusted_device_code(headers: dict, code: str) -> None` — submits
    the code. Does **not** raise on a wrong code (Apple's response here
    doesn't reliably signal that — see the existing code comment this task
    preserves); callers detect a wrong code by re-running
    `gsa_authenticate` afterward and checking whether it demands 2FA again
    (built in Task 5).
  - `trusted_device_second_factor(dsid, idms_token)` keeps its existing
    public signature and blocking behavior — internally it now just calls
    the two functions above plus `_prompt_for_code`, so every existing test
    in `test_gsa_2fa_dispatch.py` for this function must keep passing
    unmodified.

- [ ] **Step 1: Write the failing tests**

Add to `endpoint/tests/test_gsa_2fa_dispatch.py`:

```python
def test_request_trusted_device_code_returns_headers_for_submission():
    trigger_resp = _mock_response()

    with patch.object(gsa, "generate_anisette_headers", return_value={"X-Anisette": "1"}), \
            patch.object(gsa.requests, "get", return_value=trigger_resp) as mock_get:
        headers = gsa.request_trusted_device_code("dsid-1", "token-1")

    mock_get.assert_called_once()
    assert mock_get.call_args.args[0] == "https://gsa.apple.com/auth/verify/trusteddevice"
    assert headers["Content-Type"] == "text/x-xml-plist"
    assert headers["X-Anisette"] == "1"


def test_submit_trusted_device_code_posts_security_code():
    submit_resp = _mock_response()

    with patch.object(gsa, "generate_anisette_headers", return_value={}), \
            patch.object(gsa.requests, "get", return_value=submit_resp) as mock_get:
        gsa.submit_trusted_device_code({"X-Apple-Identity-Token": "id-1"}, "654321")

    mock_get.assert_called_once()
    assert mock_get.call_args.args[0] == "https://gsa.apple.com/grandslam/GsService2/validate"
    assert mock_get.call_args.kwargs["headers"]["security-code"] == "654321"


def test_submit_trusted_device_code_raises_on_server_error():
    submit_resp = _mock_response(status_code=500, ok=False)
    submit_resp.raise_for_status.side_effect = requests.HTTPError("500 Server Error")

    with patch.object(gsa, "generate_anisette_headers", return_value={}), \
            patch.object(gsa.requests, "get", return_value=submit_resp):
        with pytest.raises(requests.HTTPError):
            gsa.submit_trusted_device_code({}, "000000")
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd endpoint && python -m pytest tests/test_gsa_2fa_dispatch.py -v -k "request_trusted_device_code or submit_trusted_device_code"`
Expected: FAIL with `AttributeError: module 'register.pypush_gsa_icloud'
has no attribute 'request_trusted_device_code'`

- [ ] **Step 3: Implement**

Replace `trusted_device_second_factor` (currently lines 337-387) in
`endpoint/register/pypush_gsa_icloud.py` with:

```python
def request_trusted_device_code(dsid, idms_token):
    headers = _common_2fa_headers(dsid, idms_token)
    headers["Content-Type"] = "text/x-xml-plist"
    headers["Accept"] = "text/x-xml-plist"

    # Apple's 2FA endpoints are known to answer with a non-2xx here even though the
    # push still went out, so only a server error is treated as a real failure.
    with requests.get(
            "https://gsa.apple.com/auth/verify/trusteddevice",
            headers=headers,
            verify=False,
            timeout=10,
    ) as resp:
        if resp.status_code >= 500:
            resp.raise_for_status()
        logger.debug(f"Trusted-device code request returned HTTP {resp.status_code}")
    logger.info("Requested trusted-device 2FA code")
    return headers


def submit_trusted_device_code(headers, code):
    # Anisette metadata is meant to be single-use; the trigger/wait/resend round trip
    # before this can stretch well past that, so regenerate it right before submitting.
    submit_headers = dict(headers)
    submit_headers.update(generate_anisette_headers())
    submit_headers["security-code"] = code

    with requests.get(
            "https://gsa.apple.com/grandslam/GsService2/validate",
            headers=submit_headers,
            verify=False,
            timeout=10,
    ) as resp:
        resp.raise_for_status()
        header_string = "Headers:\n"
        for header, value in resp.headers.items():
            header_string += f"{header}: {value}\n"
        logger.debug(f"HTTP-Code: {resp.status_code} with {len(resp.text)} bytes\n{header_string}{resp.text}")

    # Unlike the SMS endpoint, this one hasn't been confirmed to signal a wrong code via
    # its response, so success is left for the caller's re-authentication attempt to prove.
    logger.info("Trusted-device code submitted, re-authenticating to confirm.")


def trusted_device_second_factor(dsid, idms_token):
    headers = request_trusted_device_code(dsid, idms_token)

    def resend():
        request_trusted_device_code(dsid, idms_token)
        return input("Enter the 2FA code shown on your trusted device: ")

    code = _prompt_for_code(
        f"Enter the 2FA code shown on your trusted device (If you do not see it, wait {WAITING_TIME}s and press Enter. An attempt will be made to resend it.): ",
        resend,
    )

    submit_trusted_device_code(headers, code)
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd endpoint && python -m pytest tests/test_gsa_2fa_dispatch.py -v`
Expected: PASS — including every pre-existing test in this file
(`test_trusted_device_second_factor_triggers_then_submits_code` and its
siblings), unmodified.

- [ ] **Step 5: Commit**

```bash
git add endpoint/register/pypush_gsa_icloud.py endpoint/tests/test_gsa_2fa_dispatch.py
git commit -m "refactor: split trusted-device 2FA into trigger/submit primitives"
```

---

### Task 3: Split SMS 2FA into trigger/submit primitives

**Files:**
- Modify: `endpoint/register/pypush_gsa_icloud.py`
- Test: `endpoint/tests/test_gsa_2fa_dispatch.py`

**Interfaces:**
- Consumes: nothing new from Tasks 1-2.
- Produces (used by Task 4):
  - `request_sms_code(dsid: str, idms_token: str) -> tuple[dict, int]` —
    triggers discovery of which phone number to use, returns `(headers,
    sms_id)`.
  - `submit_sms_code(headers: dict, sms_id: int, code: str) -> None` —
    submits the code. Raises `AppleAuthError("invalid_code")` on failure
    (replacing the current generic `Exception`, so callers can distinguish
    a wrong code from any other failure the same way the trusted-device
    path will in Task 5).
  - `sms_second_factor(dsid, idms_token)` keeps its existing public
    signature and blocking behavior, now implemented via the two functions
    above plus the existing `request_code` resend helper and
    `_prompt_for_code`.

No pytest coverage exists today for the SMS path specifically (only
`_dispatch_second_factor`'s routing to it is tested) — this task adds it.

- [ ] **Step 1: Write the failing tests**

Add to `endpoint/tests/test_gsa_2fa_dispatch.py`:

```python
def test_request_sms_code_extracts_phone_id_from_boot_args():
    boot_args = '{"direct": {"phoneNumberVerification": {"trustedPhoneNumber": {"id": 7}}}}'
    auth_resp = _mock_response(
        text=f'<script class="boot_args">{boot_args}</script>',
    )

    with patch.object(gsa, "generate_anisette_headers", return_value={"X-Anisette": "1"}), \
            patch.object(gsa.requests, "get", return_value=auth_resp) as mock_get:
        headers, sms_id = gsa.request_sms_code("dsid-1", "token-1")

    mock_get.assert_called_once_with("https://gsa.apple.com/auth", headers=headers, verify=False)
    assert sms_id == 7
    assert headers["X-Anisette"] == "1"


def test_request_sms_code_defaults_to_phone_id_one_when_boot_args_missing():
    auth_resp = _mock_response(text="<html>no script here</html>")

    with patch.object(gsa, "generate_anisette_headers", return_value={}), \
            patch.object(gsa.requests, "get", return_value=auth_resp):
        _, sms_id = gsa.request_sms_code("dsid-1", "token-1")

    assert sms_id == 1


def test_submit_sms_code_succeeds_when_dsid_header_present():
    submit_resp = _mock_response(headers={"X-Apple-DSID": "dsid-1"}, ok=True)

    with patch.object(gsa.requests, "post", return_value=submit_resp) as mock_post:
        gsa.submit_sms_code({"h": "1"}, 7, "654321")

    assert mock_post.call_args.args[0] == "https://gsa.apple.com/auth/verify/phone/securitycode"
    assert mock_post.call_args.kwargs["json"] == {
        "phoneNumber": {"id": 7}, "mode": "sms", "securityCode": {"code": "654321"},
    }


def test_submit_sms_code_raises_apple_auth_error_when_dsid_header_missing():
    submit_resp = _mock_response(headers={}, ok=True)

    with patch.object(gsa.requests, "post", return_value=submit_resp):
        with pytest.raises(gsa.AppleAuthError, match="invalid_code"):
            gsa.submit_sms_code({}, 7, "000000")
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd endpoint && python -m pytest tests/test_gsa_2fa_dispatch.py -v -k "request_sms_code or submit_sms_code"`
Expected: FAIL with `AttributeError: module 'register.pypush_gsa_icloud'
has no attribute 'request_sms_code'`

- [ ] **Step 3: Implement**

Replace `sms_second_factor` (currently lines 280-334) in
`endpoint/register/pypush_gsa_icloud.py` with:

```python
def request_sms_code(dsid, idms_token):
    headers = _common_2fa_headers(dsid, idms_token)
    headers["X-Apple-App-Info"] = "com.apple.gs.xcode.auth"
    headers["X-Xcode-Version"] = "11.2 (11B41)"

    # Extract the "boot_args" from the auth page to get the id of the trusted phone number
    pattern = r'<script.*class="boot_args">\s*(.*?)\s*</script>'
    with requests.get("https://gsa.apple.com/auth", headers=headers, verify=False) as auth:
        auth.raise_for_status()
        sms_id = 1
        match = re.search(pattern, auth.text, re.DOTALL)
        if match:
            boot_args = json.loads(match.group(1).strip())
            try:
                sms_id = boot_args["direct"]["phoneNumberVerification"]["trustedPhoneNumber"]["id"]
            except KeyError as e:
                logger.debug(match.group(1).strip())
                logger.error("Key for sms id not found. Using the first phone number")
        else:
            logger.debug(auth.text)
            logger.error("Script for sms id not found. Using the first phone number")

        logger.info(f"Using phone with id {sms_id} for SMS2FA")

    return headers, sms_id


def submit_sms_code(headers, sms_id, code):
    body = {"phoneNumber": {"id": sms_id}, "mode": "sms", "securityCode": {"code": code}}

    # Send the 2FA code to Apple
    with requests.post(
            "https://gsa.apple.com/auth/verify/phone/securitycode",
            json=body,
            headers=headers,
            verify=False,
            timeout=5,
    ) as resp:
        resp.raise_for_status()

    response = f"HTTP-Code: {resp.status_code} with {len(resp.text)} bytes"
    logger.debug(response)
    header_string = "Headers:\n"
    for header, value in resp.headers.items():
        header_string += f"{header}: {value}\n"
    logger.debug(header_string)
    # Headers does not include Apple DSID, 2FA failed
    if resp.ok and "X-Apple-DSID" in resp.headers:
        logger.info("2FA successful")
    else:
        raise AppleAuthError("invalid_code")


def sms_second_factor(dsid, idms_token):
    headers, sms_id = request_sms_code(dsid, idms_token)

    # Prompt for the 2FA code. It's just a string like '123456', no dashes or spaces
    code = _prompt_for_code(
        f"Enter SMS 2FA code (If you do not receive a code, wait {WAITING_TIME}s and press Enter. An attempt will be made to request the SMS in another way.): ",
        lambda: request_code(headers, sms_id),
    )

    submit_sms_code(headers, sms_id, code)
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd endpoint && python -m pytest tests/test_gsa_2fa_dispatch.py -v`
Expected: PASS — all tests in the file, old and new.

- [ ] **Step 5: Run the full suite**

Run: `cd endpoint && python -m pytest tests/ -v`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add endpoint/register/pypush_gsa_icloud.py endpoint/tests/test_gsa_2fa_dispatch.py
git commit -m "refactor: split SMS 2FA into trigger/submit primitives"
```

---

### Task 4: Add a uniform 2FA request/submit dispatch pair for the HTTP flow

**Files:**
- Modify: `endpoint/register/pypush_gsa_icloud.py`
- Test: `endpoint/tests/test_gsa_2fa_dispatch.py`

**Interfaces:**
- Consumes: `request_trusted_device_code`/`submit_trusted_device_code`
  (Task 2), `request_sms_code`/`submit_sms_code` (Task 3),
  `AppleAuthError` (Task 1).
- Produces (used by Tasks 5-6, `mh_endpoint.py`):
  - `request_second_factor_code(method: str, dsid: str, idms_token: str) ->
    dict` — dispatches to the right trigger function and returns an opaque
    state dict to pass to `submit_second_factor_code`: `{"headers": dict}`
    for `"trustedDeviceSecondaryAuth"`, `{"headers": dict, "sms_id": int}`
    for `"secondaryAuth"`. Raises `AppleAuthError` for an unrecognized
    method.
  - `submit_second_factor_code(method: str, state: dict, code: str) ->
    None` — dispatches to the right submit function using `state`. Raises
    `AppleAuthError` for an unrecognized method (and propagates whatever
    the underlying submit function raises).

This mirrors the existing `_dispatch_second_factor` pattern (same file)
one level up, at the request/submit granularity the HTTP handlers need
instead of the blocking-function granularity the CLI needs.

- [ ] **Step 1: Write the failing tests**

Add to `endpoint/tests/test_gsa_2fa_dispatch.py`:

```python
def test_request_second_factor_code_dispatches_trusted_device():
    with patch.object(gsa, "request_trusted_device_code", return_value={"h": "1"}) as mock_req:
        state = gsa.request_second_factor_code("trustedDeviceSecondaryAuth", "d-1", "t-1")

    mock_req.assert_called_once_with("d-1", "t-1")
    assert state == {"headers": {"h": "1"}}


def test_request_second_factor_code_dispatches_sms():
    with patch.object(gsa, "request_sms_code", return_value=({"h": "1"}, 7)) as mock_req:
        state = gsa.request_second_factor_code("secondaryAuth", "d-1", "t-1")

    mock_req.assert_called_once_with("d-1", "t-1")
    assert state == {"headers": {"h": "1"}, "sms_id": 7}


def test_request_second_factor_code_raises_for_unknown_method():
    with pytest.raises(gsa.AppleAuthError):
        gsa.request_second_factor_code("somethingElse", "d-1", "t-1")


def test_submit_second_factor_code_dispatches_trusted_device():
    with patch.object(gsa, "submit_trusted_device_code") as mock_submit:
        gsa.submit_second_factor_code("trustedDeviceSecondaryAuth", {"headers": {"h": "1"}}, "654321")

    mock_submit.assert_called_once_with({"h": "1"}, "654321")


def test_submit_second_factor_code_dispatches_sms():
    with patch.object(gsa, "submit_sms_code") as mock_submit:
        gsa.submit_second_factor_code("secondaryAuth", {"headers": {"h": "1"}, "sms_id": 7}, "654321")

    mock_submit.assert_called_once_with({"h": "1"}, 7, "654321")


def test_submit_second_factor_code_raises_for_unknown_method():
    with pytest.raises(gsa.AppleAuthError):
        gsa.submit_second_factor_code("somethingElse", {}, "654321")
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd endpoint && python -m pytest tests/test_gsa_2fa_dispatch.py -v -k second_factor_code`
Expected: FAIL with `AttributeError: module 'register.pypush_gsa_icloud'
has no attribute 'request_second_factor_code'`

- [ ] **Step 3: Implement**

Add to `endpoint/register/pypush_gsa_icloud.py`, after
`submit_trusted_device_code`/`submit_sms_code` are defined:

```python
def request_second_factor_code(method, dsid, idms_token):
    if method == "trustedDeviceSecondaryAuth":
        headers = request_trusted_device_code(dsid, idms_token)
        return {"headers": headers}
    elif method == "secondaryAuth":
        headers, sms_id = request_sms_code(dsid, idms_token)
        return {"headers": headers, "sms_id": sms_id}
    else:
        raise AppleAuthError(f"unknown_auth_value:{method}")


def submit_second_factor_code(method, state, code):
    if method == "trustedDeviceSecondaryAuth":
        submit_trusted_device_code(state["headers"], code)
    elif method == "secondaryAuth":
        submit_sms_code(state["headers"], state["sms_id"], code)
    else:
        raise AppleAuthError(f"unknown_auth_value:{method}")
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd endpoint && python -m pytest tests/test_gsa_2fa_dispatch.py -v`
Expected: PASS — all tests in the file.

- [ ] **Step 5: Run the full suite**

Run: `cd endpoint && python -m pytest tests/ -v`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add endpoint/register/pypush_gsa_icloud.py endpoint/tests/test_gsa_2fa_dispatch.py
git commit -m "feat: add uniform 2FA request/submit dispatch for HTTP login flow"
```

---

### Task 5: `POST /auth/apple/login` route

**Files:**
- Modify: `endpoint/mh_endpoint.py`
- Test: `endpoint/tests/test_mh_endpoint_apple_auth.py`

**Interfaces:**
- Consumes: `pypush_gsa_icloud.gsa_authenticate`, `.NeedsSecondFactor`,
  `.AppleAuthError`, `.request_second_factor_code`, `.register_mobileme`
  (Tasks 1 and 4).
- Produces (used by Task 6):
  - `@dataclass class PendingAppleLogin: method: str; state: dict;
    username: str; password: str; started_at: float` — module-level in
    `mh_endpoint.py`.
  - Module globals: `pending_apple_login: PendingAppleLogin | None`
    (starts `None`), `apple_session_stale: bool` (starts `False`),
    `PENDING_LOGIN_TIMEOUT_SECONDS = 600`.
  - `ServerHandler._send_json(self, status: int, body: dict) -> None` — a
    small helper (response + CORS headers + JSON body) used by all three
    new routes, added to cut down repetition across them.
  - `_complete_apple_login(g: dict, username: str) -> None` (module-level
    function) — registers the device via `register_mobileme`, writes
    `auth.json`, clears `apple_session_stale`. Raises `AppleAuthError` on a
    bad account status, propagates a `requests` exception on a network
    failure. Used again by Task 6's verify route.
  - `_SECOND_FACTOR_METHOD_NAMES: dict[str, str]` — maps Apple's raw `au`
    values (`"trustedDeviceSecondaryAuth"`, `"secondaryAuth"`, the values
    `PendingAppleLogin.method` and every `pypush_gsa_icloud` function from
    Tasks 1-4 use internally) to the wire-friendly names the spec commits
    to in the JSON response (`"trusted_device"`, `"sms"`). Only the JSON
    response is translated — `PendingAppleLogin.method` keeps the raw
    Apple value, since that's what `submit_second_factor_code` (Task 4)
    expects in Task 6.

- [ ] **Step 1: Write the failing tests**

Create `endpoint/tests/test_mh_endpoint_apple_auth.py` (this replaces the
one-test version from Task 1 — keep that test, add these):

```python
import json
import threading
from http.client import HTTPConnection
from http.server import HTTPServer
from unittest.mock import patch

import pytest
import requests

import mh_config
import mh_endpoint


@pytest.fixture
def server(tmp_path, monkeypatch):
    monkeypatch.setattr(mh_config, "getConfigFile", lambda: str(tmp_path / "auth.json"))
    mh_endpoint.pending_apple_login = None
    mh_endpoint.apple_session_stale = False

    httpd = HTTPServer(('127.0.0.1', 0), mh_endpoint.ServerHandler)
    thread = threading.Thread(target=httpd.serve_forever, daemon=True)
    thread.start()
    try:
        yield httpd
    finally:
        httpd.shutdown()
        thread.join()
        mh_endpoint.pending_apple_login = None
        mh_endpoint.apple_session_stale = False


def _post(server, path, body):
    conn = HTTPConnection('127.0.0.1', server.server_port)
    conn.request('POST', path, body=json.dumps(body), headers={'Content-Type': 'application/json'})
    response = conn.getresponse()
    data = response.read()
    conn.close()
    return response.status, json.loads(data) if data else None


def _get(server, path):
    conn = HTTPConnection('127.0.0.1', server.server_port)
    conn.request('GET', path)
    response = conn.getresponse()
    data = response.read()
    conn.close()
    return response.status, json.loads(data) if data else None


def test_get_auth_regenerates_using_configured_user_and_pass(tmp_path, monkeypatch):
    monkeypatch.setattr(mh_config, "getConfigFile", lambda: str(tmp_path / "auth.json"))
    monkeypatch.setattr(mh_config, "getUser", lambda: "user@example.com")
    monkeypatch.setattr(mh_config, "getPass", lambda: "hunter2")

    with patch.object(
        mh_endpoint.pypush_gsa_icloud, "icloud_login_mobileme",
        return_value={"dsid": "dsid-1", "searchPartyToken": "spt-1"},
    ) as mock_login:
        dsid, token = mh_endpoint.getAuth(regenerate=True)

    mock_login.assert_called_once_with(username="user@example.com", password="hunter2")
    assert (dsid, token) == ("dsid-1", "spt-1")


def test_complete_apple_login_writes_auth_json_and_clears_stale_flag(tmp_path, monkeypatch):
    monkeypatch.setattr(mh_config, "getConfigFile", lambda: str(tmp_path / "auth.json"))
    mh_endpoint.apple_session_stale = True

    with patch.object(mh_endpoint.pypush_gsa_icloud, "register_mobileme",
                       return_value={"dsid": "d-1", "searchPartyToken": "spt-1"}):
        mh_endpoint._complete_apple_login({"adsid": "a-1"}, "user@example.com")

    with open(tmp_path / "auth.json") as f:
        assert json.load(f) == {"dsid": "d-1", "searchPartyToken": "spt-1"}
    assert mh_endpoint.apple_session_stale is False


def test_post_apple_login_authenticates_immediately_when_no_second_factor(server):
    with patch.object(mh_endpoint.pypush_gsa_icloud, "gsa_authenticate", return_value={"adsid": "a-1"}), \
            patch.object(mh_endpoint, "_complete_apple_login") as mock_complete:
        status, body = _post(server, '/auth/apple/login', {"username": "user@example.com", "password": "hunter2"})

    assert status == 200
    assert body == {"status": "authenticated"}
    mock_complete.assert_called_once_with({"adsid": "a-1"}, "user@example.com")
    assert mh_endpoint.pending_apple_login is None


def test_post_apple_login_returns_code_required_for_second_factor(server):
    needs_2fa = mh_endpoint.pypush_gsa_icloud.NeedsSecondFactor(
        method="secondaryAuth", dsid="d-1", idms_token="t-1")
    with patch.object(mh_endpoint.pypush_gsa_icloud, "gsa_authenticate", return_value=needs_2fa), \
            patch.object(mh_endpoint.pypush_gsa_icloud, "request_second_factor_code",
                          return_value={"headers": {}, "sms_id": 7}) as mock_request:
        status, body = _post(server, '/auth/apple/login', {"username": "user@example.com", "password": "hunter2"})

    assert status == 200
    assert body == {"status": "code_required", "method": "sms"}
    mock_request.assert_called_once_with("secondaryAuth", "d-1", "t-1")
    assert mh_endpoint.pending_apple_login.method == "secondaryAuth"
    assert mh_endpoint.pending_apple_login.username == "user@example.com"
    assert mh_endpoint.pending_apple_login.password == "hunter2"


def test_post_apple_login_returns_401_on_bad_credentials(server):
    with patch.object(mh_endpoint.pypush_gsa_icloud, "gsa_authenticate",
                       side_effect=mh_endpoint.pypush_gsa_icloud.AppleAuthError("invalid_credentials")):
        status, body = _post(server, '/auth/apple/login', {"username": "user@example.com", "password": "wrong"})

    assert status == 401
    assert body == {"error": "invalid_credentials"}
    assert mh_endpoint.pending_apple_login is None


def test_post_apple_login_returns_400_when_fields_missing(server):
    status, body = _post(server, '/auth/apple/login', {"username": "user@example.com"})

    assert status == 400
    assert "error" in body


def test_post_apple_login_returns_502_when_apple_unreachable(server):
    with patch.object(mh_endpoint.pypush_gsa_icloud, "gsa_authenticate",
                       side_effect=requests.exceptions.ConnectTimeout()):
        status, body = _post(server, '/auth/apple/login', {"username": "user@example.com", "password": "hunter2"})

    assert status == 502
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd endpoint && python -m pytest tests/test_mh_endpoint_apple_auth.py -v`
Expected: FAIL — `404`/connection or `AttributeError:
'ServerHandler' object has no attribute '_send_json'` for the new route
tests (the `getAuth` and unrelated tests may already pass from Task 1;
that's fine).

- [ ] **Step 3: Implement**

In `endpoint/mh_endpoint.py`, add near the top imports:

```python
from dataclasses import dataclass
```

Add after the existing module globals (`history_store = None`,
`tracked_device_store = None`, `history_encryption_key = None`):

```python
PENDING_LOGIN_TIMEOUT_SECONDS = 600


@dataclass
class PendingAppleLogin:
    method: str
    state: dict
    username: str
    password: str
    started_at: float


pending_apple_login = None
apple_session_stale = False
```

Add a `_send_json` method to `ServerHandler`, right after `addCORSHeaders`:

```python
    def _send_json(self, status, body):
        self.send_response(status)
        self.addCORSHeaders()
        self.send_header('Content-type', 'application/json')
        self.end_headers()
        self.wfile.write(json.dumps(body).encode())
```

Add a `_handle_post_auth_apple_login` method to `ServerHandler`, right
after `_handle_post_history_devices`:

```python
    def _handle_post_auth_apple_login(self, body):
        global pending_apple_login

        try:
            username = body['username']
            password = body['password']
            if not isinstance(username, str) or not isinstance(password, str):
                raise TypeError("'username' and 'password' must be strings")
        except (KeyError, TypeError) as e:
            self._send_json(400, {"error": str(e)})
            return

        try:
            result = pypush_gsa_icloud.gsa_authenticate(username, password)
        except pypush_gsa_icloud.AppleAuthError:
            pending_apple_login = None
            self._send_json(401, {"error": "invalid_credentials"})
            return
        except requests.exceptions.RequestException:
            self._send_json(502, {"error": "apple_unreachable"})
            return

        if isinstance(result, pypush_gsa_icloud.NeedsSecondFactor):
            try:
                state = pypush_gsa_icloud.request_second_factor_code(
                    result.method, result.dsid, result.idms_token)
            except requests.exceptions.RequestException:
                self._send_json(502, {"error": "apple_unreachable"})
                return
            pending_apple_login = PendingAppleLogin(
                method=result.method, state=state, username=username, password=password,
                started_at=time.time(),
            )
            self._send_json(200, {
                "status": "code_required",
                "method": _SECOND_FACTOR_METHOD_NAMES[result.method],
            })
            return

        try:
            _complete_apple_login(result, username)
        except pypush_gsa_icloud.AppleAuthError as e:
            self._send_json(401, {"error": "account_error", "message": str(e)})
            return
        except requests.exceptions.RequestException:
            self._send_json(502, {"error": "apple_unreachable"})
            return

        pending_apple_login = None
        self._send_json(200, {"status": "authenticated"})
```

Add a module-level `_complete_apple_login` function, right after the
`ServerHandler` class definition ends (before `def getAuth(...)`):

```python
_SECOND_FACTOR_METHOD_NAMES = {
    "trustedDeviceSecondaryAuth": "trusted_device",
    "secondaryAuth": "sms",
}


def _complete_apple_login(g, username):
    """Finishes a successful GSA login: registers the device with mobileme
    and writes the resulting session to auth.json. Raises AppleAuthError on
    a bad account status, or a requests exception on a network failure."""
    global apple_session_stale
    j = pypush_gsa_icloud.register_mobileme(g, username)
    with open(mh_config.getConfigFile(), "w") as f:
        json.dump(j, f)
    apple_session_stale = False
```

Wire the route into `do_POST`, immediately after the existing
`/history/devices` block's `return` (right before the line
`logger.debug('Getting with post: ' + str(post_body))`):

```python
        if path == '/auth/apple/login':
            try:
                body = json.loads(post_body)
            except json.JSONDecodeError as e:
                self._send_json(400, {"error": str(e)})
                return
            self._handle_post_auth_apple_login(body)
            return
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd endpoint && python -m pytest tests/test_mh_endpoint_apple_auth.py -v`
Expected: PASS

- [ ] **Step 5: Run the full suite**

Run: `cd endpoint && python -m pytest tests/ -v`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add endpoint/mh_endpoint.py endpoint/tests/test_mh_endpoint_apple_auth.py
git commit -m "feat: add POST /auth/apple/login route"
```

---

### Task 6: `POST /auth/apple/verify` route

**Files:**
- Modify: `endpoint/mh_endpoint.py`
- Test: `endpoint/tests/test_mh_endpoint_apple_auth.py`

**Interfaces:**
- Consumes: `PendingAppleLogin`, `pending_apple_login`,
  `PENDING_LOGIN_TIMEOUT_SECONDS`, `_complete_apple_login`, `_send_json`
  (Task 5); `pypush_gsa_icloud.submit_second_factor_code`,
  `.gsa_authenticate`, `.NeedsSecondFactor`, `.AppleAuthError` (Tasks 1
  and 4).
- Produces: `ServerHandler._handle_post_auth_apple_verify(self, body)`,
  wired into `do_POST`. Nothing further depends on this beyond the routing
  in Task 7 (`GET /auth/apple/status` reads `pending_apple_login`, which
  already exists from Task 5).

Wrong-code detection differs by method: the SMS submit function raises
`AppleAuthError` directly on a bad code (Task 3). The trusted-device submit
function never does (Apple doesn't reliably signal it there - Task 2's
code comment) - a wrong trusted-device code shows up as `gsa_authenticate`
demanding *another* round of 2FA immediately after the code was submitted.
Both cases end the same way here: clear the pending state, respond
`401 invalid_code`.

- [ ] **Step 1: Write the failing tests**

Add to `endpoint/tests/test_mh_endpoint_apple_auth.py` (add `import time`
to its imports):

```python
def _set_pending(method="secondaryAuth", state=None, username="user@example.com",
                  password="hunter2", age_seconds=0):
    mh_endpoint.pending_apple_login = mh_endpoint.PendingAppleLogin(
        method=method, state=state or {"headers": {}, "sms_id": 7},
        username=username, password=password,
        started_at=time.time() - age_seconds,
    )


def test_post_apple_verify_returns_409_when_nothing_pending(server):
    status, body = _post(server, '/auth/apple/verify', {"code": "654321"})

    assert status == 409
    assert body == {"error": "no_pending_login"}


def test_post_apple_verify_returns_410_when_pending_login_expired(server):
    _set_pending(age_seconds=mh_endpoint.PENDING_LOGIN_TIMEOUT_SECONDS + 1)

    status, body = _post(server, '/auth/apple/verify', {"code": "654321"})

    assert status == 410
    assert body == {"error": "login_expired"}
    assert mh_endpoint.pending_apple_login is None


def test_post_apple_verify_returns_400_when_code_missing(server):
    _set_pending()

    status, body = _post(server, '/auth/apple/verify', {})

    assert status == 400
    assert mh_endpoint.pending_apple_login is not None


def test_post_apple_verify_returns_401_when_submit_rejects_code(server):
    _set_pending(method="secondaryAuth")

    with patch.object(mh_endpoint.pypush_gsa_icloud, "submit_second_factor_code",
                       side_effect=mh_endpoint.pypush_gsa_icloud.AppleAuthError("invalid_code")):
        status, body = _post(server, '/auth/apple/verify', {"code": "000000"})

    assert status == 401
    assert body == {"error": "invalid_code"}
    assert mh_endpoint.pending_apple_login is None


def test_post_apple_verify_returns_401_when_reauth_still_needs_second_factor(server):
    _set_pending(method="trustedDeviceSecondaryAuth", state={"headers": {}})
    needs_2fa_again = mh_endpoint.pypush_gsa_icloud.NeedsSecondFactor(
        method="trustedDeviceSecondaryAuth", dsid="d-1", idms_token="t-1")

    with patch.object(mh_endpoint.pypush_gsa_icloud, "submit_second_factor_code"), \
            patch.object(mh_endpoint.pypush_gsa_icloud, "gsa_authenticate", return_value=needs_2fa_again):
        status, body = _post(server, '/auth/apple/verify', {"code": "000000"})

    assert status == 401
    assert body == {"error": "invalid_code"}
    assert mh_endpoint.pending_apple_login is None


def test_post_apple_verify_authenticates_on_success(server):
    _set_pending()

    with patch.object(mh_endpoint.pypush_gsa_icloud, "submit_second_factor_code"), \
            patch.object(mh_endpoint.pypush_gsa_icloud, "gsa_authenticate", return_value={"adsid": "a-1"}), \
            patch.object(mh_endpoint.pypush_gsa_icloud, "register_mobileme",
                          return_value={"dsid": "d-1", "searchPartyToken": "spt-1"}):
        status, body = _post(server, '/auth/apple/verify', {"code": "654321"})

    assert status == 200
    assert body == {"status": "authenticated"}
    assert mh_endpoint.pending_apple_login is None


def test_post_apple_verify_keeps_pending_state_on_network_error(server):
    _set_pending()

    with patch.object(mh_endpoint.pypush_gsa_icloud, "submit_second_factor_code",
                       side_effect=requests.exceptions.ConnectTimeout()):
        status, body = _post(server, '/auth/apple/verify', {"code": "654321"})

    assert status == 502
    assert mh_endpoint.pending_apple_login is not None
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd endpoint && python -m pytest tests/test_mh_endpoint_apple_auth.py -v -k verify`
Expected: FAIL — every `/auth/apple/verify` request currently falls
through to the generic handler and returns something other than the
expected status (most will 500 or 400 from the unrelated fetch-reports
code path trying to read a `days`/`ids` body it doesn't have).

- [ ] **Step 3: Implement**

Add a `_handle_post_auth_apple_verify` method to `ServerHandler`, right
after `_handle_post_auth_apple_login`:

```python
    def _handle_post_auth_apple_verify(self, body):
        global pending_apple_login

        pending = pending_apple_login
        if pending is None:
            self._send_json(409, {"error": "no_pending_login"})
            return
        if time.time() - pending.started_at > PENDING_LOGIN_TIMEOUT_SECONDS:
            pending_apple_login = None
            self._send_json(410, {"error": "login_expired"})
            return

        try:
            code = body['code']
            if not isinstance(code, str):
                raise TypeError("'code' must be a string")
        except (KeyError, TypeError) as e:
            self._send_json(400, {"error": str(e)})
            return

        try:
            pypush_gsa_icloud.submit_second_factor_code(pending.method, pending.state, code)
        except pypush_gsa_icloud.AppleAuthError:
            pending_apple_login = None
            self._send_json(401, {"error": "invalid_code"})
            return
        except requests.exceptions.RequestException:
            self._send_json(502, {"error": "apple_unreachable"})
            return

        try:
            result = pypush_gsa_icloud.gsa_authenticate(pending.username, pending.password)
        except pypush_gsa_icloud.AppleAuthError:
            pending_apple_login = None
            self._send_json(401, {"error": "invalid_code"})
            return
        except requests.exceptions.RequestException:
            self._send_json(502, {"error": "apple_unreachable"})
            return

        if isinstance(result, pypush_gsa_icloud.NeedsSecondFactor):
            # The trusted-device flow doesn't signal a wrong code at submit
            # time (see submit_trusted_device_code) - Apple demanding
            # another round of 2FA immediately after is how a wrong code
            # shows up here instead.
            pending_apple_login = None
            self._send_json(401, {"error": "invalid_code"})
            return

        try:
            _complete_apple_login(result, pending.username)
        except pypush_gsa_icloud.AppleAuthError as e:
            pending_apple_login = None
            self._send_json(401, {"error": "account_error", "message": str(e)})
            return
        except requests.exceptions.RequestException:
            self._send_json(502, {"error": "apple_unreachable"})
            return

        pending_apple_login = None
        self._send_json(200, {"status": "authenticated"})
```

Wire the route into `do_POST`, immediately after the `/auth/apple/login`
block added in Task 5:

```python
        if path == '/auth/apple/verify':
            try:
                body = json.loads(post_body)
            except json.JSONDecodeError as e:
                self._send_json(400, {"error": str(e)})
                return
            self._handle_post_auth_apple_verify(body)
            return
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd endpoint && python -m pytest tests/test_mh_endpoint_apple_auth.py -v`
Expected: PASS

- [ ] **Step 5: Run the full suite**

Run: `cd endpoint && python -m pytest tests/ -v`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add endpoint/mh_endpoint.py endpoint/tests/test_mh_endpoint_apple_auth.py
git commit -m "feat: add POST /auth/apple/verify route"
```

---

### Task 7: `GET /auth/apple/status` route and stale-session detection

**Files:**
- Modify: `endpoint/mh_endpoint.py`
- Test: `endpoint/tests/test_mh_endpoint_apple_auth.py`

**Interfaces:**
- Consumes: `apple_session_stale`, `pending_apple_login`, `_send_json`
  (Task 5).
- Produces: `_raise_for_status_marking_stale(response) -> None`
  (module-level function — replaces the bare `response.raise_for_status()`
  call in both existing `fetch_from_apple` closures, re-raising whatever
  it raises so all existing error handling around those closures is
  unaffected); `ServerHandler._handle_get_auth_apple_status(self)`, wired
  into `do_GET`.

As the spec notes, `apple_session_stale` is in-memory only and resets to
`False` on a server restart even if `auth.json` is still the same stale
token — this is a deliberate simplification (the next fetch attempt
re-detects it within one poll interval), not something this task needs to
fix further.

- [ ] **Step 1: Write the failing tests**

Add to `endpoint/tests/test_mh_endpoint_apple_auth.py` (add `from
unittest.mock import MagicMock, patch` — extend the existing `patch`
import):

```python
def test_get_apple_status_reports_not_logged_in_when_no_auth_json(server):
    status, body = _get(server, '/auth/apple/status')

    assert status == 200
    assert body == {"loggedIn": False, "pending": False}


def test_get_apple_status_reports_logged_in_when_auth_json_exists(server, tmp_path):
    (tmp_path / "auth.json").write_text('{"dsid": "d-1", "searchPartyToken": "t-1"}')

    status, body = _get(server, '/auth/apple/status')

    assert status == 200
    assert body == {"loggedIn": True, "pending": False}


def test_get_apple_status_reports_not_logged_in_when_session_marked_stale(server, tmp_path):
    (tmp_path / "auth.json").write_text('{"dsid": "d-1", "searchPartyToken": "t-1"}')
    mh_endpoint.apple_session_stale = True

    status, body = _get(server, '/auth/apple/status')

    assert body == {"loggedIn": False, "pending": False}


def test_get_apple_status_reports_pending_during_login(server):
    _set_pending()

    status, body = _get(server, '/auth/apple/status')

    assert body["pending"] is True


def test_raise_for_status_marking_stale_sets_flag_on_401():
    mh_endpoint.apple_session_stale = False
    response = MagicMock()
    response.status_code = 401
    response.raise_for_status.side_effect = requests.exceptions.HTTPError("401")

    with pytest.raises(requests.exceptions.HTTPError):
        mh_endpoint._raise_for_status_marking_stale(response)

    assert mh_endpoint.apple_session_stale is True


def test_raise_for_status_marking_stale_leaves_flag_alone_on_server_error():
    mh_endpoint.apple_session_stale = False
    response = MagicMock()
    response.status_code = 500
    response.raise_for_status.side_effect = requests.exceptions.HTTPError("500")

    with pytest.raises(requests.exceptions.HTTPError):
        mh_endpoint._raise_for_status_marking_stale(response)

    assert mh_endpoint.apple_session_stale is False
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd endpoint && python -m pytest tests/test_mh_endpoint_apple_auth.py -v -k "apple_status or marking_stale"`
Expected: FAIL — `/auth/apple/status` isn't routed yet (falls through to
the generic 200 "Nothing to see here" handler, wrong body), and
`_raise_for_status_marking_stale` doesn't exist yet.

- [ ] **Step 3: Implement**

Add a module-level function to `endpoint/mh_endpoint.py`, near
`_complete_apple_login`:

```python
def _raise_for_status_marking_stale(response):
    global apple_session_stale
    try:
        response.raise_for_status()
    except requests.exceptions.HTTPError:
        if response.status_code in (401, 403):
            apple_session_stale = True
        raise
```

Replace `r.raise_for_status()` with `_raise_for_status_marking_stale(r)`
in **both** existing `fetch_from_apple` closures — the one inside
`do_POST` (around line 150) and the one inside the `if __name__ ==
"__main__":` block (around line 308). Both closures are otherwise
unchanged.

Add a `_handle_get_auth_apple_status` method to `ServerHandler`, right
after `_handle_post_auth_apple_verify`:

```python
    def _handle_get_auth_apple_status(self):
        logged_in = os.path.exists(mh_config.getConfigFile()) and not apple_session_stale
        self._send_json(200, {"loggedIn": logged_in, "pending": pending_apple_login is not None})
```

Wire the route into `do_GET`, immediately after the existing
`/history/devices` block's final `return` (right before the generic
`self.send_response(200)` / `b"Nothing to see here"` fallback):

```python
        if path == '/auth/apple/status':
            self._handle_get_auth_apple_status()
            return
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd endpoint && python -m pytest tests/test_mh_endpoint_apple_auth.py -v`
Expected: PASS

- [ ] **Step 5: Run the full suite**

Run: `cd endpoint && python -m pytest tests/ -v`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add endpoint/mh_endpoint.py endpoint/tests/test_mh_endpoint_apple_auth.py
git commit -m "feat: add GET /auth/apple/status route and stale-session detection"
```

---

### Task 8: Flutter `AppleAuthService`

**Files:**
- Create: `macless_haystack/lib/apple_auth/apple_auth_service.dart`
- Test: `macless_haystack/test/apple_auth/apple_auth_service_test.dart`

**Interfaces:**
- Consumes: the three routes' exact JSON shapes from Tasks 5-7 (`{"status":
  "authenticated"}`, `{"status": "code_required", "method": "sms" |
  "trusted_device"}`, `{"error": "..."}`, `{"loggedIn": bool, "pending":
  bool}`).
- Produces (used by Tasks 9-10):
  - `class AppleAuthHttpsRequiredException implements Exception` — thrown,
    with zero network calls made, when the endpoint URL isn't `https://`.
  - `class AppleAuthException implements Exception { final String
    errorCode; final String? message; }` — thrown when the server responds
    with a non-200 status and a JSON `error` field.
  - `enum AppleAuthMethod { sms, trustedDevice }`
  - `class AppleLoginResult { final bool authenticated; final
    AppleAuthMethod? codeRequiredMethod; }` with named constructors
    `.authenticated()` and `.codeRequired(AppleAuthMethod)`.
  - `class AppleAuthStatus { final bool loggedIn; final bool pending; }`
    with `AppleAuthStatus.fromJson(Map<String, dynamic>)`.
  - `AppleAuthService.login(String url, String endpointUser, String
    endpointPass, String appleUsername, String applePassword, {http.Client?
    client}) -> Future<AppleLoginResult>`
  - `AppleAuthService.verifyCode(String url, String endpointUser, String
    endpointPass, String code, {http.Client? client}) -> Future<void>`
  - `AppleAuthService.getStatus(String url, String endpointUser, String
    endpointPass, {http.Client? client}) -> Future<AppleAuthStatus>` — does
    **not** enforce HTTPS (the response carries no credential).

This mirrors `lib/history/history_archive_service.dart`'s shape exactly
(`_createClient`, `_authHeader`, the `{http.Client? client}` test seam).

- [ ] **Step 1: Write the failing tests**

Create `macless_haystack/test/apple_auth/apple_auth_service_test.dart`:

```dart
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:macless_haystack/apple_auth/apple_auth_service.dart';
import 'package:test/test.dart';

void main() {
  const httpsUrl = 'https://example.com';
  const httpUrl = 'http://localhost:6176';

  test('login throws AppleAuthHttpsRequiredException and makes no request over http', () async {
    var client = MockClient((request) async {
      fail('should not make a network request when the endpoint URL is not https');
    });

    expect(
      () => AppleAuthService.login(httpUrl, '', '', 'id@example.com', 'hunter2', client: client),
      throwsA(isA<AppleAuthHttpsRequiredException>()),
    );
  });

  test('verifyCode throws AppleAuthHttpsRequiredException and makes no request over http', () async {
    var client = MockClient((request) async {
      fail('should not make a network request when the endpoint URL is not https');
    });

    expect(
      () => AppleAuthService.verifyCode(httpUrl, '', '', '123456', client: client),
      throwsA(isA<AppleAuthHttpsRequiredException>()),
    );
  });

  test('login posts credentials and returns authenticated on immediate success', () async {
    Map<String, dynamic>? capturedBody;
    var client = MockClient((request) async {
      capturedBody = jsonDecode(request.body);
      expect(request.url.toString(), '$httpsUrl/auth/apple/login');
      expect(request.method, 'POST');
      return http.Response('{"status":"authenticated"}', 200);
    });

    var result = await AppleAuthService.login(httpsUrl, '', '', 'id@example.com', 'hunter2', client: client);

    expect(result.authenticated, true);
    expect(capturedBody, {'username': 'id@example.com', 'password': 'hunter2'});
  });

  test('login returns codeRequired with the parsed sms method', () async {
    var client = MockClient((request) async => http.Response('{"status":"code_required","method":"sms"}', 200));

    var result = await AppleAuthService.login(httpsUrl, '', '', 'id@example.com', 'hunter2', client: client);

    expect(result.authenticated, false);
    expect(result.codeRequiredMethod, AppleAuthMethod.sms);
  });

  test('login returns codeRequired with the parsed trusted_device method', () async {
    var client = MockClient(
        (request) async => http.Response('{"status":"code_required","method":"trusted_device"}', 200));

    var result = await AppleAuthService.login(httpsUrl, '', '', 'id@example.com', 'hunter2', client: client);

    expect(result.codeRequiredMethod, AppleAuthMethod.trustedDevice);
  });

  test('login throws AppleAuthException with the server error code on 401', () async {
    var client = MockClient((request) async => http.Response('{"error":"invalid_credentials"}', 401));

    expect(
      () => AppleAuthService.login(httpsUrl, '', '', 'id@example.com', 'wrong', client: client),
      throwsA(predicate((e) => e is AppleAuthException && e.errorCode == 'invalid_credentials')),
    );
  });

  test('verifyCode posts the code and sends a basic auth header', () async {
    Map<String, dynamic>? capturedBody;
    String? authHeader;
    var client = MockClient((request) async {
      capturedBody = jsonDecode(request.body);
      authHeader = request.headers['Authorization'];
      return http.Response('{"status":"authenticated"}', 200);
    });

    await AppleAuthService.verifyCode(httpsUrl, 'user', 'pass', '654321', client: client);

    expect(capturedBody, {'code': '654321'});
    expect(authHeader, 'Basic ${base64.encode(utf8.encode('user:pass'))}');
  });

  test('verifyCode throws AppleAuthException on an invalid code', () async {
    var client = MockClient((request) async => http.Response('{"error":"invalid_code"}', 401));

    expect(
      () => AppleAuthService.verifyCode(httpsUrl, '', '', '000000', client: client),
      throwsA(predicate((e) => e is AppleAuthException && e.errorCode == 'invalid_code')),
    );
  });

  test('getStatus parses loggedIn and pending', () async {
    var client = MockClient((request) async {
      expect(request.url.toString(), '$httpUrl/auth/apple/status');
      expect(request.method, 'GET');
      return http.Response('{"loggedIn":true,"pending":false}', 200);
    });

    var status = await AppleAuthService.getStatus(httpUrl, '', '', client: client);

    expect(status.loggedIn, true);
    expect(status.pending, false);
  });

  test('getStatus throws on a non-200 response', () async {
    var client = MockClient((request) async => http.Response('error', 500));

    expect(
      () => AppleAuthService.getStatus(httpUrl, '', '', client: client),
      throwsException,
    );
  });
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd macless_haystack && flutter test test/apple_auth/apple_auth_service_test.dart`
(or via the repo's `scripts/flutter-docker.sh test
test/apple_auth/apple_auth_service_test.dart` if no local Flutter SDK is
available)
Expected: FAIL — `Error: Not found: 'package:macless_haystack/apple_auth/apple_auth_service.dart'`

- [ ] **Step 3: Implement**

Create `macless_haystack/lib/apple_auth/apple_auth_service.dart`:

```dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

/// Thrown when a call requires an https:// endpoint URL but the configured
/// one isn't - no request is ever sent in that case.
class AppleAuthHttpsRequiredException implements Exception {
  const AppleAuthHttpsRequiredException();

  @override
  String toString() =>
      'In-app Apple ID login requires an https:// endpoint URL.';
}

/// Thrown when the server rejects a login/verify attempt, carrying the
/// server's own error code (e.g. "invalid_credentials", "invalid_code").
class AppleAuthException implements Exception {
  final String errorCode;
  final String? message;

  const AppleAuthException(this.errorCode, [this.message]);

  @override
  String toString() => message ?? errorCode;
}

enum AppleAuthMethod { sms, trustedDevice }

AppleAuthMethod _parseMethod(String method) {
  switch (method) {
    case 'sms':
      return AppleAuthMethod.sms;
    case 'trusted_device':
      return AppleAuthMethod.trustedDevice;
    default:
      throw AppleAuthException('unknown_method', 'Unrecognized 2FA method: $method');
  }
}

class AppleLoginResult {
  final bool authenticated;
  final AppleAuthMethod? codeRequiredMethod;

  const AppleLoginResult.authenticated()
      : authenticated = true,
        codeRequiredMethod = null;

  const AppleLoginResult.codeRequired(this.codeRequiredMethod) : authenticated = false;
}

class AppleAuthStatus {
  final bool loggedIn;
  final bool pending;

  const AppleAuthStatus({required this.loggedIn, required this.pending});

  static AppleAuthStatus fromJson(Map<String, dynamic> json) {
    return AppleAuthStatus(
      loggedIn: json['loggedIn'] == true,
      pending: json['pending'] == true,
    );
  }
}

/// Drives the server's Apple ID login flow (`/auth/apple/login`,
/// `/auth/apple/verify`, `/auth/apple/status`).
class AppleAuthService {
  static http.Client _createClient() {
    if (kIsWeb) {
      return http.Client();
    }
    var ioClient = HttpClient();
    ioClient.badCertificateCallback = (X509Certificate cert, String host, int port) => true;
    return IOClient(ioClient);
  }

  static String? _authHeader(String user, String pass) {
    if (user.trim().isNotEmpty || pass.trim().isNotEmpty) {
      return 'Basic ${base64.encode(utf8.encode("$user:$pass"))}';
    }
    return null;
  }

  static void _requireHttps(String url) {
    if (Uri.parse(url).scheme != 'https') {
      throw const AppleAuthHttpsRequiredException();
    }
  }

  static Future<Map<String, dynamic>> _post(
      String url, String path, String user, String pass, Map<String, dynamic> body,
      {http.Client? client}) async {
    var effectiveClient = client ?? _createClient();
    try {
      var authHeader = _authHeader(user, pass);
      var headers = {
        "Content-Type": "application/json",
        if (authHeader != null) "Authorization": authHeader,
      };
      var response =
          await effectiveClient.post(Uri.parse('$url$path'), headers: headers, body: jsonEncode(body));
      var decoded =
          response.body.isEmpty ? <String, dynamic>{} : jsonDecode(response.body) as Map<String, dynamic>;
      if (response.statusCode != 200) {
        throw AppleAuthException((decoded['error'] as String?) ?? 'request_failed', decoded['message']);
      }
      return decoded;
    } finally {
      if (client == null) {
        effectiveClient.close();
      }
    }
  }

  /// Starts an Apple ID login. Throws [AppleAuthHttpsRequiredException]
  /// without making any request if [url] isn't https. Throws
  /// [AppleAuthException] with the server's error code on failure.
  static Future<AppleLoginResult> login(
      String url, String endpointUser, String endpointPass, String appleUsername, String applePassword,
      {http.Client? client}) async {
    _requireHttps(url);
    var decoded = await _post(url, '/auth/apple/login', endpointUser, endpointPass, {
      'username': appleUsername,
      'password': applePassword,
    }, client: client);

    if (decoded['status'] == 'authenticated') {
      return const AppleLoginResult.authenticated();
    }
    return AppleLoginResult.codeRequired(_parseMethod(decoded['method']));
  }

  /// Submits a 2FA code for a login started with [login]. Same HTTPS and
  /// error-handling rules as [login].
  static Future<void> verifyCode(String url, String endpointUser, String endpointPass, String code,
      {http.Client? client}) async {
    _requireHttps(url);
    await _post(url, '/auth/apple/verify', endpointUser, endpointPass, {'code': code}, client: client);
  }

  /// Fetches whether the server currently has a valid Apple session, and
  /// whether a login is mid-flow. Does not enforce HTTPS - the response
  /// carries no credential.
  static Future<AppleAuthStatus> getStatus(String url, String endpointUser, String endpointPass,
      {http.Client? client}) async {
    var effectiveClient = client ?? _createClient();
    try {
      var authHeader = _authHeader(endpointUser, endpointPass);
      var headers = {if (authHeader != null) "Authorization": authHeader};
      var response = await effectiveClient.get(Uri.parse('$url/auth/apple/status'), headers: headers);
      if (response.statusCode != 200) {
        throw Exception('Apple auth status request failed with status code ${response.statusCode}');
      }
      return AppleAuthStatus.fromJson(jsonDecode(response.body));
    } finally {
      if (client == null) {
        effectiveClient.close();
      }
    }
  }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd macless_haystack && flutter test test/apple_auth/apple_auth_service_test.dart`
Expected: PASS

- [ ] **Step 5: Run the full Flutter test suite and analyzer**

Run: `cd macless_haystack && flutter test && flutter analyze`
Expected: PASS, no new analyzer warnings.

- [ ] **Step 6: Commit**

```bash
git add macless_haystack/lib/apple_auth/apple_auth_service.dart \
        macless_haystack/test/apple_auth/apple_auth_service_test.dart
git commit -m "feat: add AppleAuthService for the in-app login flow"
```

---

### Task 9: Apple ID login wizard screen

**Files:**
- Create: `macless_haystack/lib/apple_auth/apple_auth_page.dart`

**Interfaces:**
- Consumes: `AppleAuthService.login`/`.verifyCode`,
  `AppleAuthHttpsRequiredException`, `AppleAuthException`, `AppleAuthMethod`
  (Task 8).
- Produces: `class AppleAuthPage extends StatefulWidget` — constructor
  `AppleAuthPage({super.key, required String endpointUrl, required String
  endpointUser, required String endpointPass})`. Pops with `true` via
  `Navigator.of(context).pop(true)` on a successful login, so a caller can
  refresh its own status display; pops with nothing (back button) on
  cancel. Used by Task 10.

Per the Global Constraints, this widget has no automated test — this task
is code-review-only; manual, end-to-end verification happens in Task 10
once there's a way to actually navigate to this screen.

- [ ] **Step 1: Implement**

Create `macless_haystack/lib/apple_auth/apple_auth_page.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:macless_haystack/apple_auth/apple_auth_service.dart';

/// Login wizard for the server's Apple ID session: username/password,
/// then (if Apple requires it) a 2FA code. Pops `true` on success so the
/// caller can refresh its own status display.
class AppleAuthPage extends StatefulWidget {
  final String endpointUrl;
  final String endpointUser;
  final String endpointPass;

  const AppleAuthPage({
    super.key,
    required this.endpointUrl,
    required this.endpointUser,
    required this.endpointPass,
  });

  @override
  State<AppleAuthPage> createState() => _AppleAuthPageState();
}

enum _AppleAuthStep { credentials, code }

class _AppleAuthPageState extends State<AppleAuthPage> {
  final _formKey = GlobalKey<FormState>();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _codeController = TextEditingController();

  _AppleAuthStep _step = _AppleAuthStep.credentials;
  AppleAuthMethod? _method;
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  String _describeError(Object e) {
    if (e is AppleAuthHttpsRequiredException) {
      return e.toString();
    }
    if (e is AppleAuthException) {
      switch (e.errorCode) {
        case 'invalid_credentials':
          return 'Incorrect Apple ID or password.';
        case 'invalid_code':
          return 'Incorrect code. Please log in again.';
        case 'no_pending_login':
        case 'login_expired':
          return 'This login attempt expired. Please log in again.';
        case 'apple_unreachable':
          return "Couldn't reach Apple. Please try again.";
        case 'account_error':
          return e.message ?? 'Apple rejected this account.';
        default:
          return e.message ?? 'Login failed.';
      }
    }
    return 'Login failed: $e';
  }

  Future<void> _submitCredentials() async {
    if (_formKey.currentState?.validate() != true) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      var result = await AppleAuthService.login(
        widget.endpointUrl, widget.endpointUser, widget.endpointPass,
        _usernameController.text.trim(), _passwordController.text,
      );
      if (!mounted) return;
      if (result.authenticated) {
        Navigator.of(context).pop(true);
        return;
      }
      setState(() {
        _step = _AppleAuthStep.code;
        _method = result.codeRequiredMethod;
        _submitting = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = _describeError(e);
        _submitting = false;
      });
    }
  }

  Future<void> _submitCode() async {
    if (_codeController.text.trim().isEmpty) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await AppleAuthService.verifyCode(
        widget.endpointUrl, widget.endpointUser, widget.endpointPass,
        _codeController.text.trim(),
      );
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        // A wrong/expired code, or a dropped pending login, both require
        // starting over from the username/password step (per the design:
        // no retry-the-same-code loop).
        _step = _AppleAuthStep.credentials;
        _error = _describeError(e);
        _submitting = false;
      });
    }
  }

  String _methodLabel() {
    return _method == AppleAuthMethod.trustedDevice
        ? 'Enter the code shown on your trusted device'
        : 'Enter the SMS code sent to your phone';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Log in to Apple ID')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: _step == _AppleAuthStep.credentials
            ? Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (_error != null) ...[
                      Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                      const SizedBox(height: 8),
                    ],
                    TextFormField(
                      controller: _usernameController,
                      decoration: const InputDecoration(labelText: 'Apple ID'),
                      keyboardType: TextInputType.emailAddress,
                      validator: (v) => (v == null || v.trim().isEmpty) ? 'Enter your Apple ID' : null,
                    ),
                    TextFormField(
                      controller: _passwordController,
                      decoration: const InputDecoration(labelText: 'Password'),
                      obscureText: true,
                      validator: (v) => (v == null || v.isEmpty) ? 'Enter your password' : null,
                    ),
                    const SizedBox(height: 16),
                    ElevatedButton(
                      onPressed: _submitting ? null : _submitCredentials,
                      child: _submitting
                          ? const SizedBox(
                              height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Text('Log in'),
                    ),
                  ],
                ),
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_error != null) ...[
                    Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                    const SizedBox(height: 8),
                  ],
                  Text(_methodLabel()),
                  TextField(
                    controller: _codeController,
                    decoration: const InputDecoration(labelText: '2FA code'),
                    keyboardType: TextInputType.number,
                  ),
                  const SizedBox(height: 16),
                  ElevatedButton(
                    onPressed: _submitting ? null : _submitCode,
                    child: _submitting
                        ? const SizedBox(
                            height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Text('Submit code'),
                  ),
                ],
              ),
      ),
    );
  }
}
```

- [ ] **Step 2: Confirm the app still builds**

Run: `cd macless_haystack && flutter analyze`
Expected: PASS, no new analyzer warnings (this file isn't reachable from
any screen yet, so this step only confirms it compiles cleanly).

- [ ] **Step 3: Commit**

```bash
git add macless_haystack/lib/apple_auth/apple_auth_page.dart
git commit -m "feat: add Apple ID login wizard screen"
```

---

### Task 10: Wire the opt-in switch and status into Preferences

**Files:**
- Modify: `macless_haystack/lib/preferences/user_preferences_model.dart`
- Modify: `macless_haystack/lib/preferences/preferences_page.dart`

**Interfaces:**
- Consumes: `AppleAuthPage` (Task 9), `AppleAuthService.getStatus`,
  `AppleAuthStatus` (Task 8), the existing `endpointUrl`/`endpointUser`/
  `endpointPass` settings keys and `Settings.getValue` pattern already used
  by `_loadArchivingStatus()` in this same file.
- Produces: `const String appleAuthEnabledKey = 'APPLE_AUTH_ENABLED'` in
  `user_preferences_model.dart`. Nothing further depends on this — it's
  the last task in the plan.

Per the Global Constraints, this is manual-test only.

- [ ] **Step 1: Implement**

In `macless_haystack/lib/preferences/user_preferences_model.dart`, add
next to the other setting keys:

```dart
const String appleAuthEnabledKey = 'APPLE_AUTH_ENABLED';
```

In `macless_haystack/lib/preferences/preferences_page.dart`, add imports:

```dart
import 'package:macless_haystack/apple_auth/apple_auth_page.dart';
import 'package:macless_haystack/apple_auth/apple_auth_service.dart';
```

Add two fields to `_PreferencesPageState`, alongside the existing
`_archivingLoading`/`_archivingAllEnabled` fields:

```dart
  bool _appleAuthEnabled = false;
  bool _appleAuthStatusLoading = false;
  AppleAuthStatus? _appleAuthStatus;
```

Extend `initState` (currently just `_loadArchivingStatus()`):

```dart
  @override
  void initState() {
    super.initState();
    _loadArchivingStatus();
    _appleAuthEnabled = Settings.getValue<bool>(appleAuthEnabledKey, defaultValue: false) ?? false;
    if (_appleAuthEnabled) {
      _loadAppleAuthStatus();
    }
  }
```

Add these methods, near `_loadArchivingStatus`:

```dart
  Future<void> _loadAppleAuthStatus() async {
    setState(() => _appleAuthStatusLoading = true);
    try {
      var url = Settings.getValue<String>(endpointUrl, defaultValue: 'http://localhost:6176')!;
      var user = Settings.getValue<String>(endpointUser, defaultValue: '')!;
      var pass = Settings.getValue<String>(endpointPass, defaultValue: '')!;
      var status = await AppleAuthService.getStatus(url, user, pass);
      if (mounted) {
        setState(() {
          _appleAuthStatus = status;
          _appleAuthStatusLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _appleAuthStatus = null;
          _appleAuthStatusLoading = false;
        });
      }
    }
  }

  String _appleAuthStatusLabel() {
    if (_appleAuthStatusLoading) return 'Checking status…';
    var status = _appleAuthStatus;
    if (status == null) return 'Could not reach the endpoint';
    if (status.pending) return 'Login in progress';
    return status.loggedIn ? 'Logged in' : 'Needs re-login';
  }

  Widget getAppleAuthTile() {
    return SwitchSettingsTile(
      settingKey: appleAuthEnabledKey,
      defaultValue: false,
      title: 'Enable in-app Apple ID login',
      activeColor: Theme.of(context).colorScheme.onPrimary,
      onChange: (enabled) {
        setState(() => _appleAuthEnabled = enabled);
        if (enabled) {
          _loadAppleAuthStatus();
        }
      },
    );
  }

  Widget getAppleAuthAccountTile() {
    return ListTile(
      title: const Text('Apple Account'),
      subtitle: Text(_appleAuthStatusLabel()),
      trailing: const Icon(Icons.chevron_right),
      onTap: () async {
        var url = Settings.getValue<String>(endpointUrl, defaultValue: 'http://localhost:6176')!;
        var user = Settings.getValue<String>(endpointUser, defaultValue: '')!;
        var pass = Settings.getValue<String>(endpointPass, defaultValue: '')!;
        var loggedIn = await Navigator.of(context).push<bool>(
          MaterialPageRoute(
            builder: (context) => AppleAuthPage(endpointUrl: url, endpointUser: user, endpointPass: pass),
          ),
        );
        if (loggedIn == true) {
          _loadAppleAuthStatus();
        }
      },
    );
  }
```

Add the two tiles to `build`'s `Column` children, right after
`getPassTile()` and before `getNumberofDaysTile()`:

```dart
            getPassTile(),
            getAppleAuthTile(),
            if (_appleAuthEnabled) getAppleAuthAccountTile(),
            getNumberofDaysTile(),
```

- [ ] **Step 2: Confirm the app builds and the existing suite still passes**

Run: `cd macless_haystack && flutter analyze && flutter test`
Expected: PASS, no new analyzer warnings.

- [ ] **Step 3: Manual verification**

Run the app against a real (or locally running) `mh_endpoint.py` instance
reachable over HTTPS:

1. Open Preferences. Confirm "Enable in-app Apple ID login" is off and no
   "Apple Account" row is shown.
2. Toggle it on. Confirm an "Apple Account" row appears, briefly reading
   "Checking status…" then settling on "Needs re-login" (assuming the
   server has no `auth.json` yet) or "Logged in" (if it does).
3. Tap "Apple Account". Enter a real Apple ID and password. Confirm either
   immediate success (rare) or a 2FA code field appears labelled correctly
   for whichever method Apple actually required.
4. Enter the code. Confirm the screen pops back to Preferences and the
   status line updates to "Logged in".
5. Set the endpoint URL (in the existing "URL to Macless Haystack
   endpoint" field) to an `http://` address, then repeat step 3. Confirm
   the login attempt fails immediately with the HTTPS-required message and
   no request appears in the server's logs at all.
6. Toggle the switch back off. Confirm the "Apple Account" row disappears.

- [ ] **Step 4: Commit**

```bash
git add macless_haystack/lib/preferences/user_preferences_model.dart \
        macless_haystack/lib/preferences/preferences_page.dart
git commit -m "feat: wire in-app Apple ID login into Preferences"
```

---

## Plan self-review

**Spec coverage:** the bug fix (Task 1), the non-blocking GSA/2FA split
(Tasks 1-4), all three HTTP routes and stale-session detection (Tasks
5-7), the Flutter service with its HTTPS guard (Task 8), the login screen
(Task 9), and the opt-in switch plus status display (Task 10) all have a
task. The spec's Non-goals (no automatic re-login, no server-side TLS
setup, CLI script unchanged) are respected — nothing in this plan
contradicts them.

**Placeholder scan:** no TBD/TODO; every step has complete, runnable code.

**Type/interface consistency:** `method` on the wire is `"sms"` /
`"trusted_device"` everywhere it crosses the HTTP boundary (fixed during
this review — Tasks 5-6's server code and Task 8's Flutter parsing now
agree); internally, every `pypush_gsa_icloud` function and
`PendingAppleLogin.method` consistently use Apple's raw `au` values
(`"trustedDeviceSecondaryAuth"` / `"secondaryAuth"`) end to end through
Tasks 1-7. `AppleLoginResult`/`AppleAuthStatus`/`AppleAuthException` are
defined once (Task 8) and consumed as-is by Tasks 9-10 without
re-declaration.

## Execution options

**1. Subagent-Driven (recommended)** — I dispatch a fresh subagent per
task, review between tasks, fast iteration.

**2. Inline Execution** — Execute tasks in this session using
executing-plans, batch execution with checkpoints.

Which approach?
