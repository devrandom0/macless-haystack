import base64
import json
import threading

import pytest
from http.client import HTTPConnection
from http.server import HTTPServer

import mh_config
import mh_endpoint
from history.crypto import decrypt, load_or_create_key
from history.registry import TrackedDeviceStore


@pytest.fixture
def server(tmp_path):
    mh_endpoint.tracked_device_store = TrackedDeviceStore(":memory:")
    mh_endpoint.history_encryption_key = load_or_create_key(str(tmp_path / "history_key.bin"))
    mh_endpoint.history_store = None

    httpd = HTTPServer(('127.0.0.1', 0), mh_endpoint.ServerHandler)
    thread = threading.Thread(target=httpd.serve_forever, daemon=True)
    thread.start()
    try:
        yield httpd
    finally:
        httpd.shutdown()
        thread.join()
        mh_endpoint.tracked_device_store = None
        mh_endpoint.history_encryption_key = None


def _post(server, path, body, headers=None):
    conn = HTTPConnection('127.0.0.1', server.server_port)
    request_headers = {'Content-Type': 'application/json'}
    if headers:
        request_headers.update(headers)
    conn.request('POST', path, body=json.dumps(body), headers=request_headers)
    response = conn.getresponse()
    data = response.read()
    conn.close()
    return response.status, json.loads(data) if data else None


def _get(server, path, headers=None):
    conn = HTTPConnection('127.0.0.1', server.server_port)
    conn.request('GET', path, headers=headers or {})
    response = conn.getresponse()
    data = response.read()
    conn.close()
    return response.status, json.loads(data) if data else None


def _basic_auth_header(username, password):
    token = base64.b64encode(f'{username}:{password}'.encode('utf-8')).decode('ascii')
    return {'Authorization': f'Basic {token}'}


def test_get_history_devices_returns_empty_list_initially(server):
    status, body = _get(server, '/history/devices')
    assert status == 200
    assert body == {"devices": []}


def test_post_history_devices_upserts_and_get_reflects_it(server):
    status, body = _post(server, '/history/devices', {
        "devices": [
            {"hashedPublicKey": "hash-a", "privateKey": "AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQ==",
             "name": "Keys", "accessoryId": "acc-1", "enabled": True},
        ]
    })
    assert status == 200
    assert body == {"status": "ok"}

    status, body = _get(server, '/history/devices')
    assert status == 200
    assert body == {"devices": [
        {"hashedPublicKey": "hash-a", "name": "Keys", "accessoryId": "acc-1", "enabled": True},
    ]}


def test_post_history_devices_encrypts_private_key(server):
    _post(server, '/history/devices', {
        "devices": [
            {"hashedPublicKey": "hash-a", "privateKey": "AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQ==",
             "name": "Keys", "accessoryId": None, "enabled": True},
        ]
    })

    row = mh_endpoint.tracked_device_store._conn.execute(
        "SELECT encrypted_private_key FROM tracked_devices WHERE hashed_public_key = ?", ("hash-a",)
    ).fetchone()
    assert decrypt(mh_endpoint.history_encryption_key, row[0]) == "AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQ=="


def test_post_history_devices_missing_field_returns_400(server):
    status, body = _post(server, '/history/devices', {"devices": [{"hashedPublicKey": "hash-a"}]})
    assert status == 400
    assert "error" in body


def test_post_history_devices_non_list_devices_returns_400(server):
    status, body = _post(server, '/history/devices', {"devices": "not-a-list"})
    assert status == 400


def test_history_devices_unavailable_when_store_not_configured(server):
    mh_endpoint.tracked_device_store = None
    status, _ = _get(server, '/history/devices')
    assert status == 503


def test_root_post_behavior_is_unchanged(server, monkeypatch):
    monkeypatch.setattr(mh_endpoint.history_archiver, "fetch_reports_with_cache", lambda *a, **k: [])
    status, body = _post(server, '/', {"ids": ["hash-a"], "days": 7})
    assert status == 200
    assert body == {"results": []}


def test_history_devices_requires_auth_when_configured(server, monkeypatch):
    monkeypatch.setattr(mh_config, 'getEndpointUser', lambda: 'user')
    monkeypatch.setattr(mh_config, 'getEndpointPass', lambda: 'pass')

    status, _ = _get(server, '/history/devices')
    assert status == 401

    status, _ = _post(server, '/history/devices', {"devices": []})
    assert status == 401

    auth_headers = _basic_auth_header('user', 'pass')

    status, body = _get(server, '/history/devices', headers=auth_headers)
    assert status == 200
    assert body == {"devices": []}

    status, body = _post(server, '/history/devices', {"devices": []}, headers=auth_headers)
    assert status == 200
    assert body == {"status": "ok"}


def test_post_history_devices_unavailable_when_store_not_configured(server):
    mh_endpoint.tracked_device_store = None
    status, _ = _post(server, '/history/devices', {"devices": []})
    assert status == 503


def test_post_history_devices_non_json_body_returns_400(server):
    conn = HTTPConnection('127.0.0.1', server.server_port)
    conn.request('POST', '/history/devices', body='not-json', headers={'Content-Type': 'application/json'})
    response = conn.getresponse()
    data = response.read()
    conn.close()
    assert response.status == 400
    assert "error" in json.loads(data)


def test_post_history_devices_non_string_private_key_returns_400(server):
    status, body = _post(server, '/history/devices', {
        "devices": [
            {"hashedPublicKey": "hash-a", "privateKey": 12345,
             "name": "Keys", "accessoryId": None, "enabled": True},
        ]
    })
    assert status == 400
    assert "error" in body


def test_post_history_devices_non_string_hashed_public_key_returns_400(server):
    status, body = _post(server, '/history/devices', {
        "devices": [
            {"hashedPublicKey": {"not": "a string"}, "privateKey": "AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQ==",
             "name": "Keys", "accessoryId": None, "enabled": True},
        ]
    })
    assert status == 400
    assert "error" in body


def test_post_history_devices_corrupted_encryption_key_returns_500(server):
    mh_endpoint.history_encryption_key = b'not-a-valid-fernet-key'
    status, body = _post(server, '/history/devices', {
        "devices": [
            {"hashedPublicKey": "hash-a", "privateKey": "AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQ==",
             "name": "Keys", "accessoryId": None, "enabled": True},
        ]
    })
    assert status == 500
    assert "error" in body
