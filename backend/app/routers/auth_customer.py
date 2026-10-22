from fastapi import APIRouter, Cookie, Depends, Request, Response
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import get_settings
from app.db import get_session, on_commit
from app.tasks import dispatch
from app.errors import DomainError
from app.ratelimit import ip_limited
from app.schemas import LoginIn, RefreshIn, RegisterIn, TokenOut
from app.security.deps import client_ip
from app.security.tokens import (
    AccessClaims,
    RefreshError,
    create_access_token,
    issue_refresh_token,
    revoke_token,
    rotate_refresh_token,
)
from app.services.audit import audit
from app.services import customer_auth

router = APIRouter(prefix="/auth", tags=["auth"], dependencies=[Depends(ip_limited)])
COOKIE = "flr_rt"


class Unauthorized(DomainError):
    status_code = 401


def _set_refresh_cookie(response: Response, token: str) -> None:
    s = get_settings()
    response.set_cookie(
        COOKIE,
        token,
        max_age=s.customer_refresh_days * 86400,
        httponly=True,
        secure=s.env == "prod",
        samesite="strict",
        path="/auth",
    )


def _tokens(customer_id: int, refresh: str, client: str, response: Response) -> TokenOut:
    access = create_access_token(AccessClaims(sub=customer_id, typ="customer"))
    out = TokenOut(access_token=access, expires_in=get_settings().access_token_minutes * 60)
    if client == "app":
        out.refresh_token = refresh  # stored in Keychain/Keystore by the Flutter app
    else:
        _set_refresh_cookie(response, refresh)  # HttpOnly cookie for the web app
    return out


@router.post("/register", response_model=TokenOut, status_code=201)
async def register(data: RegisterIn, request: Request, response: Response, db: AsyncSession = Depends(get_session)) -> TokenOut:
    customer = await customer_auth.register(db, data.phone, data.password, data.display_name)
    refresh = await issue_refresh_token(db, "customer", customer.id)
    await audit(db, actor_type="customer", actor_id=customer.id, action="auth.registered", ip=client_ip(request))
    on_commit(db, lambda: dispatch("push_admins", event="customer_registered", order_ref=f"#{customer.id}", order_id=0))
    await db.commit()
    return _tokens(customer.id, refresh, data.client, response)


@router.post("/login", response_model=TokenOut)
async def login(data: LoginIn, request: Request, response: Response, db: AsyncSession = Depends(get_session)) -> TokenOut:
    customer = await customer_auth.login(db, data.phone, data.password)
    refresh = await issue_refresh_token(db, "customer", customer.id)
    await audit(db, actor_type="customer", actor_id=customer.id, action="auth.login", ip=client_ip(request))
    await db.commit()
    return _tokens(customer.id, refresh, data.client, response)


@router.post("/refresh", response_model=TokenOut)
async def refresh(
    data: RefreshIn,
    response: Response,
    flr_rt: str | None = Cookie(default=None),
    db: AsyncSession = Depends(get_session),
) -> TokenOut:
    token = data.refresh_token or flr_rt
    if not token:
        raise Unauthorized("no_refresh_token")
    try:
        row, new_token = await rotate_refresh_token(db, "customer", token)
    except RefreshError as exc:
        response.delete_cookie(COOKIE, path="/auth")
        raise Unauthorized(f"refresh_{exc}") from None
    await db.commit()
    return _tokens(row.subject_id, new_token, data.client, response)


@router.post("/logout", status_code=204)
async def logout(
    data: RefreshIn, response: Response, flr_rt: str | None = Cookie(default=None), db: AsyncSession = Depends(get_session)
) -> None:
    token = data.refresh_token or flr_rt
    if token:
        await revoke_token(db, token)
        await db.commit()
    response.delete_cookie(COOKIE, path="/auth")
