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
                "updated_at INTEGER NOT NULL, "
                "poll_interval_hours INTEGER NOT NULL DEFAULT 4, "
                "retention_days INTEGER NOT NULL DEFAULT 30)"
            )
            # ALTER TABLE for databases created before these columns existed;
            # SQLite has no "ADD COLUMN IF NOT EXISTS", so ignore the
            # "duplicate column" error when the column is already there.
            for column_def in (
                "poll_interval_hours INTEGER NOT NULL DEFAULT 4",
                "retention_days INTEGER NOT NULL DEFAULT 30",
            ):
                try:
                    self._conn.execute(f"ALTER TABLE tracked_devices ADD COLUMN {column_def}")
                except sqlite3.OperationalError as e:
                    if "duplicate column name" not in str(e):
                        raise
            self._conn.commit()

    def upsert(self, hashed_public_key, name, accessory_id, encrypted_private_key, enabled,
               poll_interval_hours=4, retention_days=30, when=None):
        when = when if when is not None else int(time.time())
        with self._lock:
            self._conn.execute(
                "INSERT OR REPLACE INTO tracked_devices "
                "(hashed_public_key, name, accessory_id, encrypted_private_key, enabled, "
                "updated_at, poll_interval_hours, retention_days) "
                "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                (hashed_public_key, name, accessory_id, encrypted_private_key, int(bool(enabled)),
                 when, poll_interval_hours, retention_days),
            )
            self._conn.commit()

    def upsert_many(self, rows, poll_interval_hours=4, retention_days=30, when=None):
        when = when if when is not None else int(time.time())
        with self._lock:
            try:
                self._conn.executemany(
                    "INSERT OR REPLACE INTO tracked_devices "
                    "(hashed_public_key, name, accessory_id, encrypted_private_key, enabled, "
                    "updated_at, poll_interval_hours, retention_days) "
                    "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                    [
                        (hp, name, aid, enc, int(bool(en)), when, poll_interval_hours, retention_days)
                        for hp, name, aid, enc, en in rows
                    ],
                )
            except Exception:
                self._conn.rollback()
                raise
            self._conn.commit()

    def list_devices(self):
        with self._lock:
            rows = self._conn.execute(
                "SELECT hashed_public_key, name, accessory_id, enabled, "
                "poll_interval_hours, retention_days FROM tracked_devices"
            ).fetchall()
        return [self._row_to_dict(row) for row in rows]

    def get_device(self, hashed_public_key):
        with self._lock:
            row = self._conn.execute(
                "SELECT hashed_public_key, name, accessory_id, enabled, "
                "poll_interval_hours, retention_days FROM tracked_devices "
                "WHERE hashed_public_key = ?",
                (hashed_public_key,),
            ).fetchone()
        return self._row_to_dict(row) if row else None

    def enabled_devices_with_intervals(self):
        with self._lock:
            rows = self._conn.execute(
                "SELECT hashed_public_key, poll_interval_hours, retention_days "
                "FROM tracked_devices WHERE enabled = 1"
            ).fetchall()
        return [(row[0], row[1], row[2]) for row in rows]

    def is_empty(self):
        with self._lock:
            row = self._conn.execute("SELECT COUNT(*) FROM tracked_devices").fetchone()
        return row[0] == 0

    @staticmethod
    def _row_to_dict(row):
        return {
            "hashedPublicKey": row[0],
            "name": row[1],
            "accessoryId": row[2],
            "enabled": bool(row[3]),
            "pollIntervalHours": row[4],
            "retentionDays": row[5],
        }
