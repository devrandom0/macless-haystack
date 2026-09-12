import base64
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


def test_get_basic_auth_users_returns_empty_dict_when_section_missing(tmp_path, monkeypatch):
    monkeypatch.setattr(mh_config.config, "has_section", lambda name: False)

    assert mh_config.getBasicAuthUsers() == {}


def test_get_basic_auth_users_returns_dict_of_configured_users(monkeypatch):
    monkeypatch.setattr(mh_config.config, "has_section", lambda name: name == "BasicAuthUsers")
    monkeypatch.setattr(mh_config.config, "items", lambda name: [("alice", "pass-a"), ("bob", "pass-b")])

    assert mh_config.getBasicAuthUsers() == {"alice": "pass-a", "bob": "pass-b"}
