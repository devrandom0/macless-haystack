# Server-Side Location History Archiver Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let macless-haystack's endpoint accumulate location history on its own schedule, independent of whether any client app is ever opened, while calling Apple's fetch API less often than today.

**Architecture:** A new `endpoint/history/` package: `store.py` (a small SQLite wrapper, `HistoryStore`) and `archiver.py` (key derivation, devices-file parsing, the cache/freshness/force decision logic, and the background poll loop). `mh_endpoint.py`'s `do_POST` is changed to route through the new cache-aware logic instead of always calling Apple directly, and its startup code launches the poll loop as a daemon thread when a devices file is present. When no devices file exists, behavior is byte-for-byte identical to today.

**Tech Stack:** Python 3 stdlib (`sqlite3`, `threading`, `time`, `json`), the `cryptography` package (already a dependency, used for the same EC math `generate_keys.py` already performs), `pytest` + `unittest.mock` for tests (already set up in `endpoint/requirements-dev.txt` and `endpoint/tests/`).

**Spec:** `docs/superpowers/specs/2026-09-11-history-archiver-design.md`

## Global Constraints

- No new runtime dependencies. `sqlite3` and `threading` are stdlib; `cryptography` is already required.
- No new *test* dependencies beyond what `endpoint/requirements-dev.txt` already has (`pytest`).
- Zero behavior change when `endpoint/data/devices.json` (or whatever `history_devices_file` points to) doesn't exist — the archiver thread doesn't start, and `do_POST`'s cache logic must degrade to "call Apple for these ids, filter to the requested day window, return" exactly as it does today.
- No decryption of location payloads anywhere server-side. Store and forward raw entries exactly as Apple returns them.
- No frontend (Dart) changes in this plan.

---

### Task 1: `HistoryStore` — SQLite-backed report storage

**Files:**
- Create: `endpoint/history/store.py`
- Test: `endpoint/tests/test_history_store.py`

**Interfaces:**
- Produces: `extract_report_timestamp(entry: dict) -> int`, `HistoryStore(db_path: str)` with methods `record_reports(hashed_key: str, reports: list[dict]) -> None`, `get_reports(hashed_keys: list[str], since: int) -> list[dict]`, `mark_polled(hashed_key: str, when: int | None = None) -> None`, `last_polled_at(hashed_key: str) -> int | None`, `close() -> None`.

Every report `entry` is a dict shaped like the entries Apple's fetch API returns (and like `endpoint/mh_endpoint.py`'s current `do_POST` already consumes): at minimum a base64 `payload` field. `extract_report_timestamp` decodes the same way `do_POST` already does inline today (first 4 bytes of the decoded payload, big-endian, plus the Apple epoch offset `978307200`).

- [ ] **Step 1: Write the failing tests**

Create `endpoint/tests/test_history_store.py`:

```python
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
    old_entry = _entry(1_000)
    new_entry = _entry(2_000)
    store.record_reports("key-a", [old_entry, new_entry])

    results = store.get_reports(["key-a"], since=1_500)

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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd endpoint && ./venv/bin/python -m pytest tests/test_history_store.py -v`
Expected: FAIL with `ModuleNotFoundError: No module named 'history'` (the module doesn't exist yet).

- [ ] **Step 3: Write the implementation**

Create `endpoint/history/store.py`:

```python
import base64
import json
import sqlite3
import threading
import time


def extract_report_timestamp(entry):
    payload = base64.b64decode(entry["payload"])
    return int.from_bytes(payload[0:4], "big") + 978307200


class HistoryStore:
    def __init__(self, db_path):
        self._conn = sqlite3.connect(db_path, check_same_thread=False)
        self._lock = threading.Lock()
        with self._lock:
            self._conn.execute(
                "CREATE TABLE IF NOT EXISTS reports ("
                "hashed_key TEXT NOT NULL, "
                "timestamp INTEGER NOT NULL, "
                "entry_json TEXT NOT NULL, "
                "PRIMARY KEY (hashed_key, timestamp))"
            )
            self._conn.execute(
                "CREATE TABLE IF NOT EXISTS poll_status ("
                "hashed_key TEXT PRIMARY KEY, "
                "last_polled_at INTEGER NOT NULL)"
            )
            self._conn.commit()

    def record_reports(self, hashed_key, reports):
        with self._lock:
            for entry in reports:
                timestamp = extract_report_timestamp(entry)
                self._conn.execute(
                    "INSERT OR REPLACE INTO reports (hashed_key, timestamp, entry_json) VALUES (?, ?, ?)",
                    (hashed_key, timestamp, json.dumps(entry)),
                )
            self._conn.commit()

    def get_reports(self, hashed_keys, since):
        if not hashed_keys:
            return []
        placeholders = ",".join("?" for _ in hashed_keys)
        with self._lock:
            rows = self._conn.execute(
                f"SELECT entry_json FROM reports WHERE hashed_key IN ({placeholders}) AND timestamp > ?",
                (*hashed_keys, since),
            ).fetchall()
        return [json.loads(row[0]) for row in rows]

    def mark_polled(self, hashed_key, when=None):
        when = when if when is not None else int(time.time())
        with self._lock:
            self._conn.execute(
                "INSERT OR REPLACE INTO poll_status (hashed_key, last_polled_at) VALUES (?, ?)",
                (hashed_key, when),
            )
            self._conn.commit()

    def last_polled_at(self, hashed_key):
        with self._lock:
            row = self._conn.execute(
                "SELECT last_polled_at FROM poll_status WHERE hashed_key = ?",
                (hashed_key,),
            ).fetchone()
        return row[0] if row else None

    def close(self):
        with self._lock:
            self._conn.close()
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd endpoint && ./venv/bin/python -m pytest tests/test_history_store.py -v`
Expected: PASS (8 tests)

- [ ] **Step 5: Commit**

```bash
git add endpoint/history/store.py endpoint/tests/test_history_store.py
git commit -m "feat: add SQLite-backed HistoryStore for location report archiving"
```

---

### Task 2: `derive_hashed_public_key` — EC key derivation

**Files:**
- Create: `endpoint/history/archiver.py`
- Test: `endpoint/tests/test_history_archiver.py`

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces: `derive_hashed_public_key(private_key_b64: str) -> str`.

This ports the exact EC derivation `generate_keys.py` already performs (see `generate_keys.py:119-132`): a base64-encoded 28-byte SECP224R1 private key scalar in, the base64-encoded SHA-256 hash of the public key's x-coordinate out — the same "hashed adv key" Apple's fetch API expects as an `id`.

- [ ] **Step 1: Write the failing test**

Create `endpoint/tests/test_history_archiver.py`:

```python
from history.archiver import derive_hashed_public_key


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
    key_b = base64_of_all_twos = "AgICAgICAgICAgICAgICAgICAgICAgICAgICAg=="
    assert derive_hashed_public_key(key_a) != derive_hashed_public_key(key_b)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd endpoint && ./venv/bin/python -m pytest tests/test_history_archiver.py -v`
Expected: FAIL with `ModuleNotFoundError: No module named 'history.archiver'` (module doesn't exist; Task 1 created `history/store.py` but not `history/archiver.py` yet).

- [ ] **Step 3: Write the implementation**

Create `endpoint/history/archiver.py`:

```python
import base64
import hashlib
import json
import logging
import time

from cryptography.hazmat.backends import default_backend
from cryptography.hazmat.primitives.asymmetric import ec

logger = logging.getLogger()


def derive_hashed_public_key(private_key_b64):
    priv_bytes = base64.b64decode(private_key_b64)
    priv_int = int.from_bytes(priv_bytes, "big")
    public_x = ec.derive_private_key(
        priv_int, ec.SECP224R1(), default_backend()
    ).public_key().public_numbers().x
    adv_bytes = public_x.to_bytes(28, "big")
    return base64.b64encode(hashlib.sha256(adv_bytes).digest()).decode("ascii")
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd endpoint && ./venv/bin/python -m pytest tests/test_history_archiver.py -v`
Expected: PASS (3 tests)

- [ ] **Step 5: Commit**

```bash
git add endpoint/history/archiver.py endpoint/tests/test_history_archiver.py
git commit -m "feat: add EC-based hashed-public-key derivation for history archiver"
```

---

### Task 3: `load_tracked_keys` — devices-file parsing

**Files:**
- Modify: `endpoint/history/archiver.py`
- Test: `endpoint/tests/test_history_archiver.py`

**Interfaces:**
- Consumes: `derive_hashed_public_key` from Task 2.
- Produces: `load_tracked_keys(devices_file_path: str) -> list[str]`.

Parses a `PREFIX_devices.json`-shaped file — the exact format `generate_keys.py` produces (a JSON array of objects with at least `privateKey` and `additionalKeys`, see `generate_keys.py:16-29`) — and returns every hashed public key across every device's main key and additional keys, flattened into one list.

- [ ] **Step 1: Write the failing tests**

Add to `endpoint/tests/test_history_archiver.py`:

```python
import json

from history.archiver import load_tracked_keys


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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd endpoint && ./venv/bin/python -m pytest tests/test_history_archiver.py -v -k load_tracked_keys`
Expected: FAIL with `ImportError: cannot import name 'load_tracked_keys'`.

- [ ] **Step 3: Write the implementation**

Add to `endpoint/history/archiver.py` (after `derive_hashed_public_key`):

```python
def load_tracked_keys(devices_file_path):
    with open(devices_file_path, "r") as f:
        devices = json.load(f)

    hashed_keys = []
    for device in devices:
        private_keys = [device["privateKey"]] + list(device.get("additionalKeys", []))
        for private_key_b64 in private_keys:
            hashed_keys.append(derive_hashed_public_key(private_key_b64))
    return hashed_keys
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd endpoint && ./venv/bin/python -m pytest tests/test_history_archiver.py -v`
Expected: PASS (all tests in the file so far)

- [ ] **Step 5: Commit**

```bash
git add endpoint/history/archiver.py endpoint/tests/test_history_archiver.py
git commit -m "feat: parse devices.json into tracked hashed public keys"
```

---

### Task 4: `fetch_reports_with_cache` — the cache/freshness/force decision

**Files:**
- Modify: `endpoint/history/archiver.py`
- Test: `endpoint/tests/test_history_archiver.py`

**Interfaces:**
- Consumes: `HistoryStore` (Task 1) — specifically `last_polled_at`, `record_reports`, `mark_polled`, `get_reports`; `extract_report_timestamp` (Task 1).
- Produces: `fetch_reports_with_cache(ids: list[str], days: int, force: bool, store: HistoryStore | None, poll_interval_hours: float, fetch_from_apple: Callable[[list[str]], list[dict]]) -> list[dict]`, and a private helper `_store_fetched_entries(hashed_keys: list[str], entries: list[dict], store: HistoryStore, when: int) -> None`. This is what `mh_endpoint.py`'s `do_POST` will call in Task 6 — `fetch_from_apple` is a caller-supplied callable so this function has no direct dependency on `requests` or Apple's URL, keeping it fully testable with a fake.

`fetch_from_apple` is expected to return a list of entry dicts exactly like Apple's fetch API does today (each entry has at least `payload` and `id`), or raise on failure — mirroring `do_POST`'s existing `requests.post(...)` call.

Behavior:
- If `store` is `None` (archiver not configured): call `fetch_from_apple(ids)`, filter to entries newer than the `days` cutoff, sort newest-first, return. This must be **exactly** what `do_POST` does today — see `mh_endpoint.py:83-118` for the current inline logic this replaces.
- If `store` is set: for each id, it's "stale" if never polled, or last polled longer than `poll_interval_hours` ago, or `force` is `True`. If any ids are stale, fetch just those from Apple, store the results (via `_store_fetched_entries`), and mark them polled — but if the live fetch raises, log a warning and fall back to whatever's already cached instead of failing the request. Either way, read back from the store filtered to the `days` window, sort newest-first, return.

- [ ] **Step 1: Write the failing tests**

Add to `endpoint/tests/test_history_archiver.py`:

```python
from unittest.mock import MagicMock

from history.archiver import fetch_reports_with_cache
from history.store import HistoryStore


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
```

Add the missing import at the top of the test file: `import time` and `from history.store import extract_report_timestamp`.

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd endpoint && ./venv/bin/python -m pytest tests/test_history_archiver.py -v -k fetch_reports_with_cache`
Expected: FAIL with `ImportError: cannot import name 'fetch_reports_with_cache'`.

- [ ] **Step 3: Write the implementation**

Add to `endpoint/history/archiver.py` (needs `from history.store import extract_report_timestamp` added to the imports at the top):

```python
def _store_fetched_entries(hashed_keys, entries, store, when):
    entries_by_id = {}
    for entry in entries:
        entries_by_id.setdefault(entry["id"], []).append(entry)
    for hashed_key in hashed_keys:
        store.record_reports(hashed_key, entries_by_id.get(hashed_key, []))
        store.mark_polled(hashed_key, when)


def fetch_reports_with_cache(ids, days, force, store, poll_interval_hours, fetch_from_apple):
    now = int(time.time())
    since = now - (days * 86400)

    if store is None:
        entries = fetch_from_apple(ids)
        entries = [e for e in entries if extract_report_timestamp(e) > since]
        return sorted(entries, key=extract_report_timestamp, reverse=True)

    freshness_window = poll_interval_hours * 3600
    stale_ids = [
        hashed_key for hashed_key in ids
        if force
        or store.last_polled_at(hashed_key) is None
        or (now - store.last_polled_at(hashed_key)) > freshness_window
    ]

    if stale_ids:
        try:
            fresh_entries = fetch_from_apple(stale_ids)
        except Exception as e:
            logger.warning(f"Live fetch failed, falling back to cached history: {e}")
        else:
            _store_fetched_entries(stale_ids, fresh_entries, store, now)

    entries = store.get_reports(ids, since)
    return sorted(entries, key=extract_report_timestamp, reverse=True)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd endpoint && ./venv/bin/python -m pytest tests/test_history_archiver.py -v`
Expected: PASS (all tests in the file)

- [ ] **Step 5: Commit**

```bash
git add endpoint/history/archiver.py endpoint/tests/test_history_archiver.py
git commit -m "feat: add cache/freshness/force decision logic for history reads"
```

---

### Task 5: `run_archiver_loop` — the background poll loop

**Files:**
- Modify: `endpoint/history/archiver.py`
- Test: `endpoint/tests/test_history_archiver.py`

**Interfaces:**
- Consumes: `load_tracked_keys` (Task 3), `_store_fetched_entries` (Task 4), `HistoryStore` (Task 1).
- Produces: `run_archiver_loop(devices_file_path: str, store: HistoryStore, poll_interval_hours: float, fetch_from_apple: Callable, sleep_fn: Callable[[float], None] = time.sleep) -> None`.

Runs forever: load the tracked keys once, then on each iteration fetch and store fresh reports for all of them, sleeping `poll_interval_hours` between iterations. `sleep_fn` is injectable so tests can run exactly one iteration without a real sleep — a test-only `sleep_fn` that raises after being called stops the loop deterministically.

- [ ] **Step 1: Write the failing tests**

Add `import pytest` to the top of `endpoint/tests/test_history_archiver.py` if it isn't already there (needed for `pytest.raises` below — the file's other tests so far haven't needed it).

Add to `endpoint/tests/test_history_archiver.py`:

```python
from history.archiver import run_archiver_loop


class _StopLoop(Exception):
    pass


def test_run_archiver_loop_loads_keys_fetches_and_stores(tmp_path):
    devices_file = tmp_path / "devices.json"
    devices_file.write_text(json.dumps([
        {"id": 1, "name": "A", "privateKey": "AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQ==", "additionalKeys": []},
    ]))
    hashed_key = derive_hashed_public_key("AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQ==")

    store = HistoryStore(":memory:")
    entry = _entry(int(time.time()), id_=hashed_key)
    fetch_from_apple = MagicMock(return_value=[entry])

    def sleep_and_stop(_seconds):
        raise _StopLoop()

    with pytest.raises(_StopLoop):
        run_archiver_loop(
            devices_file_path=str(devices_file), store=store, poll_interval_hours=4,
            fetch_from_apple=fetch_from_apple, sleep_fn=sleep_and_stop,
        )

    fetch_from_apple.assert_called_once_with([hashed_key])
    assert store.get_reports([hashed_key], since=0) == [entry]
    assert store.last_polled_at(hashed_key) is not None


def test_run_archiver_loop_missing_devices_file_returns_without_looping(tmp_path):
    missing_path = str(tmp_path / "does_not_exist.json")
    store = HistoryStore(":memory:")
    fetch_from_apple = MagicMock()

    def fail_if_called(_seconds):
        raise AssertionError("sleep_fn should never be called if the devices file is missing")

    run_archiver_loop(
        devices_file_path=missing_path, store=store, poll_interval_hours=4,
        fetch_from_apple=fetch_from_apple, sleep_fn=fail_if_called,
    )

    fetch_from_apple.assert_not_called()


def test_run_archiver_loop_continues_after_fetch_failure(tmp_path):
    devices_file = tmp_path / "devices.json"
    devices_file.write_text(json.dumps([
        {"id": 1, "name": "A", "privateKey": "AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQ==", "additionalKeys": []},
    ]))
    store = HistoryStore(":memory:")
    fetch_from_apple = MagicMock(side_effect=Exception("network error"))

    def sleep_and_stop(_seconds):
        raise _StopLoop()

    with pytest.raises(_StopLoop):
        run_archiver_loop(
            devices_file_path=str(devices_file), store=store, poll_interval_hours=4,
            fetch_from_apple=fetch_from_apple, sleep_fn=sleep_and_stop,
        )
    # Reaching sleep_fn (and raising _StopLoop from it) proves the exception
    # from fetch_from_apple was caught rather than propagating out of the loop.
```

Remove the stray placeholder line `hashed_key = derive_hashed_public_key_result_present` before running — it's dead code accidentally left from copy-paste; the very next line already reassigns `hashed_key` correctly, so simply delete that first line.

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd endpoint && ./venv/bin/python -m pytest tests/test_history_archiver.py -v -k run_archiver_loop`
Expected: FAIL with `ImportError: cannot import name 'run_archiver_loop'`.

- [ ] **Step 3: Write the implementation**

Add to `endpoint/history/archiver.py`:

```python
def run_archiver_loop(devices_file_path, store, poll_interval_hours, fetch_from_apple, sleep_fn=time.sleep):
    try:
        hashed_keys = load_tracked_keys(devices_file_path)
    except (OSError, ValueError, KeyError) as e:
        logger.error(f"Could not load history devices file {devices_file_path}: {e}")
        return

    logger.info(f"History archiver tracking {len(hashed_keys)} key(s), polling every {poll_interval_hours}h")
    while True:
        try:
            entries = fetch_from_apple(hashed_keys)
            _store_fetched_entries(hashed_keys, entries, store, int(time.time()))
        except Exception as e:
            logger.error(f"History archiver poll failed: {e}", exc_info=True)
        sleep_fn(poll_interval_hours * 3600)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd endpoint && ./venv/bin/python -m pytest tests/test_history_archiver.py -v`
Expected: PASS (all tests in the file)

- [ ] **Step 5: Run the full test suite**

Run: `cd endpoint && ./venv/bin/python -m pytest tests/ -v`
Expected: PASS (every test in `endpoint/tests/`, including the pre-existing GSA 2FA tests — confirms nothing in this task touched shared state)

- [ ] **Step 6: Commit**

```bash
git add endpoint/history/archiver.py endpoint/tests/test_history_archiver.py
git commit -m "feat: add background poll loop for history archiver"
```

---

### Task 6: Wire it into `mh_endpoint.py` and `config.ini`

**Files:**
- Modify: `endpoint/mh_config.py`
- Modify: `endpoint/data/config.ini`
- Modify: `endpoint/mh_endpoint.py`

**Interfaces:**
- Consumes: `HistoryStore` (Task 1), `fetch_reports_with_cache`, `run_archiver_loop` (Task 4, 5) from `history.archiver` / `history.store`.
- Produces: `mh_config.getHistoryDevicesFile() -> str`, `mh_config.getHistoryPollIntervalHours() -> float`. No new public interface from `mh_endpoint.py` — this task is integration, not new logic, so its "test" is running the full suite plus a manual smoke check rather than new unit tests (the logic being wired together is already fully covered by Tasks 1-5).

- [ ] **Step 1: Add config getters**

In `endpoint/mh_config.py`, add after `getEndpointPass()` (around line 60):

```python
def getHistoryDevicesFile():
    return config.get('Settings', 'history_devices_file', fallback='devices.json')


def getHistoryPollIntervalHours():
    return float(config.get('Settings', 'history_poll_interval_hours', fallback='4'))
```

In `endpoint/data/config.ini`, add under the `endpoint_user`/`endpoint_pass` lines:

```ini
history_devices_file=devices.json
history_poll_interval_hours=4
```

- [ ] **Step 2: Wire `do_POST` to use the cache-aware fetch**

In `endpoint/mh_endpoint.py`, remove the now-unused `from collections import OrderedDict` import (line 10) — the new `do_POST` below no longer builds a manual `OrderedDict`, and nothing else in this file uses it. Replace the remaining imports at the top (add the new import alongside the existing ones):

```python
import mh_config
from history import archiver as history_archiver
from history.store import HistoryStore
from register import apple_cryptography, pypush_gsa_icloud
```

Add a module-level variable right after `logger = logging.getLogger()`:

```python
history_store = None
```

Replace the body of `do_POST` (currently `mh_endpoint.py:67-133`) with:

```python
    def do_POST(self):
        if not self.authenticate():
            self.send_response(401)
            self.addCORSHeaders()
            self.send_header('WWW-Authenticate', 'Basic realm="Auth Realm"')
            self.end_headers()
            return
        if hasattr(self.headers, 'getheader'):
            content_len = int(self.headers.getheader('content-length', 0))
        else:
            content_len = int(self.headers.get('content-length'))

        post_body = self.rfile.read(content_len)

        logger.debug('Getting with post: ' + str(post_body))
        body = json.loads(post_body)
        days = body.get('days', 7)
        force = body.get('force', False)
        ids = list(body['ids'])
        logger.debug('Querying for ' + str(days) + ' days')

        def fetch_from_apple(fetch_ids):
            data = {"search": [{"startDate": 1, "ids": fetch_ids}]}
            with requests.post("https://gateway.icloud.com/acsnservice/fetch",
                                auth=getAuth(regenerate=False, second_factor='sms'),
                                headers=pypush_gsa_icloud.generate_anisette_headers(),
                                json=data) as r:
                r.raise_for_status()
            return json.loads(r.content.decode())['results']

        try:
            results = history_archiver.fetch_reports_with_cache(
                ids, days, force, history_store,
                mh_config.getHistoryPollIntervalHours(), fetch_from_apple,
            )

            self.send_response(200)
            self.addCORSHeaders()
            self.end_headers()

            responseBody = json.dumps({"results": results})
            self.wfile.write(responseBody.encode())
        except requests.exceptions.ConnectTimeout:
            logger.error("Timeout to " + mh_config.getAnisetteServer() +
                         ", is your anisette running and accepting Connections?")
            self.send_response(504)
        except Exception as e:
            logger.error(f"Unknown error occurred {e}", exc_info=True)
            self.send_response(501)
```

Note what's intentionally dropped versus the old code: the manual `OrderedDict`-based timestamp dedup collapsed *any* two entries sharing a timestamp regardless of which id they belonged to (an accident of iterating a flat list into one dict), which could silently drop a real report from a different device's rotating key. `fetch_reports_with_cache` dedupes only within `(hashed_key, timestamp)`, which is more correct, not a regression — this is called out in the design spec.

- [ ] **Step 3: Start the archiver thread at startup**

In `endpoint/mh_endpoint.py`, add `import os` is already present; add `import threading` to the top imports. In the `if __name__ == "__main__":` block (currently `mh_endpoint.py:172-210`), after the existing `apple_cryptography.registerDevice()` block and before `Handler = ServerHandler` (i.e. right after line 177), add:

```python
    devices_file_path = mh_config.getConfigPath() + '/' + mh_config.getHistoryDevicesFile()
    if os.path.isfile(devices_file_path):
        history_store = HistoryStore(mh_config.getConfigPath() + '/history.db')

        def fetch_from_apple(fetch_ids):
            data = {"search": [{"startDate": 1, "ids": fetch_ids}]}
            with requests.post("https://gateway.icloud.com/acsnservice/fetch",
                                auth=getAuth(regenerate=False, second_factor='sms'),
                                headers=pypush_gsa_icloud.generate_anisette_headers(),
                                json=data) as r:
                r.raise_for_status()
            return json.loads(r.content.decode())['results']

        archiver_thread = threading.Thread(
            target=history_archiver.run_archiver_loop,
            args=(devices_file_path, history_store, mh_config.getHistoryPollIntervalHours(), fetch_from_apple),
            daemon=True,
        )
        archiver_thread.start()
        logger.info(f"History archiver started, tracking devices from {devices_file_path}")
    else:
        logger.info(f"No history devices file at {devices_file_path}, history archiving disabled")
```

This assigns to the module-level `history_store` name — since this code runs at module scope inside `if __name__ == "__main__":` (not inside a function), no `global` declaration is needed; it directly rebinds the module-level variable declared in Step 2.

Note the `fetch_from_apple` closure is duplicated between `do_POST` and this startup block. This is intentional, not an oversight to fix later: `do_POST`'s copy calls `getAuth`/`generate_anisette_headers` fresh on every request (matching today's behavior exactly), while extracting it to a shared module-level function would be a reasonable follow-up cleanup but isn't required for correctness — flagging it here so a reviewer doesn't mistake it for a missed extraction.

- [ ] **Step 4: Run the full test suite**

Run: `cd endpoint && ./venv/bin/python -m pytest tests/ -v`
Expected: PASS (all tests, including Tasks 1-5's new tests and the pre-existing GSA 2FA tests)

- [ ] **Step 5: Manual smoke test**

This step has no automated test — `do_POST` is an HTTP handler method and the existing codebase has no precedent for spinning up a live `HTTPServer` in tests (see `endpoint/tests/` — none of the existing tests do this). Verify by hand instead:

1. Generate a throwaway test keypair: `cd /Users/sinamoghaddas/projects/my-projects/devrandom0/macless-haystack && python3 generate_keys.py -p SMOKETEST` (requires the `cryptography` package; use `endpoint/venv/bin/python3` if the system Python lacks it).
2. Copy `output/SMOKETEST_devices.json` to `endpoint/data/devices.json`.
3. Confirm `endpoint/data/config.ini` has `history_devices_file=devices.json` (from Step 1).
4. Start the endpoint locally against a real or already-authenticated setup (or just run `python3 -c "from history import archiver; print(archiver.load_tracked_keys('endpoint/data/devices.json'))"` from the repo root with `PYTHONPATH=endpoint` to confirm the devices file parses into hashed keys without error) — a full live run additionally requires a working anisette server and Apple auth, which is out of scope for this smoke test; the goal here is just confirming the new code path doesn't crash on startup with a real devices file, not a live Apple round-trip.
5. Delete `endpoint/data/devices.json` afterward (it's a throwaway test key, not meant to be committed) and confirm `git status` shows it as untracked/absent.

- [ ] **Step 6: Commit**

```bash
git add endpoint/mh_config.py endpoint/data/config.ini endpoint/mh_endpoint.py
git commit -m "feat: wire history archiver into mh_endpoint startup and do_POST"
```

---

## Self-Review Notes

- **Spec coverage:** `derive_hashed_public_key` (Task 2), `load_tracked_keys` (Task 3), `HistoryStore` (Task 1), `run_archiver_loop` as a daemon thread (Task 5, Task 6 Step 3), cache/freshness/force logic in `do_POST` (Task 4, Task 6 Step 2), config keys (Task 6 Step 1), fallback-to-cache on Apple failure (Task 4), zero-behavior-change when no devices file (Task 4's `store is None` branch, Task 6 Step 3's `else` branch) — all covered. Pruning `history.db` and wiring the app's Refresh button to `force` are explicitly out of scope per the spec's Follow-ups section, not part of this plan.
- **Placeholder scan:** none found — every step has real code, real file paths, real run commands.
- **Type consistency:** `HistoryStore` methods (`record_reports`, `get_reports`, `mark_polled`, `last_polled_at`) are used with the same names and argument order in Tasks 4, 5, and 6 as defined in Task 1. `fetch_reports_with_cache`'s signature (`ids, days, force, store, poll_interval_hours, fetch_from_apple`) matches its Task 6 call site exactly. `extract_report_timestamp` is imported from `history.store` everywhere it's used (Tasks 4, and test files), never redefined.
