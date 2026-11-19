"""Smoke tests for SSO dual-accept (platform `auth` tokens next to flariane's own, customers only). Tokens are signed
here with a throwaway Ed25519 key and a local JWKS: no network, no auth service needed."""

import base64
import time

import httpx
import jwt
import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from regisse_kit.sso import SsoVerifier
from sqlalchemy import func, select, update

from app.config import get_settings
from app.db import SessionLocal
from app.models import Customer
from app.security import sso
from app.security.crypto import phone_hash
from tests.conftest import PHONE, login_customer

ISS = "http://auth.test"
E164 = "+4917612345678"  # the German test number the suite uses (accepted outside production)
KEY = Ed25519PrivateKey.generate()


def _jwks() -> dict:
    raw = KEY.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
    return {"keys": [{"kty": "OKP", "crv": "Ed25519", "alg": "EdDSA", "kid": "k1", "x": base64.urlsafe_b64encode(raw).rstrip(b"=").decode()}]}


def token(key=KEY, alg="EdDSA", **over) -> str:
    now = int(time.time())
    claims = {"iss": ISS, "aud": "flariane", "sub": "7d2f6a1e-0000-4000-8000-000000000001", "ph": f"tel:{E164}", "role": "customer", "roles": ["customer"],
              "app": "customer", "amr": ["pwd"], "auth_time": now, "iat": now, "exp": now + 600, "sid": "s1", **over}
    claims = {k: v for k, v in claims.items() if v is not None}
    return jwt.encode(claims, key, algorithm=alg, headers={"kid": "k1"})


def bearer(t: str) -> dict:
    return {"Authorization": f"Bearer {t}"}


@pytest.fixture
def sso_on(monkeypatch):
    s = get_settings()
    monkeypatch.setattr(s, "sso_enabled", True)
    monkeypatch.setattr(s, "sso_issuer", ISS)
    monkeypatch.setattr(s, "sso_jwks_url", "http://auth.test/.well-known/jwks.json")
    v = SsoVerifier(issuer=ISS, audience="flariane", jwks_fetch=_jwks)
    monkeypatch.setattr(sso, "verifier", lambda: v)


async def customers() -> list[Customer]:
    async with SessionLocal() as db:
        return list((await db.scalars(select(Customer))).all())


async def test_disabled_by_default_an_sso_token_is_refused(client):
    assert get_settings().sso_enabled is False
    assert (await client.get("/me", headers=bearer(token()))).status_code == 401


async def test_unknown_phone_is_provisioned_once_on_first_use(client, sso_on):
    r = await client.get("/me", headers=bearer(token()))
    assert r.status_code == 200, r.text
    r2 = await client.get("/me", headers=bearer(token()))
    assert r2.status_code == 200
    rows = await customers()
    assert len(rows) == 1 and rows[0].phone_hash == phone_hash(E164)
    assert rows[0].phone_verified_at is not None and rows[0].consent_version == sso.SSO_CONSENT_VERSION and rows[0].referral_code


async def test_existing_customer_is_matched_by_phone_and_keeps_her_data(client, sso_on):
    own = await login_customer(client)  # registered the flariane way with the same number
    before = (await client.get("/me", headers=own)).json()
    via_sso = await client.get("/me", headers=bearer(token()))
    assert via_sso.status_code == 200 and via_sso.json()["id"] == before["id"] and via_sso.json()["display_name"] == "Awa Koné"
    assert len(await customers()) == 1  # no duplicate


async def test_flariane_own_tokens_still_work_with_sso_on(client, sso_on):
    own = await login_customer(client)
    assert (await client.get("/me", headers=own)).status_code == 200


async def test_blocked_customer_is_refused_with_an_sso_token(client, sso_on):
    own = await login_customer(client)
    async with SessionLocal() as db:
        await db.execute(update(Customer).values(blocked_at=func.now()))
        await db.commit()
    assert (await client.get("/me", headers=bearer(token()))).status_code == 401
    assert (await client.get("/me", headers=own)).status_code == 401


@pytest.mark.parametrize("over", [{"aud": "fidelia"}, {"iss": "http://evil"}, {"exp": 1, "iat": 0}, {"role": None}, {"app": "admin"}, {"role": "operator"}, {"mcp": True}, {"ph": "+4917612345678"}, {"ph": None}])
async def test_bad_or_wrongly_scoped_sso_tokens_are_refused(client, sso_on, over):
    assert (await client.get("/me", headers=bearer(token(**over)))).status_code == 401
    assert await customers() == []  # and nothing was provisioned


async def test_forged_tokens_are_refused(client, sso_on):
    other = Ed25519PrivateKey.generate()
    forged_sig = token(key=other)
    hs = jwt.encode(jwt.decode(token(), options={"verify_signature": False}), "x" * 40, algorithm="HS256", headers={"kid": "k1"})
    none = jwt.encode(jwt.decode(token(), options={"verify_signature": False}), None, algorithm="none", headers={"kid": "k1"})
    for t in (forged_sig, hs, none, "garbage"):
        assert (await client.get("/me", headers=bearer(t))).status_code == 401
    assert await customers() == []


async def test_sso_token_does_not_open_admin_routes(client, sso_on):
    assert (await client.get("/admin/orders", headers=bearer(token()))).status_code == 401
    assert (await client.get("/admin/orders", headers=bearer(token(role="operator", app="admin")))).status_code == 401


async def test_auth_outage_gives_401_not_500(client, monkeypatch, sso_on):
    def down():
        raise httpx.ConnectError("auth is down")

    monkeypatch.setattr(sso, "verifier", lambda: SsoVerifier(issuer=ISS, audience="flariane", jwks_fetch=down))
    assert (await client.get("/me", headers=bearer(token()))).status_code == 401


async def test_legacy_id_wins_over_the_phone_so_a_number_change_cannot_split_a_customer(client, sso_on):
    own = await login_customer(client)  # registered with E164
    cid = (await client.get("/me", headers=own)).json()["id"]
    # the token carries an OLD/other number but the right legacy id (she changed her number in flariane or auth)
    r = await client.get("/me", headers=bearer(token(ph="tel:+2250701999999", lid=str(cid))))
    assert r.status_code == 200 and r.json()["id"] == cid
    assert len(await customers()) == 1  # nobody was created for the other number


async def test_unknown_or_malformed_legacy_id_is_refused_and_never_provisioned(client, sso_on):
    assert (await client.get("/me", headers=bearer(token(lid="999999")))).status_code == 401
    assert (await client.get("/me", headers=bearer(token(lid="abc")))).status_code == 401
    assert await customers() == []


async def test_legacy_id_does_not_bypass_blocking_or_scope_checks(client, sso_on):
    own = await login_customer(client)
    cid = (await client.get("/me", headers=own)).json()["id"]
    assert (await client.get("/me", headers=bearer(token(lid=str(cid), role="operator", app="admin")))).status_code == 401
    assert (await client.get("/me", headers=bearer(token(lid=str(cid), mcp=True)))).status_code == 401
    async with SessionLocal() as db:
        await db.execute(update(Customer).values(blocked_at=func.now()))
        await db.commit()
    assert (await client.get("/me", headers=bearer(token(lid=str(cid))))).status_code == 401
