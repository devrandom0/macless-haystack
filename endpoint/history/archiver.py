import base64
import hashlib
import json
import logging
import time

from cryptography.hazmat.backends import default_backend
from cryptography.hazmat.primitives.asymmetric import ec

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
