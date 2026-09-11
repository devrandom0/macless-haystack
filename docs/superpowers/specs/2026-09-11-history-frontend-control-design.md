# Frontend Control of Server-Side History Archiving — Design

## Motivation

The server-side location-history archiver (`sina/history-archiver`, merged into
`sina/dev`) only tracks devices listed in `endpoint/data/devices.json`, a file
the user has to hand-edit (scp/ssh) on the server host, with each tracker's
**private key** in plaintext. There is no way to see or change which devices
are archived from the app, and no way to turn archiving on/off per device
without server access.

That prior feature also left a known, deliberately deferred issue: the
archiver needs a private key to derive the hashed public key it polls Apple
for, so the server host ends up holding key material it didn't hold before.

This feature adds a per-device (and an all-devices) toggle in the
`macless_haystack` app to enable/disable server-side archiving, backed by a
new HTTP API. As part of building that toggle, it also resolves the
private-key storage question the previous feature deferred: the server keeps
storing private keys (needed for a planned future capability — server-side
decryption for a web view/export, not built in this feature), but now
**encrypted at rest** instead of living in a plaintext file, and
`devices.json` is retired.

## Non-goals

- Server-side decryption of archived reports, or any web view/export of
  human-readable history. This feature only stores the private key
  encrypted so that capability can be built later without a second
  migration.
- Deleting a device's already-archived history when archiving is disabled
  for it. Disabling only stops future polling.
- Changing the existing `/` (root) POST endpoint's request/response shape.
  It keeps working exactly as it does today.

## Architecture

**New SQLite table, in the existing `endpoint/data/history.db`:**

```sql
CREATE TABLE tracked_devices (
    hashed_public_key TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    accessory_id TEXT,
    encrypted_private_key BLOB NOT NULL,
    enabled INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
)
```

One row per key (a device's primary key and each of its additional keys are
separate rows, matching how the archiver already treats them as a flat list
of hashed keys today). `accessory_id` carries the app's local accessory id
so a future feature can group rows back into one device; nothing reads it
yet.

This table fully replaces `devices.json` as the archiver's source of tracked
keys. `devices.json`-based configuration is retired by this feature (see
Migration below).

**New `endpoint/history/crypto.py`:**

- `load_or_create_key(key_file_path) -> bytes`: reads a Fernet key from
  disk; if the file doesn't exist, generates one via
  `cryptography.fernet.Fernet.generate_key()`, writes it with `0600`
  permissions, and returns it. `cryptography` is already a dependency
  (used today in `archiver.py` for EC math) — no new package.
- `encrypt(key, plaintext_b64) -> bytes` / `decrypt(key, ciphertext) -> str`:
  thin wraps around `Fernet(key).encrypt` / `.decrypt`.

Key file path is a new config value, `history_master_key_file`, default
`history_key.bin`, resolved the same way `history_devices_file` is today
(relative to `mh_config.getConfigPath()`).

**New `endpoint/history/registry.py`:**

`TrackedDeviceStore`, constructed with the same sqlite3 connection style as
`HistoryStore` (`check_same_thread=False`, a `threading.Lock` around writes):

- `upsert(hashed_public_key, name, accessory_id, encrypted_private_key, enabled, when)`
- `list_devices() -> list[dict]` — all rows, `encrypted_private_key` excluded
  from the returned dicts (never serialized back out over HTTP).
- `enabled_keys() -> list[str]` — hashed public keys where `enabled = 1`.
  This is what the archiver polls each cycle.

**New HTTP endpoints in `endpoint/mh_endpoint.py`:**

Both `do_GET` and `do_POST` currently ignore `self.path` entirely. This
feature adds path routing:

- `GET /history/devices` → `TrackedDeviceStore.list_devices()`, JSON array
  of `{"hashedPublicKey", "name", "accessoryId", "enabled"}`.
- `POST /history/devices` → body `{"devices": [{"hashedPublicKey",
  "privateKey", "name", "accessoryId", "enabled"}, ...]}`. For each entry,
  encrypts `privateKey` with the loaded Fernet key and calls
  `TrackedDeviceStore.upsert(...)`.
- The existing `GET /` and `POST /` (root path, fetch-reports) behavior is
  unchanged — this is purely additive routing.
- Both new endpoints go through the same `authenticate()` basic-auth gate
  already applied to every request today.

**Archiver loop change (`endpoint/history/archiver.py`):**

`run_archiver_loop` currently calls `load_tracked_keys(devices_file_path)`
once, before entering its `while True` loop, so a change to the tracked-key
list only takes effect on container restart. This feature changes it to
read `TrackedDeviceStore.enabled_keys()` at the top of every iteration,
so a toggle flip in the app is picked up within one poll interval
(`history_poll_interval_hours`, default 4h) without restarting anything.
`load_tracked_keys` (devices.json-based) and its file-parsing path are
removed from the loop; the function itself is kept only as the migration's
key-derivation helper (see below).

**Migration, at server startup (`mh_endpoint.py`'s `__main__` block), before
the archiver thread starts:**

If `endpoint/data/devices.json` exists and `tracked_devices` is empty:
for each device in the file, derive its hashed key(s) the same way
`load_tracked_keys` does today, encrypt the private key with the Fernet
key, and `upsert(..., enabled=True)`. On success, delete `devices.json` —
its content now lives encrypted in `history.db`, so the plaintext file is
redundant and its removal is the actual fix for the deferred security
issue. On any failure (unparseable file, bad key data), log and leave the
file in place; migration is retried on next startup rather than silently
losing data.

If `tracked_devices` is non-empty, migration is skipped unconditionally —
this also covers "user intentionally disabled/removed every device", which
must not re-import a stale file.

## Data flow

**Per-device toggle (new `SwitchListTile` in `AccessoryDetail`):**

1. Opening the accessory detail page calls `GET /history/devices`; the
   switch's initial value is "any row for this accessory's hashed key or
   additional keys has `enabled: true`".
2. Turning it on: the app collects the accessory's private key
   (`getPrivateKey()`) and its additional keys' private keys
   (`getAdditionalPrivateKeys()`, both already exist on `Accessory`), and
   sends one `POST /history/devices` with one entry per key, `enabled:
   true`, `name` set to the accessory's name (additional keys suffixed,
   e.g. `"<name> (extra key)"`), `accessoryId` set to `accessory.id`.
3. Turning it off: same POST shape, `enabled: false`. Existing archived
   history for those keys is untouched.
4. Network/HTTP failure on the POST: the switch's UI state reverts to what
   it was before the tap, and a `SnackBar` reports the error — the same
   optimistic-update-with-rollback pattern already used by "Save"/"Delete"
   actions elsewhere in this screen.

**All-devices toggle (new `SwitchListTile` in `PreferencesPage`):**

Same request/response shape, but the app builds one batched
`POST /history/devices` covering every key of every locally-known
accessory in a single call, and its initial value on page load is "every
currently-known key is enabled" (from one `GET /history/devices`).

**New `lib/history/history_archive_service.dart`:**

A small service mirroring `ReportsFetcher`'s existing shape (same URL /
basic-auth settings, same `kIsWeb` request-path split): `setDevicesArchiving(url,
user, pass, devices)` and `getArchivedDevices(url, user, pass)`. Both new
UI call sites go through this one service rather than building HTTP
requests inline.

## Error handling

- Toggle POST fails (timeout, non-2xx, connection error): UI reverts, error
  surfaced via `SnackBar`. No partial-state risk server-side since each
  `upsert` is a single-row transaction.
- `GET /history/devices` fails when a page opens: switch defaults to its
  last-known/off state, a small inline text notes the archive status
  couldn't be loaded; the rest of the page (name, icon, active toggle,
  delete) still works exactly as today.
- Server-side encrypt/decrypt failure (corrupt or missing key file after
  creation, e.g. permissions issue): logged, that request's device is
  skipped rather than crashing the endpoint — same graceful-degradation
  posture as `HistoryStore`'s existing sqlite3-error handling.
- Migration failure: logged, `devices.json` left in place, server starts
  normally with zero tracked devices (identical to today's "no devices.json
  at all" case).
- A malformed `POST /history/devices` body (missing `hashedPublicKey`,
  non-list `devices`, etc.) → `400`, matching the existing convention of
  the root endpoint returning `501` on unexpected errors (this is `400`,
  not `501`, because it's a client input problem, not a server error).

## Testing

**Python (pytest, TDD, no new dependencies):**

- `crypto.py`: key-file autogeneration (first call creates it with `0600`
  perms, second call reuses the same key), encrypt/decrypt round-trip.
- `registry.py`: upsert (insert + update-in-place), `list_devices` never
  includes `encrypted_private_key`, `enabled_keys` filters correctly.
- Migration function: fixture `devices.json` → rows inserted + file
  deleted; table non-empty → migration skipped, file untouched; malformed
  file → migration skipped, file untouched, no exception escapes.
- `archiver.run_archiver_loop`: re-reads `enabled_keys()` every iteration
  (test with a fake store whose `enabled_keys()` return value changes
  between calls, using the existing injectable `sleep_fn` pattern from
  today's tests to stop the loop after N iterations).
- `mh_endpoint.py` path routing: `GET`/`POST /history/devices` dispatch to
  the new handlers; `GET`/`POST /` behavior is unchanged (regression test
  against the existing root-path tests).

**Flutter:**

- `history_archive_service_test.dart`: unit tests using `http.MockClient`
  (request body shape, response parsing, non-200 → exception), following
  the same testable-injectable-client style used elsewhere in this app's
  networking code.
- `AccessoryDetail`/`PreferencesPage` widget wiring (the `SwitchListTile`
  callbacks) is verified manually rather than with widget tests — neither
  screen has existing test coverage today, and this feature doesn't change
  that boundary.
