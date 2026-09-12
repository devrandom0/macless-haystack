import base64
import json
import threading
import time

import pytest
from http.client import HTTPConnection
from http.server import HTTPServer

import mh_config
import mh_endpoint
from history.crypto import decrypt, load_or_create_key
from history.registry import TrackedDeviceStore
from history.store import HistoryStore, extract_report_timestamp


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
        mh_endpoint.history_store = None


def _report_entry(unix_timestamp, id_="key-a"):
    apple_timestamp = unix_timestamp - 978307200
    payload = apple_timestamp.to_bytes(4, "big") + b"\x00" * 4
    return {"payload": base64.b64encode(payload).decode("ascii"), "id": id_}


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
        {
            "hashedPublicKey": "hash-a", "name": "Keys", "accessoryId": "acc-1", "enabled": True,
            "pollIntervalHours": 4, "retentionDays": 30,
        },
    ]}


def test_post_history_devices_accepts_poll_interval_and_retention_overrides(server):
    status, body = _post(server, '/history/devices', {
        "devices": [
            {"hashedPublicKey": "hash-a", "privateKey": "AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQ==",
             "name": "Keys", "accessoryId": "acc-1", "enabled": True,
             "pollIntervalHours": 6, "retentionDays": 14},
        ]
    })
    assert status == 200

    status, body = _get(server, '/history/devices')
    assert body == {"devices": [
        {
            "hashedPublicKey": "hash-a", "name": "Keys", "accessoryId": "acc-1", "enabled": True,
            "pollIntervalHours": 6, "retentionDays": 14,
        },
    ]}


def test_post_history_devices_poll_interval_below_one_returns_400(server):
    status, body = _post(server, '/history/devices', {
        "devices": [
            {"hashedPublicKey": "hash-a", "privateKey": "AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQ==",
             "name": "Keys", "accessoryId": None, "enabled": True, "pollIntervalHours": 0.5},
        ]
    })
    assert status == 400
    assert "error" in body


def test_post_history_devices_retention_days_below_one_returns_400(server):
    status, body = _post(server, '/history/devices', {
        "devices": [
            {"hashedPublicKey": "hash-a", "privateKey": "AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQ==",
             "name": "Keys", "accessoryId": None, "enabled": True, "retentionDays": 0},
        ]
    })
    assert status == 400
    assert "error" in body


def test_post_history_devices_infinite_poll_interval_returns_400(server):
    status, body = _post(server, '/history/devices', {
        "devices": [
            {"hashedPublicKey": "hash-a", "privateKey": "AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQ==",
             "name": "Keys", "accessoryId": None, "enabled": True, "pollIntervalHours": float("inf")},
        ]
    })
    assert status == 400
    assert "error" in body


def test_post_history_devices_infinite_retention_days_returns_400(server):
    status, body = _post(server, '/history/devices', {
        "devices": [
            {"hashedPublicKey": "hash-a", "privateKey": "AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQ==",
             "name": "Keys", "accessoryId": None, "enabled": True, "retentionDays": float("inf")},
        ]
    })
    assert status == 400
    assert "error" in body


def test_post_history_devices_bool_poll_interval_returns_400(server):
    status, body = _post(server, '/history/devices', {
        "devices": [
            {"hashedPublicKey": "hash-a", "privateKey": "AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQ==",
             "name": "Keys", "accessoryId": None, "enabled": True, "pollIntervalHours": True},
        ]
    })
    assert status == 400
    assert "error" in body


def test_post_history_devices_omitting_overrides_preserves_existing_values(server):
    _post(server, '/history/devices', {
        "devices": [
            {"hashedPublicKey": "hash-a", "privateKey": "AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQ==",
             "name": "Keys", "accessoryId": None, "enabled": True,
             "pollIntervalHours": 8, "retentionDays": 90},
        ]
    })

    # A later save that only flips "enabled" and omits the interval/retention
    # fields entirely must not reset them back to the 4/30 defaults.
    status, _ = _post(server, '/history/devices', {
        "devices": [
            {"hashedPublicKey": "hash-a", "privateKey": "AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQ==",
             "name": "Keys", "accessoryId": None, "enabled": False},
        ]
    })
    assert status == 200

    _, body = _get(server, '/history/devices')
    assert body == {"devices": [
        {
            "hashedPublicKey": "hash-a", "name": "Keys", "accessoryId": None, "enabled": False,
            "pollIntervalHours": 8, "retentionDays": 90,
        },
    ]}


def test_post_history_devices_lowering_retention_deletes_out_of_range_reports(server):
    mh_endpoint.history_store = HistoryStore(":memory:")
    _post(server, '/history/devices', {
        "devices": [
            {"hashedPublicKey": "hash-a", "privateKey": "AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQ==",
             "name": "Keys", "accessoryId": None, "enabled": True, "retentionDays": 30},
        ]
    })
    now = int(time.time())
    old_entry = _report_entry(now - (20 * 86400))  # 20 days old: within 30 days, outside 10 days
    new_entry = _report_entry(now - 86400)  # 1 day old: within both windows
    mh_endpoint.history_store.record_reports("hash-a", [old_entry, new_entry])

    status, _ = _post(server, '/history/devices', {
        "devices": [
            {"hashedPublicKey": "hash-a", "privateKey": "AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQ==",
             "name": "Keys", "accessoryId": None, "enabled": True, "retentionDays": 10},
        ]
    })

    assert status == 200
    assert mh_endpoint.history_store.get_reports(["hash-a"], since=0) == [new_entry]


def test_post_history_devices_raising_retention_does_not_delete_reports(server):
    mh_endpoint.history_store = HistoryStore(":memory:")
    _post(server, '/history/devices', {
        "devices": [
            {"hashedPublicKey": "hash-a", "privateKey": "AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQ==",
             "name": "Keys", "accessoryId": None, "enabled": True, "retentionDays": 10},
        ]
    })
    now = int(time.time())
    old_entry = _report_entry(now - (20 * 86400))  # 20 days old
    mh_endpoint.history_store.record_reports("hash-a", [old_entry])

    status, _ = _post(server, '/history/devices', {
        "devices": [
            {"hashedPublicKey": "hash-a", "privateKey": "AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQ==",
             "name": "Keys", "accessoryId": None, "enabled": True, "retentionDays": 30},
        ]
    })

    assert status == 200
    assert mh_endpoint.history_store.get_reports(["hash-a"], since=0) == [old_entry]


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


def test_post_history_devices_non_string_accessory_id_returns_400(server):
    status, body = _post(server, '/history/devices', {
        "devices": [
            {"hashedPublicKey": "hash-a", "privateKey": "AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQ==",
             "name": "Keys", "accessoryId": 12345, "enabled": True},
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
