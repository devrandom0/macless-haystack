import json
import threading
import time
from http.client import HTTPConnection
from http.server import HTTPServer
from unittest.mock import MagicMock, patch

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


def test_get_auth_raises_instead_of_prompting_interactively_when_unconfigured(tmp_path, monkeypatch):
    # No auth.json (e.g. right after a logout) and no appleid/appleid_pass
    # configured must never fall through to icloud_login_mobileme's
    # input()/getpass() prompts - that would block this single-threaded
    # server indefinitely with no interactive terminal available.
    monkeypatch.setattr(mh_config, "getConfigFile", lambda: str(tmp_path / "auth.json"))
    monkeypatch.setattr(mh_config, "getUser", lambda: None)
    monkeypatch.setattr(mh_config, "getPass", lambda: None)

    with patch.object(mh_endpoint.pypush_gsa_icloud, "icloud_login_mobileme") as mock_login:
        with pytest.raises(RuntimeError):
            mh_endpoint.getAuth(regenerate=True)

    mock_login.assert_not_called()


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
    assert mh_endpoint.pending_apple_login.dsid == "d-1"
    assert mh_endpoint.pending_apple_login.idms_token == "t-1"


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


def test_post_apple_login_discards_previous_pending_login_even_when_request_invalid(server):
    needs_2fa = mh_endpoint.pypush_gsa_icloud.NeedsSecondFactor(
        method="secondaryAuth", dsid="d-1", idms_token="t-1")
    with patch.object(mh_endpoint.pypush_gsa_icloud, "gsa_authenticate", return_value=needs_2fa), \
            patch.object(mh_endpoint.pypush_gsa_icloud, "request_second_factor_code",
                          return_value={"headers": {}, "sms_id": 7}):
        status, body = _post(server, '/auth/apple/login', {"username": "user@example.com", "password": "hunter2"})

    assert body == {"status": "code_required", "method": "sms"}
    assert mh_endpoint.pending_apple_login is not None

    status, _ = _post(server, '/auth/apple/login', {"username": "user@example.com"})

    assert status == 400
    assert mh_endpoint.pending_apple_login is None


def test_post_apple_login_requires_basic_auth_when_endpoint_credentials_configured(server, monkeypatch):
    monkeypatch.setattr(mh_config, "getEndpointUser", lambda: "simo")
    monkeypatch.setattr(mh_config, "getEndpointPass", lambda: "secret")

    status, body = _post(server, '/auth/apple/login', {"username": "user@example.com", "password": "hunter2"})

    assert status == 401


def _set_pending(method="secondaryAuth", state=None, username="user@example.com",
                  password="hunter2", age_seconds=0, dsid="d-1", idms_token="t-1",
                  last_resend_at=None, resend_count=0):
    mh_endpoint.pending_apple_login = mh_endpoint.PendingAppleLogin(
        method=method, state=state or {"headers": {}, "sms_id": 7},
        username=username, password=password,
        started_at=time.time() - age_seconds,
        dsid=dsid, idms_token=idms_token,
        last_resend_at=last_resend_at, resend_count=resend_count,
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


def _numbers(*entries):
    return [{"id": i, "number": n} for i, n in entries]


def test_post_apple_resend_returns_409_when_nothing_pending(server):
    status, body = _post(server, '/auth/apple/resend', {"mode": "sms"})

    assert status == 409
    assert body == {"error": "no_pending_login"}


def test_post_apple_resend_returns_410_when_pending_login_expired(server):
    _set_pending(age_seconds=mh_endpoint.PENDING_LOGIN_TIMEOUT_SECONDS + 1)

    status, body = _post(server, '/auth/apple/resend', {"mode": "sms"})

    assert status == 410
    assert body == {"error": "login_expired"}
    assert mh_endpoint.pending_apple_login is None


def test_post_apple_resend_returns_400_when_mode_missing(server):
    _set_pending()

    status, body = _post(server, '/auth/apple/resend', {})

    assert status == 400
    assert body == {"error": "invalid_mode"}


def test_post_apple_resend_returns_400_when_mode_unrecognized(server):
    _set_pending()

    status, body = _post(server, '/auth/apple/resend', {"mode": "carrier_pigeon"})

    assert status == 400
    assert body == {"error": "invalid_mode"}


def test_post_apple_resend_returns_429_when_resent_too_soon(server):
    _set_pending(last_resend_at=time.time() - 5)

    with patch.object(mh_endpoint.pypush_gsa_icloud, "list_trusted_phone_numbers") as mock_list:
        status, body = _post(server, '/auth/apple/resend', {"mode": "sms"})

    assert status == 429
    assert body == {"error": "resend_too_soon"}
    mock_list.assert_not_called()


def test_post_apple_resend_allows_resend_once_cooldown_elapses(server):
    _set_pending(last_resend_at=time.time() - 31)

    with patch.object(mh_endpoint.pypush_gsa_icloud, "list_trusted_phone_numbers",
                       return_value=({}, _numbers((1, "+1 •••1234")))), \
            patch.object(mh_endpoint.pypush_gsa_icloud, "trigger_phone_second_factor"):
        status, body = _post(server, '/auth/apple/resend', {"mode": "sms"})

    assert status == 200


def test_post_apple_resend_returns_429_after_five_resends(server):
    _set_pending(last_resend_at=time.time() - 3600, resend_count=5)

    with patch.object(mh_endpoint.pypush_gsa_icloud, "list_trusted_phone_numbers") as mock_list:
        status, body = _post(server, '/auth/apple/resend', {"mode": "sms"})

    assert status == 429
    assert body == {"error": "too_many_resends"}
    mock_list.assert_not_called()


def test_post_apple_resend_success_increments_resend_count_and_timestamp(server):
    _set_pending(resend_count=2)
    original_started_at = mh_endpoint.pending_apple_login.started_at

    with patch.object(mh_endpoint.pypush_gsa_icloud, "list_trusted_phone_numbers",
                       return_value=({}, _numbers((1, "+1 •••1234")))), \
            patch.object(mh_endpoint.pypush_gsa_icloud, "trigger_phone_second_factor"):
        status, body = _post(server, '/auth/apple/resend', {"mode": "sms"})

    assert status == 200
    assert mh_endpoint.pending_apple_login.resend_count == 3
    assert mh_endpoint.pending_apple_login.last_resend_at is not None
    assert time.time() - mh_endpoint.pending_apple_login.last_resend_at < 5
    # A resend must not extend how long the password stays in memory.
    assert mh_endpoint.pending_apple_login.started_at == original_started_at


def test_post_apple_resend_returns_502_when_apple_unreachable_listing_numbers(server):
    _set_pending()

    with patch.object(mh_endpoint.pypush_gsa_icloud, "list_trusted_phone_numbers",
                       side_effect=requests.exceptions.ConnectTimeout()):
        status, body = _post(server, '/auth/apple/resend', {"mode": "sms"})

    assert status == 502
    assert body == {"error": "apple_unreachable"}


def test_post_apple_resend_returns_400_when_no_trusted_phone_numbers(server):
    # An empty list means the auth page parsed fine and genuinely reported
    # zero trusted numbers.
    _set_pending()

    with patch.object(mh_endpoint.pypush_gsa_icloud, "list_trusted_phone_numbers",
                       return_value=({}, [])):
        status, body = _post(server, '/auth/apple/resend', {"mode": "sms"})

    assert status == 400
    assert body == {"error": "no_trusted_phone"}


def test_post_apple_resend_returns_502_when_boot_args_page_unrecognized(server):
    # None (as opposed to []) means the auth page itself couldn't be parsed -
    # that's an apple-side problem worth telling apart from "no phone on file".
    _set_pending()

    with patch.object(mh_endpoint.pypush_gsa_icloud, "list_trusted_phone_numbers",
                       return_value=({}, None)):
        status, body = _post(server, '/auth/apple/resend', {"mode": "sms"})

    assert status == 502
    assert body == {"error": "apple_page_unrecognized"}


def test_post_apple_resend_returns_400_when_phone_id_is_a_bool(server):
    # bool is a subclass of int in Python - True/False would otherwise
    # silently match phone id 1/0.
    _set_pending()

    with patch.object(mh_endpoint.pypush_gsa_icloud, "list_trusted_phone_numbers",
                       return_value=({}, _numbers((1, "+1 •••1234")))) as mock_list:
        status, body = _post(server, '/auth/apple/resend', {"mode": "sms", "phoneId": True})

    assert status == 400
    assert body == {"error": "invalid_phone_id"}
    mock_list.assert_called_once()


def test_post_apple_resend_returns_400_when_phone_id_is_not_an_int(server):
    _set_pending()

    with patch.object(mh_endpoint.pypush_gsa_icloud, "list_trusted_phone_numbers",
                       return_value=({}, _numbers((1, "+1 •••1234")))):
        status, body = _post(server, '/auth/apple/resend', {"mode": "sms", "phoneId": "1"})

    assert status == 400
    assert body == {"error": "invalid_phone_id"}


def test_post_apple_resend_returns_400_for_unknown_phone_id(server):
    _set_pending()

    with patch.object(mh_endpoint.pypush_gsa_icloud, "list_trusted_phone_numbers",
                       return_value=({}, _numbers((1, "+1 •••1234")))):
        status, body = _post(server, '/auth/apple/resend', {"mode": "sms", "phoneId": 99})

    assert status == 400
    assert body == {"error": "invalid_phone_id"}


def test_post_apple_resend_defaults_to_first_trusted_phone(server):
    _set_pending(dsid="d-1", idms_token="t-1")

    with patch.object(mh_endpoint.pypush_gsa_icloud, "list_trusted_phone_numbers",
                       return_value=({"h": "1"}, _numbers((1, "+1 •••1234"), (2, "+1 •••5678")))) as mock_list, \
            patch.object(mh_endpoint.pypush_gsa_icloud, "trigger_phone_second_factor") as mock_trigger:
        status, body = _post(server, '/auth/apple/resend', {"mode": "sms"})

    mock_list.assert_called_once_with("d-1", "t-1")
    mock_trigger.assert_called_once_with({"h": "1"}, 1, "sms")
    assert status == 200
    assert body == {"status": "code_required", "method": "sms", "phone": "+1 •••1234"}
    assert mh_endpoint.pending_apple_login.method == "secondaryAuth"
    assert mh_endpoint.pending_apple_login.state == {"headers": {"h": "1"}, "sms_id": 1, "mode": "sms"}


def test_post_apple_resend_uses_requested_phone_id(server):
    _set_pending()

    with patch.object(mh_endpoint.pypush_gsa_icloud, "list_trusted_phone_numbers",
                       return_value=({}, _numbers((1, "+1 •••1234"), (2, "+1 •••5678")))), \
            patch.object(mh_endpoint.pypush_gsa_icloud, "trigger_phone_second_factor") as mock_trigger:
        status, body = _post(server, '/auth/apple/resend', {"mode": "voice", "phoneId": 2})

    mock_trigger.assert_called_once_with({}, 2, "voice")
    assert status == 200
    assert body == {"status": "code_required", "method": "voice", "phone": "+1 •••5678"}


def test_post_apple_resend_returns_502_when_trigger_fails(server):
    _set_pending()

    with patch.object(mh_endpoint.pypush_gsa_icloud, "list_trusted_phone_numbers",
                       return_value=({}, _numbers((1, "+1 •••1234")))), \
            patch.object(mh_endpoint.pypush_gsa_icloud, "trigger_phone_second_factor",
                          side_effect=requests.exceptions.ConnectTimeout()):
        status, body = _post(server, '/auth/apple/resend', {"mode": "sms"})

    assert status == 502
    assert body == {"error": "apple_unreachable"}
    # A failed trigger shouldn't discard the still-valid pending login.
    assert mh_endpoint.pending_apple_login is not None


def test_post_apple_resend_returns_429_when_apple_refuses_the_trigger(server):
    _set_pending()
    rejected = mh_endpoint.pypush_gsa_icloud.ApplePhoneTriggerRejected(429)

    with patch.object(mh_endpoint.pypush_gsa_icloud, "list_trusted_phone_numbers",
                       return_value=({}, _numbers((1, "+1 •••1234")))), \
            patch.object(mh_endpoint.pypush_gsa_icloud, "trigger_phone_second_factor",
                          side_effect=rejected):
        status, body = _post(server, '/auth/apple/resend', {"mode": "sms"})

    assert status == 429
    assert body == {"error": "apple_refused_code", "status": 429}
    # A refused trigger shouldn't discard the still-valid pending login either.
    assert mh_endpoint.pending_apple_login is not None


def test_post_apple_resend_returns_429_when_apple_refuses_the_trigger_with_412(server):
    _set_pending()
    rejected = mh_endpoint.pypush_gsa_icloud.ApplePhoneTriggerRejected(412)

    with patch.object(mh_endpoint.pypush_gsa_icloud, "list_trusted_phone_numbers",
                       return_value=({}, _numbers((1, "+1 •••1234")))), \
            patch.object(mh_endpoint.pypush_gsa_icloud, "trigger_phone_second_factor",
                          side_effect=rejected):
        status, body = _post(server, '/auth/apple/resend', {"mode": "sms"})

    assert status == 429
    assert body == {"error": "apple_refused_code", "status": 412}


def test_post_apple_resend_switched_pending_login_verifies_with_new_mode(server):
    _set_pending()

    with patch.object(mh_endpoint.pypush_gsa_icloud, "list_trusted_phone_numbers",
                       return_value=({"h": "1"}, _numbers((1, "+1 •••1234")))), \
            patch.object(mh_endpoint.pypush_gsa_icloud, "trigger_phone_second_factor"):
        _post(server, '/auth/apple/resend', {"mode": "voice"})

    with patch.object(mh_endpoint.pypush_gsa_icloud, "submit_second_factor_code") as mock_submit, \
            patch.object(mh_endpoint.pypush_gsa_icloud, "gsa_authenticate", return_value={"adsid": "a-1"}), \
            patch.object(mh_endpoint.pypush_gsa_icloud, "register_mobileme",
                          return_value={"dsid": "d-1", "searchPartyToken": "spt-1"}):
        status, body = _post(server, '/auth/apple/verify', {"code": "654321"})

    assert status == 200
    mock_submit.assert_called_once_with(
        "secondaryAuth", {"headers": {"h": "1"}, "sms_id": 1, "mode": "voice"}, "654321")


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


def test_get_apple_status_reports_not_pending_once_pending_login_expired(server):
    _set_pending(age_seconds=mh_endpoint.PENDING_LOGIN_TIMEOUT_SECONDS + 1)

    status, body = _get(server, '/auth/apple/status')

    assert status == 200
    assert body["pending"] is False
    assert mh_endpoint.pending_apple_login is None


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


def test_post_apple_logout_removes_auth_json_and_clears_state(server, tmp_path):
    (tmp_path / "auth.json").write_text('{"dsid": "d-1", "searchPartyToken": "t-1"}')
    mh_endpoint.apple_session_stale = True
    _set_pending()

    status, body = _post(server, '/auth/apple/logout', {})

    assert status == 200
    assert body == {"status": "logged_out"}
    assert not (tmp_path / "auth.json").exists()
    assert mh_endpoint.apple_session_stale is False
    assert mh_endpoint.pending_apple_login is None


def test_post_apple_logout_is_idempotent_when_not_logged_in(server):
    status, body = _post(server, '/auth/apple/logout', {})

    assert status == 200
    assert body == {"status": "logged_out"}


def test_post_apple_logout_works_with_no_content_length_header(server):
    # A raw POST with no body at all (as curl sends with no -d) omits
    # Content-Length entirely - this used to crash do_POST outright with
    # no HTTP response, since int(self.headers.get('content-length'))
    # raised TypeError on None. HTTPConnection.request() always adds
    # "Content-Length: 0" itself even with no body, so it can't reproduce
    # this - putrequest()+endheaders() bypasses that and sends the same
    # wire shape curl does.
    conn = HTTPConnection('127.0.0.1', server.server_port)
    conn.putrequest('POST', '/auth/apple/logout')
    conn.endheaders()
    response = conn.getresponse()
    data = response.read()
    conn.close()

    assert response.status == 200
    assert json.loads(data) == {"status": "logged_out"}


def test_post_apple_logout_requires_basic_auth_when_endpoint_credentials_configured(server, tmp_path, monkeypatch):
    (tmp_path / "auth.json").write_text('{"dsid": "d-1", "searchPartyToken": "t-1"}')
    monkeypatch.setattr(mh_config, "getEndpointUser", lambda: "simo")
    monkeypatch.setattr(mh_config, "getEndpointPass", lambda: "secret")

    status, body = _post(server, '/auth/apple/logout', {})

    assert status == 401
    # The invariant that actually matters: no session gets deleted without auth.
    assert (tmp_path / "auth.json").exists()


def test_post_apple_logout_returns_500_and_keeps_state_cleared_on_removal_error(server, tmp_path):
    (tmp_path / "auth.json").write_text('{"dsid": "d-1", "searchPartyToken": "t-1"}')
    mh_endpoint.apple_session_stale = True
    _set_pending()

    with patch.object(mh_endpoint.os, "remove", side_effect=PermissionError("denied")):
        status, body = _post(server, '/auth/apple/logout', {})

    assert status == 500
    assert body["error"] == "logout_failed"
    # Cleared regardless of the removal failure, so a failed delete can't
    # strand a pending login's password in memory.
    assert mh_endpoint.apple_session_stale is False
    assert mh_endpoint.pending_apple_login is None
