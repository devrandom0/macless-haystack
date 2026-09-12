import sqlite3

import pytest

from history.registry import TrackedDeviceStore


def test_migrating_from_pre_intervals_schema_adds_columns_without_error(tmp_path):
    # Build a real pre-migration database by hand (the old 6-column schema,
    # no poll_interval_hours/retention_days) rather than via TrackedDeviceStore,
    # which always creates the current schema - this must exercise the actual
    # ALTER TABLE path against a file that predates these columns.
    db_path = str(tmp_path / "devices.db")
    raw = sqlite3.connect(db_path)
    raw.execute(
        "CREATE TABLE tracked_devices ("
        "hashed_public_key TEXT PRIMARY KEY, "
        "name TEXT NOT NULL, "
        "accessory_id TEXT, "
        "encrypted_private_key BLOB NOT NULL, "
        "enabled INTEGER NOT NULL, "
        "updated_at INTEGER NOT NULL)"
    )
    raw.execute(
        "INSERT INTO tracked_devices "
        "(hashed_public_key, name, accessory_id, encrypted_private_key, enabled, updated_at) "
        "VALUES (?, ?, ?, ?, ?, ?)",
        ("hash-a", "A", None, b"a", 1, 1000),
    )
    raw.commit()
    raw.close()

    store = TrackedDeviceStore(db_path)
    devices = store.list_devices()

    assert devices == [{
        "hashedPublicKey": "hash-a", "name": "A", "accessoryId": None, "enabled": True,
        "pollIntervalHours": 4, "retentionDays": 30,
    }]

    # Reopening again (columns already present) must stay idempotent.
    del store
    reopened = TrackedDeviceStore(db_path)
    assert reopened.list_devices() == devices


def test_is_empty_true_for_new_store():
    store = TrackedDeviceStore(":memory:")
    assert store.is_empty() is True


def test_upsert_then_is_empty_false():
    store = TrackedDeviceStore(":memory:")
    store.upsert("hash-a", "Keys", "acc-1", b"ciphertext", enabled=True)
    assert store.is_empty() is False


def test_upsert_then_list_devices_excludes_private_key():
    store = TrackedDeviceStore(":memory:")
    store.upsert("hash-a", "Keys", "acc-1", b"ciphertext", enabled=True)

    devices = store.list_devices()

    assert devices == [
        {
            "hashedPublicKey": "hash-a", "name": "Keys", "accessoryId": "acc-1", "enabled": True,
            "pollIntervalHours": 4, "retentionDays": 30,
        }
    ]


def test_upsert_accepts_poll_interval_and_retention_overrides():
    store = TrackedDeviceStore(":memory:")
    store.upsert("hash-a", "Keys", "acc-1", b"ciphertext", enabled=True, poll_interval_hours=6, retention_days=14)

    device = store.list_devices()[0]
    assert device["pollIntervalHours"] == 6
    assert device["retentionDays"] == 14


def test_upsert_same_key_replaces_previous_row():
    store = TrackedDeviceStore(":memory:")
    store.upsert("hash-a", "Old Name", "acc-1", b"old", enabled=True)
    store.upsert("hash-a", "New Name", "acc-1", b"new", enabled=False)

    devices = store.list_devices()

    assert len(devices) == 1
    assert devices[0]["name"] == "New Name"
    assert devices[0]["enabled"] is False


def test_upsert_accepts_missing_accessory_id():
    store = TrackedDeviceStore(":memory:")
    store.upsert("hash-a", "A", None, b"a", enabled=True)

    assert store.list_devices()[0]["accessoryId"] is None


def test_upsert_many_inserts_all_rows():
    store = TrackedDeviceStore(":memory:")
    rows = [
        ("hash-a", "A", None, b"a", True),
        ("hash-b", "B", "acc-1", b"b", False),
        ("hash-c", "C", "acc-2", b"c", True),
    ]

    store.upsert_many(rows)

    devices = store.list_devices()
    assert len(devices) == 3
    assert {d["hashedPublicKey"] for d in devices} == {"hash-a", "hash-b", "hash-c"}
    by_key = {d["hashedPublicKey"]: d for d in devices}
    assert by_key["hash-a"] == {
        "hashedPublicKey": "hash-a", "name": "A", "accessoryId": None, "enabled": True,
        "pollIntervalHours": 4, "retentionDays": 30,
    }
    assert by_key["hash-b"] == {
        "hashedPublicKey": "hash-b", "name": "B", "accessoryId": "acc-1", "enabled": False,
        "pollIntervalHours": 4, "retentionDays": 30,
    }
    assert by_key["hash-c"] == {
        "hashedPublicKey": "hash-c", "name": "C", "accessoryId": "acc-2", "enabled": True,
        "pollIntervalHours": 4, "retentionDays": 30,
    }


def test_upsert_many_accepts_poll_interval_and_retention_overrides():
    store = TrackedDeviceStore(":memory:")
    rows = [("hash-a", "A", None, b"a", True)]

    store.upsert_many(rows, poll_interval_hours=8, retention_days=60)

    device = store.list_devices()[0]
    assert device["pollIntervalHours"] == 8
    assert device["retentionDays"] == 60


def test_upsert_many_rolls_back_on_error():
    store = TrackedDeviceStore(":memory:")
    rows = [
        ("hash-a", "A", None, b"a", True),
        ("hash-b", None, None, b"b", True),  # name is NOT NULL, raises during executemany
    ]

    with pytest.raises(sqlite3.Error):
        store.upsert_many(rows)

    assert store.is_empty() is True


def test_get_device_returns_none_when_missing():
    store = TrackedDeviceStore(":memory:")
    assert store.get_device("hash-a") is None


def test_get_device_returns_all_fields():
    store = TrackedDeviceStore(":memory:")
    store.upsert("hash-a", "Keys", "acc-1", b"a", enabled=True, poll_interval_hours=6, retention_days=14)

    assert store.get_device("hash-a") == {
        "hashedPublicKey": "hash-a", "name": "Keys", "accessoryId": "acc-1", "enabled": True,
        "pollIntervalHours": 6, "retentionDays": 14,
    }


def test_enabled_devices_with_intervals_only_returns_enabled_rows():
    store = TrackedDeviceStore(":memory:")
    store.upsert("hash-a", "A", None, b"a", enabled=True, poll_interval_hours=6, retention_days=10)
    store.upsert("hash-b", "B", None, b"b", enabled=False)

    assert store.enabled_devices_with_intervals() == [("hash-a", 6, 10)]


def test_enabled_devices_with_intervals_reflects_latest_toggle():
    store = TrackedDeviceStore(":memory:")
    store.upsert("hash-a", "A", None, b"a", enabled=True)
    assert store.enabled_devices_with_intervals() == [("hash-a", 4, 30)]

    store.upsert("hash-a", "A", None, b"a", enabled=False)
    assert store.enabled_devices_with_intervals() == []


def test_all_devices_with_retention_includes_disabled_devices():
    store = TrackedDeviceStore(":memory:")
    store.upsert("hash-a", "A", None, b"a", enabled=True, retention_days=10)
    store.upsert("hash-b", "B", None, b"b", enabled=False, retention_days=20)

    assert sorted(store.all_devices_with_retention()) == [("hash-a", 10), ("hash-b", 20)]
