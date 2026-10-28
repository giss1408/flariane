"""A customer can clear finished orders from her own list; the order itself is kept for the business."""

from httpx import AsyncClient
from sqlalchemy import update

from app.db import SessionLocal
from app.models import Order
from tests.conftest import AdminFixture, create_order, login_customer


async def _set_status(ref: str, status: str) -> None:
    async with SessionLocal() as db:
        await db.execute(update(Order).where(Order.public_ref == ref).values(status=status))
        await db.commit()


async def test_customer_removes_finished_orders_from_her_list(client: AsyncClient, customer: dict, admin: AdminFixture, pickup_point) -> None:  # type: ignore[no-untyped-def]
    ref = (await create_order(client, customer, pickup_point))["public_ref"]

    # An order still in progress can't be removed.
    r = await client.post(f"/orders/{ref}/hide", headers=customer)
    assert r.status_code == 409 and r.json()["detail"] == "order_not_finished"
    assert [o["public_ref"] for o in (await client.get("/orders", headers=customer)).json()] == [ref]

    # Collected: she can clear it. Cancelled and refunded orders are finished too.
    await _set_status(ref, "PICKED_UP")
    assert (await client.post(f"/orders/{ref}/hide", headers=customer)).status_code == 204
    assert (await client.get("/orders", headers=customer)).json() == []
    # Clearing twice is harmless.
    assert (await client.post(f"/orders/{ref}/hide", headers=customer)).status_code == 204

    # The business keeps it: the admin still finds the order.
    listed = (await client.get("/admin/orders?tab=done", headers=admin.headers)).json()
    assert [o["public_ref"] for o in listed] == [ref]


async def test_cancelled_and_refunded_orders_can_be_removed_too(client: AsyncClient, customer: dict, pickup_point) -> None:  # type: ignore[no-untyped-def]
    refs = [(await create_order(client, customer, pickup_point))["public_ref"] for _ in range(2)]
    await _set_status(refs[0], "CANCELLED")
    await _set_status(refs[1], "REFUNDED")
    for ref in refs:
        assert (await client.post(f"/orders/{ref}/hide", headers=customer)).status_code == 204
    assert (await client.get("/orders", headers=customer)).json() == []


async def test_nobody_else_can_remove_her_order(client: AsyncClient, customer: dict, pickup_point) -> None:  # type: ignore[no-untyped-def]
    ref = (await create_order(client, customer, pickup_point))["public_ref"]
    await _set_status(ref, "PICKED_UP")
    other = await login_customer(client, phone="+2250505050505", name="Autre")
    assert (await client.post(f"/orders/{ref}/hide", headers=other)).status_code == 404
    assert (await client.post(f"/orders/{ref}/hide")).status_code == 401
    assert [o["public_ref"] for o in (await client.get("/orders", headers=customer)).json()] == [ref]
