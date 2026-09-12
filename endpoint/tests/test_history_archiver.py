import json
import sqlite3
import time
from unittest.mock import MagicMock

import pytest

from history.archiver import derive_hashed_public_key, fetch_reports_with_cache, load_tracked_keys, run_archiver_loop
from history.archiver import migrate_devices_json_to_registry
from history.crypto import decrypt, load_or_create_key
from history.registry import TrackedDeviceStore
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


def test_fetch_reports_with_cache_falls_back_to_live_fetch_on_store_error():
    store = HistoryStore(":memory:")
    store.mark_polled("key-a", when=int(time.time()))  # fresh, so no refresh is attempted
    store.get_reports = MagicMock(side_effect=sqlite3.Error("disk I/O error"))
    now = int(time.time())
    live_entry = _entry(now - 100)
    fetch_from_apple = MagicMock(return_value=[live_entry])

    results = fetch_reports_with_cache(
        ids=["key-a"], days=7, force=False, store=store,
        poll_interval_hours=4, fetch_from_apple=fetch_from_apple,
    )

    fetch_from_apple.assert_called_once_with(["key-a"])
    assert results == [live_entry]


def test_fetch_reports_with_cache_mixed_fresh_and_stale_ids():
    store = HistoryStore(":memory:")
    now = int(time.time())

    # key-a is fresh: recently polled, already has a stored entry.
    store.mark_polled("key-a", when=now)
    fresh_a_entry = _entry(now - 100, id_="key-a")
    store.record_reports("key-a", [fresh_a_entry])

    # key-b is stale: never polled.
    stale_b_entry = _entry(now - 50, id_="key-b")
    fetch_from_apple = MagicMock(return_value=[stale_b_entry])

    results = fetch_reports_with_cache(
        ids=["key-a", "key-b"], days=7, force=False, store=store,
        poll_interval_hours=4, fetch_from_apple=fetch_from_apple,
    )

    fetch_from_apple.assert_called_once_with(["key-b"])
    assert {r["id"] for r in results} == {"key-a", "key-b"}


class _StopLoop(Exception):
    pass


class _FakeTrackedDeviceStore:
    def __init__(self, devices, all_devices=None):
        # devices: [(hashed_key, poll_interval_hours, retention_days), ...]
        # all_devices (optional): same shape as enabled_devices_with_retention
        # would need, defaults to mirroring `devices` when every device is
        # enabled - pass explicitly to simulate a disabled device.
        self._devices = devices
        self._all_devices = (
            all_devices if all_devices is not None
            else [(key, retention) for key, _, retention in devices]
        )

    def enabled_devices_with_intervals(self):
        return self._devices

    def all_devices_with_retention(self):
        return self._all_devices


def test_run_archiver_loop_fetches_and_stores_due_devices():
    store = HistoryStore(":memory:")
    tracked = _FakeTrackedDeviceStore([("key-a", 4, 30)])
    entry = _entry(int(time.time()), id_="key-a")
    fetch_from_apple = MagicMock(return_value=[entry])

    def sleep_and_stop(_seconds):
        raise _StopLoop()

    with pytest.raises(_StopLoop):
        run_archiver_loop(
            tracked_device_store=tracked, store=store,
            fetch_from_apple=fetch_from_apple, sleep_fn=sleep_and_stop,
        )

    fetch_from_apple.assert_called_once_with(["key-a"])
    assert store.get_reports(["key-a"], since=0) == [entry]


def test_run_archiver_loop_skips_devices_not_yet_due():
    store = HistoryStore(":memory:")
    store.mark_polled("key-a", when=int(time.time()))  # just polled, interval is 4h
    tracked = _FakeTrackedDeviceStore([("key-a", 4, 30)])
    fetch_from_apple = MagicMock()

    def sleep_and_stop(_seconds):
        raise _StopLoop()

    with pytest.raises(_StopLoop):
        run_archiver_loop(
            tracked_device_store=tracked, store=store,
            fetch_from_apple=fetch_from_apple, sleep_fn=sleep_and_stop,
        )

    fetch_from_apple.assert_not_called()


def test_run_archiver_loop_only_fetches_due_devices_in_one_batch_call():
    store = HistoryStore(":memory:")
    store.mark_polled("key-fresh", when=int(time.time()))  # 1h interval, just polled: not due
    store.mark_polled("key-stale", when=int(time.time()) - (5 * 3600))  # 4h interval, 5h ago: due
    tracked = _FakeTrackedDeviceStore([("key-fresh", 1, 30), ("key-stale", 4, 30)])
    fetch_from_apple = MagicMock(return_value=[])

    def sleep_and_stop(_seconds):
        raise _StopLoop()

    with pytest.raises(_StopLoop):
        run_archiver_loop(
            tracked_device_store=tracked, store=store,
            fetch_from_apple=fetch_from_apple, sleep_fn=sleep_and_stop,
        )

    fetch_from_apple.assert_called_once_with(["key-stale"])


def test_run_archiver_loop_treats_never_polled_device_as_due():
    store = HistoryStore(":memory:")
    tracked = _FakeTrackedDeviceStore([("key-a", 4, 30)])
    fetch_from_apple = MagicMock(return_value=[])

    def sleep_and_stop(_seconds):
        raise _StopLoop()

    with pytest.raises(_StopLoop):
        run_archiver_loop(
            tracked_device_store=tracked, store=store,
            fetch_from_apple=fetch_from_apple, sleep_fn=sleep_and_stop,
        )

    fetch_from_apple.assert_called_once_with(["key-a"])


def test_run_archiver_loop_enforces_retention_for_every_enabled_device_each_tick():
    store = HistoryStore(":memory:")
    now = int(time.time())
    old_entry = _entry(now - (40 * 86400), id_="key-a")  # 40 days old
    new_entry = _entry(now - 86400, id_="key-a")  # 1 day old
    store.record_reports("key-a", [old_entry, new_entry])
    store.mark_polled("key-a", when=now)  # not due, so retention runs without a poll
    tracked = _FakeTrackedDeviceStore([("key-a", 4, 30)])  # 30 day retention
    fetch_from_apple = MagicMock()

    def sleep_and_stop(_seconds):
        raise _StopLoop()

    with pytest.raises(_StopLoop):
        run_archiver_loop(
            tracked_device_store=tracked, store=store,
            fetch_from_apple=fetch_from_apple, sleep_fn=sleep_and_stop,
        )

    assert store.get_reports(["key-a"], since=0) == [new_entry]


def test_run_archiver_loop_rereads_enabled_devices_every_tick():
    store = HistoryStore(":memory:")

    class _TogglingStore:
        def __init__(self):
            self.calls = 0

        def enabled_devices_with_intervals(self):
            self.calls += 1
            return [("key-a", 4, 30)] if self.calls == 1 else []

    tracked = _TogglingStore()
    fetch_from_apple = MagicMock(return_value=[])
    call_count = {"n": 0}

    def sleep_and_stop_after_two(_seconds):
        call_count["n"] += 1
        if call_count["n"] >= 2:
            raise _StopLoop()

    with pytest.raises(_StopLoop):
        run_archiver_loop(
            tracked_device_store=tracked, store=store,
            fetch_from_apple=fetch_from_apple, sleep_fn=sleep_and_stop_after_two,
        )

    assert tracked.calls == 2
    assert fetch_from_apple.call_args_list[0].args == (["key-a"],)


def test_run_archiver_loop_skips_fetch_when_no_enabled_devices():
    store = HistoryStore(":memory:")
    tracked = _FakeTrackedDeviceStore([])
    fetch_from_apple = MagicMock()

    def sleep_and_stop(_seconds):
        raise _StopLoop()

    with pytest.raises(_StopLoop):
        run_archiver_loop(
            tracked_device_store=tracked, store=store,
            fetch_from_apple=fetch_from_apple, sleep_fn=sleep_and_stop,
        )

    fetch_from_apple.assert_not_called()


def test_run_archiver_loop_continues_after_fetch_failure():
    store = HistoryStore(":memory:")
    tracked = _FakeTrackedDeviceStore([("key-a", 4, 30)])
    fetch_from_apple = MagicMock(side_effect=Exception("network error"))

    def sleep_and_stop(_seconds):
        raise _StopLoop()

    with pytest.raises(_StopLoop):
        run_archiver_loop(
            tracked_device_store=tracked, store=store,
            fetch_from_apple=fetch_from_apple, sleep_fn=sleep_and_stop,
        )
    # Reaching sleep_fn (and raising _StopLoop from it) proves the exception
    # from fetch_from_apple was caught rather than propagating out of the loop.


def test_run_archiver_loop_marks_failed_fetch_as_polled_to_avoid_retry_storm():
    # A failed fetch must still back off to the device's own interval,
    # not retry on the very next tick - otherwise a persistent Apple
    # outage means every due device is retried every tick_interval_seconds
    # regardless of its configured poll interval, defeating the point of
    # the 1-hour minimum floor meant to protect against rate limiting.
    store = HistoryStore(":memory:")
    tracked = _FakeTrackedDeviceStore([("key-a", 4, 30)])
    fetch_from_apple = MagicMock(side_effect=Exception("network error"))
    call_count = {"n": 0}

    def sleep_and_stop_after_two(_seconds):
        call_count["n"] += 1
        if call_count["n"] >= 2:
            raise _StopLoop()

    with pytest.raises(_StopLoop):
        run_archiver_loop(
            tracked_device_store=tracked, store=store,
            fetch_from_apple=fetch_from_apple, sleep_fn=sleep_and_stop_after_two,
        )

    # Only the first tick should have attempted a fetch - the second tick
    # must see the device as not-yet-due, since the first tick's failure
    # was recorded as an attempt.
    assert fetch_from_apple.call_count == 1


def test_run_archiver_loop_failed_fetch_does_not_poison_the_on_demand_freshness_check():
    # last_polled_at also drives fetch_reports_with_cache's freshness window
    # for the app's own on-demand refresh. A failed archiver attempt must
    # not mark it as freshly polled - otherwise a transient Apple outage
    # makes the user's manual Refresh button inert for a full poll interval
    # even though no data was actually fetched.
    store = HistoryStore(":memory:")
    tracked = _FakeTrackedDeviceStore([("key-a", 4, 30)])
    fetch_from_apple = MagicMock(side_effect=Exception("network error"))

    def sleep_and_stop(_seconds):
        raise _StopLoop()

    with pytest.raises(_StopLoop):
        run_archiver_loop(
            tracked_device_store=tracked, store=store,
            fetch_from_apple=fetch_from_apple, sleep_fn=sleep_and_stop,
        )

    assert store.last_polled_at("key-a") is None


def test_run_archiver_loop_retention_failure_for_one_device_does_not_skip_others():
    store = HistoryStore(":memory:")
    now = int(time.time())
    # key-good's entry is old enough that it MUST be deleted for a passing
    # assertion to actually prove the loop reached and processed key-good,
    # rather than merely surviving because retention never ran at all.
    old_entry = _entry(now - (40 * 86400), id_="key-good")
    store.record_reports("key-good", [old_entry])
    store.record_reports("key-bad", [_entry(now - (40 * 86400), id_="key-bad")])
    tracked = _FakeTrackedDeviceStore(
        [], all_devices=[("key-bad", "not-a-number"), ("key-good", 30)],
    )
    fetch_from_apple = MagicMock()

    def sleep_and_stop(_seconds):
        raise _StopLoop()

    with pytest.raises(_StopLoop):
        run_archiver_loop(
            tracked_device_store=tracked, store=store,
            fetch_from_apple=fetch_from_apple, sleep_fn=sleep_and_stop,
        )

    # key-bad's bogus retention_days raises a TypeError computing the
    # cutoff, but key-good's retention must still run despite it.
    assert store.get_reports(["key-good"], since=0) == []


def test_run_archiver_loop_enforces_retention_even_when_fetch_fails():
    store = HistoryStore(":memory:")
    now = int(time.time())
    old_entry = _entry(now - (40 * 86400), id_="key-a")
    new_entry = _entry(now - 86400, id_="key-a")
    store.record_reports("key-a", [old_entry, new_entry])
    store.mark_polled("key-a", when=now - (5 * 3600))  # due for a 4h-interval device
    tracked = _FakeTrackedDeviceStore([("key-a", 4, 30)])
    fetch_from_apple = MagicMock(side_effect=Exception("network error"))

    def sleep_and_stop(_seconds):
        raise _StopLoop()

    with pytest.raises(_StopLoop):
        run_archiver_loop(
            tracked_device_store=tracked, store=store,
            fetch_from_apple=fetch_from_apple, sleep_fn=sleep_and_stop,
        )

    # Retention enforcement is independent of whether the fetch succeeded.
    assert store.get_reports(["key-a"], since=0) == [new_entry]


def test_run_archiver_loop_enforces_retention_for_disabled_devices():
    store = HistoryStore(":memory:")
    now = int(time.time())
    old_entry = _entry(now - (40 * 86400), id_="key-disabled")
    new_entry = _entry(now - 86400, id_="key-disabled")
    store.record_reports("key-disabled", [old_entry, new_entry])
    # No enabled devices at all, but a disabled one still has 30-day retention.
    tracked = _FakeTrackedDeviceStore([], all_devices=[("key-disabled", 30)])
    fetch_from_apple = MagicMock()

    def sleep_and_stop(_seconds):
        raise _StopLoop()

    with pytest.raises(_StopLoop):
        run_archiver_loop(
            tracked_device_store=tracked, store=store,
            fetch_from_apple=fetch_from_apple, sleep_fn=sleep_and_stop,
        )

    assert store.get_reports(["key-disabled"], since=0) == [new_entry]


def test_run_archiver_loop_uses_tick_interval_for_sleep():
    store = HistoryStore(":memory:")
    tracked = _FakeTrackedDeviceStore([])
    fetch_from_apple = MagicMock()
    seen = {}

    def sleep_and_stop(seconds):
        seen["seconds"] = seconds
        raise _StopLoop()

    with pytest.raises(_StopLoop):
        run_archiver_loop(
            tracked_device_store=tracked, store=store,
            fetch_from_apple=fetch_from_apple, sleep_fn=sleep_and_stop,
            tick_interval_seconds=60,
        )

    assert seen["seconds"] == 60


def test_migrate_devices_json_to_registry_inserts_and_deletes_file(tmp_path):
    devices_file = tmp_path / "devices.json"
    devices_file.write_text(json.dumps([
        {"id": 1, "name": "Keys", "privateKey": "AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQ==",
         "additionalKeys": ["AgICAgICAgICAgICAgICAgICAgICAgICAgICAg=="]},
    ]))
    tracked = TrackedDeviceStore(":memory:")
    key = load_or_create_key(str(tmp_path / "history_key.bin"))

    migrate_devices_json_to_registry(str(devices_file), tracked, key)

    devices = tracked.list_devices()
    assert len(devices) == 2
    assert not devices_file.exists()
    assert {d["enabled"] for d in devices} == {True}


def test_migrate_devices_json_to_registry_skips_when_registry_not_empty(tmp_path):
    devices_file = tmp_path / "devices.json"
    devices_file.write_text(json.dumps([
        {"id": 1, "name": "Keys", "privateKey": "AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQ=="},
    ]))
    tracked = TrackedDeviceStore(":memory:")
    tracked.upsert("existing", "Existing", None, b"x", enabled=True)
    key = load_or_create_key(str(tmp_path / "history_key.bin"))

    migrate_devices_json_to_registry(str(devices_file), tracked, key)

    assert devices_file.exists()
    assert [d["hashedPublicKey"] for d in tracked.list_devices()] == ["existing"]


def test_migrate_devices_json_to_registry_no_file_is_a_no_op(tmp_path):
    tracked = TrackedDeviceStore(":memory:")
    key = load_or_create_key(str(tmp_path / "history_key.bin"))

    migrate_devices_json_to_registry(str(tmp_path / "missing.json"), tracked, key)

    assert tracked.is_empty()


def test_migrate_devices_json_to_registry_malformed_file_leaves_file_in_place(tmp_path):
    devices_file = tmp_path / "devices.json"
    devices_file.write_text("not json")
    tracked = TrackedDeviceStore(":memory:")
    key = load_or_create_key(str(tmp_path / "history_key.bin"))

    migrate_devices_json_to_registry(str(devices_file), tracked, key)

    assert devices_file.exists()
    assert tracked.is_empty()


def test_migrate_devices_json_to_registry_encrypts_private_key(tmp_path):
    devices_file = tmp_path / "devices.json"
    devices_file.write_text(json.dumps([
        {"id": 1, "name": "Keys", "privateKey": "AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQ=="},
    ]))
    tracked = TrackedDeviceStore(":memory:")
    key = load_or_create_key(str(tmp_path / "history_key.bin"))

    migrate_devices_json_to_registry(str(devices_file), tracked, key)

    row = tracked._conn.execute(
        "SELECT encrypted_private_key FROM tracked_devices"
    ).fetchone()
    assert decrypt(key, row[0]) == "AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQ=="


class _FailingWriteTrackedDeviceStore:
    def is_empty(self):
        return True

    def upsert_many(self, rows, when=None):
        raise sqlite3.OperationalError("disk I/O error")


def test_migrate_devices_json_to_registry_write_failure_leaves_file_in_place(tmp_path):
    devices_file = tmp_path / "devices.json"
    devices_file.write_text(json.dumps([
        {"id": 1, "name": "Keys", "privateKey": "AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQ=="},
    ]))
    tracked = _FailingWriteTrackedDeviceStore()
    key = load_or_create_key(str(tmp_path / "history_key.bin"))

    migrate_devices_json_to_registry(str(devices_file), tracked, key)

    assert devices_file.exists()
