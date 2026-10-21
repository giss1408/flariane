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
from app.models import AdminUser
from app.ratelimit import ip_limited
from app.schemas import AdminUserIn
from app.security.crypto import encrypt, hash_password
from app.security.deps import client_ip
from app.services.audit import audit

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
    if await db.scalar(select(func.count()).select_from(AdminUser)):
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
