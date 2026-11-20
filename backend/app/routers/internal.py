"""Calls from the platform `auth` service over the private network. Not for apps or browsers: every route needs the shared key,
and the reverse proxy does not publish `/internal/*` on the public hostname."""

import hmac

from fastapi import APIRouter, Depends, Request
from pydantic import BaseModel, Field
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import get_settings
from app.db import get_session
from app.errors import Conflict, Forbidden
from app.models import Customer
from app.security.crypto import encrypt, phone_hash
from app.services import customer_auth
from app.services.audit import audit

router = APIRouter(prefix="/internal", tags=["internal"], include_in_schema=False)


def auth_service(request: Request) -> None:
    key = get_settings().auth_hook_key
    given = request.headers.get("x-service-key", "")
    if len(key) < 16 or not hmac.compare_digest(key.encode(), given.encode()):
        raise Forbidden("forbidden")


class PhoneChangedIn(BaseModel):
    old_phone: str = Field(min_length=6, max_length=32)
    new_phone: str = Field(min_length=6, max_length=32)


@router.post("/phone-changed")
async def phone_changed(data: PhoneChangedIn, request: Request, _: None = Depends(auth_service), db: AsyncSession = Depends(get_session)) -> dict:
    """auth is about to move a person to a new number (she proved it there). Her customer row follows, so a token that carries the new
    number finds her orders and points instead of opening a second, empty customer. Idempotent: no customer on the old number (never
    used flariane, or already moved) answers ok; a DIFFERENT customer already on the new number is a conflict (nothing changes)."""
    old, new = customer_auth.normalize_ci_phone(data.old_phone), customer_auth.normalize_ci_phone(data.new_phone)
    customer = await db.scalar(select(Customer).where(Customer.phone_hash == phone_hash(old)).with_for_update())
    if customer is None:
        return {"ok": True, "moved": False}
    if await db.scalar(select(Customer.id).where(Customer.phone_hash == phone_hash(new), Customer.id != customer.id)) is not None:
        raise Conflict("number_taken")
    customer.phone_enc, customer.phone_hash = encrypt(new), phone_hash(new)
    await audit(db, actor_type="system", actor_id=None, action="customer.phone_moved_by_auth", entity="customer", entity_id=customer.id)
    await db.commit()
    return {"ok": True, "moved": True}
