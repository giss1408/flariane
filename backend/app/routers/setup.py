"""First-run setup without a server shell: create the first super admin.

Works only while no admin exists, and only with the FLR_SETUP_TOKEN secret (set in the host's
environment settings). Afterwards admins are managed from the app.
"""

import hmac

import pyotp
from fastapi import APIRouter, Depends, Header, HTTPException, Request
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import get_settings
from app.db import get_session
from app.models import AdminDevice, AdminUser
from app.ratelimit import ip_limited
from app.schemas import AdminUserIn
from app.security.crypto import encrypt, hash_password
from app.security.deps import client_ip
from app.security.tokens import revoke_device_tokens, utcnow
from app.services.audit import audit

LEGACY_DEV_ADMIN = "dev@flariane.ci"

router = APIRouter(prefix="/setup", tags=["setup"], include_in_schema=False, dependencies=[Depends(ip_limited)])


@router.post("/first-admin")
async def first_admin(
    data: AdminUserIn,
    request: Request,
    x_setup_token: str = Header(default=""),
    db: AsyncSession = Depends(get_session),
) -> dict[str, str]:
    expected = get_settings().setup_token
    if not expected or not hmac.compare_digest(expected.encode(), x_setup_token.encode()):
        raise HTTPException(status_code=403, detail="setup_disabled")
    # The removed password-less test login left a placeholder admin (dev@flariane.ci) that nobody
    # can sign in with: retire it and its devices so it doesn't block setup or the device bootstrap.
    legacy = await db.scalar(select(AdminUser).where(AdminUser.email == LEGACY_DEV_ADMIN))
    if legacy is not None and legacy.active:
        legacy.active = False
        for device in (await db.scalars(select(AdminDevice).where(AdminDevice.admin_user_id == legacy.id))).all():
            device.revoked_at = device.revoked_at or utcnow()
            await revoke_device_tokens(db, device.id)
    if await db.scalar(select(func.count()).select_from(AdminUser).where(AdminUser.email != LEGACY_DEV_ADMIN)):
        raise HTTPException(status_code=409, detail="already_set_up")
    secret = pyotp.random_base32()
    user = AdminUser(email=data.email, name=data.name, role="SUPER_ADMIN", password_hash=hash_password(data.password), totp_secret_enc=encrypt(secret))
    db.add(user)
    await db.flush()
    await audit(db, actor_type="system", actor_id=None, action="setup.first_admin", entity="admin_user", entity_id=user.id, ip=client_ip(request))
    await db.commit()
    return {
        "email": user.email,
        "totp_secret": secret,
        "totp_uri": pyotp.TOTP(secret).provisioning_uri(name=user.email, issuer_name="Flariane Admin"),
    }
