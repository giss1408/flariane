from httpx import AsyncClient
from sqlalchemy import select

from app.db import SessionLocal
from app.models import Payment
from tests.conftest import AdminFixture, create_order, order_id, pay, quote_and_send


async def _accepted(client: AsyncClient, customer: dict, admin: AdminFixture, point) -> tuple[str, int, dict]:  # type: ignore[no-untyped-def]
    ref = (await create_order(client, customer, point))["public_ref"]
    oid = await order_id(ref)
    await quote_and_send(client, admin, oid)
    r = await client.post(f"/orders/{ref}/quotes/1/accept", json={"sizes_confirmed": True}, headers=customer)
    assert r.status_code == 200, r.text
    return ref, oid, r.json()


async def _status(client: AsyncClient, ref: str, customer: dict) -> str:
    return (await client.get(f"/orders/{ref}", headers=customer)).json()["status"]


async def _payment_status() -> str:
    async with SessionLocal() as db:
        return (await db.scalar(select(Payment.status).order_by(Payment.id.desc()).limit(1)))  # type: ignore[return-value]


# ---------------------------------------------------------------- operations


async def _paid(client: AsyncClient, customer: dict, admin: AdminFixture, point) -> tuple[str, int, list[int]]:  # type: ignore[no-untyped-def]
    ref, oid, payment = await _accepted(client, customer, admin, point)
    await pay(client, customer, admin, ref)
    view = (await client.get(f"/admin/orders/{oid}", headers=admin.headers)).json()
    return ref, oid, [i["id"] for i in view["items"]]


async def test_price_increase_needs_decision(client: AsyncClient, customer: dict, admin: AdminFixture, pickup_point) -> None:  # type: ignore[no-untyped-def]
    _, oid, items = await _paid(client, customer, admin, pickup_point)
    body = {"store_order_ref": "GSH1", "paid_amount": "40.00", "currency": "EUR", "checked_item_ids": items}
    r = await client.post(f"/admin/orders/{oid}/purchase", json=body, headers=admin.headers)
    assert r.status_code == 409 and r.json()["detail"] == "price_increase_decision_required"
    r = await client.post(f"/admin/orders/{oid}/purchase", json={**body, "price_increase_decision": "ABSORB"}, headers=admin.headers)
    assert r.status_code == 200 and r.json()["estimated_margin_xof"] < 3000


async def test_refused_item_creates_refund_and_completion(client: AsyncClient, customer: dict, admin: AdminFixture, pickup_point) -> None:  # type: ignore[no-untyped-def]
    ref, oid, items = await _paid(client, customer, admin, pickup_point)
    r = await client.post(f"/admin/orders/{oid}/purchase", json={
        "store_order_ref": "GSH2", "paid_amount": "12.99", "currency": "EUR",
        "checked_item_ids": [items[0]], "refused_item_ids": [items[1]],
    }, headers=admin.headers)
    assert r.status_code == 200, r.text
    assert r.json()["refund_xof"] == 2 * 5576
    refunds = (await client.get("/admin/refunds?status=PENDING", headers=admin.headers)).json()
    assert refunds[0]["amount_xof"] == 2 * 5576
    r = await client.post(f"/admin/refunds/{refunds[0]['id']}/complete", json={"external_ref": "WAVE-R-1"}, headers=admin.headers)
    assert r.status_code == 200 and r.json()["status"] == "COMPLETED"
    assert await _status(client, ref, customer) == "PURCHASED"  # partial refund: order continues


async def test_all_refused_refunds_everything(client: AsyncClient, customer: dict, admin: AdminFixture, pickup_point) -> None:  # type: ignore[no-untyped-def]
    ref, oid, items = await _paid(client, customer, admin, pickup_point)
    r = await client.post(f"/admin/orders/{oid}/purchase", json={
        "store_order_ref": "none", "paid_amount": "0", "currency": "EUR", "refused_item_ids": items,
    }, headers=admin.headers)
    assert r.status_code == 200 and r.json()["status"] == "REFUND_PENDING"
    refund = (await client.get("/admin/refunds", headers=admin.headers)).json()[0]
    await client.post(f"/admin/refunds/{refund['id']}/complete", json={"external_ref": "WAVE-R-2"}, headers=admin.headers)
    assert await _status(client, ref, customer) == "REFUNDED"
    assert await _payment_status() == "REFUNDED"


async def test_cancel_last_item_after_purchase(client: AsyncClient, customer: dict, admin: AdminFixture, pickup_point) -> None:  # type: ignore[no-untyped-def]
    ref, oid, items = await _paid(client, customer, admin, pickup_point)
    await client.post(f"/admin/orders/{oid}/purchase", json={
        "store_order_ref": "GSH3", "paid_amount": "29.99", "currency": "EUR", "checked_item_ids": items}, headers=admin.headers)
    r1 = await client.post(f"/admin/orders/{oid}/items/{items[0]}/cancel-by-store", json={}, headers=admin.headers)
    assert r1.status_code == 200 and r1.json()["amount_xof"] == 8521
    r2 = await client.post(f"/admin/orders/{oid}/items/{items[1]}/cancel-by-store", json={}, headers=admin.headers)
    assert r2.status_code == 200
    payment_total = (await client.get(f"/orders/{ref}", headers=customer)).json()["payment"]["amount_xof"]
    assert r1.json()["amount_xof"] + r2.json()["amount_xof"] == payment_total
    assert await _status(client, ref, customer) == "REFUND_PENDING"


async def test_pickup_code_locks_after_five_failures(client: AsyncClient, customer: dict, admin: AdminFixture, pickup_point) -> None:  # type: ignore[no-untyped-def]
    from app import tasks

    _, oid, items = await _paid(client, customer, admin, pickup_point)
    await client.post(f"/admin/orders/{oid}/purchase", json={"store_order_ref": "GSH4", "paid_amount": "29.99", "currency": "EUR", "checked_item_ids": items}, headers=admin.headers)
    await client.put("/admin/settings", json={"next_departure_date": "2030-01-15"}, headers=admin.headers)
    sid = (await client.get("/admin/shipments", headers=admin.headers)).json()[0]["id"]
    await client.post(f"/admin/shipments/{sid}/orders", json={"order_ids": [oid]}, headers=admin.headers)
    await client.post(f"/admin/shipments/{sid}/depart", json={}, headers=admin.headers)
    await client.post(f"/admin/shipments/{sid}/arrive", headers=admin.headers)
    await client.post(f"/admin/orders/{oid}/ready-for-pickup", json={}, headers=admin.headers)
    code = tasks.RECORDED[-1][1]["params"][4]
    wrong = "000000" if code != "000000" else "111111"
    for _ in range(5):
        assert (await client.post(f"/admin/orders/{oid}/pickup", json={"code": wrong}, headers=admin.headers)).status_code == 400
    assert (await client.post(f"/admin/orders/{oid}/pickup", json={"code": code}, headers=admin.headers)).status_code == 429
    # Re-issuing a code unlocks with a new one.
    await client.post(f"/admin/orders/{oid}/ready-for-pickup", json={}, headers=admin.headers)
    new_code = tasks.RECORDED[-1][1]["params"][4]
    assert (await client.post(f"/admin/orders/{oid}/pickup", json={"code": new_code}, headers=admin.headers)).status_code == 204


async def test_reports_and_csv(client: AsyncClient, customer: dict, admin: AdminFixture, pickup_point) -> None:  # type: ignore[no-untyped-def]
    await _paid(client, customer, admin, pickup_point)
    s = (await client.get("/admin/reports/summary", headers=admin.headers)).json()
    assert s["paid_orders"] == 1 and s["fees_xof"] == 3000 and s["revenue_xof"] > 0
    r = await client.get("/admin/reports/orders.csv", headers=admin.headers)
    assert r.status_code == 200 and "reference;date;client" in r.text and "Awa Koné" in r.text


async def test_next_departure_date(client: AsyncClient, admin: AdminFixture) -> None:
    assert (await client.get("/public/info")).json()["next_departure_date"] is None
    r = await client.put("/admin/settings", json={"next_departure_date": "2026-12-15"}, headers=admin.headers)
    assert r.status_code == 200, r.text
    assert (await client.get("/public/info")).json()["next_departure_date"] == "2026-12-15"


async def test_whatsapp_test_endpoint(client: AsyncClient, admin: AdminFixture) -> None:
    from app.integrations import whatsapp

    r = await client.post("/admin/whatsapp/test", json={"phone": "0701020304"}, headers=admin.headers)
    assert r.status_code == 200 and r.json()["mode"] == "log" and r.json()["sent"] is False
    assert whatsapp.SENT_LOG[-1]["template"] == "hello_world" and whatsapp.SENT_LOG[-1]["lang"] == "en_US"


async def test_manual_mobile_money_payment(client: AsyncClient, customer: dict, admin: AdminFixture, pickup_point) -> None:  # type: ignore[no-untyped-def]
    import io

    from PIL import Image

    from app import tasks

    await client.put("/admin/settings", json={"payment_mode": "manual", "payment_accounts": {"WAVE": "0700000000", "ORANGE": "0707070707", "MOOV": None}}, headers=admin.headers)
    info = (await client.get("/public/info")).json()
    assert info["payment_mode"] == "manual" and info["payment_accounts"] == {"WAVE": "0700000000", "ORANGE": "0707070707"}

    ref = (await create_order(client, customer, pickup_point))["public_ref"]
    oid = await order_id(ref)
    await quote_and_send(client, admin, oid)
    p = (await client.post(f"/orders/{ref}/quotes/1/accept", json={"sizes_confirmed": True}, headers=customer)).json()
    assert p["provider"] == "MANUAL" and p["status"] == "PENDING" and p["launch_url"] is None

    buf = io.BytesIO()
    Image.new("RGB", (40, 60), "orange").save(buf, format="JPEG")
    r = await client.post(f"/orders/{ref}/payment/declare", data={"method": "ORANGE"}, files={"file": ("pay.jpg", buf.getvalue(), "image/jpeg")}, headers=customer)
    assert r.status_code == 200, r.text
    assert r.json()["declared"] and r.json()["method"] == "ORANGE" and r.json()["has_proof"]
    assert tasks.RECORDED[-1][1]["event"] == "payment_declared"

    # Until an admin confirms it, the declared payment waits in the "to confirm" list.
    assert (await client.get("/admin/orders/attention", headers=admin.headers)).json()["payments_to_confirm"] == 1
    waiting = (await client.get("/admin/orders?tab=to_confirm", headers=admin.headers)).json()
    assert [o["public_ref"] for o in waiting] == [ref]

    proof = await client.get(f"/admin/orders/{oid}/payment-proof", headers=admin.headers)
    assert proof.status_code == 200 and proof.headers["content-type"] == "image/jpeg"
    assert (await client.get(f"/admin/orders/{oid}/payment-proof", headers=customer)).status_code == 401

    assert (await client.post(f"/admin/orders/{oid}/confirm-payment", json={"transaction_ref": "OM123"}, headers=admin.headers)).status_code == 204
    assert (await client.get(f"/orders/{ref}", headers=customer)).json()["status"] == "PAID"
    assert (await client.get("/admin/orders/attention", headers=admin.headers)).json()["payments_to_confirm"] == 0
    assert (await client.get("/admin/orders?tab=to_confirm", headers=admin.headers)).json() == []


async def test_pickup_agent_role(client: AsyncClient, customer: dict, admin: AdminFixture, pickup_point) -> None:  # type: ignore[no-untyped-def]
    from tests.conftest import make_admin

    agent = await make_admin(role="PICKUP", email="desk@flariane.ci")
    _, oid, items = await _paid(client, customer, admin, pickup_point)
    await client.post(f"/admin/orders/{oid}/purchase", json={"store_order_ref": "GSH7", "paid_amount": "29.99", "currency": "EUR", "checked_item_ids": items}, headers=admin.headers)
    await client.put("/admin/settings", json={"next_departure_date": "2030-01-15"}, headers=admin.headers)
    sid = (await client.get("/admin/shipments", headers=admin.headers)).json()[0]["id"]
    await client.post(f"/admin/shipments/{sid}/orders", json={"order_ids": [oid]}, headers=admin.headers)
    await client.post(f"/admin/shipments/{sid}/depart", json={}, headers=admin.headers)
    await client.post(f"/admin/shipments/{sid}/arrive", headers=admin.headers)

    # Desk sees arrived parcels; search by phone (any format) or by reference.
    assert [o["id"] for o in (await client.get("/admin/orders/pickup-desk", headers=agent.headers)).json()] == [oid]
    by_phone = (await client.get("/admin/orders/pickup-desk", params={"q": "07 01 02 03 04"}, headers=agent.headers)).json()
    assert by_phone[0]["id"] == oid and by_phone[0]["customer_phone_masked"] == "+225 07 •• •• 04"
    ref = by_phone[0]["public_ref"]
    assert (await client.get("/admin/orders/pickup-desk", params={"q": ref[-4:]}, headers=agent.headers)).json()[0]["id"] == oid

    # Pickup actions allowed.
    assert (await client.get("/admin/pickup-points", headers=agent.headers)).status_code == 200
    code = (await client.post(f"/admin/orders/{oid}/ready-for-pickup", json={}, headers=agent.headers)).json()["code"]
    assert (await client.post(f"/admin/orders/{oid}/whatsapp", json={"kind": "pickup", "code": code}, headers=agent.headers)).status_code == 200
    assert (await client.post(f"/admin/orders/{oid}/reveal-phone", headers=agent.headers)).status_code == 200
    assert (await client.post(f"/admin/orders/{oid}/pickup", json={"code": code}, headers=agent.headers)).status_code == 204

    # Everything else refused.
    for method, url in [("get", "/admin/orders"), ("get", f"/admin/orders/{oid}"), ("get", "/admin/settings"),
                        ("get", "/admin/shipments"), ("get", "/admin/reports/summary"), ("get", f"/admin/orders/{oid}/payment-proof")]:
        assert (await getattr(client, method)(url, headers=agent.headers)).status_code == 403, url
    assert (await client.post(f"/admin/orders/{oid}/whatsapp", json={"kind": "quote"}, headers=agent.headers)).status_code == 403


async def test_unpaid_orders_cancelled_after_deadline(client: AsyncClient, customer: dict, admin: AdminFixture, pickup_point) -> None:  # type: ignore[no-untyped-def]
    from datetime import timedelta

    from sqlalchemy import update

    from app import tasks
    from app.models import Quote
    from app.security.tokens import utcnow

    ref = (await create_order(client, customer, pickup_point))["public_ref"]
    oid = await order_id(ref)
    await quote_and_send(client, admin, oid)
    detail = (await client.get(f"/orders/{ref}", headers=customer)).json()
    assert detail["payment_deadline"] is not None
    assert await tasks.cancel_unpaid_orders() == 0  # not yet
    async with SessionLocal() as db:
        await db.execute(update(Quote).values(sent_at=utcnow() - timedelta(days=4)))
        await db.commit()
    assert await tasks.cancel_unpaid_orders() == 1
    assert (await client.get(f"/orders/{ref}", headers=customer)).json()["status"] == "CANCELLED"


async def test_archive_delivered_order(client: AsyncClient, customer: dict, admin: AdminFixture, pickup_point) -> None:  # type: ignore[no-untyped-def]
    ref = (await create_order(client, customer, pickup_point))["public_ref"]
    oid = await order_id(ref)
    assert (await client.post(f"/admin/orders/{oid}/archive", headers=admin.headers)).status_code == 409
    await client.post(f"/orders/{ref}/cancel", headers=customer)
    assert len((await client.get("/admin/orders?tab=done", headers=admin.headers)).json()) == 1
    assert (await client.post(f"/admin/orders/{oid}/archive", headers=admin.headers)).status_code == 204
    assert (await client.get("/admin/orders?tab=done", headers=admin.headers)).json() == []


async def test_delete_wrong_link_only_before_quote(client: AsyncClient, customer: dict, admin: AdminFixture, pickup_point) -> None:  # type: ignore[no-untyped-def]
    from app.models import Order

    ref = (await create_order(client, customer, pickup_point))["public_ref"]
    oid = await order_id(ref)
    r = await client.delete(f"/admin/orders/{oid}", params={"reason": "wrong_link"}, headers=admin.headers)
    assert r.status_code == 200, r.text
    assert ref in r.json()["text"] and r.json()["url"].startswith("https://wa.me/")
    async with SessionLocal() as db:
        assert await db.get(Order, oid) is None

    _, oid2, _ = await _accepted(client, customer, admin, pickup_point)
    r = await client.delete(f"/admin/orders/{oid2}", params={"reason": "wrong_link"}, headers=admin.headers)
    assert r.status_code == 409 and r.json()["detail"] == "order_already_quoted"


async def test_delete_unpaid_after_three_days(client: AsyncClient, customer: dict, admin: AdminFixture, pickup_point) -> None:  # type: ignore[no-untyped-def]
    from datetime import timedelta

    from app.models import Order

    ref, oid, payment = await _accepted(client, customer, admin, pickup_point)
    r = await client.delete(f"/admin/orders/{oid}", params={"reason": "unpaid"}, headers=admin.headers)
    assert r.status_code == 409 and r.json()["detail"] == "order_too_recent"
    async with SessionLocal() as db:
        order = await db.get(Order, oid)
        order.created_at -= timedelta(days=4)  # type: ignore[union-attr]
        await db.commit()
    # An open Wave checkout may still be paid: blocked until the deadline task expires it.
    r = await client.delete(f"/admin/orders/{oid}", params={"reason": "unpaid"}, headers=admin.headers)
    assert r.status_code == 409 and r.json()["detail"] == "order_paid"
    async with SessionLocal() as db:
        for p in (await db.scalars(select(Payment).where(Payment.order_id == oid))).all():
            p.status = "EXPIRED"
        await db.commit()
    r = await client.delete(f"/admin/orders/{oid}", params={"reason": "unpaid"}, headers=admin.headers)
    assert r.status_code == 200, r.text
    assert (await client.get(f"/orders/{ref}", headers=customer)).status_code == 404

    ref, oid, payment = await _accepted(client, customer, admin, pickup_point)
    assert await pay(client, customer, admin, ref) == 200
    async with SessionLocal() as db:
        order = await db.get(Order, oid)
        order.created_at -= timedelta(days=4)  # type: ignore[union-attr]
        await db.commit()
    r = await client.delete(f"/admin/orders/{oid}", params={"reason": "unpaid"}, headers=admin.headers)
    assert r.status_code == 409 and r.json()["detail"] == "order_paid"


async def test_super_admin_starts_full_refund_on_paid_order(client: AsyncClient, customer: dict, admin: AdminFixture, pickup_point) -> None:  # type: ignore[no-untyped-def]
    ref, oid, _ = await _paid(client, customer, admin, pickup_point)
    r = await client.post(f"/admin/orders/{oid}/refund", json={"reason": "Cliente a annulé"}, headers=admin.headers)
    assert r.status_code == 200, r.text
    assert r.json()["status"] == "PENDING" and r.json()["reason"] == "Cliente a annulé"
    amount = r.json()["amount_xof"]
    assert amount > 0
    assert await _status(client, ref, customer) == "REFUND_PENDING"  # the whole payment goes back: order is over
    listed = (await client.get("/admin/refunds?status=PENDING", headers=admin.headers)).json()
    assert listed[0]["order_ref"] == ref and listed[0]["method"] is None and listed[0]["has_proof"] is False
    r = await client.post(f"/admin/refunds/{listed[0]['id']}/complete", json={"external_ref": "WAVE-R-9"}, headers=admin.headers)
    assert r.status_code == 200
    assert await _status(client, ref, customer) == "REFUNDED"
    assert await _payment_status() == "REFUNDED"


async def test_partial_refund_keeps_the_order_running(client: AsyncClient, customer: dict, admin: AdminFixture, pickup_point) -> None:  # type: ignore[no-untyped-def]
    ref, oid, _ = await _paid(client, customer, admin, pickup_point)
    before = await _status(client, ref, customer)
    r = await client.post(f"/admin/orders/{oid}/refund", json={"amount_xof": 1000, "reason": "Geste commercial"}, headers=admin.headers)
    assert r.status_code == 200 and r.json()["amount_xof"] == 1000
    assert await _status(client, ref, customer) == before
    # What is left can still be refunded once, but never more than was paid.
    too_much = await client.post(f"/admin/orders/{oid}/refund", json={"amount_xof": 10**9, "reason": "Trop"}, headers=admin.headers)
    assert too_much.status_code == 409 and too_much.json()["detail"] == "refund_exceeds_payment"
    rest = await client.post(f"/admin/orders/{oid}/refund", json={"reason": "Le reste"}, headers=admin.headers)
    assert rest.status_code == 200 and rest.json()["amount_xof"] > 0
    assert await _status(client, ref, customer) == "REFUND_PENDING"


async def test_only_super_admin_starts_a_refund(client: AsyncClient, customer: dict, admin: AdminFixture, pickup_point) -> None:  # type: ignore[no-untyped-def]
    from tests.conftest import make_admin

    _, oid, _ = await _paid(client, customer, admin, pickup_point)
    operator = await make_admin(role="OPERATOR", email="op@flariane.ci")
    r = await client.post(f"/admin/orders/{oid}/refund", json={"reason": "Test"}, headers=operator.headers)
    assert r.status_code == 403


async def test_unpaid_order_cannot_be_refunded(client: AsyncClient, customer: dict, admin: AdminFixture, pickup_point) -> None:  # type: ignore[no-untyped-def]
    _, oid, _ = await _accepted(client, customer, admin, pickup_point)  # accepted, not paid
    r = await client.post(f"/admin/orders/{oid}/refund", json={"reason": "Test"}, headers=admin.headers)
    assert r.status_code == 409
    assert (await client.post(f"/admin/orders/{oid}/refund", json={"reason": "x"}, headers=admin.headers)).status_code == 422  # reason too short


async def test_delete_order_with_payment_problem(client: AsyncClient, customer: dict, admin: AdminFixture, pickup_point) -> None:  # type: ignore[no-untyped-def]
    import io

    from PIL import Image

    ref, oid, _ = await _accepted(client, customer, admin, pickup_point)
    buf = io.BytesIO()
    Image.new("RGB", (40, 60), "gray").save(buf, format="JPEG")
    r = await client.post(f"/orders/{ref}/payment/declare", data={"method": "WAVE"}, files={"file": ("pay.jpg", buf.getvalue(), "image/jpeg")}, headers=customer)
    assert r.status_code == 200, r.text
    # A declared but unconfirmed payment blocks the ordinary rules, not the payment-problem one, and it is immediate.
    assert (await client.delete(f"/admin/orders/{oid}", params={"reason": "unpaid"}, headers=admin.headers)).status_code == 409
    r = await client.delete(f"/admin/orders/{oid}", params={"reason": "payment_problem"}, headers=admin.headers)
    assert r.status_code == 200, r.text
    assert (await client.get(f"/orders/{ref}", headers=customer)).status_code == 404


async def test_payment_problem_delete_refused_once_paid(client: AsyncClient, customer: dict, admin: AdminFixture, pickup_point) -> None:  # type: ignore[no-untyped-def]
    ref, oid, _ = await _paid(client, customer, admin, pickup_point)
    r = await client.delete(f"/admin/orders/{oid}", params={"reason": "payment_problem"}, headers=admin.headers)
    assert r.status_code == 409
