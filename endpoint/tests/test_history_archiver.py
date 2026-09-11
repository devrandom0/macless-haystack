import json

from history.archiver import derive_hashed_public_key, load_tracked_keys


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
