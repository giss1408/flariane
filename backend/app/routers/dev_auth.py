"""DEV ONLY: sign in without credentials (test customer, test super admin). Never mounted when FLR_ENV=prod."""

from fastapi import APIRouter, Depends
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import get_settings
from app.db import get_session
from app.models import AdminDevice, AdminUser, Customer
from app.schemas import TokenOut
from app.security.crypto import encrypt, hash_password, phone_hash, random_token, token_hash
from app.security.tokens import AccessClaims, create_access_token, issue_refresh_token, utcnow

router = APIRouter(prefix="/dev", tags=["dev"], include_in_schema=False)
TEST_PHONE = "+2250700000001"


@router.post("/customer-login", response_model=TokenOut)
async def dev_customer_login(db: AsyncSession = Depends(get_session)) -> TokenOut:
    ph = phone_hash(TEST_PHONE)
    customer = await db.scalar(select(Customer).where(Customer.phone_hash == ph))
    if customer is None:
        customer = Customer(phone_enc=encrypt(TEST_PHONE), phone_hash=ph)
        db.add(customer)
        await db.flush()
    elif customer.display_name == "Client Test":
        customer.display_name = None  # older placeholder: let the app ask for a real first name
    refresh = await issue_refresh_token(db, "customer", customer.id)
    await db.commit()
    access = create_access_token(AccessClaims(sub=customer.id, typ="customer"))
    return TokenOut(access_token=access, expires_in=get_settings().access_token_minutes * 60, refresh_token=refresh)


@router.post("/admin-login")
async def dev_admin_login(db: AsyncSession = Depends(get_session)) -> dict:
    """Signs in as dev@flariane.ci (SUPER_ADMIN) on a fresh, pre-approved device. No password, no TOTP."""
    user = await db.scalar(select(AdminUser).where(AdminUser.email == "dev@flariane.ci"))
    if user is None:
        user = AdminUser(
            email="dev@flariane.ci", name="Admin Test", role="SUPER_ADMIN",
            password_hash=hash_password(random_token()), totp_secret_enc=encrypt("UNUSEDDEVSECRET2"),
        )
        db.add(user)
        await db.flush()
    secret = random_token()
    device = AdminDevice(admin_user_id=user.id, name="Dev", platform="android", secret_hash=token_hash(secret), approved_at=utcnow())
    db.add(device)
    await db.flush()
    refresh = await issue_refresh_token(db, "admin", user.id, device.id)
    await db.commit()
    access = create_access_token(AccessClaims(sub=user.id, typ="admin", device_id=device.id, role=user.role))
    return {"device_id": device.id, "device_secret": secret, "access_token": access, "refresh_token": refresh}
