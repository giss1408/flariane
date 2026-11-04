"""Inbound webhooks. Signatures are verified on the raw bytes before any JSON parsing; payloads are
never declared as Pydantic body parameters here."""

import json
import logging

from fastapi import APIRouter, Depends, HTTPException, Query, Request
from fastapi.responses import PlainTextResponse
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import get_settings
from app.db import get_session
from app.integrations import whatsapp
from app.models import Notification

router = APIRouter(prefix="/webhooks", tags=["webhooks"])
log = logging.getLogger("flariane.webhooks")


@router.get("/whatsapp")
async def whatsapp_verify(
    mode: str = Query(alias="hub.mode"),
    token: str = Query(alias="hub.verify_token"),
    challenge: str = Query(alias="hub.challenge"),
) -> PlainTextResponse:
    s = get_settings()
    if mode == "subscribe" and s.whatsapp_verify_token and token == s.whatsapp_verify_token:
        return PlainTextResponse(challenge)
    raise HTTPException(status_code=403)


@router.post("/whatsapp")
async def whatsapp_webhook(request: Request, db: AsyncSession = Depends(get_session)) -> dict[str, bool]:
    body = await request.body()
    if not whatsapp.verify_signature(request.headers.get("x-hub-signature-256"), body, get_settings().whatsapp_app_secret):
        raise HTTPException(status_code=401)
    payload = json.loads(body)
    # Delivery receipts: update our notification rows. Inbound customer messages are handled by
    # the support inbox (WhatsApp Business app), not by the API.
    for entry in payload.get("entry", []):
        for change in entry.get("changes", []):
            for status in change.get("value", {}).get("statuses", []):
                note = await db.scalar(select(Notification).where(Notification.provider_message_id == status.get("id")))
                if note is not None:
                    note.status = str(status.get("status", "")).upper()[:16]
    await db.commit()
    return {"received": True}
