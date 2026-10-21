"""Payment state machine, driven only by verified Wave webhooks and reconciliation — never by
the success redirect or the client."""

import logging
from decimal import Decimal, InvalidOperation
from typing import Any

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import get_settings
from app.enums import OrderStatus, PaymentStatus, QuoteStatus
from app.errors import Conflict
from app.integrations import wave
from app.models import Order, Payment, Quote
from app.security.tokens import utcnow
from app.services import notify
from app.services.audit import audit
from app.services.orders import transition_order

log = logging.getLogger("flariane.payments")

P = PaymentStatus
PAYMENT_TRANSITIONS: dict[P, set[P]] = {
    P.INITIATED: {P.PENDING, P.FAILED},
    P.PENDING: {P.SUCCEEDED, P.FAILED, P.EXPIRED, P.HELD},
    # A late success after we marked it failed/expired still means money was taken.
    P.FAILED: {P.SUCCEEDED, P.HELD},
    P.EXPIRED: {P.SUCCEEDED, P.HELD},
    P.SUCCEEDED: {P.REFUNDED},
    P.HELD: {P.SUCCEEDED, P.REFUNDED},
    P.REFUNDED: set(),
}


async def transition_payment(db: AsyncSession, payment: Payment, to: P, *, actor: str, reason: str | None = None) -> None:
    current = P(payment.status)
    if to not in PAYMENT_TRANSITIONS[current]:
        raise Conflict("invalid_payment_transition", f"{current} -> {to}")
    payment.status = to
    if reason:
        payment.status_reason = reason
    await audit(
        db,
        actor_type="system" if ":" not in actor else actor.split(":")[0],
        actor_id=None,
        action="payment.status",
        entity="payment",
        entity_id=payment.id,
        before={"status": current},
        after={"status": to, "reason": reason, "via": actor},
    )


async def start_checkout(db: AsyncSession, payment_id: int, order_ref: str) -> Payment:
    """Create (or fetch, via idempotency key) the Wave checkout session for a payment row."""
    payment = await db.get(Payment, payment_id, with_for_update=True)
    assert payment is not None
    if payment.status == P.PENDING and payment.launch_url:
        return payment
    if payment.status != P.INITIATED:
        return payment
    s = get_settings()
    # Mobile-only: Wave returns to an API page that sends the customer back to the app,
    # which re-reads the order (the webhook, not this redirect, confirms payment).
    return_url = f"{s.api_base_url}/paiement/retour/{order_ref}"
    try:
        session = await wave.create_checkout_session(
            amount_xof=payment.amount_xof,
            client_reference=order_ref,
            success_url=f"{return_url}?statut=ok",
            error_url=f"{return_url}?statut=erreur",
            idempotency_key=payment.idempotency_key,
        )
    except Exception as exc:
        log.warning("wave checkout failed for payment %s: %s", payment.id, exc)
        await transition_payment(db, payment, P.FAILED, actor="system", reason="checkout_creation_failed")
        await db.commit()
        raise
    payment.checkout_session_id = session.id
    payment.launch_url = session.launch_url
    await transition_payment(db, payment, P.PENDING, actor="system")
    await db.commit()
    return payment


def _amount_matches(payment: Payment, amount: str, currency: str) -> bool:
    try:
        return currency == "XOF" and Decimal(amount) == Decimal(payment.amount_xof)
    except InvalidOperation:
        return False


async def apply_session_state(db: AsyncSession, payment: Payment, session: wave.CheckoutSession, *, source: str) -> bool:
    """Apply what Wave reports about a checkout session. `payment` must be locked. Returns True if changed."""
    status = P(payment.status)
    if session.payment_status == "succeeded":
        if status in (P.SUCCEEDED, P.HELD, P.REFUNDED):
            return False
        payment.provider_txn_id = session.transaction_id
        payment.confirmed_at = utcnow()
        order = await db.get(Order, payment.order_id, with_for_update=True)
        assert order is not None

        if not _amount_matches(payment, session.amount, session.currency):
            await transition_payment(db, payment, P.HELD, actor=source, reason=f"amount_mismatch:{session.amount} {session.currency}")
            notify.admins(db, "payment_held", order)
            return True

        quote = await db.get(Quote, payment.quote_id)
        if order.status != OrderStatus.AWAITING_PAYMENT or quote is None or quote.status != QuoteStatus.ACCEPTED:
            # Paid for an order that moved on (cancelled, already paid by another attempt…): refund manually.
            await transition_payment(db, payment, P.HELD, actor=source, reason=f"order_state:{order.status}")
            notify.admins(db, "payment_held", order)
            return True

        await transition_payment(db, payment, P.SUCCEEDED, actor=source)
        await transition_order(db, order, OrderStatus.PAID, actor=f"wave:{source}")
        notify.payment_received(db, order.customer_id, order)
        notify.admins(db, "payment_received", order)
        return True

    if session.payment_status == "cancelled" or source == "checkout.session.payment_failed":
        if status in (P.INITIATED, P.PENDING):
            await transition_payment(db, payment, P.FAILED, actor=source)
            return True
        return False

    if session.checkout_status == "expired" and status == P.PENDING:
        await transition_payment(db, payment, P.EXPIRED, actor=source)
        return True
    return False


async def apply_wave_event(db: AsyncSession, event: dict[str, Any]) -> None:
    data = event.get("data") or {}
    session_id = data.get("id")
    payment = await db.scalar(
        select(Payment).where(Payment.checkout_session_id == session_id).with_for_update()
    ) if session_id else None
    if payment is None:
        await audit(db, actor_type="system", actor_id=None, action="webhook.unmatched", after={"type": event.get("type")})
        return
    session = wave.CheckoutSession(
        id=session_id,
        launch_url=data.get("wave_launch_url", ""),
        checkout_status=data.get("checkout_status", ""),
        payment_status=data.get("payment_status"),
        amount=str(data.get("amount", "")),
        currency=data.get("currency", ""),
        client_reference=data.get("client_reference"),
        transaction_id=data.get("transaction_id"),
    )
    await apply_session_state(db, payment, session, source=str(event.get("type", "webhook")))


async def confirm_manual_payment(db: AsyncSession, order_id: int, transaction_ref: str | None, admin_id: int, ip: str | None) -> None:
    from app.errors import NotFound

    order = await db.get(Order, order_id, with_for_update=True)
    if order is None:
        raise NotFound()
    if order.status != OrderStatus.AWAITING_PAYMENT:
        raise Conflict("not_awaiting_payment", order.status)
    payment = await db.scalar(
        select(Payment).where(Payment.order_id == order.id, Payment.provider == "WAVE_QR", Payment.status == P.PENDING)
        .order_by(Payment.id.desc()).limit(1).with_for_update()
    )
    if payment is None:
        raise Conflict("no_pending_payment")
    payment.provider_txn_id, payment.confirmed_at = transaction_ref, utcnow()
    await transition_payment(db, payment, P.SUCCEEDED, actor=f"admin:{admin_id}", reason="confirmed_by_admin")
    await transition_order(db, order, OrderStatus.PAID, actor=f"admin:{admin_id}", actor_type="admin", actor_id=admin_id, ip=ip)
    await audit(db, actor_type="admin", actor_id=admin_id, action="payment.confirmed_manually", entity="payment", entity_id=payment.id,
                after={"amount_xof": payment.amount_xof, "transaction_ref": transaction_ref}, ip=ip)
    notify.payment_received(db, order.customer_id, order)
