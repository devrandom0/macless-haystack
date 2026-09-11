import json
import time
from unittest.mock import MagicMock

from history.archiver import derive_hashed_public_key, fetch_reports_with_cache, load_tracked_keys
from history.store import HistoryStore, extract_report_timestamp


def test_derive_hashed_public_key_matches_known_vector():
    # Fixed 28-byte private key (bytes 1..28) and its independently-computed
    # hash, generated once via the same cryptography.hazmat EC derivation
    # generate_keys.py uses (SECP224R1, x-coordinate of the derived public key,
    # SHA-256, base64) — see generate_keys.py:119-132 for the reference math.
    private_key_b64 = "AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQ=="
    expected_hash = "7+Gc2EctOUZl/u+AaNnMNa3JVjmrIgefrqM5YjtQ08k="

    assert derive_hashed_public_key(private_key_b64) == expected_hash


def test_derive_hashed_public_key_is_deterministic():
    private_key_b64 = "AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQ=="
    assert derive_hashed_public_key(private_key_b64) == derive_hashed_public_key(private_key_b64)


def test_derive_hashed_public_key_differs_for_different_keys():
    key_a = "AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQ=="
    key_b = "AgICAgICAgICAgICAgICAgICAgICAgICAgICAg=="
    assert derive_hashed_public_key(key_a) != derive_hashed_public_key(key_b)


def test_load_tracked_keys_includes_main_and_additional_keys(tmp_path):
    devices_file = tmp_path / "devices.json"
    devices_file.write_text(json.dumps([
        {
            "id": 1,
            "name": "Keys",
            "privateKey": "AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQ==",
            "additionalKeys": ["AgICAgICAgICAgICAgICAgICAgICAgICAgICAg=="],
        }
    ]))

    hashed_keys = load_tracked_keys(str(devices_file))

    assert len(hashed_keys) == 2
    assert derive_hashed_public_key_result_present(hashed_keys)


def derive_hashed_public_key_result_present(hashed_keys):
    from history.archiver import derive_hashed_public_key
    expected_main = derive_hashed_public_key("AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQ==")
    expected_additional = derive_hashed_public_key("AgICAgICAgICAgICAgICAgICAgICAgICAgICAg==")
    return expected_main in hashed_keys and expected_additional in hashed_keys


def test_load_tracked_keys_handles_missing_additional_keys(tmp_path):
    devices_file = tmp_path / "devices.json"
    devices_file.write_text(json.dumps([
        {"id": 1, "name": "Keys", "privateKey": "AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQ=="}
    ]))

    hashed_keys = load_tracked_keys(str(devices_file))

    assert len(hashed_keys) == 1


def test_load_tracked_keys_flattens_multiple_devices(tmp_path):
    devices_file = tmp_path / "devices.json"
    devices_file.write_text(json.dumps([
        {"id": 1, "name": "A", "privateKey": "AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQ==", "additionalKeys": []},
        {"id": 2, "name": "B", "privateKey": "AgICAgICAgICAgICAgICAgICAgICAgICAgICAg==", "additionalKeys": []},
    ]))

    hashed_keys = load_tracked_keys(str(devices_file))

    assert len(hashed_keys) == 2


def _entry(unix_timestamp, id_="key-a"):
    import base64
    apple_timestamp = unix_timestamp - 978307200
    payload = apple_timestamp.to_bytes(4, "big") + b"\x00" * 4
    return {"payload": base64.b64encode(payload).decode("ascii"), "id": id_}


def test_fetch_reports_with_cache_no_store_calls_apple_and_filters_by_days():
    now = int(time.time())
    old_entry = _entry(now - 10 * 86400)  # 10 days old
    new_entry = _entry(now - 1 * 86400)   # 1 day old
    fetch_from_apple = MagicMock(return_value=[old_entry, new_entry])

    results = fetch_reports_with_cache(
        ids=["key-a"], days=7, force=False, store=None,
        poll_interval_hours=4, fetch_from_apple=fetch_from_apple,
    )

    fetch_from_apple.assert_called_once_with(["key-a"])
    assert results == [new_entry]


def test_fetch_reports_with_cache_fresh_store_skips_apple():
    store = HistoryStore(":memory:")
    store.mark_polled("key-a", when=int(time.time()))
    fetch_from_apple = MagicMock()

    results = fetch_reports_with_cache(
        ids=["key-a"], days=7, force=False, store=store,
        poll_interval_hours=4, fetch_from_apple=fetch_from_apple,
    )

    fetch_from_apple.assert_not_called()
    assert results == []


def test_fetch_reports_with_cache_stale_store_calls_apple_and_persists():
    store = HistoryStore(":memory:")
    stale_time = int(time.time()) - (5 * 3600)  # 5h ago, poll interval is 4h
    store.mark_polled("key-a", when=stale_time)
    entry = _entry(int(time.time()) - 3600)
    fetch_from_apple = MagicMock(return_value=[entry])

    results = fetch_reports_with_cache(
        ids=["key-a"], days=7, force=False, store=store,
        poll_interval_hours=4, fetch_from_apple=fetch_from_apple,
    )

    fetch_from_apple.assert_called_once_with(["key-a"])
    assert results == [entry]
    assert store.last_polled_at("key-a") > stale_time


def test_fetch_reports_with_cache_force_calls_apple_even_if_fresh():
    store = HistoryStore(":memory:")
    store.mark_polled("key-a", when=int(time.time()))
    entry = _entry(int(time.time()))
    fetch_from_apple = MagicMock(return_value=[entry])

    results = fetch_reports_with_cache(
        ids=["key-a"], days=7, force=True, store=store,
        poll_interval_hours=4, fetch_from_apple=fetch_from_apple,
    )

    fetch_from_apple.assert_called_once_with(["key-a"])
    assert results == [entry]


def test_fetch_reports_with_cache_falls_back_to_cache_on_apple_failure():
    store = HistoryStore(":memory:")
    old_poll = int(time.time()) - (10 * 3600)
    store.mark_polled("key-a", when=old_poll)
    cached_entry = _entry(int(time.time()) - 3600)
    store.record_reports("key-a", [cached_entry])
    fetch_from_apple = MagicMock(side_effect=Exception("network error"))

    results = fetch_reports_with_cache(
        ids=["key-a"], days=7, force=False, store=store,
        poll_interval_hours=4, fetch_from_apple=fetch_from_apple,
    )

    assert results == [cached_entry]
    # last_polled_at is untouched since the fetch failed
    assert store.last_polled_at("key-a") == old_poll


def test_fetch_reports_with_cache_sorts_newest_first():
    store = HistoryStore(":memory:")
    now = int(time.time())
    store.record_reports("key-a", [_entry(now - 100), _entry(now - 50)])
    store.mark_polled("key-a", when=now)

    results = fetch_reports_with_cache(
        ids=["key-a"], days=7, force=False, store=store,
        poll_interval_hours=4, fetch_from_apple=MagicMock(),
    )

    assert [extract_report_timestamp(r) for r in results] == [now - 50, now - 100]
