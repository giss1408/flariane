"""Builds notification parameters and dispatches them after the transaction commits."""

from datetime import datetime

from sqlalchemy.ext.asyncio import AsyncSession

from app.db import on_commit
from app.models import Customer, Order, PickupPoint, Quote
from app.tasks import dispatch


def fcfa(amount: int) -> str:
    return f"{amount:,}".replace(",", " ")


def short_datetime(dt: datetime) -> str:
    # Abidjan is UTC+0 all year.
    return dt.strftime("%d/%m à %Hh%M")


def first_name(customer: Customer) -> str:
    return (customer.display_name or "").split(" ")[0] or "client"


def _whatsapp(db: AsyncSession, customer_id: int, template: str, params: list[str]) -> None:
    on_commit(db, lambda: dispatch("send_customer_whatsapp", customer_id=customer_id, template=template, params=params))


def admins(db: AsyncSession, event: str, order: Order) -> None:
    ref, oid = order.public_ref, order.id
    on_commit(db, lambda: dispatch("push_admins", event=event, order_ref=ref, order_id=oid))


def quote_ready(db: AsyncSession, customer: Customer, order: Order, quote: Quote) -> None:
    assert quote.expires_at is not None
    _whatsapp(
        db,
        customer.id,
        "quote_ready",
        [first_name(customer), order.public_ref, fcfa(quote.total_xof), short_datetime(quote.expires_at)],
    )


def payment_received(db: AsyncSession, customer_id: int, order: Order) -> None:
    _whatsapp(db, customer_id, "payment_received", [order.public_ref])


def ready_for_pickup(db: AsyncSession, customer: Customer, order: Order, point: PickupPoint, code: str) -> None:
    _whatsapp(
        db,
        customer.id,
        "order_ready_pickup",
        [first_name(customer), order.public_ref, f"{point.name}, {point.address}", point.opening_hours, code],
    )


def item_cancelled(db: AsyncSession, customer_id: int, order: Order, refund_xof: int) -> None:
    _whatsapp(db, customer_id, "item_cancelled", [order.public_ref, fcfa(refund_xof)])


def refund_completed(db: AsyncSession, customer_id: int, order: Order, amount_xof: int) -> None:
    _whatsapp(db, customer_id, "refund_completed", [order.public_ref, fcfa(amount_xof)])
