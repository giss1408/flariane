"""Customer accounts: Ivorian phone number + password (no SMS/WhatsApp code)."""

import re
from datetime import timedelta

from anyio import to_thread
from limits import parse
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.errors import BadRequest, Conflict, DomainError, TooManyRequests
from app.models import Customer
from app.ratelimit import limiter
from app.services import loyalty
from app.security.tokens import utcnow
from app.security.crypto import encrypt, hash_password, phone_hash, random_token, verify_password

# Ivorian mobile numbers since 2021: 10 digits, 01 (Moov), 05 (MTN), 07 (Orange).
_LOCAL_CI = re.compile(r"^0[157]\d{8}$")
# Bump when the privacy policy or the consent wording changes: customers are asked again.
CONSENT_VERSION = "2026-10-22"
FAILED_LOGIN_LIMIT = parse("5/15minutes")  # per phone number: CGNAT makes IP limits useless
_DUMMY_HASH = hash_password(random_token())


class InvalidCredentials(DomainError):
    status_code = 401


# German mobiles (+49 15x/16x/17x), accepted outside production (and in production when FLR_ALLOW_GERMAN_NUMBERS
# is set) so the team can test from Germany.
_DE_MOBILE = re.compile(r"^1[5-7]\d{8,9}$")


def _test_phone(digits: str) -> str | None:
    from app.config import get_settings

    s = get_settings()
    if s.env == "prod" and not s.allow_german_numbers:
        return None
    for prefix in ("+49", "0049"):
        if digits.startswith(prefix) and _DE_MOBILE.match(digits[len(prefix):].lstrip("0")):
            return "+49" + digits[len(prefix):].lstrip("0")
    return None


def normalize_ci_phone(raw: str) -> str:
    """Accept 0701020304, 07 01 02 03 04, +225 07…, 00225 07…; return E.164.
    German mobiles in international format are accepted too outside production, or when allowed by the setting."""
    digits = re.sub(r"[\s.\-()/]", "", raw or "")
    test = _test_phone(digits)
    if test:
        return test
    if digits.startswith("00225"):
        digits = digits[5:]
    elif digits.startswith("+225"):
        digits = digits[4:]
    elif digits.startswith("225") and len(digits) == 13:
        digits = digits[3:]
    if not _LOCAL_CI.match(digits):
        raise BadRequest("invalid_phone", "Numéro ivoirien à 10 chiffres attendu")
    return "+225" + digits


def check_password_strength(password: str) -> None:
    if len(password) < 8:
        raise BadRequest("weak_password", "8 caractères minimum")
    if password.isdigit() and len(set(password)) <= 2:
        raise BadRequest("weak_password", "Mot de passe trop simple")


async def register(db: AsyncSession, raw_phone: str, password: str, display_name: str | None, referral_code: str | None = None) -> Customer:
    phone = normalize_ci_phone(raw_phone)
    check_password_strength(password)
    ph = phone_hash(phone)
    password_hash = await to_thread.run_sync(hash_password, password)  # argon2 is CPU-bound: keep the event loop free
    if await db.scalar(select(Customer.id).where(Customer.phone_hash == ph)):
        raise Conflict("phone_taken")
    referrer = await loyalty.referrer_for_code(db, referral_code) if referral_code else None
    customer = Customer(phone_enc=encrypt(phone), phone_hash=ph, display_name=display_name, password_hash=password_hash,
                        consent_at=utcnow(), consent_version=CONSENT_VERSION, referred_by_id=referrer.id if referrer else None)
    await loyalty.assign_referral_code(db, customer)
    db.add(customer)
    await db.flush()
    return customer


async def login(db: AsyncSession, raw_phone: str, password: str) -> Customer:
    phone = normalize_ci_phone(raw_phone)
    ph = phone_hash(phone)
    key = f"customer-login-fail:{ph}"
    if not limiter().test(FAILED_LOGIN_LIMIT, key):
        raise TooManyRequests("login_locked")
    customer = await db.scalar(select(Customer).where(Customer.phone_hash == ph))
    # Always run one hash check so response time doesn't reveal which numbers have accounts.
    ok = await to_thread.run_sync(verify_password, customer.password_hash if customer and customer.password_hash else _DUMMY_HASH, password)
    if customer is None or customer.anonymised_at is not None or not customer.password_hash or not ok:
        limiter().hit(FAILED_LOGIN_LIMIT, key)
        raise InvalidCredentials("invalid_credentials")
    if customer.must_change_password and customer.temp_password_expires_at and customer.temp_password_expires_at < utcnow():
        raise InvalidCredentials("temp_password_expired")  # only said once the password itself was right
    return customer


async def change_password(customer: Customer, current: str, new: str) -> None:
    if not customer.password_hash or not await to_thread.run_sync(verify_password, customer.password_hash, current):
        raise InvalidCredentials("invalid_credentials")
    check_password_strength(new)
    customer.password_hash = await to_thread.run_sync(hash_password, new)
    customer.must_change_password = False
    customer.password_reset_requested_at = customer.temp_password_expires_at = None


RESET_REQUEST_COOLDOWN = timedelta(hours=1)
TEMP_PASSWORD_TTL = timedelta(hours=24)


async def request_password_reset(db: AsyncSession, phone: str) -> Customer | None:
    """Marks the account as waiting for an admin. Returns the customer only when the admins should be notified
    (not for unknown numbers, nor for a repeated request within the hour)."""
    customer = await db.scalar(select(Customer).where(Customer.phone_hash == phone_hash(phone)))
    if customer is None or customer.anonymised_at is not None or not customer.password_hash:
        return None
    now = utcnow()
    if customer.password_reset_requested_at and now - customer.password_reset_requested_at < RESET_REQUEST_COOLDOWN:
        return None
    customer.password_reset_requested_at = now
    return customer


def temporary_password() -> str:
    """Issued by an admin when a customer forgets theirs; passed on by WhatsApp/phone by the admin."""
    alphabet = "23456789abcdefghjkmnpqrstuvwxyz"
    import secrets

    return "".join(secrets.choice(alphabet) for _ in range(10))
