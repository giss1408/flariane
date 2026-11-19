"""Back office through auth: the admin app signs in at auth (password + code), then exchanges the token here; device approval and
the flariane session stay in flariane. Smoke tests with a local key/JWKS (no network)."""

import jwt
import pytest
from sqlalchemy import select, update

from app.config import get_settings
from app.db import SessionLocal
from app.models import AdminDevice, AdminUser, RefreshToken
from app.security import sso
from tests.conftest import make_admin
from tests.test_sso_dual_accept import bearer, sso_on, token  # noqa: F401  (sso_on is a fixture)

DEVICE = {"name": "Awa phone", "platform": "android"}


def atoken(admin, **over) -> str:
    return token(app="admin", role=over.pop("role", "super_admin"), roles=["super_admin"], lid=str(admin.user.id), amr=over.pop("amr", ["pwd", "totp"]), ph="", **over)


async def exchange(client, tok, device=None):
    return await client.post("/admin/auth/sso-login", json={"device": device or DEVICE}, headers=bearer(tok))


async def approve(device_id: int) -> None:
    async with SessionLocal() as db:
        await db.execute(update(AdminDevice).where(AdminDevice.id == device_id).values(approved_at=__import__("datetime").datetime.now(__import__("datetime").UTC)))
        await db.commit()


async def test_disabled_by_default(client, admin):
    assert (await exchange(client, atoken(admin))).status_code == 401


async def test_new_device_waits_for_approval_then_the_exchange_opens_a_flariane_session(client, sso_on, admin):
    r = await exchange(client, atoken(admin))
    assert r.status_code == 200 and r.json()["status"] == "device_pending" and r.json()["device_secret"]
    dev = r.json()
    await approve(dev["device_id"])
    ok = await exchange(client, atoken(admin), {**DEVICE, "device_id": dev["device_id"], "device_secret": dev["device_secret"]})
    assert ok.status_code == 200 and ok.json()["status"] == "ok"
    h = {"Authorization": f"Bearer {ok.json()['tokens']['access_token']}"}
    me = await client.get("/admin/auth/me", headers=h)
    assert me.status_code == 200 and me.json()["email"] == admin.user.email and me.json()["device_id"] == dev["device_id"]
    # the session row remembers the auth session it came from
    async with SessionLocal() as db:
        row = (await db.scalars(select(RefreshToken).where(RefreshToken.subject_type == "admin", RefreshToken.device_id == dev["device_id"]))).first()
    assert row.sso_sid == "s1"


async def test_an_already_approved_device_gets_in_straight_away(client, sso_on, admin):
    # the fixture admin's phone is approved; its secret is not known here, so use a registered-and-approved new device
    r = (await exchange(client, atoken(admin))).json()
    await approve(r["device_id"])
    ok = await exchange(client, atoken(admin), {**DEVICE, "device_id": r["device_id"], "device_secret": r["device_secret"]})
    assert ok.json()["status"] == "ok"


async def test_wrong_secret_or_someone_elses_device_is_refused(client, sso_on, admin):
    other = await make_admin("OPERATOR", "op@flariane.ci")
    r = (await exchange(client, atoken(admin))).json()
    await approve(r["device_id"])
    assert (await exchange(client, atoken(admin), {**DEVICE, "device_id": r["device_id"], "device_secret": "x" * 20})).json()["detail"] == "unknown_device"
    other_tok = atoken(other, role="operator")
    assert (await exchange(client, other_tok, {**DEVICE, "device_id": r["device_id"], "device_secret": r["device_secret"]})).json()["detail"] == "unknown_device"


@pytest.mark.parametrize("over", [{"aud": "fidelia"}, {"iss": "http://evil"}, {"exp": 1, "iat": 0}, {"mcp": True}, {"app": "customer"}, {"role": "emperor"}, {"lid": None}, {"lid": "abc"}, {"lid": "999999"}])
async def test_bad_or_wrongly_scoped_tokens_are_refused(client, sso_on, admin, over):
    base = {"app": "admin", "role": "super_admin", "roles": ["super_admin"], "lid": str(admin.user.id), "amr": ["pwd", "totp"], "ph": ""}
    r = await exchange(client, token(**{**base, **over}))
    assert r.status_code == 401 and r.json()["detail"] == "invalid_credentials"


async def test_a_customer_token_cannot_open_the_back_office(client, sso_on, admin):
    # same lid as an admin id, but it is a customer session
    assert (await exchange(client, token(lid=str(admin.user.id)))).status_code == 401


async def test_the_authenticator_code_is_required_unless_the_account_never_had_one(client, sso_on):
    boss = await make_admin("SUPER_ADMIN", "boss@flariane.ci")
    no_code = atoken(boss, amr=["pwd"])
    assert (await exchange(client, no_code)).status_code == 401  # a super admin always needs the code
    op = await make_admin("OPERATOR", "op@flariane.ci")
    assert (await exchange(client, atoken(op, role="operator", amr=["pwd"]))).status_code == 401  # totp_required is true
    async with SessionLocal() as db:
        await db.execute(update(AdminUser).where(AdminUser.id == op.user.id).values(totp_required=False))
        await db.commit()
    assert (await exchange(client, atoken(op, role="operator", amr=["pwd"]))).status_code == 200  # exempt, as before the migration
    assert (await exchange(client, atoken(boss, amr=["pwd"]))).status_code == 401  # still never for a super admin


async def test_inactive_admin_is_refused(client, sso_on, admin):
    async with SessionLocal() as db:
        await db.execute(update(AdminUser).where(AdminUser.id == admin.user.id).values(active=False))
        await db.commit()
    assert (await exchange(client, atoken(admin))).status_code == 401


async def test_role_follows_auth(client, sso_on):
    op = await make_admin("OPERATOR", "op@flariane.ci")
    assert (await exchange(client, atoken(op, role="viewer"))).status_code == 200
    async with SessionLocal() as db:
        assert (await db.get(AdminUser, op.user.id)).role == "VIEWER"  # auth is the authority for roles once migrated


async def _session(client, admin):
    r = (await exchange(client, atoken(admin))).json()
    await approve(r["device_id"])
    ok = (await exchange(client, atoken(admin), {**DEVICE, "device_id": r["device_id"], "device_secret": r["device_secret"]})).json()
    return r, ok


async def _refresh(client, dev, ok):
    return await client.post("/admin/auth/refresh", json={"refresh_token": ok["tokens"]["refresh_token"], "device_id": dev["device_id"], "device_secret": dev["device_secret"]})


async def test_refresh_ends_when_the_auth_session_ended(client, sso_on, admin, monkeypatch):
    dev, ok = await _session(client, admin)
    async def alive(sid): return True
    monkeypatch.setattr(sso, "session_active", alive)
    r = await _refresh(client, dev, ok)
    assert r.status_code == 200
    async def dead(sid): return False
    monkeypatch.setattr(sso, "session_active", dead)
    ended = await client.post("/admin/auth/refresh", json={"refresh_token": r.json()["refresh_token"], "device_id": dev["device_id"], "device_secret": dev["device_secret"]})
    assert ended.status_code == 401 and ended.json()["detail"] == "sso_session_ended"
    # the whole family is revoked: the next token is useless too
    again = await client.post("/admin/auth/refresh", json={"refresh_token": r.json()["refresh_token"], "device_id": dev["device_id"], "device_secret": dev["device_secret"]})
    assert again.status_code == 401


async def test_auth_unreachable_at_refresh_follows_the_fail_open_setting(client, sso_on, admin, monkeypatch):
    dev, ok = await _session(client, admin)
    async def unreachable(sid): return None
    monkeypatch.setattr(sso, "session_active", unreachable)
    r = await _refresh(client, dev, ok)
    assert r.status_code == 200  # default: availability
    monkeypatch.setattr(get_settings(), "sso_admin_fail_open", False)
    strict = await client.post("/admin/auth/refresh", json={"refresh_token": r.json()["refresh_token"], "device_id": dev["device_id"], "device_secret": dev["device_secret"]})
    assert strict.status_code == 401 and strict.json()["detail"] == "sso_session_ended"


async def test_sessions_not_opened_through_auth_are_never_checked(client, sso_on, admin, monkeypatch):
    async def boom(sid): raise AssertionError("auth must not be called for a legacy session")
    monkeypatch.setattr(sso, "session_active", boom)
    r = await client.post("/admin/auth/login", json={"email": admin.user.email, "password": admin.password, "totp": __import__("pyotp").TOTP(admin.totp_secret).now(), "device": {"device_id": admin.device.id, "device_secret": "x", "name": "Test phone", "platform": "android"}})
    assert r.status_code == 403  # wrong device secret on purpose: the legacy login path is unchanged and never calls auth


async def test_password_login_can_be_switched_off_after_the_cutover(client, admin, monkeypatch):
    monkeypatch.setattr(get_settings(), "sso_admin_only", True)
    r = await client.post("/admin/auth/login", json={"email": admin.user.email, "password": admin.password, "device": {"name": "x", "platform": "android"}})
    assert r.status_code == 403 and r.json()["detail"] == "use_sso"
