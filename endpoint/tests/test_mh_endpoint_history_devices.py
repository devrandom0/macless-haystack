import json
import threading

import pytest
from http.client import HTTPConnection
from http.server import HTTPServer

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
