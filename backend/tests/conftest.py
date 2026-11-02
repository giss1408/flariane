import base64
import os
from collections.abc import AsyncIterator

# Test configuration must be in place before the app is imported.
os.environ.update(
    {
        "FLR_ENV": "test",
        "FLR_DATABASE_URL": "postgresql+asyncpg://flariane:flariane@localhost:5433/flariane_test",
        "FLR_JWT_SECRET": base64.b64encode(b"j" * 32).decode(),
        "FLR_FIELD_ENCRYPTION_KEY": base64.b64encode(b"e" * 32).decode(),
        "FLR_HASH_KEY": base64.b64encode(b"h" * 32).decode(),
        "FLR_WHATSAPP_MODE": "log",
        "FLR_WHATSAPP_APP_SECRET": "wa-app-secret",
        "FLR_PUSH_MODE": "log",
        "FLR_TASK_MODE": "record",
        "FLR_RATE_LIMIT_STORAGE": "memory://",
        "FLR_STORAGE_LOCAL_DIR": "/tmp/flariane-test-uploads",
    }
)

import asyncpg  # noqa: E402
import pyotp  # noqa: E402
import pytest  # noqa: E402
from httpx import ASGITransport, AsyncClient  # noqa: E402
from sqlalchemy import text  # noqa: E402

from app import ratelimit, tasks  # noqa: E402
from app.db import Base, SessionLocal, engine  # noqa: E402
from app.integrations import push, whatsapp  # noqa: E402
from app.main import app  # noqa: E402
from app.models import AdminDevice, AdminUser, PickupPoint  # noqa: E402
from app.security.crypto import encrypt, hash_password  # noqa: E402
from app.security.tokens import AccessClaims, create_access_token, utcnow  # noqa: E402


@pytest.fixture(scope="session", autouse=True)
def _create_test_db() -> None:
    import asyncio

    async def setup() -> None:
        conn = await asyncpg.connect("postgresql://flariane:flariane@localhost:5433/flariane")
        await conn.execute("DROP DATABASE IF EXISTS flariane_test WITH (FORCE)")
        await conn.execute("CREATE DATABASE flariane_test")
        await conn.close()
        async with engine.begin() as c:
            await c.run_sync(Base.metadata.create_all)

    asyncio.run(setup())


@pytest.fixture(autouse=True)
async def _clean() -> AsyncIterator[None]:
    tables = ", ".join(t.name for t in Base.metadata.sorted_tables)
    async with engine.begin() as c:
        await c.execute(text(f"TRUNCATE {tables} RESTART IDENTITY CASCADE"))
    tasks.RECORDED.clear()
    whatsapp.SENT_LOG.clear()
    push.SENT_LOG.clear()
    ratelimit.reset()
    yield


@pytest.fixture
async def client() -> AsyncIterator[AsyncClient]:
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as c:
        yield c


@pytest.fixture
async def pickup_point() -> PickupPoint:
    async with SessionLocal() as db:
        point = PickupPoint(name="Flariane Cocody", address="Riviera 2", commune="Cocody", opening_hours="9h–19h")
        db.add(point)
        await db.commit()
        return point


class AdminFixture:
    def __init__(self, user: AdminUser, device: AdminDevice, totp_secret: str, password: str):
        self.user, self.device, self.totp_secret, self.password = user, device, totp_secret, password

    @property
    def headers(self) -> dict[str, str]:
        token = create_access_token(AccessClaims(sub=self.user.id, typ="admin", device_id=self.device.id, role=self.user.role))
        return {"Authorization": f"Bearer {token}"}


async def make_admin(role: str = "SUPER_ADMIN", email: str = "admin@flariane.ci") -> AdminFixture:
    secret = pyotp.random_base32()
    password = "correct horse battery staple"
    async with SessionLocal() as db:
        user = AdminUser(email=email, name="Admin", role=role, password_hash=hash_password(password), totp_secret_enc=encrypt(secret))
        db.add(user)
        await db.flush()
        device = AdminDevice(admin_user_id=user.id, name="Test phone", platform="android", secret_hash="x", approved_at=utcnow())
        db.add(device)
        await db.commit()
        return AdminFixture(user, device, secret, password)


@pytest.fixture
async def admin() -> AdminFixture:
    return await make_admin()


PHONE = "0701020304"


PASSWORD = "awa-secret-2026"


async def login_customer(client: AsyncClient, phone: str = PHONE, name: str = "Awa Koné") -> dict[str, str]:
    r = await client.post("/auth/register", json={"phone": phone, "password": PASSWORD, "display_name": name, "consent": True})
    assert r.status_code == 201, r.text
    # Most tests start from a verified number (the verification flow has its own test).
    from sqlalchemy import update

    from app.models import Customer
    from app.security.crypto import phone_hash
    from app.services.customer_auth import normalize_ci_phone

    async with SessionLocal() as db:
        await db.execute(update(Customer).where(Customer.phone_hash == phone_hash(normalize_ci_phone(phone))).values(phone_verified_at=utcnow()))
        await db.commit()
    return {"Authorization": f"Bearer {r.json()['access_token']}"}


@pytest.fixture
async def customer(client: AsyncClient) -> dict[str, str]:
    return await login_customer(client)


CART_SHARE = "Regarde mon panier SHEIN ! https://onelink.shein.com/57/65rpbi9ni43f?shc=2_RNw3pcqAELu"

DRAFT = {
    "items": [
        {"title": "Robe midi fleurie", "size": "M", "color": "Bleu", "qty": 1, "source_price": "12.99", "source_currency": "EUR"},
        {"title": "Sandales", "size": "39", "color": "Noir", "qty": 2, "source_price": "8.50", "source_currency": "EUR"},
    ],
    "fee_xof": 3000,
}


async def create_order(client: AsyncClient, customer: dict[str, str], point: PickupPoint) -> dict:
    r = await client.post("/orders", json={"share_text": CART_SHARE, "pickup_point_id": point.id}, headers=customer)
    assert r.status_code == 201, r.text
    return r.json()


async def order_id(ref: str) -> int:
    from sqlalchemy import select

    from app.models import Order

    async with SessionLocal() as db:
        return (await db.scalar(select(Order.id).where(Order.public_ref == ref)))  # type: ignore[return-value]


async def quote_and_send(client: AsyncClient, admin: AdminFixture, oid: int, draft: dict | None = None) -> dict:
    r = await client.put(f"/admin/orders/{oid}/quote-draft", json=draft or DRAFT, headers=admin.headers)
    assert r.status_code == 200, r.text
    version = r.json()["version"]
    r = await client.post(f"/admin/orders/{oid}/quotes/{version}/send", json={}, headers=admin.headers)
    assert r.status_code == 200, r.text
    return r.json()


async def pay(client: AsyncClient, customer: dict, admin: AdminFixture, ref: str) -> int:
    """Manual payment: the customer sends the screenshot, an admin confirms it. Returns the confirm status."""
    import io

    from PIL import Image

    buf = io.BytesIO()
    Image.new("RGB", (40, 60), "orange").save(buf, format="JPEG")
    r = await client.post(f"/orders/{ref}/payment/declare", data={"method": "WAVE"}, files={"file": ("pay.jpg", buf.getvalue(), "image/jpeg")}, headers=customer)
    assert r.status_code == 200, r.text
    oid = await order_id(ref)
    r = await client.post(f"/admin/orders/{oid}/confirm-payment", json={"transaction_ref": "T_TEST"}, headers=admin.headers)
    return 200 if r.status_code == 204 else r.status_code
