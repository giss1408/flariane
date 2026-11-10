"""Public legal pages (App Store / Google Play links) and the same texts as JSON for the customer app."""

import html
import re

from fastapi import APIRouter, Depends
from sqlalchemy.ext.asyncio import AsyncSession
from fastapi.responses import HTMLResponse

from app.config import get_settings
from app.db import get_session
from app.errors import NotFound
from app.services.legal_docs import Doc, documents
from app.services.settings import get_settings_map

router = APIRouter(prefix="/legal", include_in_schema=False)

_STYLE = """<style>body{font-family:system-ui,-apple-system,Segoe UI,Roboto,sans-serif;max-width:720px;margin:32px auto;
padding:0 18px;line-height:1.55;color:#2B0F2E}h1{color:#B5164F}h2{margin-top:28px}a{color:#B5164F}
.brief{background:#FDE7EE;border-radius:14px;padding:4px 18px;margin:18px 0}.brief h2{margin:12px 0 4px;font-size:1rem}</style>"""


def _page(title: str, body: str) -> str:
    return f"""<!doctype html><html lang="fr"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>{html.escape(title)}</title>{_STYLE}<body><h1>{html.escape(title)}</h1>{body}</body></html>"""


_EMAIL = re.compile(r"[\w.+-]+@[\w-]+(?:\.[\w-]+)+")


def _text(raw: str) -> str:
    """Escaped, with e-mail addresses made clickable."""
    return _EMAIL.sub(lambda m: f'<a href="mailto:{m.group(0)}">{m.group(0)}</a>', html.escape(raw))


def _render(doc: Doc) -> str:
    brief = "".join(f"<li>{_text(b)}</li>" for b in doc.summary)
    body = [f'<div class="brief"><h2>En bref</h2><ul>{brief}</ul></div>']
    for sec in doc.sections:
        body.append(f"<h2>{html.escape(sec.heading)}</h2>")
        body += [f"<p>{_text(p)}</p>" for p in sec.paragraphs]
        if sec.bullets:
            body.append("<ul>" + "".join(f"<li>{_text(b)}</li>" for b in sec.bullets) + "</ul>")
    body.append(f"<p><small>Dernière mise à jour : {html.escape(doc.updated)}</small></p>")
    return _page(doc.title, "".join(body))


async def _docs(db: AsyncSession) -> dict[str, Doc]:
    return documents(get_settings(), await get_settings_map(db))


@router.get("/documents")
async def document_list(db: AsyncSession = Depends(get_session)) -> list[dict]:
    """For the app's "Infos et légal" screen: no auth, nothing private."""
    return [{"slug": d.slug, "title": d.title, "icon": d.icon, "summary": d.summary, "updated": d.updated} for d in (await _docs(db)).values()]


@router.get("/documents/{slug}")
async def document(slug: str, db: AsyncSession = Depends(get_session)) -> dict:
    doc = (await _docs(db)).get(slug)
    if doc is None:
        raise NotFound()
    return doc.as_dict()


@router.get("/suppression-compte", response_class=HTMLResponse)
async def account_deletion() -> str:
    s = get_settings()
    email = html.escape(s.contact_email)
    return _page("Supprimer ton compte Flariane", f"""
<h2>Depuis l’application</h2>
<ol><li>Ouvre Flariane et connecte-toi.</li><li>Touche l’icône <b>compte</b> en haut à droite.</li>
<li>Touche <b>Supprimer mon compte</b> et confirme.</li></ol>
<p>La suppression est immédiate si tu n’as pas de commande en cours (payée et pas encore retirée).</p>
<h2>Sans l’application</h2>
<p>Écris-nous depuis ton numéro WhatsApp ou à <a href="mailto:{email}">{email}</a> en indiquant ton numéro de téléphone :
nous supprimons ton compte sous 7 jours.</p>
<h2>Ce qui est supprimé</h2>
<p>Numéro de téléphone, prénom, mot de passe, adresse à Abidjan, liens et captures de panier.
Les montants des commandes payées sont conservés, anonymisés, pour la comptabilité.</p>""")


@router.get("/support", response_class=HTMLResponse)
async def support(db: AsyncSession = Depends(get_session)) -> str:
    """Support page for the App Store / Google Play "support URL" field."""
    email = html.escape(get_settings().contact_email)
    wa = re.sub(r"\D", "", str((await get_settings_map(db)).get("support_whatsapp") or ""))
    whatsapp = f'<li>WhatsApp : <a href="https://wa.me/{wa}">+{wa}</a></li>' if wa else ""
    return _page("Aide et contact Flariane", f"""
<p>Une question sur ta commande, ton devis, ton paiement ou ton retrait à Abidjan ? Écris-nous, nous répondons en général sous 2 h en journée (heure d’Abidjan).</p>
<h2>Nous contacter</h2>
<ul><li>Dans l’application : bouton WhatsApp sur l’écran d’accueil ou sur ta commande.</li>{whatsapp}
<li>E-mail : <a href="mailto:{email}">{email}</a></li></ul>
<p>Indique ton numéro de téléphone et la référence de ta commande (FLR-XXXXX) pour que nous puissions t’aider vite.</p>
<h2>Liens utiles</h2>
<ul><li><a href="/legal/fonctionnement">Comment ça marche</a></li><li><a href="/legal/remboursement">Remboursement</a></li>
<li><a href="/legal/confidentialite">Confidentialité</a></li><li><a href="/legal/suppression-compte">Supprimer ton compte</a></li></ul>""")


@router.get("/{slug}", response_class=HTMLResponse)
async def page(slug: str, db: AsyncSession = Depends(get_session)) -> str:
    doc = (await _docs(db)).get(slug)
    if doc is None:
        raise NotFound()
    return _render(doc)


