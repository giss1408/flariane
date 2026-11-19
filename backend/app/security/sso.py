"""Accept tokens from the platform `auth` service next to flariane's own (dual-accept, customers only).

A token is mapped to a flariane Customer by the `lid` claim (the customer's flariane id, set by auth for migrated accounts), else by
the `ph` claim (`tel:+225...`) through the same keyed phone hash flariane already uses, so existing customers keep their orders and points. A phone unknown to flariane gets a customer row on
first use (auth already verified the number and recorded consent at registration). Verification is local with the
JWKS (algorithm pinned to EdDSA by regisse_kit.sso): an auth outage does not stop customers who hold a valid token.
"""

from functools import lru_cache

import httpx
from anyio import to_thread
from regisse_kit.sso import SsoError, SsoVerifier
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import get_settings
from app.enums import AdminRole
from app.models import AdminUser, Customer
from app.security.crypto import encrypt, phone_hash
from app.security.tokens import utcnow
from app.services import loyalty

SSO_CONSENT_VERSION = "sso-2026-11"


@lru_cache
def verifier() -> SsoVerifier:
    s = get_settings()
    return SsoVerifier(issuer=s.sso_issuer, audience=s.sso_audience, jwks_fetch=lambda: httpx.get(s.sso_jwks_url, timeout=5).raise_for_status().json())


def reset() -> None:
    verifier.cache_clear()


async def customer_from_token(db: AsyncSession, token: str) -> Customer | None:
    """The Customer behind an `auth` token, or None when the token is not acceptable. Never raises on bad tokens."""
    s = get_settings()
    if not s.sso_enabled or not s.sso_issuer or not s.sso_jwks_url:
        return None
    try:
        p = await to_thread.run_sync(verifier().verify, token)
    except (SsoError, httpx.HTTPError, ValueError):
        return None
    # customer app only, a real customer session, and not in the middle of a forced password change
    if p.app != "customer" or p.role != "customer" or p.must_change_password or not p.phone_key.startswith("tel:+"):
        return None
    if p.legacy_id is not None:
        # A migrated account: auth says which flariane customer this is. Trust the id, never the phone, so a number change in
        # flariane (or in auth) cannot split her into two customers. An id that does not exist is refused, never re-created.
        try:
            customer = await db.get(Customer, int(p.legacy_id))
        except ValueError:
            return None
        if customer is None:
            return None
    else:
        e164 = p.phone_key[4:]
        ph = phone_hash(e164)
        customer = await db.scalar(select(Customer).where(Customer.phone_hash == ph))
        if customer is None:
            customer = Customer(phone_enc=encrypt(e164), phone_hash=ph, phone_verified_at=utcnow(), consent_at=utcnow(), consent_version=SSO_CONSENT_VERSION)
            await loyalty.assign_referral_code(db, customer)
            db.add(customer)
            try:
                await db.commit()
            except IntegrityError:  # two first requests at once: the other one created it
                await db.rollback()
                customer = await db.scalar(select(Customer).where(Customer.phone_hash == ph))
    if customer is None or customer.anonymised_at is not None or customer.blocked_at is not None:
        return None
    return customer


async def admin_from_token(db: AsyncSession, token: str):
    """(AdminUser, Principal) for an `auth` back-office token, or None. Migrated admins only: the token carries the admin's
    flariane id (`lid`); a back-office user unknown to flariane is refused, never created on the fly."""
    s = get_settings()
    if not s.sso_enabled or not s.sso_issuer or not s.sso_jwks_url:
        return None
    try:
        p = await to_thread.run_sync(verifier().verify, token)
    except (SsoError, httpx.HTTPError, ValueError):
        return None
    if p.app != "admin" or p.must_change_password or p.legacy_id is None or p.role.upper() not in {r.value for r in AdminRole}:
        return None
    try:
        user = await db.get(AdminUser, int(p.legacy_id))
    except ValueError:
        return None
    if user is None or not user.active:
        return None
    return user, p


async def session_active(sid: str) -> bool | None:
    """Is the auth session behind a back-office login still alive? None = auth unreachable (the caller decides)."""
    s = get_settings()
    if not s.sso_auth_url or not s.sso_service_key:
        return None
    try:
        async with httpx.AsyncClient(timeout=3) as c:
            r = await c.post(f"{s.sso_auth_url.rstrip('/')}/v1/sessions/check", json={"sid": sid}, headers={"X-Service-Key": s.sso_service_key})
        r.raise_for_status()
        return bool(r.json().get("active"))
    except (httpx.HTTPError, ValueError):
        return None
