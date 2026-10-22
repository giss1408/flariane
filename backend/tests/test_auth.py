import time

import pyotp
from httpx import AsyncClient
from sqlalchemy import select, update

from app.db import SessionLocal
from app.models import AdminDevice
from app.security.tokens import utcnow
from tests.conftest import AdminFixture, login_customer, make_admin


async def test_register_then_login(client: AsyncClient) -> None:
    r = await client.post("/auth/register", json={"phone": "07 01 02 03 04", "password": "bonjour-2026", "display_name": "Awa"})
    assert r.status_code == 201 and r.json()["refresh_token"]
    r = await client.post("/auth/register", json={"phone": "+2250701020304", "password": "autre-mot-de-passe"})
    assert r.status_code == 409 and r.json()["detail"] == "phone_taken"
    r = await client.post("/auth/login", json={"phone": "0701020304", "password": "bonjour-2026"})
    assert r.status_code == 200
    me = (await client.get("/me", headers={"Authorization": f"Bearer {r.json()['access_token']}"})).json()
    assert me["display_name"] == "Awa" and me["must_change_password"] is False


async def test_weak_password_rejected(client: AsyncClient) -> None:
    for pw in ("short", "11111111"):
        r = await client.post("/auth/register", json={"phone": "0701020304", "password": pw})
        assert r.status_code == 400 and r.json()["detail"] == "weak_password"


async def test_login_locks_after_five_failures_per_phone(client: AsyncClient) -> None:
    await client.post("/auth/register", json={"phone": "0701020304", "password": "bonjour-2026"})
    for _ in range(5):
        r = await client.post("/auth/login", json={"phone": "0701020304", "password": "wrong-password"})
        assert r.status_code == 401 and r.json()["detail"] == "invalid_credentials"
    r = await client.post("/auth/login", json={"phone": "0701020304", "password": "bonjour-2026"})
    assert r.status_code == 429 and r.json()["detail"] == "login_locked"
    # Another number is unaffected (CGNAT: many customers share one IP).
    await client.post("/auth/register", json={"phone": "0501020304", "password": "bonjour-2026"})
    assert (await client.post("/auth/login", json={"phone": "0501020304", "password": "bonjour-2026"})).status_code == 200


async def test_unknown_phone_same_error(client: AsyncClient) -> None:
    r = await client.post("/auth/login", json={"phone": "0109090909", "password": "whatever-123"})
    assert r.status_code == 401 and r.json()["detail"] == "invalid_credentials"


async def test_admin_reset_and_customer_change_password(client: AsyncClient, admin: AdminFixture) -> None:
    from tests.conftest import PASSWORD

    headers = await login_customer(client)
    cid = (await client.get("/me", headers=headers)).json()["id"]
    r = await client.post(f"/admin/customers/{cid}/reset-password", headers=admin.headers)
    temp = r.json()["temporary_password"]
    # Old password no longer works; temp works and the app is told to ask for a new one.
    assert (await client.post("/auth/login", json={"phone": "0701020304", "password": PASSWORD})).status_code == 401
    r = await client.post("/auth/login", json={"phone": "0701020304", "password": temp})
    h = {"Authorization": f"Bearer {r.json()['access_token']}"}
    assert (await client.get("/me", headers=h)).json()["must_change_password"] is True
    r = await client.post("/me/password", headers=h, json={"current_password": "wrong", "new_password": "nouveau-2026"})
    assert r.status_code == 401
    r = await client.post("/me/password", headers=h, json={"current_password": temp, "new_password": "nouveau-2026"})
    assert r.status_code == 204
    assert (await client.get("/me", headers=h)).json()["must_change_password"] is False
    assert (await client.post("/auth/login", json={"phone": "0701020304", "password": "nouveau-2026"})).status_code == 200


async def test_web_refresh_cookie_rotation_and_reuse_detection(client: AsyncClient) -> None:
    r = await client.post("/auth/register", json={"phone": "0701020304", "password": "bonjour-2026", "client": "web"})
    assert r.json()["refresh_token"] is None  # web: token only in the HttpOnly cookie
    first = r.cookies["flr_rt"]

    r = await client.post("/auth/refresh", json={})
    assert r.status_code == 200
    second = r.cookies["flr_rt"]
    assert second != first

    # Replaying the first (rotated) token revokes the whole family.
    client.cookies.clear()
    r = await client.post("/auth/refresh", json={"refresh_token": first})
    assert r.status_code == 401 and r.json()["detail"] == "refresh_reused"
    r = await client.post("/auth/refresh", json={"refresh_token": second})
    assert r.status_code == 401


async def test_customer_token_rejected_on_admin_routes(client: AsyncClient, customer: dict) -> None:
    assert (await client.get("/admin/orders", headers=customer)).status_code == 401


async def test_admin_token_rejected_on_customer_routes(client: AsyncClient, admin: AdminFixture) -> None:
    assert (await client.get("/me", headers=admin.headers)).status_code == 401


async def _login(client: AsyncClient, a: AdminFixture, device: dict, totp_at: int | None = None) -> dict:
    code = pyotp.TOTP(a.totp_secret).at(totp_at or int(time.time()))
    r = await client.post("/admin/auth/login", json={"email": a.user.email, "password": a.password, "totp": code, "device": device})
    return {"http": r.status_code, **(r.json() if r.headers.get("content-type", "").startswith("application/json") else {})}


async def test_admin_device_approval_flow(client: AsyncClient, admin: AdminFixture) -> None:
    other = await make_admin(role="OPERATOR", email="op@flariane.ci")
    r = await _login(client, other, {"name": "Pixel", "platform": "android"})
    assert r["http"] == 200 and r["status"] == "device_pending" and r["device_id"] and r["device_secret"]
    assert r.get("tokens") is None
    device = {"device_id": r["device_id"], "device_secret": r["device_secret"], "name": "Pixel", "platform": "android"}

    # Still pending (new TOTP step needed: codes are single use).
    r2 = await _login(client, other, device, totp_at=int(time.time()) + 30)
    assert r2["http"] == 200 and r2["status"] == "device_pending"

    # Operators can't approve devices; super admins can.
    assert (await client.post(f"/admin/devices/{device['device_id']}/approve", headers=other.headers)).status_code == 403
    assert (await client.post(f"/admin/devices/{device['device_id']}/approve", headers=admin.headers)).status_code == 200

    # Both usable TOTP steps are spent; in real life the admin waits 30 s. Reset the marker instead.
    from app.models import AdminUser

    async with SessionLocal() as db:
        await db.execute(update(AdminUser).where(AdminUser.id == other.user.id).values(totp_last_step=0))
        await db.commit()
    r3 = await _login(client, other, device)
    assert r3["http"] == 200 and r3["status"] == "ok"
    access, refresh = r3["tokens"]["access_token"], r3["tokens"]["refresh_token"]
    assert (await client.get("/admin/auth/me", headers={"Authorization": f"Bearer {access}"})).json()["role"] == "OPERATOR"

    # Refresh needs the device secret too.
    bad = await client.post("/admin/auth/refresh", json={"refresh_token": refresh, "device_id": device["device_id"], "device_secret": "nope"})
    assert bad.status_code == 401
    ok = await client.post("/admin/auth/refresh", json={"refresh_token": refresh, "device_id": device["device_id"], "device_secret": device["device_secret"]})
    assert ok.status_code == 200

    # Revoking the device cuts access immediately, before the access token expires.
    assert (await client.post(f"/admin/devices/{device['device_id']}/revoke", headers=admin.headers)).status_code == 200
    assert (await client.get("/admin/auth/me", headers={"Authorization": f"Bearer {access}"})).status_code == 401
    r4 = await client.post("/admin/auth/refresh", json={"refresh_token": ok.json()["refresh_token"], "device_id": device["device_id"], "device_secret": device["device_secret"]})
    assert r4.status_code == 401


async def test_totp_code_cannot_be_replayed(client: AsyncClient, admin: AdminFixture) -> None:
    async with SessionLocal() as db:
        await db.execute(update(AdminDevice).values(secret_hash="unused"))
        await db.commit()
    now = int(time.time())
    first = await _login(client, admin, {"name": "Web", "platform": "web"}, totp_at=now)
    assert first["http"] == 200
    replay = await _login(client, admin, {"name": "Web", "platform": "web"}, totp_at=now)
    assert replay["http"] == 401


async def test_admin_login_wrong_password(client: AsyncClient, admin: AdminFixture) -> None:
    code = pyotp.TOTP(admin.totp_secret).now()
    r = await client.post("/admin/auth/login", json={"email": admin.user.email, "password": "wrong password!", "totp": code,
                                                      "device": {"name": "x", "platform": "web"}})
    assert r.status_code == 401
    r = await client.post("/admin/auth/login", json={"email": "nobody@x.ci", "password": "wrong password!", "totp": code,
                                                      "device": {"name": "x", "platform": "web"}})
    assert r.status_code == 401
    async with SessionLocal() as db:
        assert (await db.scalars(select(AdminDevice))).all().__len__() == 1  # no device created on failure


async def test_viewer_cannot_quote(client: AsyncClient, customer: dict, pickup_point) -> None:  # type: ignore[no-untyped-def]
    from tests.conftest import DRAFT, create_order, order_id

    viewer = await make_admin(role="VIEWER", email="v@flariane.ci")
    ref = (await create_order(client, customer, pickup_point))["public_ref"]
    oid = await order_id(ref)
    assert (await client.get(f"/admin/orders/{oid}", headers=viewer.headers)).status_code == 200
    assert (await client.put(f"/admin/orders/{oid}/quote-draft", json=DRAFT, headers=viewer.headers)).status_code == 403


async def test_unknown_fields_rejected(client: AsyncClient, customer: dict, pickup_point) -> None:  # type: ignore[no-untyped-def]
    r = await client.post("/orders", json={"share_text": "https://onelink.shein.com/57/a", "pickup_point_id": pickup_point.id,
                                           "status": "PAID"}, headers=customer)
    assert r.status_code == 422


async def test_delete_account_anonymises(client: AsyncClient, pickup_point) -> None:  # type: ignore[no-untyped-def]
    headers = await login_customer(client)
    assert (await client.get("/me", headers=headers)).json()["phone_masked"] == "+225 07 •• •• 04"
    assert (await client.delete("/me", headers=headers)).status_code == 204
    assert (await client.get("/me", headers=headers)).status_code == 401


async def test_first_admin_setup_and_bootstrap_device(client: AsyncClient, monkeypatch) -> None:  # type: ignore[no-untyped-def]
    from app.config import get_settings

    body = {"email": "boss@flariane.ci", "name": "Boss", "role": "SUPER_ADMIN", "password": "a-long-password-123"}
    assert (await client.post("/setup/first-admin", json=body, headers={"x-setup-token": "nope"})).status_code == 403
    monkeypatch.setattr(get_settings(), "setup_token", "s3cret-setup")
    assert (await client.post("/setup/first-admin", json=body, headers={"x-setup-token": "wrong"})).status_code == 403
    r = await client.post("/setup/first-admin", json=body, headers={"x-setup-token": "s3cret-setup"})
    assert r.status_code == 200
    secret = r.json()["totp_secret"]
    # Only once.
    assert (await client.post("/setup/first-admin", json={**body, "email": "x@y.ci"}, headers={"x-setup-token": "s3cret-setup"})).status_code == 409

    # Her first device is approved at login (no approved device exists yet).
    r = await client.post("/admin/auth/login", json={"email": "boss@flariane.ci", "password": "a-long-password-123",
                                                      "totp": pyotp.TOTP(secret).now(), "device": {"name": "Pixel", "platform": "android"}})
    assert r.json()["status"] == "ok" and r.json()["tokens"]["access_token"] and r.json()["device_secret"]


async def test_second_device_still_needs_approval(client: AsyncClient, admin: AdminFixture) -> None:
    # `admin` fixture already has an approved device: a new one waits for approval.
    r = await client.post("/admin/auth/login", json={"email": admin.user.email, "password": admin.password,
                                                      "totp": pyotp.TOTP(admin.totp_secret).now(), "device": {"name": "Tab", "platform": "android"}})
    assert r.json()["status"] == "device_pending"


async def test_setup_retires_legacy_dev_admin(client: AsyncClient, monkeypatch) -> None:  # type: ignore[no-untyped-def]
    from app.config import get_settings

    legacy = await make_admin(email="dev@flariane.ci")  # has an approved device
    monkeypatch.setattr(get_settings(), "setup_token", "tok")
    body = {"email": "boss@flariane.ci", "name": "Boss", "role": "SUPER_ADMIN", "password": "a-long-password-123"}
    r = await client.post("/setup/first-admin", json=body, headers={"x-setup-token": "tok"})
    assert r.status_code == 200
    assert (await client.get("/admin/auth/me", headers=legacy.headers)).status_code == 401
    r = await client.post("/admin/auth/login", json={"email": "boss@flariane.ci", "password": "a-long-password-123",
                                                      "totp": pyotp.TOTP(r.json()["totp_secret"]).now(), "device": {"name": "P", "platform": "android"}})
    assert r.json()["status"] == "ok"


async def test_reset_admin_recovers_login(client: AsyncClient, admin: AdminFixture, monkeypatch) -> None:  # type: ignore[no-untyped-def]
    from app.config import get_settings

    monkeypatch.setattr(get_settings(), "setup_token", "tok")
    pw = "Te+st\\/9B?=x{=4mQp[R2\\@ZZ1"  # dummy: backslashes and symbols survive the round trip
    body = {"email": admin.user.email, "name": "Admin", "role": "SUPER_ADMIN", "password": pw}
    assert (await client.post("/setup/reset-admin", json=body)).status_code == 403
    r = await client.post("/setup/reset-admin", json=body, headers={"x-setup-token": "tok"})
    assert r.status_code == 200
    assert (await client.get("/admin/auth/me", headers=admin.headers)).status_code == 401  # old device revoked
    r = await client.post("/admin/auth/login", json={"email": admin.user.email, "password": pw,
                                                      "totp": pyotp.TOTP(r.json()["totp_secret"]).now(), "device": {"name": "P", "platform": "android"}})
    assert r.json()["status"] == "ok"


async def test_admin_users_reset_and_remove(client: AsyncClient, admin: AdminFixture) -> None:
    other = await make_admin(role="OPERATOR", email="op@flariane.ci")
    r = await client.post(f"/admin/users/{other.user.id}/reset-credentials", headers=admin.headers)
    creds = r.json()
    assert r.status_code == 200 and creds["password"] and creds["totp_secret"]
    r = await client.post("/admin/auth/login", json={"email": "op@flariane.ci", "password": creds["password"],
                                                      "totp": pyotp.TOTP(creds["totp_secret"]).now(), "device": {"name": "x", "platform": "android"}})
    assert r.status_code == 200
    assert (await client.post(f"/admin/users/{other.user.id}/deactivate", headers=admin.headers)).status_code == 200
    emails = [u["email"] for u in (await client.get("/admin/users", headers=admin.headers)).json()]
    assert "op@flariane.ci" not in emails


async def test_admin_without_totp_needs_approved_device(client: AsyncClient, admin: AdminFixture) -> None:
    r = await client.post("/admin/users", json={"email": "desk2@flariane.ci", "name": "Desk", "role": "PICKUP",
                                                "password": "a-long-password-123", "totp_required": False}, headers=admin.headers)
    assert r.status_code == 201 and r.json()["totp_uri"] is None and r.json()["totp_required"] is False
    uid = r.json()["id"]
    login = {"email": "desk2@flariane.ci", "password": "a-long-password-123", "device": {"name": "P", "platform": "android"}}
    r = (await client.post("/admin/auth/login", json=login)).json()
    assert r["status"] == "device_pending"  # no code, but the phone still needs approval
    dev = {"device_id": r["device_id"], "device_secret": r["device_secret"], "name": "P", "platform": "android"}
    await client.post(f"/admin/devices/{r['device_id']}/approve", headers=admin.headers)
    r = (await client.post("/admin/auth/login", json={**login, "device": dev})).json()
    assert r["status"] == "ok"
    # Wrong password still refused.
    assert (await client.post("/admin/auth/login", json={**login, "password": "wrong-password!!", "device": dev})).status_code == 401
    # Turning the code back on makes it mandatory again.
    await client.post(f"/admin/users/{uid}/totp", json={"required": True}, headers=admin.headers)
    assert (await client.post("/admin/auth/login", json={**login, "device": dev})).status_code == 401


async def test_super_admin_always_needs_totp(client: AsyncClient, admin: AdminFixture) -> None:
    r = await client.post("/admin/users", json={"email": "sa@flariane.ci", "name": "SA", "role": "SUPER_ADMIN",
                                                "password": "a-long-password-123", "totp_required": False}, headers=admin.headers)
    assert r.json()["totp_required"] is True and r.json()["totp_uri"]
    r = await client.post(f"/admin/users/{admin.user.id}/totp", json={"required": False}, headers=admin.headers)
    assert r.status_code == 400


async def test_phone_verification_by_whatsapp_code(client: AsyncClient, admin: AdminFixture) -> None:
    from urllib.parse import unquote

    from app import tasks
    from tests.conftest import CART_SHARE

    r = await client.post("/auth/register", json={"phone": "0507080910", "password": "bonjour-2026", "display_name": "Aya"})
    h = {"Authorization": f"Bearer {r.json()['access_token']}"}
    assert tasks.RECORDED[-1][1]["event"] == "customer_registered"
    assert (await client.get("/me", headers=h)).json()["phone_verified"] is False
    r = await client.post("/orders", json={"share_text": CART_SHARE}, headers=h)
    assert r.status_code == 403 and r.json()["detail"] == "phone_not_verified"

    pending = (await client.get("/admin/customers/unverified", headers=admin.headers)).json()
    cid = pending[0]["id"]
    assert pending[0]["phone_masked"] == "+225 05 •• •• 10" and pending[0]["code_sent"] is False
    url = (await client.post(f"/admin/customers/{cid}/verification-code", headers=admin.headers)).json()["url"]
    assert url.startswith("https://wa.me/2250507080910?text=")
    code = unquote(url).split("*")[1]
    wrong = "000000" if code != "000000" else "111111"
    assert (await client.post("/me/verify-phone", json={"code": wrong}, headers=h)).status_code == 400
    r = await client.post("/me/verify-phone", json={"code": code}, headers=h)
    assert r.status_code == 200 and r.json()["phone_verified"] is True
    assert (await client.post("/orders", json={"share_text": CART_SHARE}, headers=h)).status_code == 201
    assert (await client.get("/admin/customers/unverified", headers=admin.headers)).json() == []


async def test_wrong_number_rejected_then_corrected(client: AsyncClient, admin: AdminFixture) -> None:
    r = await client.post("/auth/register", json={"phone": "0102030405", "password": "bonjour-2026"})
    h = {"Authorization": f"Bearer {r.json()['access_token']}"}
    cid = (await client.get("/admin/customers/unverified", headers=admin.headers)).json()[0]["id"]
    assert (await client.post(f"/admin/customers/{cid}/reject", headers=admin.headers)).status_code == 204
    me = (await client.get("/me", headers=h)).json()
    assert me["phone_rejected"] is True and me["phone_verified"] is False
    assert (await client.get("/admin/customers/unverified", headers=admin.headers)).json() == []
    # The number is free again for its real owner…
    assert (await client.post("/auth/register", json={"phone": "0102030405", "password": "autre-mdp-2026"})).status_code == 201
    # …so she can't take it back, but can enter her correct one.
    assert (await client.put("/me/phone", json={"phone": "0102030405"}, headers=h)).status_code == 409
    me = (await client.put("/me/phone", json={"phone": "0102030499"}, headers=h)).json()
    assert me["phone_rejected"] is False and me["phone_masked"] == "+225 01 •• •• 99"
    assert any(c["id"] == cid for c in (await client.get("/admin/customers/unverified", headers=admin.headers)).json())
