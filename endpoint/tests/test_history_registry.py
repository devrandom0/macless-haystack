from history.registry import TrackedDeviceStore


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
        {"hashedPublicKey": "hash-a", "name": "Keys", "accessoryId": "acc-1", "enabled": True}
    ]


def test_upsert_same_key_replaces_previous_row():
    store = TrackedDeviceStore(":memory:")
    store.upsert("hash-a", "Old Name", "acc-1", b"old", enabled=True)
    store.upsert("hash-a", "New Name", "acc-1", b"new", enabled=False)

    devices = store.list_devices()

    assert len(devices) == 1
    assert devices[0]["name"] == "New Name"
    assert devices[0]["enabled"] is False


def test_enabled_keys_only_returns_enabled_rows():
    store = TrackedDeviceStore(":memory:")
    store.upsert("hash-a", "A", None, b"a", enabled=True)
    store.upsert("hash-b", "B", None, b"b", enabled=False)

    assert store.enabled_keys() == ["hash-a"]


def test_enabled_keys_reflects_latest_toggle():
    store = TrackedDeviceStore(":memory:")
    store.upsert("hash-a", "A", None, b"a", enabled=True)
    assert store.enabled_keys() == ["hash-a"]

    store.upsert("hash-a", "A", None, b"a", enabled=False)
    assert store.enabled_keys() == []


def test_upsert_accepts_missing_accessory_id():
    store = TrackedDeviceStore(":memory:")
    store.upsert("hash-a", "A", None, b"a", enabled=True)

    assert store.list_devices()[0]["accessoryId"] is None
