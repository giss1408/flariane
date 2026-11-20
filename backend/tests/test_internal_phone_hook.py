"""The auth service moves a person to a new number: her flariane customer row follows first, so nothing is split or lost."""

import pytest
from sqlalchemy import select

from app.config import get_settings
from app.db import SessionLocal
from app.models import AuditLog, Customer
from app.security.crypto import decrypt, phone_hash
from tests.conftest import login_customer

KEY = "k" * 32
OLD = "+4917612345678"  # the German test number the suite uses outside production
NEW = "+4917699998888"
HDR = {"X-Service-Key": KEY}


@pytest.fixture
def hook_on(monkeypatch):
    monkeypatch.setattr(get_settings(), "auth_hook_key", KEY)


async def by_phone(e164):
    async with SessionLocal() as db:
        return await db.scalar(select(Customer).where(Customer.phone_hash == phone_hash(e164)))


async def test_off_by_default_and_the_key_is_required(client, monkeypatch):
    body = {"old_phone": OLD, "new_phone": NEW}
    assert (await client.post("/internal/phone-changed", json=body, headers=HDR)).status_code == 403  # no key configured: closed
    monkeypatch.setattr(get_settings(), "auth_hook_key", KEY)
    assert (await client.post("/internal/phone-changed", json=body)).status_code == 403
    assert (await client.post("/internal/phone-changed", json=body, headers={"X-Service-Key": "x" * 32})).status_code == 403
    monkeypatch.setattr(get_settings(), "auth_hook_key", "short")
    assert (await client.post("/internal/phone-changed", json=body, headers={"X-Service-Key": "short"})).status_code == 403  # a weak key is no key


async def test_the_customer_row_follows_the_new_number_and_keeps_its_id(client, hook_on):
    await login_customer(client)
    before = await by_phone(OLD)
    assert before is not None
    r = await client.post("/internal/phone-changed", json={"old_phone": OLD, "new_phone": NEW}, headers=HDR)
    assert r.status_code == 200 and r.json() == {"ok": True, "moved": True}
    assert await by_phone(OLD) is None
    after = await by_phone(NEW)
    assert after.id == before.id and decrypt(after.phone_enc) == NEW
    async with SessionLocal() as db:
        logged = (await db.scalars(select(AuditLog).where(AuditLog.action == "customer.phone_moved_by_auth"))).all()
        assert len(logged) == 1 and OLD not in str(logged[0].after) and NEW not in str(logged[0].after)


async def test_idempotent_and_a_person_who_never_used_flariane_is_fine(client, hook_on):
    body = {"old_phone": OLD, "new_phone": NEW}
    assert (await client.post("/internal/phone-changed", json=body, headers=HDR)).json() == {"ok": True, "moved": False}  # nobody on OLD
    await login_customer(client)
    assert (await client.post("/internal/phone-changed", json=body, headers=HDR)).json()["moved"] is True
    assert (await client.post("/internal/phone-changed", json=body, headers=HDR)).json() == {"ok": True, "moved": False}  # already moved


async def test_a_different_customer_on_the_new_number_stops_the_move(client, hook_on):
    await login_customer(client)
    async with SessionLocal() as db:
        db.add(Customer(phone_enc=__import__("app.security.crypto", fromlist=["encrypt"]).encrypt(NEW), phone_hash=phone_hash(NEW)))
        await db.commit()
    r = await client.post("/internal/phone-changed", json={"old_phone": OLD, "new_phone": NEW}, headers=HDR)
    assert r.status_code == 409
    assert await by_phone(OLD) is not None  # nothing moved


async def test_the_hook_is_not_in_the_public_api_description(client, hook_on):
    assert "/internal/phone-changed" not in str((await client.get("/openapi.json")).text)
