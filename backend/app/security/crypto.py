"""Crypto helpers. Implementation lives in regisse_kit (shared across products); this module keeps
flariane's API and reads the keys from settings."""

import base64
from functools import lru_cache

from regisse_kit import crypto as kit
from regisse_kit.crypto import (  # noqa: F401  (re-exported: same behaviour, same wire formats)
    constant_time_equals,
    hash_password,
    random_digits,
    random_token,
    token_hash,
    verify_password,
)
from regisse_kit.phone import mask_phone  # noqa: F401

from app.config import get_settings


def _key(name: str) -> bytes:
    """Raw 32-byte key from settings (used by file URL signing in integrations/storage.py)."""
    raw = base64.b64decode(getattr(get_settings(), name))
    if len(raw) != 32:
        raise RuntimeError(f"{name} must be 32 bytes, base64-encoded")
    return raw


@lru_cache
def _cipher(key_b64: str) -> kit.FieldCipher:
    return kit.FieldCipher(key_b64)


@lru_cache
def _hasher(key_b64: str) -> kit.KeyedHasher:
    return kit.KeyedHasher(key_b64)


def encrypt(plaintext: str) -> bytes:
    """AES-256-GCM field-level encryption. Output = 12-byte nonce || ciphertext+tag."""
    return _cipher(get_settings().field_encryption_key).encrypt(plaintext)


def decrypt(blob: bytes) -> str:
    return _cipher(get_settings().field_encryption_key).decrypt(blob)


def keyed_hash(value: str, purpose: str) -> str:
    """Deterministic HMAC-SHA256 for lookups (phone numbers) and short secrets (OTP, pickup codes)."""
    return _hasher(get_settings().hash_key).hash(value, purpose)


def phone_hash(phone_e164: str) -> str:
    return _hasher(get_settings().hash_key).phone(phone_e164)
