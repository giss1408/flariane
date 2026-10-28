"""End-to-end: cart link → quote → accept → Wave → purchase → shipment → pickup."""

from httpx import AsyncClient

from app import tasks
from app.integrations import wave
from tests.conftest import AdminFixture, create_order, order_id, pay, quote_and_send


def recorded(name: str) -> list[dict]:
    return [kw for n, kw in tasks.RECORDED if n == name]


async def test_happy_path(client: AsyncClient, customer: dict, admin: AdminFixture, pickup_point) -> None:  # type: ignore[no-untyped-def]
    order = await create_order(client, customer, pickup_point)
    ref = order["public_ref"]
    assert order["status"] == "QUOTE_REQUESTED"
    assert order["source_cart_url"].startswith("https://onelink.shein.com/57/")
    assert recorded("push_admins")[-1]["event"] == "quote_requested"
    oid = await order_id(ref)

    # Admin inbox shows it.
    r = await client.get("/admin/orders?tab=to_quote", headers=admin.headers)
    assert [o["public_ref"] for o in r.json()] == [ref]

    # Draft: totals computed server-side; customer can't see a draft.
    r = await client.put(f"/admin/orders/{oid}/quote-draft", json={
        "items": [{"title": "Robe", "size": "M", "color": "Bleu", "qty": 1, "source_price": "10.00", "source_currency": "EUR"}],
        "freight_xof": 3000, "customs_xof": 1500, "fee_xof": 2500,
    }, headers=admin.headers)
    assert r.status_code == 200, r.text
    draft = r.json()
    assert draft["status"] == "DRAFT" and draft["items_xof"] == 6560 and draft["total_xof"] == 6560 + 3000 + 1500 + 2500
    r = await client.get(f"/orders/{ref}", headers=customer)
    assert r.json()["quote"] is None

    r = await client.post(f"/admin/orders/{oid}/quotes/1/send", json={}, headers=admin.headers)
    assert r.status_code == 200, r.text
    assert recorded("send_customer_whatsapp")[-1]["template"] == "quote_ready"

    r = await client.get(f"/orders/{ref}", headers=customer)
    detail = r.json()
    assert detail["status"] == "QUOTED" and detail["quote"]["version"] == 1 and detail["quote"]["total_xof"] == 13560

    # Accept requires the size confirmation.
    r = await client.post(f"/orders/{ref}/quotes/1/accept", json={"sizes_confirmed": False}, headers=customer)
    assert r.status_code == 400
    r = await client.post(f"/orders/{ref}/quotes/1/accept", json={"sizes_confirmed": True}, headers=customer)
    assert r.status_code == 200, r.text
    payment = r.json()
    assert payment["status"] == "PENDING" and payment["amount_xof"] == 13560
    session = next(iter(wave.FAKE_SESSIONS.values()))
    assert session["amount"] == "13560" and session["client_reference"] == ref and session["currency"] == "XOF"

    # Double tap returns the same checkout, no second session.
    r2 = await client.post(f"/orders/{ref}/quotes/1/accept", json={"sizes_confirmed": True}, headers=customer)
    assert r2.json()["launch_url"] == payment["launch_url"] and len(wave.FAKE_SESSIONS) == 1

    assert await pay(client, payment["launch_url"]) == 200
    r = await client.get(f"/orders/{ref}", headers=customer)
    assert r.json()["status"] == "PAID"
    assert recorded("send_customer_whatsapp")[-1]["template"] == "payment_received"

    # Purchase: checklist must cover every accepted line.
    r = await client.get(f"/admin/orders/{oid}", headers=admin.headers)
    item_id = r.json()["items"][0]["id"]
    r = await client.post(f"/admin/orders/{oid}/purchase", json={"store_order_ref": "GSH123", "paid_amount": "10.00", "currency": "EUR"}, headers=admin.headers)
    assert r.status_code == 400 and r.json()["detail"] == "checklist_incomplete"
    r = await client.post(f"/admin/orders/{oid}/purchase", json={
        "store_order_ref": "GSH123", "paid_amount": "10.00", "currency": "EUR", "checked_item_ids": [item_id],
    }, headers=admin.headers)
    assert r.status_code == 200, r.text
    assert r.json()["estimated_margin_xof"] == 2500

    # Shipment: created by setting the next departure, with its order deadline.
    r = await client.put("/admin/settings", json={"next_departure_date": "2030-01-15", "next_order_deadline": "2030-01-20"}, headers=admin.headers)
    assert r.status_code == 400 and r.json()["detail"] == "order_deadline_after_departure"
    r = await client.put("/admin/settings", json={"next_departure_date": "2030-01-15", "next_order_deadline": "2030-01-10"}, headers=admin.headers)
    assert r.status_code == 200, r.text
    assert (await client.get("/public/info")).json()["next_order_deadline"] == "2030-01-10"
    r = await client.get("/admin/shipments", headers=admin.headers)
    assert len(r.json()) == 1 and r.json()[0]["departure_date"] == "2030-01-15" and r.json()[0]["order_deadline"] == "2030-01-10"
    sid = r.json()[0]["id"]
    # Saving the same departure again doesn't create a second shipment.
    await client.put("/admin/settings", json={"next_departure_date": "2030-01-15"}, headers=admin.headers)
    assert len((await client.get("/admin/shipments", headers=admin.headers)).json()) == 1
    r = await client.post(f"/admin/shipments/{sid}/orders", json={"order_ids": [oid]}, headers=admin.headers)
    assert r.json()["order_refs"] == [ref] and r.json()["order_ids"] == [oid]
    # The order shows its shipment in the "À expédier" list and on its own screen.
    label = "Départ du 15/01/2030"
    r = await client.get("/admin/orders?tab=to_ship", headers=admin.headers)
    assert [(o["public_ref"], o["shipment_id"], o["shipment_label"]) for o in r.json()] == [(ref, sid, label)]
    r = await client.get(f"/admin/orders/{oid}", headers=admin.headers)
    assert r.json()["shipment_id"] == sid and r.json()["shipment_label"] == label
    r = await client.delete(f"/admin/shipments/{sid}/orders/{oid}", headers=admin.headers)
    assert r.status_code == 200 and r.json()["order_refs"] == []
    r = await client.get("/admin/orders?tab=to_ship", headers=admin.headers)
    assert [(o["shipment_id"], o["shipment_label"]) for o in r.json()] == [(None, None)]
    r = await client.get(f"/admin/orders/{oid}", headers=admin.headers)
    assert r.json()["shipment_id"] is None and r.json()["shipment_label"] is None
    await client.post(f"/admin/shipments/{sid}/orders", json={"order_ids": [oid]}, headers=admin.headers)
    r = await client.post(f"/admin/shipments/{sid}/depart", json={"tracking_ref": "AWB1", "weight_kg": "1.2"}, headers=admin.headers)
    assert r.json()["status"] == "IN_TRANSIT"
    r = await client.post(f"/admin/shipments/{sid}/arrive", headers=admin.headers)
    assert r.json()["status"] == "ARRIVED"

    # Pickup with the code sent on WhatsApp.
    r = await client.post(f"/admin/orders/{oid}/ready-for-pickup", json={}, headers=admin.headers)
    assert r.status_code == 200, r.text
    code = r.json()["code"]
    assert recorded("send_customer_whatsapp")[-1]["params"][4] == code
    wa = (await client.post(f"/admin/orders/{oid}/whatsapp", json={"kind": "pickup", "code": code}, headers=admin.headers)).json()
    assert wa["url"].startswith("https://wa.me/2250701020304?text=") and code in wa["text"]
    wa = (await client.post(f"/admin/orders/{oid}/whatsapp", json={"kind": "quote"}, headers=admin.headers)).json()
    assert "13 560 FCFA" in wa["text"]
    wrong = "000000" if code != "000000" else "111111"
    r = await client.post(f"/admin/orders/{oid}/pickup", json={"code": wrong}, headers=admin.headers)
    assert r.status_code == 400
    r = await client.post(f"/admin/orders/{oid}/pickup", json={"code": code}, headers=admin.headers)
    assert r.status_code == 204

    r = await client.get(f"/orders/{ref}", headers=customer)
    history = [h["to_status"] for h in r.json()["history"]]
    assert history == ["QUOTE_REQUESTED", "QUOTED", "AWAITING_PAYMENT", "PAID", "PURCHASED", "IN_TRANSIT", "ARRIVED", "READY_FOR_PICKUP", "PICKED_UP"]


async def test_change_request_creates_new_version(client: AsyncClient, customer: dict, admin: AdminFixture, pickup_point) -> None:  # type: ignore[no-untyped-def]
    ref = (await create_order(client, customer, pickup_point))["public_ref"]
    oid = await order_id(ref)
    await quote_and_send(client, admin, oid)
    detail = (await client.get(f"/orders/{ref}", headers=customer)).json()
    lines = detail["quote"]["lines"]

    r = await client.post(f"/orders/{ref}/quotes/1/change-request", json={
        "removed_item_ids": [lines[1]["order_item_id"]],
        "line_changes": [{"order_item_id": lines[0]["order_item_id"], "size": "L"}],
        "note": "Plutôt en L",
    }, headers=customer)
    assert r.status_code == 201, r.text
    assert tasks.RECORDED[-1] == ("push_admins", {"event": "change_requested", "order_ref": ref, "order_id": oid})

    admin_view = (await client.get(f"/admin/orders/{oid}", headers=admin.headers)).json()
    assert admin_view["status"] == "QUOTE_REQUESTED"
    assert admin_view["quotes"][0]["status"] == "CHANGE_REQUESTED"
    assert admin_view["change_requests"][0]["note"] == "Plutôt en L"
    inbox = (await client.get("/admin/orders?tab=to_quote", headers=admin.headers)).json()
    assert inbox[0]["has_change_request"] is True

    # Accepting the old version is refused.
    r = await client.post(f"/orders/{ref}/quotes/1/accept", json={"sizes_confirmed": True}, headers=customer)
    assert r.status_code == 409 and r.json()["detail"] == "quote_outdated"

    item = admin_view["items"][0]
    v2 = await quote_and_send(client, admin, oid, {
        "items": [{"id": item["id"], "title": item["title"], "size": "L", "color": item["color"], "qty": 1,
                   "source_price": "12.99", "source_currency": "EUR"}],
        "fee_xof": 3000,
    })
    assert v2["version"] == 2 and len(v2["lines"]) == 1 and v2["lines"][0]["size"] == "L"
    detail = (await client.get(f"/orders/{ref}", headers=customer)).json()
    assert detail["status"] == "QUOTED" and detail["quote"]["version"] == 2

    r = await client.post(f"/orders/{ref}/quotes/2/accept", json={"sizes_confirmed": True}, headers=customer)
    assert r.status_code == 200 and r.json()["amount_xof"] == v2["total_xof"]


async def test_resent_quote_supersedes_previous(client: AsyncClient, customer: dict, admin: AdminFixture, pickup_point) -> None:  # type: ignore[no-untyped-def]
    ref = (await create_order(client, customer, pickup_point))["public_ref"]
    oid = await order_id(ref)
    await quote_and_send(client, admin, oid)
    await quote_and_send(client, admin, oid, {**_draft_with_fee(4000)})
    view = (await client.get(f"/admin/orders/{oid}", headers=admin.headers)).json()
    assert [q["status"] for q in view["quotes"]] == ["SENT", "SUPERSEDED"]
    r = await client.post(f"/orders/{ref}/quotes/1/accept", json={"sizes_confirmed": True}, headers=customer)
    assert r.status_code == 409


def _draft_with_fee(fee: int) -> dict:
    from tests.conftest import DRAFT

    return {**DRAFT, "fee_xof": fee}


async def test_fee_below_minimum_needs_confirmation(client: AsyncClient, customer: dict, admin: AdminFixture, pickup_point) -> None:  # type: ignore[no-untyped-def]
    ref = (await create_order(client, customer, pickup_point))["public_ref"]
    oid = await order_id(ref)
    r = await client.put(f"/admin/orders/{oid}/quote-draft", json=_draft_with_fee(500), headers=admin.headers)
    assert r.json()["fee_below_minimum"] is True
    r = await client.post(f"/admin/orders/{oid}/quotes/1/send", json={}, headers=admin.headers)
    assert r.status_code == 409 and r.json()["detail"] == "fee_below_minimum"
    r = await client.post(f"/admin/orders/{oid}/quotes/1/send", json={"confirm_low_fee": True}, headers=admin.headers)
    assert r.status_code == 200


async def test_default_freight_and_customs(client: AsyncClient, customer: dict, admin: AdminFixture, pickup_point) -> None:  # type: ignore[no-untyped-def]
    ref = (await create_order(client, customer, pickup_point))["public_ref"]
    r = await client.put(f"/admin/orders/{await order_id(ref)}/quote-draft", json=_draft_with_fee(3000), headers=admin.headers)
    q = r.json()
    assert q["freight_xof"] == 3 * 3000  # 3 articles × default per item
    assert q["customs_xof"] == -(-q["items_xof"] * 20 // 100)  # 20 %, rounded up


async def test_expired_quote_cannot_be_accepted_and_can_be_requoted(client: AsyncClient, customer: dict, admin: AdminFixture, pickup_point) -> None:  # type: ignore[no-untyped-def]
    from sqlalchemy import update

    from app.db import SessionLocal
    from app.models import Quote
    from app.security.tokens import utcnow

    ref = (await create_order(client, customer, pickup_point))["public_ref"]
    oid = await order_id(ref)
    await quote_and_send(client, admin, oid)
    async with SessionLocal() as db:
        await db.execute(update(Quote).values(expires_at=utcnow()))
        await db.commit()
    r = await client.post(f"/orders/{ref}/quotes/1/accept", json={"sizes_confirmed": True}, headers=customer)
    assert r.status_code == 409 and r.json()["detail"] == "quote_expired"
    assert (await tasks.expire_quotes()) == 1
    detail = (await client.get(f"/orders/{ref}", headers=customer)).json()
    assert detail["can_request_requote"] is True
    r = await client.post(f"/orders/{ref}/requote", headers=customer)
    assert r.status_code == 201
    assert (await client.get(f"/orders/{ref}", headers=customer)).json()["status"] == "QUOTE_REQUESTED"


async def test_customer_cannot_see_other_orders(client: AsyncClient, customer: dict, pickup_point) -> None:  # type: ignore[no-untyped-def]
    from tests.conftest import login_customer

    ref = (await create_order(client, customer, pickup_point))["public_ref"]
    other = await login_customer(client, phone="0501020304", name="Moussa")
    assert (await client.get(f"/orders/{ref}", headers=other)).status_code == 404
    assert (await client.post(f"/orders/{ref}/cancel", headers=other)).status_code == 404


async def test_order_requires_shein_link(client: AsyncClient, customer: dict, pickup_point) -> None:  # type: ignore[no-untyped-def]
    r = await client.post("/orders", json={"share_text": "https://evil.com/cart", "pickup_point_id": pickup_point.id}, headers=customer)
    assert r.status_code == 400 and r.json()["detail"] == "no_shein_link"


async def test_same_cart_twice_returns_same_order(client: AsyncClient, customer: dict, pickup_point) -> None:  # type: ignore[no-untyped-def]
    a = await create_order(client, customer, pickup_point)
    b = await create_order(client, customer, pickup_point)
    assert a["public_ref"] == b["public_ref"]


async def test_cancel_rules(client: AsyncClient, customer: dict, admin: AdminFixture, pickup_point) -> None:  # type: ignore[no-untyped-def]
    ref = (await create_order(client, customer, pickup_point))["public_ref"]
    oid = await order_id(ref)
    await quote_and_send(client, admin, oid)
    r = await client.post(f"/orders/{ref}/quotes/1/accept", json={"sizes_confirmed": True}, headers=customer)
    launch = r.json()["launch_url"]
    # Pending Wave payment: cannot cancel or change.
    assert (await client.post(f"/orders/{ref}/cancel", headers=customer)).status_code == 409
    r = await client.post(f"/orders/{ref}/quotes/1/change-request", json={"note": "x"}, headers=customer)
    assert r.status_code == 409 and r.json()["detail"] == "payment_in_progress"
    # After a failed payment the customer may cancel.
    assert await pay(client, launch, outcome="failed") == 200
    assert (await client.post(f"/orders/{ref}/cancel", headers=customer)).status_code == 204


async def test_order_without_pickup_point(client: AsyncClient, customer: dict) -> None:
    from tests.conftest import CART_SHARE

    r = await client.post("/orders", json={"share_text": CART_SHARE}, headers=customer)
    assert r.status_code == 201 and r.json()["pickup_point"] is None


async def test_location_snapshot_and_dispatch(client: AsyncClient, customer: dict, admin: AdminFixture) -> None:
    from tests.conftest import CART_SHARE

    loc = {"commune": "Cocody", "quartier": "Riviera 3", "landmark": "Près de la pharmacie Les Oscars", "lat": 5.36, "lng": -3.95}
    r = await client.put("/me/location", json=loc, headers=customer)
    assert r.status_code == 200 and r.json()["location"]["maps_url"].endswith("5.36,-3.95")
    assert (await client.put("/me/location", json={**loc, "commune": "Paris"}, headers=customer)).status_code == 422
    assert (await client.put("/me/location", json={**loc, "lng": None}, headers=customer)).status_code == 400

    ref = (await client.post("/orders", json={"share_text": CART_SHARE}, headers=customer)).json()["public_ref"]
    oid = await order_id(ref)
    detail = (await client.get(f"/admin/orders/{oid}", headers=admin.headers)).json()
    assert detail["delivery_location"]["quartier"] == "Riviera 3"

    # Moving before the parcel arrives updates open orders.
    await client.put("/me/location", json={"commune": "Yopougon", "quartier": "Niangon"}, headers=customer)
    assert (await client.get(f"/orders/{ref}", headers=customer)).json()["delivery_location"]["commune"] == "Yopougon"

    groups = (await client.get("/admin/dispatch?statuses=QUOTE_REQUESTED", headers=admin.headers)).json()
    assert groups[0]["commune"] == "Yopougon" and groups[0]["orders"][0]["public_ref"] == ref


async def test_cart_mode_quote_with_screenshot(client: AsyncClient, customer: dict, admin: AdminFixture, pickup_point) -> None:  # type: ignore[no-untyped-def]
    import io

    from PIL import Image

    from tests.conftest import pay

    ref = (await create_order(client, customer, pickup_point))["public_ref"]
    oid = await order_id(ref)
    r = await client.put(f"/admin/orders/{oid}/quote-draft", json={"cart_price_xof": 32500}, headers=admin.headers)
    q = r.json()
    assert r.status_code == 200 and q["freight_xof"] == 5000 and q["total_xof"] == 37500 and q["lines"] == []
    # Can't send without the cart screenshot.
    r = await client.post(f"/admin/orders/{oid}/quotes/1/send", json={}, headers=admin.headers)
    assert r.status_code == 400 and r.json()["detail"] == "cart_quote_incomplete"
    buf = io.BytesIO()
    Image.new("RGB", (30, 30), "pink").save(buf, format="PNG")
    r = await client.post(f"/admin/orders/{oid}/quote-screenshot", files={"file": ("cart.png", buf.getvalue(), "image/png")}, headers=admin.headers)
    assert r.status_code == 200 and r.json()["screenshot_url"]
    assert (await client.post(f"/admin/orders/{oid}/quotes/1/send", json={}, headers=admin.headers)).status_code == 200

    detail = (await client.get(f"/orders/{ref}", headers=customer)).json()
    assert detail["quote"]["total_xof"] == 37500 and detail["quote"]["screenshot_url"]
    assert detail["attachments"] == 0  # the quote screenshot isn't one of her uploads

    p = (await client.post(f"/orders/{ref}/quotes/1/accept", json={"sizes_confirmed": True}, headers=customer)).json()
    assert await pay(client, p["launch_url"]) == 200
    r = await client.post(f"/admin/orders/{oid}/purchase", json={"store_order_ref": "GSH9", "paid_amount": "32500", "currency": "XOF"}, headers=admin.headers)
    assert r.status_code == 200 and r.json()["estimated_margin_xof"] == 0



async def test_temu_order(client: AsyncClient, customer: dict, admin: AdminFixture) -> None:
    r = await client.post("/orders", json={"share_text": "Mon panier https://share.temu.com/xyZ789"}, headers=customer)
    assert r.status_code == 201 and r.json()["store"] == "TEMU"
    detail = (await client.get(f"/admin/orders/{await order_id(r.json()['public_ref'])}", headers=admin.headers)).json()
    assert detail["store"] == "TEMU"


async def test_cart_price_in_euros(client: AsyncClient, customer: dict, admin: AdminFixture, pickup_point) -> None:  # type: ignore[no-untyped-def]
    ref = (await create_order(client, customer, pickup_point))["public_ref"]
    oid = await order_id(ref)
    q = (await client.put(f"/admin/orders/{oid}/quote-draft", json={"cart_price": "49.90", "cart_currency": "EUR"}, headers=admin.headers)).json()
    assert q["items_xof"] == 32733  # 49.90 x 655.957 = 32732.25 -> rounded up
    assert q["cart_source_amount"] == "49.90" and q["cart_source_currency"] == "EUR"
    assert q["total_xof"] == 32733 + 5000
    shein = (await client.get("/admin/orders?tab=to_quote&store=SHEIN", headers=admin.headers)).json()
    assert shein[0]["store"] == "SHEIN"
    assert (await client.get("/admin/orders?tab=to_quote&store=TEMU", headers=admin.headers)).json() == []


async def test_customer_never_sees_euros(client: AsyncClient, customer: dict, admin: AdminFixture, pickup_point) -> None:  # type: ignore[no-untyped-def]
    import io

    from PIL import Image

    ref = (await create_order(client, customer, pickup_point))["public_ref"]
    oid = await order_id(ref)
    await client.put(f"/admin/orders/{oid}/quote-draft", json={"cart_price": "49.90"}, headers=admin.headers)
    buf = io.BytesIO()
    Image.new("RGB", (20, 20), "red").save(buf, format="PNG")
    await client.post(f"/admin/orders/{oid}/quote-screenshot", files={"file": ("c.png", buf.getvalue(), "image/png")}, headers=admin.headers)
    await client.post(f"/admin/orders/{oid}/quotes/1/send", json={}, headers=admin.headers)
    quote = (await client.get(f"/orders/{ref}", headers=customer)).json()["quote"]
    assert quote["total_xof"] == 37733 and quote["cart_source_amount"] is None and quote["cart_source_currency"] is None


async def test_attention_counts(client: AsyncClient, customer: dict, admin: AdminFixture, pickup_point) -> None:  # type: ignore[no-untyped-def]
    await create_order(client, customer, pickup_point)
    a = (await client.get("/admin/orders/attention", headers=admin.headers)).json()
    assert a["to_quote"] == 1 and a["to_buy"] == 0 and a["registrations_to_verify"] == 0
