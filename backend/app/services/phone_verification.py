"""Phone ownership check: an admin sends a 6-digit code from their own WhatsApp; the customer
types it in the app. Until then she can't place orders."""

from datetime import timedelta

from app.errors import BadRequest, Conflict, TooManyRequests
from app.models import Customer
from app.security.crypto import constant_time_equals, keyed_hash, random_digits
from app.security.tokens import utcnow

CODE_TTL = timedelta(hours=48)
MAX_ATTEMPTS = 5


def _hash(customer_id: int, code: str) -> str:
    return keyed_hash(f"{customer_id}:{code}", "phone-verify")


def issue_code(customer: Customer) -> str:
    """New code (the previous one stops working). Returned once, for the WhatsApp message."""
    if customer.phone_verified_at is not None:
        raise Conflict("already_verified")
    code = random_digits(6)
    customer.verify_code_hash = _hash(customer.id, code)
    customer.verify_code_expires_at = utcnow() + CODE_TTL
    customer.verify_attempts = 0
    return code


def check_code(customer: Customer, code: str) -> None:
    if customer.phone_verified_at is not None:
        return
    if customer.verify_code_hash is None or customer.verify_code_expires_at is None or customer.verify_code_expires_at <= utcnow():
        raise BadRequest("no_verification_code")
    if customer.verify_attempts >= MAX_ATTEMPTS:
        raise TooManyRequests("verification_locked")
    if not constant_time_equals(customer.verify_code_hash, _hash(customer.id, code)):
        customer.verify_attempts += 1
        raise BadRequest("wrong_verification_code")
    customer.phone_verified_at = utcnow()
    customer.verify_code_hash = customer.verify_code_expires_at = None


def message(first_name: str, code: str) -> str:
    return (
        f"Bonjour {first_name} 👋 Bienvenue chez Flariane !\n\n"
        f"Ton code de vérification : *{code}*\n\n"
        "Saisis-le dans l’app Flariane pour activer ton compte. Si tu n’as pas créé de compte, ignore ce message."
    )
