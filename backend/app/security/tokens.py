"""Access tokens (JWT, 15 min) and rotating refresh tokens with reuse detection."""

import uuid
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from typing import Literal

import jwt
from sqlalchemy import select, update
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import get_settings
from app.models import RefreshToken
from app.security.crypto import random_token, token_hash

SubjectType = Literal["customer", "admin"]
ALGORITHM = "HS256"


def utcnow() -> datetime:
    return datetime.now(UTC)


@dataclass
class AccessClaims:
    sub: int
    typ: SubjectType
    device_id: int | None = None
    role: str | None = None


def create_access_token(claims: AccessClaims) -> str:
    s = get_settings()
    now = utcnow()
    payload = {
        "sub": str(claims.sub),
        "typ": claims.typ,
        "iat": int(now.timestamp()),
        "exp": int((now + timedelta(minutes=s.access_token_minutes)).timestamp()),
        "aud": f"flariane-{claims.typ}",
    }
    if claims.device_id is not None:
        payload["dev"] = claims.device_id
    if claims.role is not None:
        payload["role"] = claims.role
    return jwt.encode(payload, s.jwt_secret, algorithm=ALGORITHM)


def decode_access_token(token: str, expected: SubjectType) -> AccessClaims:
    """Raises jwt.PyJWTError on any problem. Audience pins the token to customer or admin routes."""
    data = jwt.decode(
        token,
        get_settings().jwt_secret,
        algorithms=[ALGORITHM],
        audience=f"flariane-{expected}",
        options={"require": ["exp", "sub", "aud"]},
    )
    if data.get("typ") != expected:
        raise jwt.InvalidTokenError("wrong token type")
    return AccessClaims(sub=int(data["sub"]), typ=expected, device_id=data.get("dev"), role=data.get("role"))


def _refresh_lifetime(typ: SubjectType) -> timedelta:
    s = get_settings()
    return timedelta(days=s.customer_refresh_days) if typ == "customer" else timedelta(hours=s.admin_refresh_hours)


async def issue_refresh_token(
    db: AsyncSession, typ: SubjectType, subject_id: int, device_id: int | None = None
) -> str:
    """Start a new token family (on login). Admin families end after 12 h: full re-login with TOTP."""
    token = random_token()
    now = utcnow()
    life = _refresh_lifetime(typ)
    db.add(
        RefreshToken(
            subject_type=typ,
            subject_id=subject_id,
            device_id=device_id,
            family_id=str(uuid.uuid4()),
            token_hash=token_hash(token),
            expires_at=now + life,
            family_expires_at=now + life,
        )
    )
    return token


class RefreshError(Exception):
    pass


async def rotate_refresh_token(db: AsyncSession, typ: SubjectType, token: str) -> tuple[RefreshToken, str]:
    """Exchange a refresh token for a new one in the same family.

    Presenting an already-rotated token means it was stolen or replayed: revoke the whole family.
    """
    row = await db.scalar(
        select(RefreshToken).where(RefreshToken.token_hash == token_hash(token)).with_for_update()
    )
    now = utcnow()
    if row is None or row.subject_type != typ:
        raise RefreshError("unknown")
    if row.revoked_at is not None:
        raise RefreshError("revoked")
    if row.rotated_at is not None:
        await revoke_family(db, row.family_id)
        await db.commit()
        raise RefreshError("reused")
    if row.expires_at <= now or row.family_expires_at <= now:
        raise RefreshError("expired")

    row.rotated_at = now
    new_token = random_token()
    # Customers get a sliding window; admin families keep their fixed 12 h end.
    expires = now + _refresh_lifetime(typ) if typ == "customer" else row.family_expires_at
    db.add(
        RefreshToken(
            subject_type=typ,
            subject_id=row.subject_id,
            device_id=row.device_id,
            family_id=row.family_id,
            token_hash=token_hash(new_token),
            expires_at=expires,
            family_expires_at=expires,
        )
    )
    return row, new_token


async def revoke_family(db: AsyncSession, family_id: str) -> None:
    await db.execute(
        update(RefreshToken)
        .where(RefreshToken.family_id == family_id, RefreshToken.revoked_at.is_(None))
        .values(revoked_at=utcnow())
    )


async def revoke_token(db: AsyncSession, token: str) -> None:
    row = await db.scalar(select(RefreshToken).where(RefreshToken.token_hash == token_hash(token)))
    if row is not None:
        await revoke_family(db, row.family_id)


async def revoke_device_tokens(db: AsyncSession, device_id: int) -> None:
    await db.execute(
        update(RefreshToken)
        .where(RefreshToken.device_id == device_id, RefreshToken.revoked_at.is_(None))
        .values(revoked_at=utcnow())
    )
