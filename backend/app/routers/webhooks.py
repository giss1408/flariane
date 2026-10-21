"""Inbound webhooks. Signatures are verified on the raw bytes before any JSON parsing; payloads are
never declared as Pydantic body parameters here."""

import json
import logging

from fastapi import APIRouter, Depends, HTTPException, Query, Request
from fastapi.responses import PlainTextResponse
from sqlalchemy import func, select, update
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import get_settings
from app.db import get_session
from app.integrations import wave, whatsapp
from app.models import Notification, WebhookEvent
from app.services.audit import audit
from app.services.payments import apply_wave_event

router = APIRouter(prefix="/webhooks", tags=["webhooks"])
log = logging.getLogger("flariane.webhooks")


async def verified_wave_body(request: Request, db: AsyncSession = Depends(get_session)) -> bytes:
    body = await request.body()
    s = get_settings()
    if not wave.verify_signature(request.headers.get("wave-signature"), body, s.wave_webhook_secret, s.webhook_tolerance_seconds):
        await audit(db, actor_type="system", actor_id=None, action="webhook.signature_failed", after={"provider": "WAVE"},
                    ip=request.client.host if request.client else None)
        await db.commit()
        log.warning("wave webhook signature failure")
        raise HTTPException(status_code=401)
    return body


@router.post("/wave")
async def wave_webhook(body: bytes = Depends(verified_wave_body), db: AsyncSession = Depends(get_session)) -> dict[str, bool]:
    try:
        event = json.loads(body)
        event_id, event_type = str(event["id"]), str(event["type"])
    except (ValueError, KeyError, TypeError):
        raise HTTPException(status_code=400) from None

    # Dedupe row, payment update and audit log commit together. If processing fails, everything
    # rolls back (dedupe row included), we return 500, and Wave's retry is processed normally.
    row_id = await db.scalar(
        insert(WebhookEvent)
        .values(provider="WAVE", event_id=event_id, type=event_type)
        .on_conflict_do_nothing(index_elements=["provider", "event_id"])
        .returning(WebhookEvent.id)
    )
    if row_id is None:
        await db.rollback()
        return {"received": True, "duplicate": True}
    try:
        await apply_wave_event(db, event)
        await db.execute(update(WebhookEvent).where(WebhookEvent.id == row_id).values(processed_at=func.now()))
        await db.commit()
    except Exception:
        await db.rollback()
        log.exception("wave webhook processing failed")
        raise
    return {"received": True}


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
