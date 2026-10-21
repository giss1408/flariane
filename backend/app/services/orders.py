import secrets

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.enums import OrderStatus as S
from app.errors import Conflict
from app.models import Order, OrderStatusHistory
from app.services.audit import audit
from app.security.tokens import utcnow

# The only allowed order transitions. Anything else is a bug or an attack and is refused.
TRANSITIONS: dict[S, set[S]] = {
    S.QUOTE_REQUESTED: {S.QUOTED, S.CANCELLED},
    S.QUOTED: {S.AWAITING_PAYMENT, S.QUOTE_REQUESTED, S.CANCELLED},
    S.AWAITING_PAYMENT: {S.PAID, S.QUOTE_REQUESTED, S.CANCELLED},
    S.PAID: {S.PURCHASED, S.REFUND_PENDING},
    S.PURCHASED: {S.IN_TRANSIT, S.REFUND_PENDING},
    S.IN_TRANSIT: {S.ARRIVED},
    S.ARRIVED: {S.READY_FOR_PICKUP},
    S.READY_FOR_PICKUP: {S.PICKED_UP},
    S.PICKED_UP: set(),
    S.CANCELLED: set(),
    S.REFUND_PENDING: {S.REFUNDED},
    S.REFUNDED: set(),
}

# Unambiguous alphabet for references read aloud or typed on a phone (no 0/O, 1/I/L).
_REF_ALPHABET = "23456789ABCDEFGHJKMNPQRSTUVWXYZ"


def new_public_ref() -> str:
    return "FLR-" + "".join(secrets.choice(_REF_ALPHABET) for _ in range(5))


async def unique_public_ref(db: AsyncSession) -> str:
    for _ in range(10):
        ref = new_public_ref()
        if await db.scalar(select(Order.id).where(Order.public_ref == ref)) is None:
            return ref
    raise RuntimeError("could not generate a unique order reference")


async def transition_order(
    db: AsyncSession,
    order: Order,
    to: S,
    *,
    actor: str,
    actor_type: str = "system",
    actor_id: int | None = None,
    ip: str | None = None,
) -> None:
    """Single entry point for order status changes: validates, records history and audit log."""
    current = S(order.status)
    if to not in TRANSITIONS[current]:
        raise Conflict("invalid_transition", f"{current} -> {to}")
    order.status = to
    order.status_changed_at = utcnow()
    db.add(OrderStatusHistory(order_id=order.id, from_status=current, to_status=to, actor=actor))
    await audit(
        db,
        actor_type=actor_type,
        actor_id=actor_id,
        action="order.status",
        entity="order",
        entity_id=order.id,
        before={"status": current},
        after={"status": to},
        ip=ip,
    )


async def lock_order(db: AsyncSession, **filters: object) -> Order | None:
    stmt = select(Order).with_for_update()
    for key, value in filters.items():
        stmt = stmt.where(getattr(Order, key) == value)
    return await db.scalar(stmt)
