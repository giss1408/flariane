"""Loyalty program: referral codes, points on collection, redemption on a quote."""

from urllib.parse import unquote

from httpx import AsyncClient
from sqlalchemy import func, select

from app.db import SessionLocal
from app.enums import OrderStatus
from app.models import LoyaltyLedger, Order, Quote
from app.services import loyalty
from app.services.orders import lock_order, transition_order
from tests.conftest import AdminFixture, create_order, login_customer, order_id, pay, quote_and_send

FRIEND_PHONE = "+49 176 55555555"


async def points(client: AsyncClient, headers: dict) -> dict:
    r = await client.get("/me/loyalty", headers=headers)
    assert r.status_code == 200, r.text
    return r.json()


async def collect(oid: int) -> None:
    """Take the order to PICKED_UP through the real transition (the points hook lives there)."""
    async with SessionLocal() as db:
        order = await lock_order(db, id=oid)
        order.status = OrderStatus.READY_FOR_PICKUP
        await transition_order(db, order, OrderStatus.PICKED_UP, actor="test")
        await db.commit()


async def grant(customer_id: int, pts: int) -> None:
    async with SessionLocal() as db:
        db.add(LoyaltyLedger(customer_id=customer_id, points=pts, kind="ORDER", order_id=None))
        await db.commit()


async def customer_id(client: AsyncClient, headers: dict) -> int:
    return (await client.get("/me", headers=headers)).json()["id"]


async def test_new_customer_gets_a_referral_code(client: AsyncClient, customer: dict) -> None:
    info = await points(client, customer)
    assert info["balance"] == 0 and info["history"] == []
    code = info["referral_code"]
    assert len(code) == 8 and code[3] == "-" and not set(code) & set("01OI")
    assert info["redeem_points"] == 100 and info["discount_percent"] == 10


async def test_invalid_referral_code_rejected(client: AsyncClient) -> None:
    r = await client.post("/auth/register", json={"phone": FRIEND_PHONE, "password": "bonjour-2026", "consent": True, "referral_code": "NOPE-1234"})
    assert r.status_code == 400 and r.json()["detail"] == "referral_code_invalid"


async def test_signup_point_credited_once_at_phone_verification(client: AsyncClient, customer: dict, admin: AdminFixture) -> None:
    code = (await points(client, customer))["referral_code"]
    r = await client.post("/auth/register", json={"phone": "0507080910", "password": "bonjour-2026", "display_name": "Aya", "consent": True, "referral_code": code.lower()})
    assert r.status_code == 201, r.text
    friend = {"Authorization": f"Bearer {r.json()['access_token']}"}
    assert (await points(client, customer))["balance"] == 0  # nothing until the number is verified

    fid = (await client.get("/admin/customers/unverified", headers=admin.headers)).json()[0]["id"]
    url = (await client.post(f"/admin/customers/{fid}/verification-code", headers=admin.headers)).json()["url"]
    otp = unquote(url).split("*")[1]
    assert (await client.post("/me/verify-phone", json={"code": otp}, headers=friend)).status_code == 200
    assert (await client.post("/me/verify-phone", json={"code": otp}, headers=friend)).status_code == 200  # replay

    info = await points(client, customer)
    assert info["balance"] == 1
    assert info["history"][0]["kind"] == "REFERRAL_SIGNUP" and info["history"][0]["friend_name"] == "Aya"
    assert "phone" not in str(info["history"][0])


async def test_pickup_credits_customer_and_referrer_first_order_only(client: AsyncClient, customer: dict, pickup_point) -> None:
    code = (await points(client, customer))["referral_code"]
    friend = await login_customer(client, FRIEND_PHONE, "Aya")
    # login_customer registers without a code: link her to the referrer directly.
    async with SessionLocal() as db:
        from app.models import Customer
        referrer = (await db.scalar(select(Customer).where(Customer.referral_code == code)))
        fr = await db.get(Customer, await customer_id(client, friend))
        fr.referred_by_id = referrer.id
        await db.commit()

    refs = []
    for n in range(2):
        r = await client.post("/orders", json={"share_text": f"https://onelink.shein.com/57/cart{n}abc", "pickup_point_id": pickup_point.id}, headers=friend)
        assert r.status_code == 201, r.text
        refs.append(r.json()["public_ref"])
    oids = [await order_id(r) for r in refs]
    await collect(oids[0])
    assert (await points(client, friend))["balance"] == 5
    assert (await points(client, customer))["balance"] == 3
    assert (await client.get(f"/orders/{refs[0]}", headers=friend)).json()["loyalty_points_earned"] == 5

    await collect(oids[1])
    assert (await points(client, friend))["balance"] == 10
    assert (await points(client, customer))["balance"] == 3  # referrer: first collected order only

    # A replay credits nothing.
    async with SessionLocal() as db:
        order = await db.get(Order, oids[0])
        await loyalty.credit_pickup(db, order)
        await db.commit()
    assert (await points(client, friend))["balance"] == 10


async def accept_with_points(client: AsyncClient, customer: dict, admin: AdminFixture, pickup_point, draft: dict | None = None):
    ref = (await create_order(client, customer, pickup_point))["public_ref"]
    oid = await order_id(ref)
    await quote_and_send(client, admin, oid, draft)
    return ref, oid


async def test_redeem_discounts_fee_and_payment(client: AsyncClient, customer: dict, admin: AdminFixture, pickup_point) -> None:
    cid = await customer_id(client, customer)
    await grant(cid, 100)
    ref, oid = await accept_with_points(client, customer, admin, pickup_point)  # fee 3000 → discount 300
    quote = (await client.get(f"/orders/{ref}", headers=customer)).json()["quote"]
    total = quote["total_xof"]
    assert quote["loyalty_discount_xof"] == 0 and quote["amount_to_pay_xof"] == total

    r = await client.post(f"/orders/{ref}/quotes/1/accept", json={"sizes_confirmed": True, "use_points": True}, headers=customer)
    assert r.status_code == 200, r.text
    assert r.json()["amount_xof"] == total - 300
    # Double tap: same payment, no second redemption.
    r = await client.post(f"/orders/{ref}/quotes/1/accept", json={"sizes_confirmed": True, "use_points": True}, headers=customer)
    assert r.json()["amount_xof"] == total - 300
    assert (await points(client, customer))["balance"] == 0
    detail = (await client.get(f"/orders/{ref}", headers=customer)).json()
    assert detail["quote"]["loyalty_points_used"] == 100 and detail["quote"]["amount_to_pay_xof"] == total - 300
    admin_q = (await client.get(f"/admin/orders/{oid}", headers=admin.headers)).json()["quotes"][0]
    assert admin_q["loyalty_discount_xof"] == 300 and admin_q["total_xof"] == total

    # After payment the points are spent for good.
    assert await pay(client, customer, admin, ref) == 200
    assert (await points(client, customer))["balance"] == 0


async def test_redeem_needs_enough_points(client: AsyncClient, customer: dict, admin: AdminFixture, pickup_point) -> None:
    await grant(await customer_id(client, customer), 99)
    ref, _ = await accept_with_points(client, customer, admin, pickup_point)
    r = await client.post(f"/orders/{ref}/quotes/1/accept", json={"sizes_confirmed": True, "use_points": True}, headers=customer)
    assert r.status_code == 400 and r.json()["detail"] == "loyalty_not_available"
    # The failed attempt left the quote acceptable without points.
    r = await client.post(f"/orders/{ref}/quotes/1/accept", json={"sizes_confirmed": True}, headers=customer)
    assert r.status_code == 200


async def test_discount_rounds_down(client: AsyncClient, customer: dict, admin: AdminFixture, pickup_point) -> None:
    await grant(await customer_id(client, customer), 100)
    ref, _ = await accept_with_points(client, customer, admin, pickup_point, {**__import__("tests.conftest", fromlist=["DRAFT"]).DRAFT, "fee_xof": 2555})
    r = await client.post(f"/orders/{ref}/quotes/1/accept", json={"sizes_confirmed": True, "use_points": True}, headers=customer)
    quote = (await client.get(f"/orders/{ref}", headers=customer)).json()["quote"]
    assert quote["loyalty_discount_xof"] == 255 and r.json()["amount_xof"] == quote["total_xof"] - 255


async def test_points_returned_on_change_request_and_can_be_redeemed_again(client: AsyncClient, customer: dict, admin: AdminFixture, pickup_point) -> None:
    await grant(await customer_id(client, customer), 100)
    ref, oid = await accept_with_points(client, customer, admin, pickup_point)
    await client.post(f"/orders/{ref}/quotes/1/accept", json={"sizes_confirmed": True, "use_points": True}, headers=customer)
    assert (await points(client, customer))["balance"] == 0
    async with SessionLocal() as db:  # a change request needs the payment attempt to be over (failed/expired)
        from app.models import Payment
        for p in (await db.scalars(select(Payment).where(Payment.order_id == oid))).all():
            p.status = "EXPIRED"
        await db.commit()

    r = await client.post(f"/orders/{ref}/quotes/1/change-request", json={"note": "autre taille"}, headers=customer)
    assert r.status_code == 201, r.text
    assert (await points(client, customer))["balance"] == 100
    async with SessionLocal() as db:
        q = await db.scalar(select(Quote).where(Quote.order_id == oid, Quote.version == 1))
        assert q.loyalty_points_used == 0 and q.loyalty_discount_xof == 0

    await quote_and_send(client, admin, oid)
    r = await client.post(f"/orders/{ref}/quotes/2/accept", json={"sizes_confirmed": True, "use_points": True}, headers=customer)
    assert r.status_code == 200 and (await points(client, customer))["balance"] == 0


async def test_points_returned_on_cancellation_before_payment(client: AsyncClient, customer: dict, admin: AdminFixture, pickup_point) -> None:
    await grant(await customer_id(client, customer), 100)
    ref, oid = await accept_with_points(client, customer, admin, pickup_point)
    await client.post(f"/orders/{ref}/quotes/1/accept", json={"sizes_confirmed": True, "use_points": True}, headers=customer)
    async with SessionLocal() as db:  # the automatic unpaid-deadline cancellation goes through the same transition
        order = await lock_order(db, id=oid)
        await transition_order(db, order, OrderStatus.CANCELLED, actor="system:unpaid_deadline")
        await db.commit()
    assert (await points(client, customer))["balance"] == 100
    async with SessionLocal() as db:
        n = await db.scalar(select(func.count()).select_from(LoyaltyLedger).where(LoyaltyLedger.kind == "RELEASE"))
        assert n == 1


async def test_changed_settings_apply_to_later_events(client: AsyncClient, customer: dict, admin: AdminFixture, pickup_point) -> None:
    r = await client.put("/admin/settings", json={"loyalty_points_per_order": 7}, headers=admin.headers)
    assert r.status_code == 200 and r.json()["loyalty_points_per_order"] == 7
    ref = (await create_order(client, customer, pickup_point))["public_ref"]
    await collect(await order_id(ref))
    assert (await points(client, customer))["balance"] == 7


async def test_migration_style_codes_are_unique(client: AsyncClient) -> None:
    codes = set()
    for i in range(5):
        r = await client.post("/auth/register", json={"phone": f"+49 176 1000000{i}", "password": "bonjour-2026", "display_name": "Awa", "consent": True})
        h = {"Authorization": f"Bearer {r.json()['access_token']}"}
        codes.add((await points(client, h))["referral_code"])
    assert len(codes) == 5 and all(c.startswith("AWA-") for c in codes)
