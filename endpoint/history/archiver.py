import base64
import hashlib
import json
import logging
import time

from cryptography.hazmat.backends import default_backend
from cryptography.hazmat.primitives.asymmetric import ec

logger = logging.getLogger()


def derive_hashed_public_key(private_key_b64):
    priv_bytes = base64.b64decode(private_key_b64)
    priv_int = int.from_bytes(priv_bytes, "big")
    public_x = ec.derive_private_key(
        priv_int, ec.SECP224R1(), default_backend()
    ).public_key().public_numbers().x
    adv_bytes = public_x.to_bytes(28, "big")
    return base64.b64encode(hashlib.sha256(adv_bytes).digest()).decode("ascii")
