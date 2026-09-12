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

logger = logging.getLogger()


def derive_hashed_public_key(private_key_b64):
    priv_bytes = base64.b64decode(private_key_b64)
    priv_int = int.from_bytes(priv_bytes, "big")
    public_x = ec.derive_private_key(
        priv_int, ec.SECP224R1(), default_backend()
    ).public_key().public_numbers().x
    adv_bytes = public_x.to_bytes(28, "big")
    return base64.b64encode(hashlib.sha256(adv_bytes).digest()).decode("ascii")


def load_tracked_keys(devices_file_path):
    with open(devices_file_path, "r") as f:
        devices = json.load(f)

    hashed_keys = []
    for device in devices:
        private_keys = [device["privateKey"]] + list(device.get("additionalKeys", []))
        for private_key_b64 in private_keys:
            hashed_keys.append(derive_hashed_public_key(private_key_b64))
    return hashed_keys


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

    def _fetch_live():
        entries = fetch_from_apple(ids)
        entries = [e for e in entries if extract_report_timestamp(e) > since]
        return sorted(entries, key=extract_report_timestamp, reverse=True)

    if store is None:
        return _fetch_live()

    try:
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
    except sqlite3.Error as e:
        logger.error(f"History store error, falling back to live Apple fetch without caching: {e}")
        return _fetch_live()


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
                rows.append((hashed_key, entry_name, None, encrypted, True))
    except Exception as e:
        logger.error(f"Could not migrate {devices_file_path} to the device registry: {e}", exc_info=True)
        return

    try:
        tracked_device_store.upsert_many(rows, poll_interval_hours=4, retention_days=30, when=now)
        os.remove(devices_file_path)
    except Exception as e:
        logger.error(f"Could not migrate {devices_file_path} to the device registry: {e}", exc_info=True)
        return

    logger.info(f"Migrated devices from {devices_file_path} into the device registry; file removed")


def run_archiver_loop(tracked_device_store, store, fetch_from_apple, sleep_fn=time.sleep, tick_interval_seconds=300):
    logger.info(f"History archiver started, checking devices every {tick_interval_seconds}s against their own poll interval")
    while True:
        now = int(time.time())

        # Polling and retention are independent concerns kept in separate
        # try/excepts - a fetch failure must not also skip retention, and a
        # retention failure must not also skip polling.
        try:
            devices = tracked_device_store.enabled_devices_with_intervals()
            due_keys = []
            for hashed_key, poll_interval_hours, _ in devices:
                last_polled_at = store.last_polled_at(hashed_key)
                if last_polled_at is None or (now - last_polled_at) >= poll_interval_hours * 3600:
                    due_keys.append(hashed_key)
            if due_keys:
                try:
                    entries = fetch_from_apple(due_keys)
                except Exception as e:
                    logger.error(f"History archiver fetch failed: {e}", exc_info=True)
                    # Record the attempt anyway, so a persistent outage backs
                    # off to each device's own interval instead of retrying
                    # every tick - the 1h minimum floor exists specifically
                    # to protect against Apple's rate limiting.
                    for hashed_key in due_keys:
                        store.mark_polled(hashed_key, now)
                else:
                    _store_fetched_entries(due_keys, entries, store, now)
            elif not devices:
                logger.debug("History archiver: no enabled devices, skipping poll")
        except Exception as e:
            logger.error(f"History archiver poll failed: {e}", exc_info=True)

        try:
            # Every tracked device, enabled or not - disabling archiving
            # must not freeze a device's existing history forever.
            for hashed_key, retention_days in tracked_device_store.all_devices_with_retention():
                store.delete_reports_older_than(hashed_key, now - retention_days * 86400)
        except Exception as e:
            logger.error(f"History archiver retention cleanup failed: {e}", exc_info=True)

        sleep_fn(tick_interval_seconds)
