from collections.abc import Callable, Coroutine
from dataclasses import dataclass
from typing import Any

import jwt
from fastapi import Depends, HTTPException, Request
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from sqlalchemy.ext.asyncio import AsyncSession

from app.db import get_session
from app.enums import ROLE_RANK, AdminRole
from app.models import AdminDevice, AdminUser, Customer
from app.security.tokens import decode_access_token, utcnow

bearer = HTTPBearer(auto_error=False)


def client_ip(request: Request) -> str | None:
    # Uvicorn runs with --proxy-headers behind the platform proxy, so client.host is the real IP.
    return request.client.host if request.client else None


def _unauthorized() -> HTTPException:
    return HTTPException(status_code=401, detail="not_authenticated", headers={"WWW-Authenticate": "Bearer"})


async def current_customer(
    request: Request,
    creds: HTTPAuthorizationCredentials | None = Depends(bearer),
    db: AsyncSession = Depends(get_session),
) -> Customer:
    if creds is None:
        raise _unauthorized()
    try:
        claims = decode_access_token(creds.credentials, "customer")
    except jwt.PyJWTError:
        raise _unauthorized() from None
    customer = await db.get(Customer, claims.sub)
    if customer is None or customer.anonymised_at is not None:
        raise _unauthorized()
    request.state.rate_key = f"customer:{customer.id}"
    return customer


@dataclass
class AdminContext:
    user: AdminUser
    device: AdminDevice

    @property
    def id(self) -> int:
        return self.user.id

    @property
    def role(self) -> AdminRole:
        return AdminRole(self.user.role)


async def current_admin(
    request: Request,
    creds: HTTPAuthorizationCredentials | None = Depends(bearer),
    db: AsyncSession = Depends(get_session),
) -> AdminContext:
    if creds is None:
        raise _unauthorized()
    try:
        claims = decode_access_token(creds.credentials, "admin")
    except jwt.PyJWTError:
        raise _unauthorized() from None
    user = await db.get(AdminUser, claims.sub)
    device = await db.get(AdminDevice, claims.device_id) if claims.device_id else None
    # A revoked device or deactivated admin loses access at the next request, not at token expiry.
    if (
        user is None
        or not user.active
        or device is None
        or device.admin_user_id != user.id
        or device.approved_at is None
        or device.revoked_at is not None
    ):
        raise _unauthorized()
    device.last_seen_at = utcnow()
    request.state.rate_key = f"admin:{user.id}"
    return AdminContext(user=user, device=device)


def require_pickup_access() -> Callable[..., Coroutine[Any, Any, AdminContext]]:
    """Pickup agents and operators (and above): the pickup desk actions."""

    async def dependency(admin: AdminContext = Depends(current_admin)) -> AdminContext:
        if admin.role != AdminRole.PICKUP and ROLE_RANK[admin.role] < ROLE_RANK[AdminRole.OPERATOR]:
            raise HTTPException(status_code=403, detail="forbidden")
        return admin

    return dependency


def require_role(minimum: AdminRole) -> Callable[..., Coroutine[Any, Any, AdminContext]]:
    async def dependency(admin: AdminContext = Depends(current_admin)) -> AdminContext:
        if ROLE_RANK[admin.role] < ROLE_RANK[minimum]:
            raise HTTPException(status_code=403, detail="forbidden")
        return admin

    return dependency
