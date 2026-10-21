"""Admin login: email + password + TOTP, then device approval.

A new device gets a one-time `device_secret` (stored in Keychain/Keystore or browser storage) and
stays pending until a SUPER_ADMIN approves it. Refresh tokens are bound to the device, and admin
sessions end after 12 h (full login with TOTP again).
"""

import time

import pyotp
from fastapi import APIRouter, Depends, HTTPException, Request
from limits import parse
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import get_settings
from app.db import get_session
from app.models import AdminDevice, AdminUser
from app.ratelimit import admin_limited, ip_limited, limiter
from app.schemas import AdminLoginIn, AdminLoginOut, AdminMeOut, AdminRefreshIn, PushTokenIn, TokenOut
from app.security.crypto import constant_time_equals, decrypt, hash_password, random_token, token_hash, verify_password
from app.security.deps import AdminContext, client_ip
from app.security.tokens import (
    AccessClaims,
    RefreshError,
    create_access_token,
    issue_refresh_token,
    revoke_token,
    rotate_refresh_token,
    utcnow,
)
from app.services.audit import audit

router = APIRouter(prefix="/admin/auth", tags=["admin-auth"])
LOGIN_LIMIT = parse("10/15minutes")

# A fixed hash to compare against when the email is unknown, so timing doesn't reveal valid emails.
_DUMMY_HASH = hash_password(random_token())


def _bad_login() -> HTTPException:
    return HTTPException(status_code=401, detail="invalid_credentials")


def _check_totp(user: AdminUser, code: str) -> bool:
    totp = pyotp.TOTP(decrypt(user.totp_secret_enc))
    now = int(time.time())
    for offset in (-1, 0, 1):  # tolerate 30 s clock drift
        step = now // 30 + offset
        if step > user.totp_last_step and constant_time_equals(totp.at(step * 30), code):
            user.totp_last_step = step  # a code can be used once
            return True
    return False


def _tokens(user: AdminUser, device: AdminDevice, refresh: str) -> TokenOut:
    access = create_access_token(AccessClaims(sub=user.id, typ="admin", device_id=device.id, role=user.role))
    return TokenOut(access_token=access, expires_in=get_settings().access_token_minutes * 60, refresh_token=refresh)


@router.post("/login", response_model=AdminLoginOut, dependencies=[Depends(ip_limited)])
async def login(data: AdminLoginIn, request: Request, db: AsyncSession = Depends(get_session)) -> AdminLoginOut:
    ip = client_ip(request)
    if not limiter().hit(LOGIN_LIMIT, f"admin-login:{data.email}") or not limiter().hit(LOGIN_LIMIT, f"admin-login-ip:{ip}"):
        raise HTTPException(status_code=429, detail="rate_limited")

    user = await db.scalar(select(AdminUser).where(AdminUser.email == data.email).with_for_update())
    password_ok = verify_password(user.password_hash if user else _DUMMY_HASH, data.password)
    if user is None or not user.active or not password_ok or not _check_totp(user, data.totp):
        await audit(db, actor_type="admin", actor_id=user.id if user else None, action="auth.login_failed", ip=ip)
        await db.commit()
        raise _bad_login()

    if data.device.device_id is None:
        secret = random_token()
        device = AdminDevice(
            admin_user_id=user.id, name=data.device.name, platform=data.device.platform, secret_hash=token_hash(secret)
        )
        db.add(device)
        await db.flush()
        await audit(db, actor_type="admin", actor_id=user.id, action="device.registered", entity="admin_device", entity_id=device.id, ip=ip)
        # Bootstrap: the very first device of a super admin approves itself (nobody else could).
        no_approved_device = not await db.scalar(
            select(func.count()).select_from(AdminDevice).where(AdminDevice.approved_at.is_not(None), AdminDevice.revoked_at.is_(None))
        )
        if not (no_approved_device and user.role == "SUPER_ADMIN"):
            await db.commit()
            return AdminLoginOut(status="device_pending", device_id=device.id, device_secret=secret)
        device.approved_at, device.approved_by = utcnow(), user.id
        await audit(db, actor_type="admin", actor_id=user.id, action="device.auto_approved_bootstrap", entity="admin_device", entity_id=device.id, ip=ip)
        user.last_login_at = device.last_seen_at = utcnow()
        refresh = await issue_refresh_token(db, "admin", user.id, device.id)
        await db.commit()
        return AdminLoginOut(status="ok", device_id=device.id, device_secret=secret, tokens=_tokens(user, device, refresh))

    device = await db.get(AdminDevice, data.device.device_id)
    if (
        device is None
        or device.admin_user_id != user.id
        or not data.device.device_secret
        or not constant_time_equals(device.secret_hash, token_hash(data.device.device_secret))
    ):
        await db.commit()  # keeps totp_last_step
        raise HTTPException(status_code=403, detail="unknown_device")
    if device.revoked_at is not None:
        await db.commit()
        raise HTTPException(status_code=403, detail="device_revoked")
    if device.approved_at is None:
        await db.commit()
        return AdminLoginOut(status="device_pending", device_id=device.id)

    user.last_login_at = device.last_seen_at = utcnow()
    refresh = await issue_refresh_token(db, "admin", user.id, device.id)
    await audit(db, actor_type="admin", actor_id=user.id, action="auth.login", entity="admin_device", entity_id=device.id, ip=ip)
    await db.commit()
    return AdminLoginOut(status="ok", device_id=device.id, tokens=_tokens(user, device, refresh))


@router.post("/refresh", response_model=TokenOut, dependencies=[Depends(ip_limited)])
async def refresh(data: AdminRefreshIn, db: AsyncSession = Depends(get_session)) -> TokenOut:
    device = await db.get(AdminDevice, data.device_id)
    if (
        device is None
        or device.approved_at is None
        or device.revoked_at is not None
        or not constant_time_equals(device.secret_hash, token_hash(data.device_secret))
    ):
        raise HTTPException(status_code=401, detail="device_invalid")
    try:
        row, new_token = await rotate_refresh_token(db, "admin", data.refresh_token)
    except RefreshError as exc:
        raise HTTPException(status_code=401, detail=f"refresh_{exc}") from None
    if row.device_id != device.id:
        raise HTTPException(status_code=401, detail="device_mismatch")
    user = await db.get(AdminUser, row.subject_id)
    if user is None or not user.active:
        raise HTTPException(status_code=401, detail="inactive")
    await db.commit()
    return _tokens(user, device, new_token)


@router.post("/logout", status_code=204)
async def logout(data: AdminRefreshIn, db: AsyncSession = Depends(get_session)) -> None:
    await revoke_token(db, data.refresh_token)
    await db.commit()


@router.get("/me", response_model=AdminMeOut)
async def me(admin: AdminContext = Depends(admin_limited)) -> AdminMeOut:
    return AdminMeOut(id=admin.id, email=admin.user.email, name=admin.user.name, role=admin.user.role, device_id=admin.device.id)


@router.post("/push-token", status_code=204)
async def set_push_token(data: PushTokenIn, admin: AdminContext = Depends(admin_limited), db: AsyncSession = Depends(get_session)) -> None:
    admin.device.push_token = data.push_token
    await db.commit()
