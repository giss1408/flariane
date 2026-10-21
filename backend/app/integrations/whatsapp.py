"""WhatsApp Cloud API (Meta). Templates must be approved in Business Manager with these names, in `fr`."""

import hashlib
import hmac
import logging
from typing import Any

import httpx

from app.config import get_settings

log = logging.getLogger("flariane.whatsapp")

# name -> number of body parameters. Keep in sync with the templates registered at Meta.
TEMPLATES: dict[str, int] = {
    "quote_ready": 4,  # name, ref, total, expiry
    "payment_received": 1,  # ref
    "order_ready_pickup": 5,  # name, ref, location, hours, pickup code
    "item_cancelled": 2,  # ref, refund amount
    "refund_completed": 2,  # ref, amount
}

SENT_LOG: list[dict[str, Any]] = []  # log mode only: inspected by tests and the dev console


class WhatsAppError(Exception):
    pass


async def send_template(to_e164: str, template: str, params: list[str], lang: str = "fr") -> str:
    """Send a template message; returns the provider message id."""
    if template not in TEMPLATES or len(params) != TEMPLATES[template]:
        raise ValueError(f"bad template call {template}")
    s = get_settings()
    if s.whatsapp_mode == "log":
        SENT_LOG.append({"to": to_e164, "template": template, "params": params, "lang": lang})
        log.info("whatsapp(log) %s -> %s %s", template, to_e164[-4:], params)
        return f"wamid.log.{len(SENT_LOG)}"

    components: list[dict[str, Any]] = [
        {"type": "body", "parameters": [{"type": "text", "text": p} for p in params]}
    ]
    payload = {
        "messaging_product": "whatsapp",
        "to": to_e164.lstrip("+"),
        "type": "template",
        "template": {"name": template, "language": {"code": lang}, "components": components},
    }
    url = f"https://graph.facebook.com/{s.whatsapp_api_version}/{s.whatsapp_phone_number_id}/messages"
    async with httpx.AsyncClient(timeout=15) as client:
        resp = await client.post(url, json=payload, headers={"Authorization": f"Bearer {s.whatsapp_token}"})
    if resp.status_code >= 400:
        raise WhatsAppError(f"{resp.status_code}: {resp.text[:200]}")
    return resp.json()["messages"][0]["id"]


def verify_signature(header: str | None, body: bytes, app_secret: str) -> bool:
    """X-Hub-Signature-256: sha256=<hex HMAC of the raw body with the app secret>."""
    if not header or not header.startswith("sha256=") or not app_secret:
        return False
    expected = hmac.new(app_secret.encode(), body, hashlib.sha256).hexdigest()
    given = header.removeprefix("sha256=")
    return given.isascii() and hmac.compare_digest(expected.encode(), given.encode())
