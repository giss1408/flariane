import time

from httpx import AsyncClient
from sqlalchemy import func, select

from app.db import SessionLocal
from app.models import Payment, WebhookEvent
from tests.conftest import AdminFixture, create_order, order_id, pay, quote_and_send, send_wave_event


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


async def test_bad_signature_rejected(client: AsyncClient, customer: dict, admin: AdminFixture, pickup_point) -> None:  # type: ignore[no-untyped-def]
    ref, _, payment = await _accepted(client, customer, admin, pickup_point)
    event = {"id": "EV_x", "type": "checkout.session.completed", "data": {"id": "whatever"}}
    assert await send_wave_event(client, event, secret="wrong") == 401
    assert await send_wave_event(client, event, timestamp=int(time.time()) - 3600) == 401
    assert await _status(client, ref, customer) == "AWAITING_PAYMENT"


async def test_duplicate_event_is_noop(client: AsyncClient, customer: dict, admin: AdminFixture, pickup_point) -> None:  # type: ignore[no-untyped-def]
    ref, _, payment = await _accepted(client, customer, admin, pickup_point)
    assert await pay(client, payment["launch_url"]) == 200
    assert await pay(client, payment["launch_url"]) == 200
    async with SessionLocal() as db:
        assert await db.scalar(select(func.count()).select_from(WebhookEvent)) == 1
    assert await _status(client, ref, customer) == "PAID"


async def test_amount_mismatch_holds_payment(client: AsyncClient, customer: dict, admin: AdminFixture, pickup_point) -> None:  # type: ignore[no-untyped-def]
    ref, _, payment = await _accepted(client, customer, admin, pickup_point)
    assert await pay(client, payment["launch_url"], amount="100") == 200
    assert await _payment_status() == "HELD"
    assert await _status(client, ref, customer) == "AWAITING_PAYMENT"
    held = (await client.get("/admin/payments/held", headers=admin.headers)).json()
    assert held[0]["reason"].startswith("amount_mismatch")


async def test_unknown_session_is_logged_not_failed(client: AsyncClient) -> None:
    event = {"id": "EV_unknown", "type": "checkout.session.completed", "data": {"id": "cos-nope", "payment_status": "succeeded"}}
    assert await send_wave_event(client, event) == 200


async def test_processing_error_rolls_back_dedupe(client: AsyncClient, customer: dict, admin: AdminFixture, pickup_point, monkeypatch) -> None:  # type: ignore[no-untyped-def]
    import pytest

    from app.routers import webhooks

    ref, _, payment = await _accepted(client, customer, admin, pickup_point)

    async def boom(*_a, **_k):  # type: ignore[no-untyped-def]
        raise RuntimeError("db down")

    monkeypatch.setattr(webhooks, "apply_wave_event", boom)
    with pytest.raises(RuntimeError):
        await pay(client, payment["launch_url"])
    async with SessionLocal() as db:
        assert await db.scalar(select(func.count()).select_from(WebhookEvent)) == 0
    monkeypatch.undo()
    # Wave retries the same event: processed normally.
    assert await pay(client, payment["launch_url"]) == 200
    assert await _status(client, ref, customer) == "PAID"


async def test_failed_payment_then_retry(client: AsyncClient, customer: dict, admin: AdminFixture, pickup_point) -> None:  # type: ignore[no-untyped-def]
    ref, _, payment = await _accepted(client, customer, admin, pickup_point)
    assert await pay(client, payment["launch_url"], outcome="failed") == 200
    assert await _payment_status() == "FAILED"
    r = await client.post(f"/orders/{ref}/payment", headers=customer)
    assert r.status_code == 200 and r.json()["launch_url"] != payment["launch_url"]
    assert await pay(client, r.json()["launch_url"]) == 200
    assert await _status(client, ref, customer) == "PAID"


async def test_success_for_cancelled_order_is_held(client: AsyncClient, customer: dict, admin: AdminFixture, pickup_point) -> None:  # type: ignore[no-untyped-def]
    ref, _, payment = await _accepted(client, customer, admin, pickup_point)
    await pay(client, payment["launch_url"], outcome="failed")
    assert (await client.post(f"/orders/{ref}/cancel", headers=customer)).status_code == 204
    # Late success for the same session (customer completed it after all).
    from app.integrations import wave

    session_id = payment["launch_url"].rsplit("/", 1)[-1]
    data = {**{k: v for k, v in wave.FAKE_SESSIONS[session_id].items() if not k.startswith("_")}, "payment_status": "succeeded"}
    assert await send_wave_event(client, {"id": "EV_late", "type": "checkout.session.completed", "data": data}) == 200
    assert await _payment_status() == "HELD"
    assert await _status(client, ref, customer) == "CANCELLED"


async def test_reconcile_catches_lost_webhook(client: AsyncClient, customer: dict, admin: AdminFixture, pickup_point) -> None:  # type: ignore[no-untyped-def]
    from sqlalchemy import update

    from app import tasks
    from app.integrations import wave
    from app.security.tokens import utcnow

    ref, _, payment = await _accepted(client, customer, admin, pickup_point)
    session_id = payment["launch_url"].rsplit("/", 1)[-1]
    wave.FAKE_SESSIONS[session_id].update(checkout_status="complete", payment_status="succeeded", transaction_id="T1")
    async with SessionLocal() as db:
        from datetime import timedelta

        await db.execute(update(Payment).values(created_at=utcnow() - timedelta(minutes=20)))
        await db.commit()
    assert await tasks.reconcile_payments() == {"checked": 1, "changed": 1}
    assert await _status(client, ref, customer) == "PAID"


# ---------------------------------------------------------------- operations


async def _paid(client: AsyncClient, customer: dict, admin: AdminFixture, point) -> tuple[str, int, list[int]]:  # type: ignore[no-untyped-def]
    ref, oid, payment = await _accepted(client, customer, admin, point)
    await pay(client, payment["launch_url"])
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
    sid = (await client.post("/admin/shipments", json={"label": "S"}, headers=admin.headers)).json()["id"]
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

    proof = await client.get(f"/admin/orders/{oid}/payment-proof", headers=admin.headers)
    assert proof.status_code == 200 and proof.headers["content-type"] == "image/jpeg"
    assert (await client.get(f"/admin/orders/{oid}/payment-proof", headers=customer)).status_code == 401

    assert (await client.post(f"/admin/orders/{oid}/confirm-payment", json={"transaction_ref": "OM123"}, headers=admin.headers)).status_code == 204
    assert (await client.get(f"/orders/{ref}", headers=customer)).json()["status"] == "PAID"
