"""Departure creation, batch "ready for pickup" and the pickup code shown to the owner."""

from httpx import AsyncClient

from app import tasks
from tests.conftest import AdminFixture
from tests.test_payments_ops import _paid


async def _purchased(client: AsyncClient, customer: dict, admin: AdminFixture, point) -> tuple[str, int]:  # type: ignore[no-untyped-def]
    ref, oid, items = await _paid(client, customer, admin, point)
    r = await client.post(f"/admin/orders/{oid}/purchase", json={"store_order_ref": "GSH9", "paid_amount": "29.99", "currency": "EUR", "checked_item_ids": items}, headers=admin.headers)
    assert r.status_code == 200, r.text
    return ref, oid


async def test_create_departure_unblocks_a_used_next_departure(client: AsyncClient, customer: dict, admin: AdminFixture, pickup_point) -> None:  # type: ignore[no-untyped-def]
    ref, oid = await _purchased(client, customer, admin, pickup_point)
    await client.put("/admin/settings", json={"next_departure_date": "2030-01-15"}, headers=admin.headers)
    first = (await client.get("/admin/shipments", headers=admin.headers)).json()[0]["id"]
    await client.post(f"/admin/shipments/{first}/orders", json={"order_ids": [oid]}, headers=admin.headers)
    await client.post(f"/admin/shipments/{first}/depart", json={}, headers=admin.headers)

    # The next departure already left: a new one is created and becomes the next one customers see.
    r = await client.post("/admin/shipments", json={"departure_date": "2030-02-20"}, headers=admin.headers)
    assert r.status_code == 201 and r.json()["status"] == "OPEN" and r.json()["departure_date"] == "2030-02-20"
    assert (await client.get("/admin/settings", headers=admin.headers)).json()["next_departure_date"] == "2030-02-20"
    # A date that belongs to a shipment that already left cannot be reused; the past is refused.
    assert (await client.post("/admin/shipments", json={"departure_date": "2030-01-15"}, headers=admin.headers)).json()["detail"] == "departure_date_taken"
    assert (await client.post("/admin/shipments", json={"departure_date": "2020-01-01"}, headers=admin.headers)).json()["detail"] == "departure_in_past"
    # A second open departure does not steal the "next departure" from a still-open one.
    await client.post("/admin/shipments", json={"departure_date": "2030-03-20"}, headers=admin.headers)
    assert (await client.get("/admin/settings", headers=admin.headers)).json()["next_departure_date"] == "2030-02-20"


async def test_batch_ready_for_pickup_and_code_visible_to_owner(client: AsyncClient, customer: dict, admin: AdminFixture, pickup_point) -> None:  # type: ignore[no-untyped-def]
    ref, oid = await _purchased(client, customer, admin, pickup_point)
    await client.put("/admin/settings", json={"next_departure_date": "2030-01-15"}, headers=admin.headers)
    sid = (await client.get("/admin/shipments", headers=admin.headers)).json()[0]["id"]
    await client.post(f"/admin/shipments/{sid}/orders", json={"order_ids": [oid]}, headers=admin.headers)
    # Not arrived yet: refused.
    assert (await client.post(f"/admin/shipments/{sid}/ready-for-pickup", json={}, headers=admin.headers)).json()["detail"] == "shipment_not_arrived"
    await client.post(f"/admin/shipments/{sid}/depart", json={}, headers=admin.headers)
    await client.post(f"/admin/shipments/{sid}/arrive", headers=admin.headers)
    assert (await client.get(f"/orders/{ref}", headers=customer)).json()["pickup_code"] is None  # not ready yet

    r = await client.post(f"/admin/shipments/{sid}/ready-for-pickup", json={}, headers=admin.headers)
    assert r.status_code == 200 and r.json() == [{"order_id": oid, "ref": ref, "ok": True, "error": None}]
    code = [kw for n, kw in tasks.RECORDED if n == "send_customer_whatsapp"][-1]["params"][4]

    # The owner sees the same code that went out on WhatsApp; nobody else's order shows it.
    detail = (await client.get(f"/orders/{ref}", headers=customer)).json()
    assert detail["status"] == "READY_FOR_PICKUP" and detail["pickup_code"] == code
    # Running it again changes nothing (no order is ARRIVED any more).
    assert (await client.post(f"/admin/shipments/{sid}/ready-for-pickup", json={}, headers=admin.headers)).json() == []
    # The admin can resend the same code without issuing a new one.
    w = await client.post(f"/admin/orders/{oid}/whatsapp", json={"kind": "pickup"}, headers=admin.headers)
    assert w.status_code == 200 and code in w.json()["text"]

    # Once collected, the code disappears.
    assert (await client.post(f"/admin/orders/{oid}/pickup", json={"code": code}, headers=admin.headers)).status_code == 204
    assert (await client.get(f"/orders/{ref}", headers=customer)).json()["pickup_code"] is None
