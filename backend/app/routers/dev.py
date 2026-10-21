"""Development-only routes: a fake Wave checkout page that sends correctly signed webhooks.
Never mounted when FLR_ENV=prod or FLR_WAVE_MODE=live."""

import html
import json
import uuid

import httpx
from fastapi import APIRouter, Form, HTTPException
from fastapi.responses import HTMLResponse, RedirectResponse

from app.config import get_settings
from app.integrations import wave

router = APIRouter(prefix="/dev", tags=["dev"], include_in_schema=False)


@router.get("/wave/checkout/{session_id}", response_class=HTMLResponse)
async def fake_checkout(session_id: str) -> str:
    session = wave.FAKE_SESSIONS.get(session_id)
    if session is None:
        raise HTTPException(404)
    amount = html.escape(f"{int(session['amount']):,}".replace(",", " "))
    ref = html.escape(session["client_reference"])
    return f"""<!doctype html><html lang="fr"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Wave (simulation)</title>
<body style="font-family:system-ui;max-width:420px;margin:40px auto;padding:0 16px">
<h1 style="color:#1dc3ff">Wave — simulation</h1>
<p>Commande <b>{ref}</b></p><p style="font-size:28px"><b>{amount} FCFA</b></p>
<form method="post" action="/dev/wave/checkout/{html.escape(session_id)}">
<button name="outcome" value="succeeded" style="width:100%;height:52px;font-size:18px;background:#1dc3ff;border:0;border-radius:8px;color:#fff">Payer</button>
<p></p><button name="outcome" value="failed" style="width:100%;height:48px">Échec du paiement</button>
</form></body></html>"""


@router.post("/wave/checkout/{session_id}")
async def fake_checkout_submit(session_id: str, outcome: str = Form(...)) -> RedirectResponse:
    s = get_settings()
    session = wave.FAKE_SESSIONS.get(session_id)
    if session is None:
        raise HTTPException(404)
    succeeded = outcome == "succeeded"
    session["checkout_status"] = "complete"
    session["payment_status"] = "succeeded" if succeeded else "cancelled"
    session["transaction_id"] = f"T_FAKE_{uuid.uuid4().hex[:10].upper()}"
    event = {
        "id": f"EV_{uuid.uuid4().hex}",
        "type": "checkout.session.completed" if succeeded else "checkout.session.payment_failed",
        "data": {k: v for k, v in session.items() if not k.startswith("_")},
    }
    body = json.dumps(event).encode()
    async with httpx.AsyncClient(base_url=s.api_base_url, timeout=10) as client:
        await client.post(
            "/webhooks/wave",
            content=body,
            headers={"wave-signature": wave.sign_payload(body, s.wave_webhook_secret), "content-type": "application/json"},
        )
    return RedirectResponse(session["success_url"] if succeeded else session["error_url"], status_code=303)
