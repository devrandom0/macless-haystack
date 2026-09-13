import base64
import logging
import threading

import pytest
from http.client import HTTPConnection
from http.server import HTTPServer

import mh_config
import mh_endpoint


@pytest.fixture
def server():
    httpd = HTTPServer(('127.0.0.1', 0), mh_endpoint.ServerHandler)
    thread = threading.Thread(target=httpd.serve_forever, daemon=True)
    thread.start()
    try:
        yield httpd
    finally:
        httpd.shutdown()
        thread.join()


def _basic_auth_header(username, password):
    token = base64.b64encode(f'{username}:{password}'.encode('utf-8')).decode('ascii')
    return {'Authorization': f'Basic {token}'}


def _get(server, path, headers=None):
    conn = HTTPConnection('127.0.0.1', server.server_port)
    conn.request('GET', path, headers=headers or {})
    response = conn.getresponse()
    response.read()
    conn.close()
    return response.status


def test_no_auth_configured_allows_any_request(server, monkeypatch):
    monkeypatch.setattr(mh_config, "getEndpointUser", lambda: None)
    monkeypatch.setattr(mh_config, "getEndpointPass", lambda: None)
    monkeypatch.setattr(mh_config, "getBasicAuthUsers", lambda: {})

    assert _get(server, '/auth/apple/status') == 200


def test_legacy_single_pair_still_works_alone(server, monkeypatch):
    monkeypatch.setattr(mh_config, "getEndpointUser", lambda: "simo")
    monkeypatch.setattr(mh_config, "getEndpointPass", lambda: "hunter2")
    monkeypatch.setattr(mh_config, "getBasicAuthUsers", lambda: {})

    assert _get(server, '/auth/apple/status', _basic_auth_header("simo", "hunter2")) == 200
    assert _get(server, '/auth/apple/status', _basic_auth_header("simo", "wrong")) == 401
    assert _get(server, '/auth/apple/status') == 401


def test_multiple_basic_auth_users_each_authenticate(server, monkeypatch):
    monkeypatch.setattr(mh_config, "getEndpointUser", lambda: None)
    monkeypatch.setattr(mh_config, "getEndpointPass", lambda: None)
    monkeypatch.setattr(mh_config, "getBasicAuthUsers", lambda: {"alice": "pass-a", "bob": "pass-b"})

    assert _get(server, '/auth/apple/status', _basic_auth_header("alice", "pass-a")) == 200
    assert _get(server, '/auth/apple/status', _basic_auth_header("bob", "pass-b")) == 200


def test_multiple_basic_auth_users_rejects_wrong_password(server, monkeypatch):
    monkeypatch.setattr(mh_config, "getEndpointUser", lambda: None)
    monkeypatch.setattr(mh_config, "getEndpointPass", lambda: None)
    monkeypatch.setattr(mh_config, "getBasicAuthUsers", lambda: {"alice": "pass-a"})

    assert _get(server, '/auth/apple/status', _basic_auth_header("alice", "wrong")) == 401


def test_multiple_basic_auth_users_rejects_unlisted_username(server, monkeypatch):
    monkeypatch.setattr(mh_config, "getEndpointUser", lambda: None)
    monkeypatch.setattr(mh_config, "getEndpointPass", lambda: None)
    monkeypatch.setattr(mh_config, "getBasicAuthUsers", lambda: {"alice": "pass-a"})

    assert _get(server, '/auth/apple/status', _basic_auth_header("mallory", "pass-a")) == 401


def test_legacy_pair_and_multiple_users_both_work_together(server, monkeypatch):
    monkeypatch.setattr(mh_config, "getEndpointUser", lambda: "simo")
    monkeypatch.setattr(mh_config, "getEndpointPass", lambda: "hunter2")
    monkeypatch.setattr(mh_config, "getBasicAuthUsers", lambda: {"alice": "pass-a"})

    assert _get(server, '/auth/apple/status', _basic_auth_header("simo", "hunter2")) == 200
    assert _get(server, '/auth/apple/status', _basic_auth_header("alice", "pass-a")) == 200
    assert _get(server, '/auth/apple/status', _basic_auth_header("alice", "wrong")) == 401


def test_empty_legacy_pair_with_users_rejects_empty_credentials(server, monkeypatch):
    # This is the shipped config.ini's default shape: endpoint_user/pass
    # present but blank, once someone has also configured [BasicAuthUsers].
    # Without the has_legacy_pair guard, Basic base64("":"") would match
    # username == "" and password == "" and bypass auth entirely.
    monkeypatch.setattr(mh_config, "getEndpointUser", lambda: "")
    monkeypatch.setattr(mh_config, "getEndpointPass", lambda: "")
    monkeypatch.setattr(mh_config, "getBasicAuthUsers", lambda: {"alice": "pass-a"})

    assert _get(server, '/auth/apple/status', _basic_auth_header("", "")) == 401
    assert _get(server, '/auth/apple/status', _basic_auth_header("alice", "pass-a")) == 200


def _config_with(ini_text):
    import configparser
    c = configparser.ConfigParser()
    c.read_string(ini_text)
    return c


def test_get_basic_auth_users_returns_empty_dict_when_section_missing(monkeypatch):
    monkeypatch.setattr(mh_config, "config", _config_with("[Settings]\nendpoint_user = simo\n"))

    assert mh_config.getBasicAuthUsers() == {}


def test_get_basic_auth_users_returns_dict_of_configured_users(monkeypatch):
    monkeypatch.setattr(mh_config, "config", _config_with(
        "[BasicAuthUsers]\nalice = pass-a\nbob = pass-b\n"))

    assert mh_config.getBasicAuthUsers() == {"alice": "pass-a", "bob": "pass-b"}


def test_get_basic_auth_users_excludes_default_section_options(monkeypatch):
    # config.items(section) merges in [DEFAULT] options - appleid_pass here
    # must never turn into a working Basic Auth password.
    monkeypatch.setattr(mh_config, "config", _config_with(
        "[DEFAULT]\nappleid_pass = topsecret\n[BasicAuthUsers]\nalice = pass-a\n"))

    assert mh_config.getBasicAuthUsers() == {"alice": "pass-a"}


def test_get_basic_auth_users_does_not_interpolate_percent_in_password(monkeypatch):
    # Default ConfigParser interpolation would raise InterpolationSyntaxError
    # on a literal "%" - getBasicAuthUsers must read it raw.
    monkeypatch.setattr(mh_config, "config", _config_with("[BasicAuthUsers]\nalice = p%ssw0rd\n"))

    assert mh_config.getBasicAuthUsers() == {"alice": "p%ssw0rd"}


def test_log_auth_status_warns_when_nothing_configured(caplog, monkeypatch):
    monkeypatch.setattr(mh_config, "getEndpointUser", lambda: "")
    monkeypatch.setattr(mh_config, "getEndpointPass", lambda: "")
    monkeypatch.setattr(mh_config, "getBasicAuthUsers", lambda: {})

    with caplog.at_level(logging.WARNING):
        mh_endpoint._log_auth_status()

    assert "not protected" in caplog.text


def test_log_auth_status_reports_protected_for_legacy_pair(caplog, monkeypatch):
    monkeypatch.setattr(mh_config, "getEndpointUser", lambda: "simo")
    monkeypatch.setattr(mh_config, "getEndpointPass", lambda: "hunter2")
    monkeypatch.setattr(mh_config, "getBasicAuthUsers", lambda: {})

    with caplog.at_level(logging.INFO):
        mh_endpoint._log_auth_status()

    assert "is protected by authentication" in caplog.text


def test_log_auth_status_reports_protected_for_basic_auth_users_alone(caplog, monkeypatch):
    # This is the exact bug this helper fixes: migrating from the legacy
    # pair to [BasicAuthUsers] alone used to log a false "not protected"
    # warning, even though authenticate() still requires credentials.
    monkeypatch.setattr(mh_config, "getEndpointUser", lambda: "")
    monkeypatch.setattr(mh_config, "getEndpointPass", lambda: "")
    monkeypatch.setattr(mh_config, "getBasicAuthUsers", lambda: {"alice": "pass-a"})

    with caplog.at_level(logging.INFO):
        mh_endpoint._log_auth_status()

    assert "is protected by authentication" in caplog.text
