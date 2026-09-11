import base64
import time

from history.store import HistoryStore, extract_report_timestamp


def _entry(unix_timestamp, id_="key-a", extra=None):
    apple_timestamp = unix_timestamp - 978307200
    payload = apple_timestamp.to_bytes(4, "big") + b"\x00" * 4
    entry = {"payload": base64.b64encode(payload).decode("ascii"), "id": id_}
    if extra:
        entry.update(extra)
    return entry


def test_extract_report_timestamp_decodes_apple_epoch_offset():
    entry = _entry(1_700_000_000)
    assert extract_report_timestamp(entry) == 1_700_000_000


def test_record_and_get_reports_round_trips():
    store = HistoryStore(":memory:")
    entry = _entry(1_700_000_000, extra={"statusCode": 0})

    store.record_reports("key-a", [entry])

    results = store.get_reports(["key-a"], since=0)
    assert results == [entry]


def test_record_reports_dedupes_by_hashed_key_and_timestamp():
    store = HistoryStore(":memory:")
    first = _entry(1_700_000_000, extra={"statusCode": 0})
    second = _entry(1_700_000_000, extra={"statusCode": 1})  # same key+timestamp, different payload detail

    store.record_reports("key-a", [first])
    store.record_reports("key-a", [second])

    results = store.get_reports(["key-a"], since=0)
    assert results == [second]  # last write wins, no duplicate row


def test_get_reports_filters_by_since():
    store = HistoryStore(":memory:")
    old_entry = _entry(1_700_000_000)
    new_entry = _entry(1_700_000_100)
    store.record_reports("key-a", [old_entry, new_entry])

    results = store.get_reports(["key-a"], since=1_700_000_050)

    assert results == [new_entry]


def test_get_reports_only_returns_requested_hashed_keys():
    store = HistoryStore(":memory:")
    store.record_reports("key-a", [_entry(1_700_000_000)])
    store.record_reports("key-b", [_entry(1_700_000_000)])

    results = store.get_reports(["key-a"], since=0)

    assert len(results) == 1


def test_last_polled_at_is_none_before_first_poll():
    store = HistoryStore(":memory:")
    assert store.last_polled_at("key-a") is None


def test_mark_polled_then_last_polled_at_round_trips():
    store = HistoryStore(":memory:")
    store.mark_polled("key-a", when=1_700_000_000)
    assert store.last_polled_at("key-a") == 1_700_000_000


def test_mark_polled_defaults_to_now():
    store = HistoryStore(":memory:")
    before = int(time.time())
    store.mark_polled("key-a")
    after = int(time.time())
    assert before <= store.last_polled_at("key-a") <= after
