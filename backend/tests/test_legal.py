from httpx import AsyncClient

from app.config import get_settings
from app.services.legal_docs import documents

SLUGS = ["fonctionnement", "conditions", "remboursement", "confidentialite", "mentions-legales"]
BIZ = {"quote_validity_hours": 48, "payment_deadline_days": 3, "min_fee_xof": 2000}


async def test_document_list_for_the_app(client: AsyncClient) -> None:
    r = await client.get("/legal/documents")
    assert r.status_code == 200
    rows = r.json()
    assert [d["slug"] for d in rows] == SLUGS
    assert all(d["title"] and d["icon"] and len(d["summary"]) >= 2 for d in rows)


async def test_every_document_has_a_summary_and_sections(client: AsyncClient) -> None:
    for slug in SLUGS:
        r = await client.get(f"/legal/documents/{slug}")
        assert r.status_code == 200, slug
        d = r.json()
        assert d["summary"] and d["sections"] and all(s["heading"] and (s["paragraphs"] or s["bullets"]) for s in d["sections"])
    assert (await client.get("/legal/documents/nope")).status_code == 404


async def test_web_pages_share_the_same_text(client: AsyncClient) -> None:
    for slug in SLUGS:
        doc = (await client.get(f"/legal/documents/{slug}")).json()
        page = await client.get(f"/legal/{slug}")
        assert page.status_code == 200 and "En bref" in page.text and doc["sections"][0]["heading"] in page.text, slug
    # The URLs already given to the stores keep working.
    assert (await client.get("/legal/confidentialite")).status_code == 200
    assert (await client.get("/legal/suppression-compte")).status_code == 200
    assert (await client.get("/legal/nope")).status_code == 404


async def test_support_page_for_the_stores(client: AsyncClient) -> None:
    r = await client.get("/legal/support")
    assert r.status_code == 200
    assert 'href="mailto:flariane@regisse.com"' in r.text and "Aide et contact" in r.text


async def test_contact_email_is_the_configured_one(client: AsyncClient) -> None:
    assert get_settings().contact_email == "flariane@regisse.com"
    page = (await client.get("/legal/confidentialite")).text
    assert 'href="mailto:flariane@regisse.com"' in page
    assert "contact@flariane.ci" not in page


def test_numbers_come_from_the_settings_and_the_notice_shows_only_what_is_filled_in() -> None:
    cfg = get_settings()
    docs = documents(cfg, {**BIZ, "quote_validity_hours": 24, "payment_deadline_days": 1, "min_fee_xof": 2500})
    text = " ".join(p for s in docs["conditions"].sections + docs["fonctionnement"].sections for p in s.paragraphs)
    assert "24 heures" in text and "1 jour " in text and "2 500 FCFA" in text and "48 heures" not in text

    bare = documents(cfg.model_copy(update={"company_address": "", "company_registration": ""}), BIZ)
    assert [b for b in bare["mentions-legales"].sections[0].bullets if "Adresse" in b or "Immatriculation" in b] == []
    filled = documents(cfg.model_copy(update={"company_address": "Cocody, Abidjan", "company_registration": "CI-ABJ-2026-B-0000"}), BIZ)
    bullets = filled["mentions-legales"].sections[0].bullets
    assert any("Cocody, Abidjan" in b for b in bullets) and any("CI-ABJ-2026-B-0000" in b for b in bullets)
