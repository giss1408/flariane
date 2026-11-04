"""Payment state machine. Payments are manual: the customer pays one of our mobile-money numbers,
sends the screenshot, and an admin confirms it."""

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.enums import OrderStatus, PaymentStatus
from app.errors import Conflict
from app.models import Order, Payment
from app.security.tokens import utcnow
from app.services import notify
from app.services.audit import audit
from app.services.orders import transition_order

# Paid by the customer outside our systems, confirmed by an admin (WAVE_QR kept for older rows).
MANUAL_PROVIDERS = ("MANUAL", "WAVE_QR")

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


async def confirm_manual_payment(db: AsyncSession, order_id: int, transaction_ref: str | None, admin_id: int, ip: str | None) -> None:
    from app.errors import NotFound

    order = await db.get(Order, order_id, with_for_update=True)
    if order is None:
        raise NotFound()
    if order.status != OrderStatus.AWAITING_PAYMENT:
        raise Conflict("not_awaiting_payment", order.status)
    payment = await db.scalar(
        select(Payment).where(Payment.order_id == order.id, Payment.provider.in_(MANUAL_PROVIDERS), Payment.status == P.PENDING)
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
