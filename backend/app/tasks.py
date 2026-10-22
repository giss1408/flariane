"""Background work: notifications, quote expiry, payment reconciliation.

Each task is a plain async function taking only JSON-serialisable arguments. `dispatch` runs it
through Celery (prod), as an asyncio task (dev) or records it (tests). Call `dispatch` via
`db.on_commit` so nothing is sent for a transaction that rolls back.
"""

import asyncio
import logging
from collections.abc import Awaitable, Callable
from datetime import timedelta
from typing import Any

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from app import db as db_module
from app.config import get_settings
from app.enums import PaymentStatus, QuoteStatus
from app.integrations import push, whatsapp
from app.models import AdminDevice, AdminUser, Customer, Notification, Payment, Quote
from app.security.crypto import decrypt
from app.security.tokens import utcnow

log = logging.getLogger("flariane.tasks")

# Overridden by the Celery worker with a NullPool engine (one event loop per task).
session_factory: async_sessionmaker[AsyncSession] = db_module.SessionLocal

RECORDED: list[tuple[str, dict[str, Any]]] = []
_background: set[asyncio.Task[Any]] = set()


async def send_customer_whatsapp(customer_id: int, template: str, params: list[str]) -> None:
    async with session_factory() as db:
        customer = await db.get(Customer, customer_id)
        if customer is None or customer.phone_enc is None:
            return
        note = Notification(channel="whatsapp", customer_id=customer_id, template=template)
        db.add(note)
        try:
            note.provider_message_id = await whatsapp.send_template(
                decrypt(customer.phone_enc), template, params, customer.locale or "fr"
            )
            note.status = "SENT"
        except Exception as exc:  # recorded and retried by Celery
            note.status, note.error = "FAILED", str(exc)[:500]
            await db.commit()
            raise
        await db.commit()


ADMIN_EVENTS = {
    "quote_requested": ("Nouvelle demande de devis", "Commande {ref} à chiffrer"),
    "change_requested": ("Modification demandée", "Commande {ref} : nouveau devis à faire"),
    "quote_accepted": ("Devis accepté", "Commande {ref} : en attente de paiement"),
    "payment_received": ("Paiement reçu", "Commande {ref} à acheter"),
    "payment_held": ("Paiement à vérifier", "Commande {ref} : montant incohérent"),
    "customer_registered": ("Nouvelle inscription", "Un numéro est à vérifier ({ref})"),
    "payment_declared": ("Paiement Wave déclaré", "Commande {ref} : vérifie ton Wave et confirme"),
}


async def push_admins(event: str, order_ref: str, order_id: int) -> None:
    title, body = ADMIN_EVENTS[event]
    async with session_factory() as db:
        devices = (
            await db.scalars(
                select(AdminDevice)
                .join(AdminUser, AdminUser.id == AdminDevice.admin_user_id)
                .where(
                    AdminDevice.push_token.is_not(None),
                    AdminDevice.approved_at.is_not(None),
                    AdminDevice.revoked_at.is_(None),
                    AdminUser.active.is_(True),
                )
            )
        ).all()
        for device in devices:
            note = Notification(channel="push", admin_device_id=device.id, template=event)
            db.add(note)
            try:
                note.provider_message_id = await push.send_push(
                    device.push_token or "",
                    title,
                    body.format(ref=order_ref),
                    {"event": event, "order_id": str(order_id), "ref": order_ref},
                )
                note.status = "SENT"
            except Exception as exc:
                note.status, note.error = "FAILED", str(exc)[:500]
        await db.commit()


async def expire_quotes() -> int:
    """Mark SENT quotes past their expiry as EXPIRED. The order stays QUOTED until the customer asks again."""
    async with session_factory() as db:
        quotes = (
            await db.scalars(
                select(Quote)
                .where(Quote.status == QuoteStatus.SENT, Quote.expires_at <= utcnow())
                .with_for_update(skip_locked=True)
            )
        ).all()
        for q in quotes:
            q.status = QuoteStatus.EXPIRED
        await db.commit()
        return len(quotes)


async def reconcile_payments() -> dict[str, int]:
    """Ask Wave about payments still pending after 10 minutes, in case a webhook was lost."""
    from app.integrations import wave
    from app.services.payments import apply_session_state

    counts = {"checked": 0, "changed": 0}
    async with session_factory() as db:
        ids = (
            await db.scalars(
                select(Payment.id).where(
                    Payment.status == PaymentStatus.PENDING,
                    Payment.created_at <= utcnow() - timedelta(minutes=10),
                    Payment.checkout_session_id.is_not(None),
                )
            )
        ).all()
    for pid in ids:
        async with session_factory() as db:
            payment = await db.get(Payment, pid, with_for_update=True)
            if payment is None or payment.status != PaymentStatus.PENDING:
                continue
            try:
                session = await wave.get_checkout_session(payment.checkout_session_id or "")
            except Exception:
                log.exception("reconcile: wave lookup failed for payment %s", pid)
                continue
            counts["checked"] += 1
            if await apply_session_state(db, payment, session, source="reconcile"):
                counts["changed"] += 1
            await db.commit()
    return counts


TASKS: dict[str, Callable[..., Awaitable[Any]]] = {
    "send_customer_whatsapp": send_customer_whatsapp,
    "push_admins": push_admins,
    "expire_quotes": expire_quotes,
    "reconcile_payments": reconcile_payments,
}


def dispatch(name: str, **kwargs: Any) -> None:
    mode = get_settings().task_mode
    if mode == "record":
        RECORDED.append((name, kwargs))
    elif mode == "celery":
        from app.worker import celery_app

        celery_app.send_task(f"flariane.{name}", kwargs=kwargs)
    else:
        task = asyncio.get_running_loop().create_task(TASKS[name](**kwargs))
        _background.add(task)
        task.add_done_callback(_background.discard)
