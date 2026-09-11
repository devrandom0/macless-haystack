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
