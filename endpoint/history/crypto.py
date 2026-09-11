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
