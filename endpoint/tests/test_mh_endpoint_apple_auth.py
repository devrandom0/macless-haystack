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
