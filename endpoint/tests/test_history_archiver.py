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
    key_b = "AgICAgICAgICAgICAgICAgICAgICAgICAgICAg=="
    assert derive_hashed_public_key(key_a) != derive_hashed_public_key(key_b)
