"""DEV ONLY: sign in as a test customer without credentials. Never mounted when FLR_ENV=prod."""

from fastapi import APIRouter, Depends
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import get_settings
from app.db import get_session
from app.models import Customer
from app.schemas import TokenOut
from app.security.crypto import encrypt, phone_hash
from app.security.tokens import AccessClaims, create_access_token, issue_refresh_token

router = APIRouter(prefix="/dev", tags=["dev"], include_in_schema=False)
TEST_PHONE = "+2250700000001"


@router.post("/customer-login", response_model=TokenOut)
async def dev_customer_login(db: AsyncSession = Depends(get_session)) -> TokenOut:
    ph = phone_hash(TEST_PHONE)
    customer = await db.scalar(select(Customer).where(Customer.phone_hash == ph))
    if customer is None:
        customer = Customer(phone_enc=encrypt(TEST_PHONE), phone_hash=ph, display_name="Client Test")
        db.add(customer)
        await db.flush()
    refresh = await issue_refresh_token(db, "customer", customer.id)
    await db.commit()
    access = create_access_token(AccessClaims(sub=customer.id, typ="customer"))
    return TokenOut(access_token=access, expires_in=get_settings().access_token_minutes * 60, refresh_token=refresh)
