import base64
import hashlib
import hmac
import os
import secrets

from argon2 import PasswordHasher
from argon2.exceptions import InvalidHashError, VerifyMismatchError
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

from app.config import get_settings

_ph = PasswordHasher()


def _key(name: str) -> bytes:
    raw = base64.b64decode(getattr(get_settings(), name))
    if len(raw) != 32:
        raise RuntimeError(f"{name} must be 32 bytes, base64-encoded")
    return raw


def encrypt(plaintext: str) -> bytes:
    """AES-256-GCM field-level encryption. Output = 12-byte nonce || ciphertext+tag."""
    nonce = os.urandom(12)
    return nonce + AESGCM(_key("field_encryption_key")).encrypt(nonce, plaintext.encode(), None)


def decrypt(blob: bytes) -> str:
    return AESGCM(_key("field_encryption_key")).decrypt(blob[:12], blob[12:], None).decode()


def keyed_hash(value: str, purpose: str) -> str:
    """Deterministic HMAC-SHA256 for lookups (phone numbers) and short secrets (OTP, pickup codes).

    `purpose` separates domains so a hash from one use can't be replayed in another.
    """
    return hmac.new(_key("hash_key"), f"{purpose}:{value}".encode(), hashlib.sha256).hexdigest()


def phone_hash(phone_e164: str) -> str:
    return keyed_hash(phone_e164, "phone")


def token_hash(token: str) -> str:
    return hashlib.sha256(token.encode()).hexdigest()


def random_token(nbytes: int = 32) -> str:
    return secrets.token_urlsafe(nbytes)


def random_digits(n: int) -> str:
    return "".join(secrets.choice("0123456789") for _ in range(n))


def constant_time_equals(a: str, b: str) -> bool:
    return hmac.compare_digest(a.encode(), b.encode())


def hash_password(password: str) -> str:
    return _ph.hash(password)


def verify_password(password_hash: str, password: str) -> bool:
    try:
        return _ph.verify(password_hash, password)
    except (VerifyMismatchError, InvalidHashError):
        return False


def mask_phone(phone_e164: str) -> str:
    """+2250701020345 -> +225 07 •• •• 45"""
    if phone_e164.startswith("+225") and len(phone_e164) == 14:
        local = phone_e164[4:]
        return f"+225 {local[:2]} •• •• {local[-2:]}"
    return phone_e164[:4] + " •• " + phone_e164[-2:]
