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
