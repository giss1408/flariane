from httpx import AsyncClient
from sqlalchemy import update

from app.db import SessionLocal
from app.models import Order, PickupPoint
from tests.conftest import PASSWORD, PHONE, AdminFixture, create_order, login_customer, make_admin, order_id


async def _cid(client: AsyncClient, headers: dict[str, str]) -> int:
    return (await client.get("/me", headers=headers)).json()["id"]


async def test_super_admin_lists_searches_and_views_customers(client: AsyncClient, admin: AdminFixture, pickup_point: PickupPoint) -> None:
    awa = await login_customer(client, name="Awa Koné")
    await login_customer(client, phone="+49 151 98765432", name="Fatou Traoré")
    cid = await _cid(client, awa)
    await create_order(client, awa, pickup_point)

    rows = (await client.get("/admin/customers", headers=admin.headers)).json()
    assert [r["display_name"] for r in rows] == ["Fatou Traoré", "Awa Koné"]
    assert "176" not in rows[1]["phone_masked"] and rows[1]["orders_count"] == 1 and rows[1]["phone_verified"] is True

    by_name = (await client.get("/admin/customers", params={"q": "awa"}, headers=admin.headers)).json()
    assert [r["id"] for r in by_name] == [cid]
    by_phone = (await client.get("/admin/customers", params={"q": PHONE}, headers=admin.headers)).json()
    assert [r["id"] for r in by_phone] == [cid]
    assert (await client.get("/admin/customers", params={"q": "zzz"}, headers=admin.headers)).json() == []

    d = (await client.get(f"/admin/customers/{cid}", headers=admin.headers)).json()
    assert d["orders_count"] == 1 and d["referral_code"] and d["loyalty_points"] == 0 and d["recent_orders"][0]["status"] == "QUOTE_REQUESTED"


async def test_only_super_admin_manages_customers(client: AsyncClient, admin: AdminFixture) -> None:
    operator = await make_admin("OPERATOR", "op@flariane.ci")
    cid = await _cid(client, await login_customer(client))
    for method, url in [("GET", "/admin/customers"), ("GET", f"/admin/customers/{cid}"), ("POST", f"/admin/customers/{cid}/block"),
                        ("POST", f"/admin/customers/{cid}/unblock"), ("DELETE", f"/admin/customers/{cid}")]:
        r = await client.request(method, url, headers=operator.headers)
        assert r.status_code == 403, (method, url, r.status_code)


async def test_blocked_customer_is_locked_out_and_can_be_unblocked(client: AsyncClient, admin: AdminFixture) -> None:
    headers = await login_customer(client)
    cid = await _cid(client, headers)
    refresh = (await client.post("/auth/login", json={"phone": PHONE, "password": PASSWORD})).json()["refresh_token"]

    assert (await client.post(f"/admin/customers/{cid}/block", headers=admin.headers)).status_code == 204
    # The access token stops working at once, the refresh token is revoked, and login says why.
    assert (await client.get("/me", headers=headers)).status_code == 401
    assert (await client.post("/auth/refresh", json={"refresh_token": refresh})).status_code == 401
    r = await client.post("/auth/login", json={"phone": PHONE, "password": PASSWORD})
    assert r.status_code == 401 and r.json()["detail"] == "account_blocked"
    # A wrong password does not reveal that the account is blocked.
    assert (await client.post("/auth/login", json={"phone": PHONE, "password": "wrong-password"})).json()["detail"] == "invalid_credentials"
    assert (await client.get(f"/admin/customers/{cid}", headers=admin.headers)).json()["blocked"] is True

    assert (await client.post(f"/admin/customers/{cid}/unblock", headers=admin.headers)).status_code == 204
    assert (await client.post("/auth/login", json={"phone": PHONE, "password": PASSWORD})).status_code == 200


async def test_admin_deletes_customer_but_not_with_an_order_in_progress(client: AsyncClient, admin: AdminFixture, pickup_point: PickupPoint) -> None:
    headers = await login_customer(client)
    cid = await _cid(client, headers)
    ref = (await create_order(client, headers, pickup_point))["public_ref"]
    async with SessionLocal() as db:
        await db.execute(update(Order).where(Order.id == await order_id(ref)).values(status="PAID"))
        await db.commit()

    r = await client.delete(f"/admin/customers/{cid}", headers=admin.headers)
    assert r.status_code == 409 and r.json()["detail"] == "orders_in_progress"

    async with SessionLocal() as db:
        await db.execute(update(Order).where(Order.id == await order_id(ref)).values(status="PICKED_UP"))
        await db.commit()
    assert (await client.delete(f"/admin/customers/{cid}", headers=admin.headers)).status_code == 204
    assert (await client.get("/me", headers=headers)).status_code == 401
    assert (await client.post("/auth/login", json={"phone": PHONE, "password": PASSWORD})).json()["detail"] == "invalid_credentials"
    assert (await client.get(f"/admin/customers/{cid}", headers=admin.headers)).status_code == 404
    assert (await client.get("/admin/customers", headers=admin.headers)).json() == []
    # The number is free again.
    assert (await client.post("/auth/register", json={"phone": PHONE, "password": PASSWORD, "consent": True})).status_code == 201
