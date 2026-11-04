"""Idempotency-Key on order creation and payment declaration: a retry gets the first answer."""

import io

from httpx import AsyncClient
from PIL import Image
from sqlalchemy import func, select

from app import tasks
from app.db import SessionLocal
from app.models import Order, PickupPoint
from tests.conftest import AdminFixture, CART_SHARE, create_order, order_id, quote_and_send

OTHER_CART = "Mon panier https://onelink.shein.com/57/zzzzzzzzzzz?shc=1"


async def _orders() -> int:
    async with SessionLocal() as db:
        return await db.scalar(select(func.count()).select_from(Order))


async def test_create_order_replays_stored_answer(client: AsyncClient, customer: dict, pickup_point: PickupPoint) -> None:
    h = {**customer, "Idempotency-Key": "k-1"}
    first = await client.post("/orders", json={"share_text": CART_SHARE, "pickup_point_id": pickup_point.id}, headers=h)
    assert first.status_code == 201
    # Same key, even with a different body: the stored answer comes back, nothing new is created.
    again = await client.post("/orders", json={"share_text": OTHER_CART, "pickup_point_id": pickup_point.id}, headers=h)
    assert again.status_code == 201 and again.json()["public_ref"] == first.json()["public_ref"]
    assert await _orders() == 1
    # A new key is a new request.
    third = await client.post("/orders", json={"share_text": OTHER_CART, "pickup_point_id": pickup_point.id}, headers={**customer, "Idempotency-Key": "k-2"})
    assert third.json()["public_ref"] != first.json()["public_ref"] and await _orders() == 2


async def test_failed_attempt_releases_the_key(client: AsyncClient, customer: dict, pickup_point: PickupPoint) -> None:
    h = {**customer, "Idempotency-Key": "k-fail"}
    bad = await client.post("/orders", json={"share_text": "pas de lien"}, headers=h)
    assert bad.status_code == 400
    ok = await client.post("/orders", json={"share_text": CART_SHARE, "pickup_point_id": pickup_point.id}, headers=h)
    assert ok.status_code == 201


async def test_declare_payment_replayed_once(client: AsyncClient, customer: dict, admin: AdminFixture, pickup_point: PickupPoint) -> None:
    await client.put("/admin/settings", json={"payment_mode": "manual", "payment_accounts": {"WAVE": "0700000000"}}, headers=admin.headers)
    ref = (await create_order(client, customer, pickup_point))["public_ref"]
    await quote_and_send(client, admin, await order_id(ref))
    await client.post(f"/orders/{ref}/quotes/1/accept", json={"sizes_confirmed": True}, headers=customer)
    buf = io.BytesIO()
    Image.new("RGB", (40, 60), "orange").save(buf, format="JPEG")

    def send() -> object:
        return client.post(f"/orders/{ref}/payment/declare", data={"method": "WAVE"}, files={"file": ("pay.jpg", buf.getvalue(), "image/jpeg")}, headers={**customer, "Idempotency-Key": "k-pay"})

    before = len(tasks.RECORDED)
    r1, r2 = await send(), await send()  # type: ignore[misc]
    assert r1.status_code == r2.status_code == 200 and r1.json() == r2.json()
    assert [e for _, e in tasks.RECORDED[before:] if e.get("event") == "payment_declared"].__len__() == 1
