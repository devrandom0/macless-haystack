# In-App Apple ID Authentication — Design

## Motivation

Today, logging the server into Apple (needed for the `searchPartyToken` that
lets it fetch tracker locations) is an interactive terminal flow: SSH into
the server host, attach to the running container's stdin/tty, and answer
Apple's SRP login and 2FA (SMS or trusted-device code) at a shell prompt
(`endpoint/register/apple_cryptography.py`'s `registerDevice()` →
`pypush_gsa_icloud.py`'s `gsa_authenticate()`, which blocks on `input()`/
`getpass()`). This only runs once at container startup, when
`endpoint/data/auth.json` doesn't yet exist — but if that session ever needs
to be redone, it's back to SSH.

This feature lets the app itself drive that login, including 2FA, as an
**opt-in** feature — the app can also detect when the session has gone
stale (an Apple API call starts failing with an auth error) and surface a
"needs re-login" state, instead of you noticing location updates silently
stopped.

## Non-goals

- Automatic re-login. When the saved session goes stale, the server flags
  it; you still open the app and log in again. The password is discarded
  after each login (see Security below), so the server has nothing to
  re-authenticate with on its own even if it wanted to.
- Changing how the server's day-to-day Apple API calls work
  (`mh_endpoint.py`'s `getAuth()`/`fetch_from_apple`) beyond adding the
  stale-session detection described below.
- TLS setup on the server. Enabling this feature enforces HTTPS
  client-side, but actually turning on TLS on a given server (self-signed
  cert or otherwise, already documented in `FAQ.md`) is a deployment
  prerequisite the user handles themselves.
- The standalone interactive CLI script continues to work unchanged for
  anyone not using the app for this.

## Architecture

**Fixing a latent bug found while exploring this area:** `mh_endpoint.py`'s
own `getAuth()` calls
`pypush_gsa_icloud.icloud_login_mobileme(username=mh_config.USER, password=mh_config.PASS)`
— `mh_config.USER`/`mh_config.PASS` don't exist as module attributes (the
real accessors are `mh_config.getUser()`/`getPass()`, as
`apple_cryptography.py`'s copy of this function already uses correctly).
This is currently unreachable because `auth.json` already exists by the
time any request calls `getAuth()`, but it's exactly the code path this
feature turns into a live, reachable one (stale-session detection calls
`getAuth(regenerate=True)`), so it gets fixed as part of this work.

**Splitting the blocking login functions.** `pypush_gsa_icloud.py`'s
`gsa_authenticate()`, `sms_second_factor()`, and
`trusted_device_second_factor()` are written as one blocking call chain:
SRP handshake → (if 2FA required) request a code → block on `input()` →
submit the code → recurse to finish. An HTTP request/response can't block a
phone for up to a minute waiting on a human to type a code, so each 2FA
function splits into a **trigger** half (request the code — the SMS path's
`request_code()` and the trusted-device path's `request_trusted_device_code()`
already exist as separate closures, so this mostly means exposing them, not
inventing them) and a **submit** half (send the code, raise on failure —
already how `sms_second_factor`'s and `trusted_device_second_factor`'s
POST/GET calls work internally, just not currently callable outside their
own blocking wrapper).

`gsa_authenticate()` itself splits at the point it currently calls
`_dispatch_second_factor()` and recurses: instead, when Apple's response
says 2FA is required, it triggers the code request and returns a
`NeedsSecondFactor(method, dsid, idms_token)` value rather than blocking.
Completing the login (submitting the code, then re-running the SRP
handshake to finish) becomes a second explicit call,
`complete_second_factor(method, dsid, idms_token, code, username, password)`.

The existing CLI script keeps working unchanged in shape: it wraps these
same split functions with its own `input()` loop, so nothing about running
`registerDevice()` from a terminal regresses.

**Server-side login session state.** Since this is a single-user,
single-tenant server, there's exactly one login attempt in flight at a
time — no session IDs, just one in-memory slot on the `ServerHandler`
module (a small dataclass: method, dsid, idms_token, username, password,
started-at timestamp). Starting a new login (`POST /auth/apple/login`)
always replaces whatever was pending. A pending attempt older than 10
minutes is treated as expired and cleared (bounds how long the password
sits in memory if a login is started and abandoned).

**New HTTP routes**, added to `mh_endpoint.py`'s existing `do_GET`/`do_POST`
dispatch (so they're covered by the same Basic Auth gate as every other
route — no new auth mechanism):

- `POST /auth/apple/login` — body `{"username": str, "password": str}`.
  Runs the SRP handshake. No 2FA needed → logs in fully, writes
  `auth.json`, responds `{"status": "authenticated"}`. 2FA needed →
  triggers the code push, stores the pending state, responds
  `{"status": "code_required", "method": "sms" | "trusted_device"}`. Bad
  credentials → `401 {"error": "invalid_credentials"}`.
- `POST /auth/apple/verify` — body `{"code": str}`. Submits the code
  against the pending state, then finishes the SRP handshake. Success →
  writes `auth.json`, discards the pending state (password included),
  responds `{"status": "authenticated"}`. Wrong code → `401
  {"error": "invalid_code"}`, pending state cleared — the flow restarts
  from `/login`, matching the CLI's existing behavior of a hard failure on
  a wrong code rather than a retry loop. No pending login → `409
  {"error": "no_pending_login"}`. Pending login expired (>10 min) → `410
  {"error": "login_expired"}`.
- `GET /auth/apple/status` — `{"loggedIn": bool, "pending": bool}`.
  `loggedIn` reflects whether `auth.json` exists *and* the stale-session
  flag (below) hasn't been set; `pending` reflects whether a login is
  mid-flow.

**Stale-session detection.** `mh_endpoint.py`'s `fetch_from_apple` closures
(used by both the `/` POST handler and the archiver thread) already call
`.raise_for_status()` on the Apple API response. This gets a specific catch
for a 401/403 `HTTPError`, which sets a module-level `apple_session_stale`
flag; `GET /auth/apple/status` reports `loggedIn: false` while it's set. A
successful `/auth/apple/verify` clears the flag again.

This flag is in-memory only and resets to "not stale" on a server restart,
even if the underlying `auth.json` is still the same stale token it was
before the restart — a deliberate simplification rather than an oversight.
The next fetch attempt (archiver poll or manual request) re-detects the
failure and re-sets the flag within one poll interval, so the window where
status could read "logged in" when it's actually stale is bounded by that
interval, not indefinite.

## Data flow

1. User opens the new "Apple Account" section in Preferences (behind the
   "Enable in-app Apple ID login" switch, off by default). The app fetches
   `GET /auth/apple/status` and shows "Logged in" / "Needs re-login" / "Not
   configured".
2. User taps "Log in to Apple ID", opening a dedicated screen. Before
   showing the form, and again before each network call, the app checks
   the configured endpoint URL's scheme; an `http://` URL blocks the
   attempt entirely with an explanatory message, no request constructed.
3. User enters Apple ID + password, submits → `POST /auth/apple/login`.
4. If the response is `code_required`, the screen shows a code field
   (labelled per `method`) → user enters the code → `POST /auth/apple/verify`.
5. Success closes the screen and refreshes the status line. Failure shows
   the error and returns to the username/password step (per the
   no-retry-on-wrong-code decision above).
6. Independently, if the archiver or a manual fetch hits a stale session,
   the next time the user opens the Apple Account section, `GET
   /auth/apple/status` reports `loggedIn: false` and prompts a fresh login.

## Error handling

| Condition | Server response | App behavior |
|---|---|---|
| Wrong Apple ID/password | `401 invalid_credentials` | Show error, stay on login form |
| Wrong 2FA code | `401 invalid_code` | Show error, return to login form (restart) |
| `/verify` with nothing pending | `409 no_pending_login` | Show error, return to login form |
| `/verify` after 10-minute timeout | `410 login_expired` | Show error, return to login form |
| Apple/network error (timeout, 5xx) during login | `502`/`504` | Generic "couldn't reach Apple" message; no pending state was created, retry from the login form |
| Apple/network error (timeout, 5xx) during verify | `502`/`504` | Generic "couldn't reach Apple" message; pending state is **not** cleared, so the app can retry `/verify` with the same code/session instead of restarting |
| Endpoint URL is `http://` | *(no request made)* | Client-side error, feature unusable until URL is `https://` |

Only a successful verify, a wrong code, or the 10-minute timeout clear the
pending login state — a transient network failure while verifying does not,
so a flaky connection during 2FA doesn't force starting over.

None of these three endpoints' handlers log the raw request body or the
`password`/`code` fields, at any log level — the existing `/` POST path
logs its body at DEBUG for the unrelated fetch-reports request, but that
pattern must not be copied here.

## Security

- The Apple ID password exists only in server memory, only for the
  duration of one login attempt (bounded by the 10-minute pending-state
  timeout), and is discarded immediately on success, failure, or timeout.
  It is never written to `config.ini` or any file, and never logged.
- Enabling the feature enforces HTTPS client-side for these three
  endpoints. This is a per-feature opt-in guard, not a change to the
  server or to any other endpoint — deployments that don't use this
  feature aren't required to set up TLS.
- These endpoints are gated by the same `endpoint_user`/`endpoint_pass`
  Basic Auth as every other route; no new auth mechanism is introduced,
  and no additional rate-limiting is added (this is a single-user server
  already behind that gate, and Apple's own servers already rate-limit
  failed login attempts).
- Starting a new login while one is already pending silently replaces it
  — acceptable for a single-user server, not treated as a conflict.

## Testing

- `endpoint/tests/`: extend `test_gsa_2fa_dispatch.py` (or add a sibling)
  for the split trigger/submit functions in `pypush_gsa_icloud.py` — SRP
  success with no 2FA, SRP success requiring each 2FA method, wrong
  password, correct/incorrect code submission for both methods.
- `endpoint/tests/`: new tests for `mh_endpoint.py`'s three routes —
  login → authenticated, login → code_required, login → invalid
  credentials, verify → authenticated, verify → invalid code, verify → no
  pending login, verify → expired pending login, status reflecting
  logged-in/pending/stale states. Also a regression test for the
  `mh_config.USER`/`PASS` fix (`getAuth(regenerate=True)` must use
  `getUser()`/`getPass()`).
- `macless_haystack/test/`: unit tests for the new
  `apple_auth_service.dart` using `http`'s `MockClient` (mirroring the
  existing `history_archive_service` test pattern) — successful login,
  code-required flow, error responses mapped to the right result types,
  and specifically that calling `login()`/`verifyCode()` with an
  `http://` endpoint URL makes zero calls into the mock client.
- Widget-level wiring of the new Preferences switch and the login screen
  is manual-only, matching this codebase's existing testing boundary for
  UI wiring (e.g. the sibling `history_frontend_control` feature's
  `SwitchListTile`s).
