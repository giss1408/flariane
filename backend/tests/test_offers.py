"""Offers the admin shows customers on the app's home screen ("Réduction pour les 20 premières commandes")."""

from datetime import timedelta

from httpx import AsyncClient

from app.security.tokens import utcnow
from tests.conftest import AdminFixture, make_admin

OFFER = {"title": "-10 % sur tes 20 premières commandes", "message": "Offre de lancement : le frais de service baisse de 10 %."}


async def test_admin_creates_edits_and_deletes_an_offer(client: AsyncClient, admin: AdminFixture) -> None:
    assert (await client.get("/public/info")).json()["offers"] == []

    r = await client.post("/admin/offers", json=OFFER, headers=admin.headers)
    assert r.status_code == 201, r.text
    offer = r.json()
    assert offer["active"] is True and offer["title"] == OFFER["title"] and offer["ends_at"] is None

    # Customers (no login needed) see it in the app's public info.
    shown = (await client.get("/public/info")).json()["offers"]
    assert shown == [{"id": offer["id"], "title": OFFER["title"], "message": OFFER["message"], "ends_at": None}]

    # Switch it off: gone for customers, still listed for the admin.
    r = await client.patch(f"/admin/offers/{offer['id']}", json={"active": False}, headers=admin.headers)
    assert r.status_code == 200 and r.json()["active"] is False
    assert (await client.get("/public/info")).json()["offers"] == []
    assert [o["id"] for o in (await client.get("/admin/offers", headers=admin.headers)).json()] == [offer["id"]]

    # Edit and switch back on.
    r = await client.patch(f"/admin/offers/{offer['id']}", json={"title": "-15 % cette semaine", "active": True}, headers=admin.headers)
    assert r.json()["title"] == "-15 % cette semaine"
    assert (await client.get("/public/info")).json()["offers"][0]["title"] == "-15 % cette semaine"

    assert (await client.delete(f"/admin/offers/{offer['id']}", headers=admin.headers)).status_code == 204
    assert (await client.get("/admin/offers", headers=admin.headers)).json() == []
    assert (await client.delete(f"/admin/offers/{offer['id']}", headers=admin.headers)).status_code == 404


async def test_expired_offers_are_not_shown(client: AsyncClient, admin: AdminFixture) -> None:
    now = utcnow()
    await client.post("/admin/offers", json={**OFFER, "title": "Terminée", "ends_at": (now - timedelta(hours=1)).isoformat()}, headers=admin.headers)
    soon = (now + timedelta(days=2)).isoformat()
    await client.post("/admin/offers", json={**OFFER, "title": "En cours", "ends_at": soon}, headers=admin.headers)
    shown = (await client.get("/public/info")).json()["offers"]
    assert [o["title"] for o in shown] == ["En cours"] and shown[0]["ends_at"] is not None
    # The admin still sees the expired one, to reuse or delete it.
    assert len((await client.get("/admin/offers", headers=admin.headers)).json()) == 2


async def test_newest_offer_comes_first(client: AsyncClient, admin: AdminFixture) -> None:
    for title in ("Première", "Deuxième"):
        await client.post("/admin/offers", json={**OFFER, "title": title}, headers=admin.headers)
    assert [o["title"] for o in (await client.get("/public/info")).json()["offers"]] == ["Deuxième", "Première"]


async def test_offer_text_is_validated(client: AsyncClient, admin: AdminFixture) -> None:
    for bad in ({**OFFER, "title": "  "}, {**OFFER, "title": "x" * 81}, {**OFFER, "message": "y" * 241}, {"message": "pas de titre"}):
        assert (await client.post("/admin/offers", json=bad, headers=admin.headers)).status_code == 422


async def test_only_super_admins_manage_offers(client: AsyncClient, customer: dict, admin: AdminFixture) -> None:
    operator = await make_admin(role="OPERATOR", email="op@flariane.ci")
    assert (await client.post("/admin/offers", json=OFFER, headers=operator.headers)).status_code == 403
    assert (await client.post("/admin/offers", json=OFFER, headers=customer)).status_code == 401
    assert (await client.get("/admin/offers", headers=customer)).status_code == 401
    assert (await client.post("/admin/offers", json=OFFER)).status_code == 401
