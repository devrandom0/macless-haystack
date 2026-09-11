# Frontend Control of Server-Side History Archiving Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the app enable/disable server-side location-history archiving per device (or for all devices at once), replacing the manual `devices.json` file with an HTTP API and an encrypted-at-rest device registry.

**Architecture:** A new SQLite-backed `TrackedDeviceStore` (table `tracked_devices` in the existing `history.db`) replaces `devices.json` as the archiver's source of tracked keys. Private keys sent to the server are encrypted at rest with a locally-generated Fernet key before being stored. Two new HTTP endpoints (`GET`/`POST /history/devices`) let the app read and write the registry. The archiver's poll loop re-reads the enabled-key list every cycle instead of once at startup, so a toggle takes effect without a container restart. A one-time startup migration moves any existing `devices.json` into the registry and deletes the file.

**Tech Stack:** Python 3.12 stdlib `sqlite3` + `cryptography.fernet` (already a dependency) on the server; Dart/Flutter with `package:http`'s `Client`/`IOClient`/`MockClient` on the app side. No new dependencies on either side.

**Spec:** `docs/superpowers/specs/2026-09-11-history-frontend-control-design.md`

## Global Constraints

- No new Python or Dart dependencies — `cryptography` (server) and `http` (Flutter, `testing.dart` ships in the same package) already cover everything needed.
- Every new Python function is developed test-first (pytest); `history_archive_service.dart` is developed test-first (`package:http/testing.dart`'s `MockClient`).
- Widget-level `SwitchListTile` wiring in `AccessoryDetail`/`PreferencesPage` has **no automated tests** — verified manually per each task's steps. This matches the spec's explicit call-out that this codebase has no existing test coverage on those two screens.
- `GET`/`POST /history/devices` must go through the existing `authenticate()` basic-auth gate, exactly like every other endpoint today.
- `POST /history/devices` and `GET /history/devices` responses never include a private key or `encrypted_private_key` value.
- The migration from `devices.json` to the registry only runs when `tracked_devices` is empty, and only deletes the file on success — a parse/derive failure must leave the file in place.
- `run_archiver_loop` must call `TrackedDeviceStore.enabled_keys()` at the top of every loop iteration (not once before the loop) so a toggle flip is picked up within one poll interval without a restart.
- The existing `GET`/`POST /` (root path) request/response behavior is unchanged.

---

### Task 1: Encryption-at-rest for stored private keys (`endpoint/history/crypto.py`)

**Files:**
- Create: `endpoint/history/crypto.py`
- Test: `endpoint/tests/test_history_crypto.py`
- Modify: `endpoint/mh_config.py` (add `getHistoryMasterKeyFile()`)
- Modify: `endpoint/data/config.ini` (add `history_master_key_file=history_key.bin`)
- Modify: `.gitignore` (ignore the generated key file)

**Interfaces:**
- Produces: `load_or_create_key(key_file_path: str) -> bytes`, `encrypt(key: bytes, plaintext: str) -> bytes`, `decrypt(key: bytes, ciphertext: bytes) -> str`. `mh_config.getHistoryMasterKeyFile() -> str` (default `'history_key.bin'`).

- [ ] **Step 1: Write the failing tests**

Create `endpoint/tests/test_history_crypto.py`:

```python
import os
import stat

import pytest
from cryptography.fernet import InvalidToken

from history.crypto import decrypt, encrypt, load_or_create_key


def test_load_or_create_key_creates_file_with_restricted_permissions(tmp_path):
    key_file = tmp_path / "history_key.bin"

    load_or_create_key(str(key_file))

    assert key_file.exists()
    mode = stat.S_IMODE(os.stat(key_file).st_mode)
    assert mode == 0o600


def test_load_or_create_key_reuses_existing_key(tmp_path):
    key_file = tmp_path / "history_key.bin"

    first = load_or_create_key(str(key_file))
    second = load_or_create_key(str(key_file))

    assert first == second


def test_encrypt_decrypt_round_trips(tmp_path):
    key = load_or_create_key(str(tmp_path / "history_key.bin"))
    plaintext = "AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQ=="

    ciphertext = encrypt(key, plaintext)

    assert decrypt(key, ciphertext) == plaintext


def test_encrypt_output_does_not_contain_plaintext(tmp_path):
    key = load_or_create_key(str(tmp_path / "history_key.bin"))
    plaintext = "AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQ=="

    ciphertext = encrypt(key, plaintext)

    assert plaintext.encode("utf-8") not in ciphertext


def test_decrypt_with_wrong_key_raises(tmp_path):
    key_a = load_or_create_key(str(tmp_path / "key_a.bin"))
    key_b = load_or_create_key(str(tmp_path / "key_b.bin"))
    ciphertext = encrypt(key_a, "plaintext")

    with pytest.raises(InvalidToken):
        decrypt(key_b, ciphertext)
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `pytest endpoint/tests/test_history_crypto.py -v`
Expected: FAIL with `ModuleNotFoundError: No module named 'history.crypto'`

- [ ] **Step 3: Write the minimal implementation**

Create `endpoint/history/crypto.py`:

```python
import os

from cryptography.fernet import Fernet


def load_or_create_key(key_file_path):
    if os.path.exists(key_file_path):
        with open(key_file_path, "rb") as f:
            return f.read()

    key = Fernet.generate_key()
    fd = os.open(key_file_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "wb") as f:
        f.write(key)
    return key


def encrypt(key, plaintext):
    return Fernet(key).encrypt(plaintext.encode("utf-8"))


def decrypt(key, ciphertext):
    return Fernet(key).decrypt(ciphertext).decode("utf-8")
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `pytest endpoint/tests/test_history_crypto.py -v`
Expected: PASS (5 tests)

- [ ] **Step 5: Add the config getter**

In `endpoint/mh_config.py`, add this function next to `getHistoryPollIntervalHours()` (no test — every existing config getter in this file is untested; this one follows the identical pattern):

```python
def getHistoryMasterKeyFile():
    return config.get('Settings', 'history_master_key_file', fallback='history_key.bin')
```

In `endpoint/data/config.ini`, add this line under the existing `history_poll_interval_hours=4` line:

```
history_master_key_file=history_key.bin
```

- [ ] **Step 6: Ignore the generated key file**

In `.gitignore`, add this line right after the existing `endpoint/data/*.db` line:

```
endpoint/data/*.bin
```

- [ ] **Step 7: Commit**

```bash
git add endpoint/history/crypto.py endpoint/tests/test_history_crypto.py endpoint/mh_config.py endpoint/data/config.ini .gitignore
git commit -m "feat: add Fernet-based encryption at rest for archived private keys"
```

---

### Task 2: Tracked-device registry (`endpoint/history/registry.py`)

**Files:**
- Create: `endpoint/history/registry.py`
- Test: `endpoint/tests/test_history_registry.py`

**Interfaces:**
- Consumes: nothing from Task 1 (independent of crypto — stores whatever bytes it's given).
- Produces: `TrackedDeviceStore(db_path)` with methods `upsert(hashed_public_key: str, name: str, accessory_id: str | None, encrypted_private_key: bytes, enabled: bool, when: int | None = None) -> None`, `list_devices() -> list[dict]` (each dict: `{"hashedPublicKey", "name", "accessoryId", "enabled"}`, never includes the encrypted key), `enabled_keys() -> list[str]`, `is_empty() -> bool`.

- [ ] **Step 1: Write the failing tests**

Create `endpoint/tests/test_history_registry.py`:

```python
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `pytest endpoint/tests/test_history_registry.py -v`
Expected: FAIL with `ModuleNotFoundError: No module named 'history.registry'`

- [ ] **Step 3: Write the minimal implementation**

Create `endpoint/history/registry.py`:

```python
import sqlite3
import threading
import time


class TrackedDeviceStore:
    def __init__(self, db_path):
        self._conn = sqlite3.connect(db_path, check_same_thread=False)
        self._lock = threading.Lock()
        with self._lock:
            self._conn.execute(
                "CREATE TABLE IF NOT EXISTS tracked_devices ("
                "hashed_public_key TEXT PRIMARY KEY, "
                "name TEXT NOT NULL, "
                "accessory_id TEXT, "
                "encrypted_private_key BLOB NOT NULL, "
                "enabled INTEGER NOT NULL, "
                "updated_at INTEGER NOT NULL)"
            )
            self._conn.commit()

    def upsert(self, hashed_public_key, name, accessory_id, encrypted_private_key, enabled, when=None):
        when = when if when is not None else int(time.time())
        with self._lock:
            self._conn.execute(
                "INSERT OR REPLACE INTO tracked_devices "
                "(hashed_public_key, name, accessory_id, encrypted_private_key, enabled, updated_at) "
                "VALUES (?, ?, ?, ?, ?, ?)",
                (hashed_public_key, name, accessory_id, encrypted_private_key, int(bool(enabled)), when),
            )
            self._conn.commit()

    def list_devices(self):
        with self._lock:
            rows = self._conn.execute(
                "SELECT hashed_public_key, name, accessory_id, enabled FROM tracked_devices"
            ).fetchall()
        return [
            {
                "hashedPublicKey": row[0],
                "name": row[1],
                "accessoryId": row[2],
                "enabled": bool(row[3]),
            }
            for row in rows
        ]

    def enabled_keys(self):
        with self._lock:
            rows = self._conn.execute(
                "SELECT hashed_public_key FROM tracked_devices WHERE enabled = 1"
            ).fetchall()
        return [row[0] for row in rows]

    def is_empty(self):
        with self._lock:
            row = self._conn.execute("SELECT COUNT(*) FROM tracked_devices").fetchone()
        return row[0] == 0
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `pytest endpoint/tests/test_history_registry.py -v`
Expected: PASS (7 tests)

- [ ] **Step 5: Commit**

```bash
git add endpoint/history/registry.py endpoint/tests/test_history_registry.py
git commit -m "feat: add SQLite-backed tracked-device registry"
```

---

### Task 3: Dynamic poll list and devices.json migration (`endpoint/history/archiver.py`)

**Files:**
- Modify: `endpoint/history/archiver.py`
- Modify: `endpoint/tests/test_history_archiver.py` (replace the 4 existing `run_archiver_loop` tests, add migration tests)

**Interfaces:**
- Consumes: `history.crypto.encrypt(key, plaintext) -> bytes` (Task 1), `history.registry.TrackedDeviceStore` with `upsert(...)`, `is_empty()` (Task 2).
- Produces: `migrate_devices_json_to_registry(devices_file_path: str, tracked_device_store: TrackedDeviceStore, encryption_key: bytes) -> None`. `run_archiver_loop(tracked_device_store: TrackedDeviceStore, store: HistoryStore, poll_interval_hours: float, fetch_from_apple, sleep_fn=time.sleep) -> None` — **signature changed**: `devices_file_path` param removed, `tracked_device_store` param added as the first argument. `derive_hashed_public_key`, `load_tracked_keys`, and `fetch_reports_with_cache` are unchanged.

- [ ] **Step 1: Write the failing tests**

In `endpoint/tests/test_history_archiver.py`, delete these four existing tests (their behavior is superseded — the loop no longer reads a file at all):
- `test_run_archiver_loop_loads_keys_fetches_and_stores`
- `test_run_archiver_loop_missing_devices_file_returns_without_looping`
- `test_run_archiver_loop_malformed_devices_file_returns_without_looping`
- `test_run_archiver_loop_continues_after_fetch_failure`

Add this import near the top of the file, alongside the existing `from history.archiver import ...` line:

```python
from history.archiver import migrate_devices_json_to_registry
from history.crypto import decrypt, load_or_create_key
from history.registry import TrackedDeviceStore
```

Add these tests (a fake store keeps these tests focused on the loop's re-read behavior, independent of Task 2's real `TrackedDeviceStore`):

```python
class _FakeTrackedDeviceStore:
    def __init__(self, keys):
        self._keys = keys

    def enabled_keys(self):
        return self._keys


def test_run_archiver_loop_fetches_and_stores_enabled_keys():
    store = HistoryStore(":memory:")
    tracked = _FakeTrackedDeviceStore(["key-a"])
    entry = _entry(int(time.time()), id_="key-a")
    fetch_from_apple = MagicMock(return_value=[entry])

    def sleep_and_stop(_seconds):
        raise _StopLoop()

    with pytest.raises(_StopLoop):
        run_archiver_loop(
            tracked_device_store=tracked, store=store, poll_interval_hours=4,
            fetch_from_apple=fetch_from_apple, sleep_fn=sleep_and_stop,
        )

    fetch_from_apple.assert_called_once_with(["key-a"])
    assert store.get_reports(["key-a"], since=0) == [entry]


def test_run_archiver_loop_rereads_enabled_keys_every_iteration():
    store = HistoryStore(":memory:")

    class _TogglingStore:
        def __init__(self):
            self.calls = 0

        def enabled_keys(self):
            self.calls += 1
            return ["key-a"] if self.calls == 1 else []

    tracked = _TogglingStore()
    fetch_from_apple = MagicMock(return_value=[])
    call_count = {"n": 0}

    def sleep_and_stop_after_two(_seconds):
        call_count["n"] += 1
        if call_count["n"] >= 2:
            raise _StopLoop()

    with pytest.raises(_StopLoop):
        run_archiver_loop(
            tracked_device_store=tracked, store=store, poll_interval_hours=4,
            fetch_from_apple=fetch_from_apple, sleep_fn=sleep_and_stop_after_two,
        )

    assert tracked.calls == 2
    assert fetch_from_apple.call_args_list[0].args == (["key-a"],)


def test_run_archiver_loop_skips_fetch_when_no_enabled_keys():
    store = HistoryStore(":memory:")
    tracked = _FakeTrackedDeviceStore([])
    fetch_from_apple = MagicMock()

    def sleep_and_stop(_seconds):
        raise _StopLoop()

    with pytest.raises(_StopLoop):
        run_archiver_loop(
            tracked_device_store=tracked, store=store, poll_interval_hours=4,
            fetch_from_apple=fetch_from_apple, sleep_fn=sleep_and_stop,
        )

    fetch_from_apple.assert_not_called()


def test_run_archiver_loop_continues_after_fetch_failure():
    store = HistoryStore(":memory:")
    tracked = _FakeTrackedDeviceStore(["key-a"])
    fetch_from_apple = MagicMock(side_effect=Exception("network error"))

    def sleep_and_stop(_seconds):
        raise _StopLoop()

    with pytest.raises(_StopLoop):
        run_archiver_loop(
            tracked_device_store=tracked, store=store, poll_interval_hours=4,
            fetch_from_apple=fetch_from_apple, sleep_fn=sleep_and_stop,
        )
    # Reaching sleep_fn (and raising _StopLoop from it) proves the exception
    # from fetch_from_apple was caught rather than propagating out of the loop.


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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `pytest endpoint/tests/test_history_archiver.py -v`
Expected: FAIL — `run_archiver_loop` tests fail with `TypeError: run_archiver_loop() got an unexpected keyword argument 'tracked_device_store'`; migration tests fail with `ImportError: cannot import name 'migrate_devices_json_to_registry'`.

- [ ] **Step 3: Write the minimal implementation**

In `endpoint/history/archiver.py`, change the imports at the top (add `os`, drop nothing):

```python
import base64
import hashlib
import json
import logging
import os
import sqlite3
import time

from cryptography.hazmat.backends import default_backend
from cryptography.hazmat.primitives.asymmetric import ec

from history import crypto
from history.store import extract_report_timestamp
```

Replace the existing `run_archiver_loop` function with:

```python
def run_archiver_loop(tracked_device_store, store, poll_interval_hours, fetch_from_apple, sleep_fn=time.sleep):
    logger.info(f"History archiver started, polling every {poll_interval_hours}h")
    while True:
        try:
            hashed_keys = tracked_device_store.enabled_keys()
            if hashed_keys:
                entries = fetch_from_apple(hashed_keys)
                _store_fetched_entries(hashed_keys, entries, store, int(time.time()))
            else:
                logger.debug("History archiver: no enabled devices, skipping poll")
        except Exception as e:
            logger.error(f"History archiver poll failed: {e}", exc_info=True)
        sleep_fn(poll_interval_hours * 3600)
```

Add this new function below `load_tracked_keys` (it reuses `load_tracked_keys`'s per-device key derivation logic, but also needs each device's name and raw private key, so it duplicates the file-walking loop rather than reusing `load_tracked_keys` directly):

```python
def migrate_devices_json_to_registry(devices_file_path, tracked_device_store, encryption_key):
    if not tracked_device_store.is_empty():
        return
    if not os.path.isfile(devices_file_path):
        return

    try:
        with open(devices_file_path, "r") as f:
            devices = json.load(f)
        now = int(time.time())
        rows = []
        for device in devices:
            name = device.get("name", "Unnamed")
            private_keys = [device["privateKey"]] + list(device.get("additionalKeys", []))
            for index, private_key_b64 in enumerate(private_keys):
                hashed_key = derive_hashed_public_key(private_key_b64)
                encrypted = crypto.encrypt(encryption_key, private_key_b64)
                entry_name = name if index == 0 else f"{name} (extra key)"
                rows.append((hashed_key, entry_name, encrypted))
    except Exception as e:
        logger.error(f"Could not migrate {devices_file_path} to the device registry: {e}", exc_info=True)
        return

    for hashed_key, entry_name, encrypted in rows:
        tracked_device_store.upsert(hashed_key, entry_name, None, encrypted, enabled=True, when=now)

    os.remove(devices_file_path)
    logger.info(f"Migrated devices from {devices_file_path} into the device registry; file removed")
```

Note the two-phase structure (compute `rows` inside the `try`, write them outside it): a failure while parsing or deriving keys must leave both the file and the registry untouched, so no row is written until every row has been computed successfully.

- [ ] **Step 4: Run tests to verify they pass**

Run: `pytest endpoint/tests/test_history_archiver.py -v`
Expected: PASS (existing `derive_hashed_public_key`/`load_tracked_keys`/`fetch_reports_with_cache` tests still pass unchanged; new/replaced tests pass)

- [ ] **Step 5: Commit**

```bash
git add endpoint/history/archiver.py endpoint/tests/test_history_archiver.py
git commit -m "feat: poll enabled devices dynamically and migrate devices.json into the registry"
```

---

### Task 4: Wire the registry into the HTTP server (`endpoint/mh_endpoint.py`)

**Files:**
- Modify: `endpoint/mh_endpoint.py`
- Test: `endpoint/tests/test_mh_endpoint_history_devices.py`

**Interfaces:**
- Consumes: `history.crypto.load_or_create_key`/`encrypt` (Task 1), `history.registry.TrackedDeviceStore` (Task 2), `history.archiver.migrate_devices_json_to_registry`/`run_archiver_loop(tracked_device_store, store, poll_interval_hours, fetch_from_apple, sleep_fn=...)` (Task 3), `mh_config.getHistoryMasterKeyFile()` (Task 1).
- Produces: `GET /history/devices` → `200 {"devices": [...]}` or `503 {"error": "..."}` if the store failed to initialize at startup. `POST /history/devices` → `200 {"status": "ok"}`, `400 {"error": "..."}` on a malformed body, `503 {"error": "..."}` if unavailable.

- [ ] **Step 1: Write the failing tests**

Create `endpoint/tests/test_mh_endpoint_history_devices.py`:

```python
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `pytest endpoint/tests/test_mh_endpoint_history_devices.py -v`
Expected: FAIL — every `/history/devices` request falls through to the existing catch-all handlers (`GET` returns the "Nothing to see here" 200 with the wrong body; `POST` returns 501, since `body['ids']` raises `KeyError` on a body shaped `{"devices": [...]}`).

- [ ] **Step 3: Write the minimal implementation**

In `endpoint/mh_endpoint.py`, update the imports at the top:

```python
#!/usr/bin/env python3

import base64
import json
import logging
import os
import ssl
import sys
import threading
import time
from datetime import datetime,  timezone
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse

import requests

import mh_config
from history import archiver as history_archiver
from history import crypto
from history.registry import TrackedDeviceStore
from history.store import HistoryStore
from register import apple_cryptography, pypush_gsa_icloud

logger = logging.getLogger()

history_store = None
tracked_device_store = None
history_encryption_key = None
```

Replace `do_GET` with:

```python
    def do_GET(self):
        if not self.authenticate():
            self.send_response(401)
            self.addCORSHeaders()
            self.send_header('WWW-Authenticate', 'Basic realm="Auth Realm"')
            self.end_headers()
            return

        path = urlparse(self.path).path
        if path == '/history/devices':
            if tracked_device_store is None:
                self.send_response(503)
                self.addCORSHeaders()
                self.end_headers()
                self.wfile.write(json.dumps({"error": "history archiving unavailable"}).encode())
                return
            self.send_response(200)
            self.addCORSHeaders()
            self.send_header('Content-type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps({"devices": tracked_device_store.list_devices()}).encode())
            return

        self.send_response(200)
        self.addCORSHeaders()
        self.send_header('Content-type', 'text/plain')
        self.end_headers()
        self.wfile.write(b"Nothing to see here")
```

Change the start of `do_POST` to branch on path right after reading the body (everything from `days = body.get('days', 7)` onward is unchanged and stays inside the `else` path implicitly, by returning early from the new branch):

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

        path = urlparse(self.path).path
        if path == '/history/devices':
            self._handle_post_history_devices(body)
            return

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

    def _handle_post_history_devices(self, body):
        if tracked_device_store is None:
            self.send_response(503)
            self.addCORSHeaders()
            self.end_headers()
            self.wfile.write(json.dumps({"error": "history archiving unavailable"}).encode())
            return

        try:
            devices = body['devices']
            if not isinstance(devices, list):
                raise ValueError("'devices' must be a list")
            now = int(time.time())
            parsed = []
            for device in devices:
                parsed.append((
                    device['hashedPublicKey'],
                    device['privateKey'],
                    device['name'],
                    device.get('accessoryId'),
                    bool(device['enabled']),
                ))
        except (KeyError, ValueError, TypeError) as e:
            self.send_response(400)
            self.addCORSHeaders()
            self.end_headers()
            self.wfile.write(json.dumps({"error": str(e)}).encode())
            return

        for hashed_public_key, private_key, name, accessory_id, enabled in parsed:
            encrypted = crypto.encrypt(history_encryption_key, private_key)
            tracked_device_store.upsert(hashed_public_key, name, accessory_id, encrypted, enabled, when=now)

        self.send_response(200)
        self.addCORSHeaders()
        self.end_headers()
        self.wfile.write(json.dumps({"status": "ok"}).encode())
```

(The `parsed`/two-phase structure mirrors Task 3's migration function: every entry in the body is fully validated before any row is written, so a bad entry midway through a batch does not leave a partial write.)

Finally, replace the history-archiver startup block inside `if __name__ == "__main__":` (currently the `devices_file_path = ...` line through the `else: logger.info(...)` line) with:

```python
    def fetch_from_apple(fetch_ids):
        data = {"search": [{"startDate": 1, "ids": fetch_ids}]}
        with requests.post("https://gateway.icloud.com/acsnservice/fetch",
                            auth=getAuth(regenerate=False, second_factor='sms'),
                            headers=pypush_gsa_icloud.generate_anisette_headers(),
                            json=data) as r:
            r.raise_for_status()
        return json.loads(r.content.decode())['results']

    try:
        history_store = HistoryStore(mh_config.getConfigPath() + '/history.db')
        tracked_device_store = TrackedDeviceStore(mh_config.getConfigPath() + '/history.db')
        history_encryption_key = crypto.load_or_create_key(
            mh_config.getConfigPath() + '/' + mh_config.getHistoryMasterKeyFile())
    except Exception as e:
        logger.error(f"Could not open history database, archiving disabled: {e}", exc_info=True)
        history_store = None
        tracked_device_store = None
        history_encryption_key = None

    if history_store is not None and tracked_device_store is not None:
        devices_file_path = mh_config.getConfigPath() + '/' + mh_config.getHistoryDevicesFile()
        history_archiver.migrate_devices_json_to_registry(
            devices_file_path, tracked_device_store, history_encryption_key)

        archiver_thread = threading.Thread(
            target=history_archiver.run_archiver_loop,
            args=(tracked_device_store, history_store, mh_config.getHistoryPollIntervalHours(), fetch_from_apple),
            daemon=True,
        )
        archiver_thread.start()
        logger.info("History archiver started")
    else:
        logger.info("History store unavailable, archiving disabled")
```

This removes the old `if os.path.isfile(devices_file_path): ... else: ...` gate entirely — the archiver now always starts as long as both stores initialize, since devices can be enabled from the app at any time, not just when a `devices.json` happens to exist on disk.

- [ ] **Step 4: Run tests to verify they pass**

Run: `pytest endpoint/tests/test_mh_endpoint_history_devices.py -v`
Expected: PASS (8 tests)

Then run the full endpoint suite to confirm nothing else regressed:

Run: `pytest endpoint/tests -v`
Expected: PASS (all tests, across every test file in `endpoint/tests/`)

- [ ] **Step 5: Commit**

```bash
git add endpoint/mh_endpoint.py endpoint/tests/test_mh_endpoint_history_devices.py
git commit -m "feat: add GET/POST /history/devices endpoints and always-on archiver startup"
```

---

### Task 5: Flutter HTTP client for the new endpoints (`lib/history/history_archive_service.dart`)

**Files:**
- Create: `macless_haystack/lib/history/history_archive_service.dart`
- Test: `macless_haystack/test/history/history_archive_service_test.dart`

**Interfaces:**
- Produces: `HistoryDeviceEntry` (fields: `hashedPublicKey`, `privateKey`, `name`, `accessoryId` (`String?`), `enabled`), `ArchivedDeviceStatus` (fields: `hashedPublicKey`, `name`, `accessoryId` (`String?`), `enabled`), `HistoryArchiveService.setDevicesArchiving(String url, String user, String pass, List<HistoryDeviceEntry> devices, {http.Client? client}) -> Future<void>`, `HistoryArchiveService.getArchivedDevices(String url, String user, String pass, {http.Client? client}) -> Future<List<ArchivedDeviceStatus>>`. The optional `client` parameter is what Task 6/7 leave unset (using the real client) and what this task's tests set (using `MockClient`).

- [ ] **Step 1: Write the failing tests**

Create `macless_haystack/test/history/history_archive_service_test.dart`:

```dart
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:macless_haystack/history/history_archive_service.dart';
import 'package:test/test.dart';

void main() {
  const url = 'http://localhost:6176';
  const device = HistoryDeviceEntry(
    hashedPublicKey: 'hash-a',
    privateKey: 'AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQ==',
    name: 'Keys',
    accessoryId: 'acc-1',
    enabled: true,
  );

  test('setDevicesArchiving posts the device list as JSON', () async {
    Map<String, dynamic>? capturedBody;
    var client = MockClient((request) async {
      capturedBody = jsonDecode(request.body);
      expect(request.url.toString(), '$url/history/devices');
      expect(request.method, 'POST');
      return http.Response('{"status":"ok"}', 200);
    });

    await HistoryArchiveService.setDevicesArchiving(url, '', '', [device], client: client);

    expect(capturedBody, {
      'devices': [
        {
          'hashedPublicKey': 'hash-a',
          'privateKey': 'AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQ==',
          'name': 'Keys',
          'accessoryId': 'acc-1',
          'enabled': true,
        }
      ]
    });
  });

  test('setDevicesArchiving sends a basic auth header when credentials are set', () async {
    String? authHeader;
    var client = MockClient((request) async {
      authHeader = request.headers['Authorization'];
      return http.Response('{"status":"ok"}', 200);
    });

    await HistoryArchiveService.setDevicesArchiving(url, 'user', 'pass', [device], client: client);

    expect(authHeader, 'Basic ${base64.encode(utf8.encode('user:pass'))}');
  });

  test('setDevicesArchiving omits the auth header when credentials are empty', () async {
    String? authHeader = 'unset';
    var client = MockClient((request) async {
      authHeader = request.headers['Authorization'];
      return http.Response('{"status":"ok"}', 200);
    });

    await HistoryArchiveService.setDevicesArchiving(url, '', '', [device], client: client);

    expect(authHeader, isNull);
  });

  test('setDevicesArchiving throws on a non-200 response', () async {
    var client = MockClient((request) async => http.Response('error', 500));

    expect(
      () => HistoryArchiveService.setDevicesArchiving(url, '', '', [device], client: client),
      throwsException,
    );
  });

  test('setDevicesArchiving throws a specific message on 401', () async {
    var client = MockClient((request) async => http.Response('', 401));

    expect(
      () => HistoryArchiveService.setDevicesArchiving(url, '', '', [device], client: client),
      throwsA(predicate((e) => e is Exception && e.toString().contains('Authentication failure'))),
    );
  });

  test('getArchivedDevices sends a GET request and parses the device list', () async {
    var client = MockClient((request) async {
      expect(request.url.toString(), '$url/history/devices');
      expect(request.method, 'GET');
      return http.Response(
        jsonEncode({
          'devices': [
            {'hashedPublicKey': 'hash-a', 'name': 'Keys', 'accessoryId': 'acc-1', 'enabled': true},
          ]
        }),
        200,
      );
    });

    var devices = await HistoryArchiveService.getArchivedDevices(url, '', '', client: client);

    expect(devices.length, 1);
    expect(devices.first.hashedPublicKey, 'hash-a');
    expect(devices.first.name, 'Keys');
    expect(devices.first.accessoryId, 'acc-1');
    expect(devices.first.enabled, true);
  });

  test('getArchivedDevices throws on a non-200 response', () async {
    var client = MockClient((request) async => http.Response('error', 500));

    expect(
      () => HistoryArchiveService.getArchivedDevices(url, '', '', client: client),
      throwsException,
    );
  });
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd macless_haystack && flutter test test/history/history_archive_service_test.dart`
Expected: FAIL — `Error: Error when reading 'lib/history/history_archive_service.dart': No such file or directory`

- [ ] **Step 3: Write the minimal implementation**

Create `macless_haystack/lib/history/history_archive_service.dart`:

```dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

class HistoryDeviceEntry {
  final String hashedPublicKey;
  final String privateKey;
  final String name;
  final String? accessoryId;
  final bool enabled;

  const HistoryDeviceEntry({
    required this.hashedPublicKey,
    required this.privateKey,
    required this.name,
    required this.accessoryId,
    required this.enabled,
  });

  Map<String, dynamic> toJson() => {
        'hashedPublicKey': hashedPublicKey,
        'privateKey': privateKey,
        'name': name,
        'accessoryId': accessoryId,
        'enabled': enabled,
      };
}

class ArchivedDeviceStatus {
  final String hashedPublicKey;
  final String name;
  final String? accessoryId;
  final bool enabled;

  const ArchivedDeviceStatus({
    required this.hashedPublicKey,
    required this.name,
    required this.accessoryId,
    required this.enabled,
  });

  static ArchivedDeviceStatus fromJson(Map<String, dynamic> json) {
    return ArchivedDeviceStatus(
      hashedPublicKey: json['hashedPublicKey'],
      name: json['name'],
      accessoryId: json['accessoryId'],
      enabled: json['enabled'],
    );
  }
}

/// Reads and writes which devices have server-side location-history
/// archiving enabled, via the endpoint's `/history/devices` API.
class HistoryArchiveService {
  static http.Client _createClient() {
    if (kIsWeb) {
      return http.Client();
    }
    var ioClient = HttpClient();
    ioClient.badCertificateCallback = (X509Certificate cert, String host, int port) => true;
    return IOClient(ioClient);
  }

  static String? _authHeader(String user, String pass) {
    if (user.trim().isNotEmpty || pass.trim().isNotEmpty) {
      return 'Basic ${base64.encode(utf8.encode("$user:$pass"))}';
    }
    return null;
  }

  static void _checkStatus(int statusCode) {
    if (statusCode == 401) {
      throw Exception("Authentication failure. User/password wrong");
    }
    if (statusCode != 200) {
      throw Exception("History archiving request failed with statusCode:$statusCode");
    }
  }

  /// Enables or disables server-side archiving for [devices] in one request.
  /// Throws [Exception] if the server does not confirm success.
  static Future<void> setDevicesArchiving(
      String url, String user, String pass, List<HistoryDeviceEntry> devices,
      {http.Client? client}) async {
    var effectiveClient = client ?? _createClient();
    try {
      var authHeader = _authHeader(user, pass);
      var headers = {
        "Content-Type": "application/json",
        if (authHeader != null) "Authorization": authHeader,
      };
      var body = jsonEncode({'devices': devices.map((d) => d.toJson()).toList()});

      var response = await effectiveClient.post(Uri.parse('$url/history/devices'), headers: headers, body: body);
      _checkStatus(response.statusCode);
    } finally {
      if (client == null) {
        effectiveClient.close();
      }
    }
  }

  /// Fetches the current server-side archiving status for every device the
  /// server currently knows about.
  static Future<List<ArchivedDeviceStatus>> getArchivedDevices(String url, String user, String pass,
      {http.Client? client}) async {
    var effectiveClient = client ?? _createClient();
    try {
      var authHeader = _authHeader(user, pass);
      var headers = {
        if (authHeader != null) "Authorization": authHeader,
      };

      var response = await effectiveClient.get(Uri.parse('$url/history/devices'), headers: headers);
      _checkStatus(response.statusCode);

      var decoded = jsonDecode(response.body);
      List devices = decoded['devices'];
      return devices.map((d) => ArchivedDeviceStatus.fromJson(d)).toList();
    } finally {
      if (client == null) {
        effectiveClient.close();
      }
    }
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd macless_haystack && flutter test test/history/history_archive_service_test.dart`
Expected: PASS (7 tests)

- [ ] **Step 5: Commit**

```bash
git add macless_haystack/lib/history/history_archive_service.dart macless_haystack/test/history/history_archive_service_test.dart
git commit -m "feat: add Flutter client for the history-devices API"
```

---

### Task 6: Per-device archiving toggle (`lib/accessory/accessory_detail.dart`)

**Files:**
- Modify: `macless_haystack/lib/accessory/accessory_detail.dart`

**Interfaces:**
- Consumes: `HistoryArchiveService.getArchivedDevices`/`setDevicesArchiving`, `HistoryDeviceEntry` (Task 5); `Accessory.hashedPublicKey`, `Accessory.additionalKeys`, `Accessory.getPrivateKey()`, `Accessory.getAdditionalPrivateKeys()`, `Accessory.id`, `Accessory.name` (all already exist on `Accessory`, unchanged by this plan); `endpointUrl`/`endpointUser`/`endpointPass` settings keys from `lib/preferences/user_preferences_model.dart` (already exist).

**No automated test for this task** — per the spec's Testing section, `AccessoryDetail`'s widget wiring has no existing test coverage and this feature doesn't change that boundary. Verified manually in Step 3.

- [ ] **Step 1: Add the imports and state**

In `macless_haystack/lib/accessory/accessory_detail.dart`, add these imports alongside the existing ones:

```dart
import 'package:flutter_settings_screens/flutter_settings_screens.dart';
import 'package:macless_haystack/history/history_archive_service.dart';
import 'package:macless_haystack/preferences/user_preferences_model.dart';
```

Add two fields to `_AccessoryDetailState`, right after `final _formKey = GlobalKey<FormState>();`:

```dart
  bool _archivingLoading = true;
  bool _archivingEnabled = false;
```

Change `initState` to also kick off the status load:

```dart
  @override
  void initState() {
    // Initialize changed accessory with existing accessory properties.
    newAccessory = widget.accessory.clone();
    super.initState();
    _loadArchivingStatus();
  }
```

- [ ] **Step 2: Add the load/toggle methods and the switch**

Add these methods to `_AccessoryDetailState` (anywhere after `initState`):

```dart
  Future<void> _loadArchivingStatus() async {
    try {
      var url = Settings.getValue<String>(endpointUrl, defaultValue: 'http://localhost:6176')!;
      var user = Settings.getValue<String>(endpointUser, defaultValue: '')!;
      var pass = Settings.getValue<String>(endpointPass, defaultValue: '')!;
      var devices = await HistoryArchiveService.getArchivedDevices(url, user, pass);
      var relevantKeys = {widget.accessory.hashedPublicKey, ...widget.accessory.additionalKeys};
      var enabled = devices.any((d) => relevantKeys.contains(d.hashedPublicKey) && d.enabled);
      if (mounted) {
        setState(() {
          _archivingEnabled = enabled;
          _archivingLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _archivingLoading = false;
        });
      }
    }
  }

  Future<void> _setArchiving(bool enabled) async {
    var previous = _archivingEnabled;
    setState(() {
      _archivingEnabled = enabled;
    });
    try {
      var url = Settings.getValue<String>(endpointUrl, defaultValue: 'http://localhost:6176')!;
      var user = Settings.getValue<String>(endpointUser, defaultValue: '')!;
      var pass = Settings.getValue<String>(endpointPass, defaultValue: '')!;

      var accessory = widget.accessory;
      var additionalPrivateKeys = await accessory.getAdditionalPrivateKeys();
      List<HistoryDeviceEntry> devices = [
        HistoryDeviceEntry(
          hashedPublicKey: accessory.hashedPublicKey,
          privateKey: await accessory.getPrivateKey(),
          name: accessory.name,
          accessoryId: accessory.id,
          enabled: enabled,
        ),
        for (var i = 0; i < accessory.additionalKeys.length; i++)
          HistoryDeviceEntry(
            hashedPublicKey: accessory.additionalKeys[i],
            privateKey: additionalPrivateKeys[i],
            name: '${accessory.name} (extra key)',
            accessoryId: accessory.id,
            enabled: enabled,
          ),
      ];

      await HistoryArchiveService.setDevicesArchiving(url, user, pass, devices);
    } catch (e) {
      if (mounted) {
        setState(() {
          _archivingEnabled = previous;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not update server-side archiving: $e')),
        );
      }
    }
  }
```

In `build()`, add the switch right after the existing `SwitchListTile` for `Is Active` (before the `Save` `ListTile`):

```dart
              SwitchListTile(
                value: _archivingEnabled,
                title: const Text('Archive location history on server'),
                subtitle: _archivingLoading ? const Text('Loading status…') : null,
                onChanged: _archivingLoading ? null : _setArchiving,
              ),
```

- [ ] **Step 3: Verify manually**

1. Run the app pointed at a local dev server (`flutter run`, with `HAYSTACK_URL` set in Settings to your running endpoint's address).
2. Open an accessory's detail page. Confirm the new "Archive location history on server" switch appears below "Is Active", initially off (assuming the server's registry is empty).
3. Turn it on. Confirm no error `SnackBar` appears.
4. From a terminal, run `curl <endpoint-url>/history/devices` and confirm the response's `devices` array contains an entry for this accessory's hashed public key with `"enabled": true`.
5. Reopen the accessory detail page (or hot-restart the app). Confirm the switch now loads as **on** (state persisted server-side, not just in the widget).
6. Turn it off. Confirm the same `curl` now shows `"enabled": false` for that key, and that any rows already in `history.db` for it are untouched (only `enabled` changed).
7. Temporarily stop the server, then flip the switch again. Confirm a `SnackBar` reports the failure and the switch visually reverts to its previous state.

- [ ] **Step 4: Commit**

```bash
git add macless_haystack/lib/accessory/accessory_detail.dart
git commit -m "feat: add per-device server-side archiving toggle"
```

---

### Task 7: All-devices archiving toggle (`lib/preferences/preferences_page.dart`)

**Files:**
- Modify: `macless_haystack/lib/preferences/preferences_page.dart`

**Interfaces:**
- Consumes: `HistoryArchiveService.getArchivedDevices`/`setDevicesArchiving`, `HistoryDeviceEntry` (Task 5); `AccessoryRegistry.accessories` (already exists, unchanged); `Accessory` fields/methods as in Task 6.

**No automated test for this task**, for the same reason as Task 6. Verified manually in Step 3.

- [ ] **Step 1: Add the imports and state**

In `macless_haystack/lib/preferences/preferences_page.dart`, add these imports alongside the existing ones:

```dart
import 'package:macless_haystack/accessory/accessory_model.dart';
import 'package:macless_haystack/accessory/accessory_registry.dart';
import 'package:macless_haystack/history/history_archive_service.dart';
```

Add state and an `initState` override to `_PreferencesPageState` (it currently has none):

```dart
class _PreferencesPageState extends State<PreferencesPage> {
  bool _archivingLoading = true;
  bool _archivingAllEnabled = false;

  @override
  void initState() {
    super.initState();
    _loadArchivingStatus();
  }
```

- [ ] **Step 2: Add the load/toggle methods and the tile**

Add these methods to `_PreferencesPageState`:

```dart
  Set<String> _allKnownKeys(Iterable<Accessory> accessories) {
    var keys = <String>{};
    for (var accessory in accessories) {
      keys.add(accessory.hashedPublicKey);
      keys.addAll(accessory.additionalKeys);
    }
    return keys;
  }

  Future<void> _loadArchivingStatus() async {
    try {
      var url = Settings.getValue<String>(endpointUrl, defaultValue: 'http://localhost:6176')!;
      var user = Settings.getValue<String>(endpointUser, defaultValue: '')!;
      var pass = Settings.getValue<String>(endpointPass, defaultValue: '')!;
      var accessories = Provider.of<AccessoryRegistry>(context, listen: false).accessories;
      var allKeys = _allKnownKeys(accessories);

      var devices = await HistoryArchiveService.getArchivedDevices(url, user, pass);
      var enabledKeys = devices.where((d) => d.enabled).map((d) => d.hashedPublicKey).toSet();
      var allEnabled = allKeys.isNotEmpty && allKeys.every(enabledKeys.contains);

      if (mounted) {
        setState(() {
          _archivingAllEnabled = allEnabled;
          _archivingLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _archivingLoading = false;
        });
      }
    }
  }

  Future<void> _setArchivingAll(bool enabled) async {
    var previous = _archivingAllEnabled;
    setState(() {
      _archivingAllEnabled = enabled;
    });
    try {
      var url = Settings.getValue<String>(endpointUrl, defaultValue: 'http://localhost:6176')!;
      var user = Settings.getValue<String>(endpointUser, defaultValue: '')!;
      var pass = Settings.getValue<String>(endpointPass, defaultValue: '')!;
      var accessories = Provider.of<AccessoryRegistry>(context, listen: false).accessories;

      List<HistoryDeviceEntry> devices = [];
      for (var accessory in accessories) {
        var additionalPrivateKeys = await accessory.getAdditionalPrivateKeys();
        devices.add(HistoryDeviceEntry(
          hashedPublicKey: accessory.hashedPublicKey,
          privateKey: await accessory.getPrivateKey(),
          name: accessory.name,
          accessoryId: accessory.id,
          enabled: enabled,
        ));
        for (var i = 0; i < accessory.additionalKeys.length; i++) {
          devices.add(HistoryDeviceEntry(
            hashedPublicKey: accessory.additionalKeys[i],
            privateKey: additionalPrivateKeys[i],
            name: '${accessory.name} (extra key)',
            accessoryId: accessory.id,
            enabled: enabled,
          ));
        }
      }

      if (devices.isNotEmpty) {
        await HistoryArchiveService.setDevicesArchiving(url, user, pass, devices);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _archivingAllEnabled = previous;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not update server-side archiving: $e')),
        );
      }
    }
  }

  getArchiveAllTile() {
    return SwitchListTile(
      value: _archivingAllEnabled,
      title: const Text('Archive all devices on server'),
      subtitle: _archivingLoading ? const Text('Loading status…') : null,
      onChanged: _archivingLoading ? null : _setArchivingAll,
    );
  }
```

Add `getArchiveAllTile()` to the `Column` in `build()`, right after `getNumberofDaysTile()`:

```dart
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
      ),
      body: Center(
        child: Column(
          children: <Widget>[
            getLocationTile(),
            getFetchOnStartupTile(),
            getUrlTile(),
            getUserTile(),
            getPassTile(),
            getNumberofDaysTile(),
            getArchiveAllTile(),
            ListTile(
              title: getAbout(),
            ),
          ],
        ),
      ),
    );
  }
```

- [ ] **Step 3: Verify manually**

1. With at least two accessories added in the app and the endpoint URL pointed at a running dev server, open Settings.
2. Confirm the new "Archive all devices on server" switch appears after "Number of days to fetch location", initially reflecting whatever Task 6's manual testing left the server's registry in (off, unless every device was left enabled).
3. Turn it on. Confirm no error `SnackBar`, then `curl <endpoint-url>/history/devices` and confirm every accessory's hashed key (and any additional keys) now shows `"enabled": true`.
4. Turn it off. Confirm the same `curl` now shows `"enabled": false` for all of them.
5. Add a new accessory, leave the switch on from a prior run, reopen Settings, and confirm the switch correctly shows **off** now (since the new accessory's key isn't yet enabled — "all" means literally all).

- [ ] **Step 4: Commit**

```bash
git add macless_haystack/lib/preferences/preferences_page.dart
git commit -m "feat: add all-devices server-side archiving toggle"
```
