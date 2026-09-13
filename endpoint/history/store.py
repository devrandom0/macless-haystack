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
        """Stores [reports] for [hashed_key], returning how many of them
        were not already present (by hashed_key+timestamp) before this
        call - the signal used to tell a genuinely new fetch from Apple
        apart from one that just re-confirmed already-known reports.
        """
        with self._lock:
            new_count = 0
            try:
                for entry in reports:
                    timestamp = extract_report_timestamp(entry)
                    exists = self._conn.execute(
                        "SELECT 1 FROM reports WHERE hashed_key = ? AND timestamp = ?",
                        (hashed_key, timestamp),
                    ).fetchone()
                    if exists is None:
                        new_count += 1
                    self._conn.execute(
                        "INSERT OR REPLACE INTO reports (hashed_key, timestamp, entry_json) VALUES (?, ?, ?)",
                        (hashed_key, timestamp, json.dumps(entry)),
                    )
            except Exception:
                self._conn.rollback()
                raise
            self._conn.commit()
            return new_count

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

    def delete_reports_older_than(self, hashed_key, cutoff_timestamp):
        with self._lock:
            self._conn.execute(
                "DELETE FROM reports WHERE hashed_key = ? AND timestamp < ?",
                (hashed_key, cutoff_timestamp),
            )
            self._conn.commit()

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
