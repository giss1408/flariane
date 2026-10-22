"""Public pages required by the App Store and Google Play: privacy policy and account deletion."""

import html

from fastapi import APIRouter
from fastapi.responses import HTMLResponse

from app.config import get_settings

router = APIRouter(prefix="/legal", include_in_schema=False)

_STYLE = """<style>body{font-family:system-ui,-apple-system,Segoe UI,Roboto,sans-serif;max-width:720px;margin:32px auto;
padding:0 18px;line-height:1.55;color:#2B0F2E}h1{color:#B5164F}h2{margin-top:28px}a{color:#B5164F}</style>"""


def _page(title: str, body: str) -> str:
    return f"""<!doctype html><html lang="fr"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>{html.escape(title)}</title>{_STYLE}<body><h1>{html.escape(title)}</h1>{body}</body></html>"""


@router.get("/confidentialite", response_class=HTMLResponse)
async def privacy() -> str:
    s = get_settings()
    company, email = html.escape(s.company_name), html.escape(s.contact_email)
    return _page("Politique de confidentialité", f"""
<p>{company} (« nous ») exploite l’application Flariane, qui permet de faire acheter des paniers SHEIN et Temu
et de les retirer à Abidjan. Cette page explique quelles données nous collectons et pourquoi.</p>
<h2>Données collectées</h2>
<ul>
<li><b>Compte</b> : numéro de téléphone (WhatsApp), prénom, mot de passe (stocké uniquement sous forme chiffrée irréversible).</li>
<li><b>Commandes</b> : liens de panier SHEIN/Temu, captures d’écran de panier que tu envoies, devis, statut des commandes.</li>
<li><b>Paiement</b> : moyen choisi (Wave, Orange Money, Moov Money) et la capture d’écran du paiement. Nous ne recevons jamais tes codes ni tes identifiants de paiement.</li>
<li><b>Adresse à Abidjan</b> : commune, quartier, repère et, si tu l’acceptes, ta position GPS.</li>
</ul>
<h2>Utilisation</h2>
<p>Ces données servent uniquement à vérifier ton numéro, établir tes devis, passer tes commandes, organiser la livraison
et le retrait, et te contacter sur WhatsApp au sujet de tes commandes. Nous ne vendons pas tes données et
n’affichons pas de publicité.</p>
<h2>Partage</h2>
<p>Nous communiquons au transitaire et au point de retrait uniquement ce qui est nécessaire à la livraison
(référence de commande, prénom). Les données sont hébergées chez nos prestataires techniques (hébergement du serveur
et de la base de données) dans l’Union européenne.</p>
<h2>Sécurité</h2>
<p>Ton numéro de téléphone et ton adresse sont chiffrés dans notre base de données. Les échanges avec l’application
sont chiffrés (HTTPS). L’accès de notre équipe est protégé et journalisé.</p>
<h2>Conservation et suppression</h2>
<p>Tu peux supprimer ton compte à tout moment depuis l’application : <i>Mon compte → Supprimer mon compte</i>.
Tes données personnelles sont alors effacées ; seules les informations comptables des commandes payées sont
conservées, sans lien avec ton identité, comme l’exige la loi.
Voir aussi <a href="/legal/suppression-compte">la suppression de compte</a>.</p>
<h2>Tes droits</h2>
<p>Conformément à la loi ivoirienne n° 2013-450 relative à la protection des données à caractère personnel, tu peux
accéder à tes données, les corriger ou les supprimer, en nous écrivant à <a href="mailto:{email}">{email}</a>.</p>
<h2>Contact</h2><p>{company} — <a href="mailto:{email}">{email}</a></p>""")


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
