"""Landing page after Wave checkout. It never changes payment state."""

import html

from fastapi import APIRouter
from fastapi.responses import HTMLResponse

router = APIRouter(include_in_schema=False)


@router.get("/paiement/retour/{ref}", response_class=HTMLResponse)
async def payment_return(ref: str, statut: str = "ok") -> str:
    ref = html.escape(ref[:16])
    title = "Paiement envoyé" if statut == "ok" else "Paiement non abouti"
    body = (
        "Retournez dans l’application Flariane : votre commande sera mise à jour dès que Wave confirme le paiement."
        if statut == "ok"
        else "Le paiement n’a pas abouti. Retournez dans l’application Flariane pour réessayer."
    )
    return f"""<!doctype html><html lang="fr"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>{title}</title><body style="font-family:system-ui;max-width:420px;margin:48px auto;padding:0 16px;color:#1F2933">
<h1 style="color:#0F5F5C;font-size:22px">{title}</h1><p>Commande <b>{ref}</b></p><p>{body}</p>
<p><a href="flariane://commandes/{ref}" style="display:block;text-align:center;background:#0F5F5C;color:#fff;padding:14px;border-radius:12px;text-decoration:none">Ouvrir Flariane</a></p>
</body></html>"""
