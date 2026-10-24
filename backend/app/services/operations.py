"""Admin operations after payment: SHEIN purchase, store cancellations, refunds, shipments, pickups."""

from datetime import date
from decimal import Decimal

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.enums import ItemStatus, OrderStatus, PaymentStatus, RefundStatus, ShipmentStatus
from app.errors import BadRequest, Conflict, NotFound, TooManyRequests
from app.models import (
    Customer,
    Order,
    OrderItem,
    Payment,
    PickupCode,
    PickupPoint,
    Refund,
    Shipment,
    ShipmentOrder,
    StorePurchase,
)
from app.schemas import PurchaseIn
from app.security.crypto import constant_time_equals, keyed_hash, random_digits
from app.security.tokens import utcnow
from app.services import notify
from app.services.audit import audit
from app.services.orders import lock_order, transition_order
from app.services.payments import transition_payment
from app.services.pricing import to_xof
from app.services.quotes import accepted_quote
from app.services.settings import get_settings_map

MAX_PICKUP_ATTEMPTS = 5


async def _locked_order(db: AsyncSession, order_id: int) -> Order:
    order = await lock_order(db, id=order_id)
    if order is None:
        raise NotFound()
    return order


async def succeeded_payment(db: AsyncSession, order_id: int) -> Payment | None:
    return await db.scalar(
        select(Payment).where(Payment.order_id == order_id, Payment.status == PaymentStatus.SUCCEEDED)
    )


async def _refunded_so_far(db: AsyncSession, payment_id: int) -> int:
    # SUM() over BIGINT comes back as Decimal from Postgres.
    return int(await db.scalar(select(func.coalesce(func.sum(Refund.amount_xof), 0)).where(Refund.payment_id == payment_id)) or 0)


async def create_refund(
    db: AsyncSession, order: Order, payment: Payment, amount_xof: int, reason: str, admin_id: int | None
) -> Refund:
    if amount_xof <= 0:
        raise BadRequest("invalid_refund_amount")
    if await _refunded_so_far(db, payment.id) + amount_xof > payment.amount_xof:
        raise Conflict("refund_exceeds_payment")
    refund = Refund(
        payment_id=payment.id, order_id=order.id, amount_xof=amount_xof, reason=reason, created_by=admin_id
    )
    db.add(refund)
    await db.flush()
    await audit(
        db, actor_type="admin" if admin_id else "system", actor_id=admin_id, action="refund.created",
        entity="refund", entity_id=refund.id, after={"amount_xof": amount_xof, "reason": reason},
    )
    return refund


async def record_purchase(db: AsyncSession, order_id: int, data: PurchaseIn, admin_id: int, ip: str | None) -> dict[str, int | str]:
    order = await _locked_order(db, order_id)
    if order.status != OrderStatus.PAID:
        raise Conflict("order_not_paid", order.status)
    quote = await accepted_quote(db, order.id)
    payment = await succeeded_payment(db, order.id)
    if quote is None or payment is None:
        raise Conflict("no_accepted_paid_quote")

    line_items = {line.order_item_id: line for line in quote.lines}
    checked, refused = set(data.checked_item_ids), set(data.refused_item_ids)
    if not line_items:
        return await _record_cart_purchase(db, order, quote, payment, data, admin_id, ip)
    if checked & refused:
        raise BadRequest("item_both_checked_and_refused")
    if checked | refused != set(line_items):
        # Every line of the accepted quote must be ticked or marked refused: no silent skips.
        raise BadRequest("checklist_incomplete")

    settings = await get_settings_map(db)
    fx = {**settings["fx_rates"], **quote.fx_rates}
    if data.currency not in fx:
        raise BadRequest("missing_fx_rate", data.currency)
    paid_xof = to_xof(Decimal(data.paid_amount), data.currency, fx)
    quoted_items = sum(line_items[i].line_total_xof for i in checked)
    refund_xof = sum(line_items[i].line_total_xof for i in refused)

    if not checked:
        # SHEIN refused everything: nothing bought, refund the full payment.
        for item_id in refused:
            item = await db.get(OrderItem, item_id)
            assert item is not None
            item.item_status = ItemStatus.CANCELLED_BY_STORE
        await create_refund(db, order, payment, payment.amount_xof, "Tous les articles indisponibles", admin_id)
        await transition_order(db, order, OrderStatus.REFUND_PENDING, actor=f"admin:{admin_id}", actor_type="admin", actor_id=admin_id, ip=ip)
        notify.item_cancelled(db, order.customer_id, order, payment.amount_xof)
        return {"status": order.status, "paid_xof": 0, "quoted_items_xof": 0, "refund_xof": payment.amount_xof, "estimated_margin_xof": 0}

    buffer = Decimal(str(settings["price_increase_buffer_percent"])) / 100
    if paid_xof > quoted_items * (1 + buffer) and data.price_increase_decision is None:
        raise Conflict("price_increase_decision_required", f"paid={paid_xof} quoted={quoted_items}")

    for item_id in refused:
        item = await db.get(OrderItem, item_id)
        assert item is not None
        item.item_status = ItemStatus.CANCELLED_BY_STORE
    if refund_xof:
        await create_refund(db, order, payment, refund_xof, "Articles indisponibles chez le magasin", admin_id)
        notify.item_cancelled(db, order.customer_id, order, refund_xof)

    db.add(
        StorePurchase(
            order_id=order.id,
            store=order.store,
            store_order_ref=data.store_order_ref,
            paid_amount=data.paid_amount,
            currency=data.currency,
            paid_xof=paid_xof,
            price_increase_decision=data.price_increase_decision,
            purchased_by=admin_id,
        )
    )
    await transition_order(db, order, OrderStatus.PURCHASED, actor=f"admin:{admin_id}", actor_type="admin", actor_id=admin_id, ip=ip)
    margin = payment.amount_xof - refund_xof - paid_xof - quote.freight_xof - quote.customs_xof
    await audit(
        db, actor_type="admin", actor_id=admin_id, action="purchase.recorded", entity="order", entity_id=order.id,
        after={"store_order_ref": data.store_order_ref, "paid_xof": paid_xof, "decision": data.price_increase_decision},
        ip=ip,
    )
    return {"status": order.status, "paid_xof": paid_xof, "quoted_items_xof": quoted_items, "refund_xof": refund_xof, "estimated_margin_xof": margin}


async def _record_cart_purchase(db: AsyncSession, order: Order, quote, payment: Payment, data: PurchaseIn, admin_id: int, ip: str | None) -> dict[str, int | str]:  # type: ignore[no-untyped-def]
    """Cart-mode quote (screenshot + cart price): the whole cart is bought at once."""
    if data.checked_item_ids or data.refused_item_ids:
        raise BadRequest("no_lines_in_cart_quote")
    settings = await get_settings_map(db)
    fx = {**settings["fx_rates"], **quote.fx_rates, "XOF": "1"}
    if data.currency not in fx:
        raise BadRequest("missing_fx_rate", data.currency)
    paid_xof = to_xof(Decimal(data.paid_amount), data.currency, fx)
    buffer = Decimal(str(settings["price_increase_buffer_percent"])) / 100
    if paid_xof > quote.items_xof * (1 + buffer) and data.price_increase_decision is None:
        raise Conflict("price_increase_decision_required", f"paid={paid_xof} quoted={quote.items_xof}")
    db.add(StorePurchase(order_id=order.id, store=order.store, store_order_ref=data.store_order_ref, paid_amount=data.paid_amount,
                         currency=data.currency, paid_xof=paid_xof, price_increase_decision=data.price_increase_decision, purchased_by=admin_id))
    await transition_order(db, order, OrderStatus.PURCHASED, actor=f"admin:{admin_id}", actor_type="admin", actor_id=admin_id, ip=ip)
    await audit(db, actor_type="admin", actor_id=admin_id, action="purchase.recorded", entity="order", entity_id=order.id,
                after={"store_order_ref": data.store_order_ref, "paid_xof": paid_xof, "mode": "cart"}, ip=ip)
    margin = payment.amount_xof - paid_xof - quote.freight_xof - quote.customs_xof
    return {"status": order.status, "paid_xof": paid_xof, "quoted_items_xof": quote.items_xof, "refund_xof": 0, "estimated_margin_xof": margin}


async def cancel_item_by_store(db: AsyncSession, order_id: int, item_id: int, reason: str, admin_id: int, ip: str | None) -> Refund:
    """SHEIN cancelled a line after purchase: refund that line; refund everything if nothing is left."""
    order = await _locked_order(db, order_id)
    if order.status not in (OrderStatus.PURCHASED, OrderStatus.IN_TRANSIT):
        raise Conflict("order_state", order.status)
    quote = await accepted_quote(db, order.id)
    payment = await succeeded_payment(db, order.id)
    item = await db.get(OrderItem, item_id)
    if quote is None or payment is None or item is None or item.order_id != order.id:
        raise NotFound()
    if item.item_status != ItemStatus.OK:
        raise Conflict("item_already_cancelled")
    line = next((ln for ln in quote.lines if ln.order_item_id == item.id), None)
    if line is None:
        raise NotFound()
    item.item_status = ItemStatus.CANCELLED_BY_STORE

    others = (
        await db.scalars(
            select(OrderItem).where(
                OrderItem.id.in_([ln.order_item_id for ln in quote.lines if ln.order_item_id != item.id]),
                OrderItem.item_status == ItemStatus.OK,
            )
        )
    ).all()
    if others:
        refund = await create_refund(db, order, payment, line.line_total_xof, reason, admin_id)
    else:
        already = await _refunded_so_far(db, payment.id)
        refund = await create_refund(db, order, payment, payment.amount_xof - already, reason, admin_id)
        if order.status == OrderStatus.PURCHASED:
            await transition_order(db, order, OrderStatus.REFUND_PENDING, actor=f"admin:{admin_id}", actor_type="admin", actor_id=admin_id, ip=ip)
    notify.item_cancelled(db, order.customer_id, order, refund.amount_xof)
    return refund


async def complete_refund(db: AsyncSession, refund_id: int, external_ref: str, admin_id: int, ip: str | None) -> Refund:
    """Mark a refund as paid out (done in the Wave Business app). SUPER_ADMIN only, enforced by the route."""
    refund = await db.get(Refund, refund_id, with_for_update=True)
    if refund is None:
        raise NotFound()
    if refund.status != RefundStatus.PENDING:
        raise Conflict("refund_not_pending")
    refund.status, refund.completed_by, refund.completed_at = RefundStatus.COMPLETED, admin_id, utcnow()
    refund.external_ref = external_ref
    await audit(db, actor_type="admin", actor_id=admin_id, action="refund.completed", entity="refund", entity_id=refund.id,
                after={"external_ref": external_ref, "amount_xof": refund.amount_xof}, ip=ip)

    order = await _locked_order(db, refund.order_id)
    payment = await db.get(Payment, refund.payment_id, with_for_update=True)
    assert payment is not None
    completed = int(await db.scalar(
        select(func.coalesce(func.sum(Refund.amount_xof), 0)).where(
            Refund.payment_id == payment.id, Refund.status == RefundStatus.COMPLETED
        )
    ) or 0)
    if completed >= payment.amount_xof and payment.status in (PaymentStatus.SUCCEEDED, PaymentStatus.HELD):
        await transition_payment(db, payment, PaymentStatus.REFUNDED, actor=f"admin:{admin_id}")
    pending = await db.scalar(
        select(func.count()).select_from(Refund).where(Refund.order_id == order.id, Refund.status == RefundStatus.PENDING)
    )
    if order.status == OrderStatus.REFUND_PENDING and not pending:
        await transition_order(db, order, OrderStatus.REFUNDED, actor=f"admin:{admin_id}", actor_type="admin", actor_id=admin_id, ip=ip)
    notify.refund_completed(db, order.customer_id, order, refund.amount_xof)
    return refund


async def refund_held_payment(db: AsyncSession, payment_id: int, admin_id: int, ip: str | None) -> Refund:
    """A HELD payment (mismatch or paid for a moved-on order) is refunded in full."""
    payment = await db.get(Payment, payment_id, with_for_update=True)
    if payment is None:
        raise NotFound()
    if payment.status != PaymentStatus.HELD:
        raise Conflict("payment_not_held")
    order = await _locked_order(db, payment.order_id)
    return await create_refund(db, order, payment, payment.amount_xof - await _refunded_so_far(db, payment.id), "Paiement à rembourser", admin_id)


# ---------------------------------------------------------------- shipments


async def ensure_departure_shipment(db: AsyncSession, departure: date, order_deadline: date | None, admin_id: int) -> Shipment:
    """One shipment per "prochain départ": created when the date is set, deadline kept in sync."""
    shipment = await db.scalar(select(Shipment).where(Shipment.departure_date == departure).with_for_update())
    if shipment is None:
        shipment = Shipment(label=f"Départ du {departure:%d/%m/%Y}", status=ShipmentStatus.OPEN, departure_date=departure)
        db.add(shipment)
        await db.flush()
        await audit(db, actor_type="admin", actor_id=admin_id, action="shipment.created", entity="shipment", entity_id=shipment.id,
                    after={"departure_date": departure.isoformat()})
    shipment.order_deadline = order_deadline
    return shipment


async def add_orders_to_shipment(db: AsyncSession, shipment_id: int, order_ids: list[int], admin_id: int) -> None:
    shipment = await db.get(Shipment, shipment_id, with_for_update=True)
    if shipment is None:
        raise NotFound()
    if shipment.status != ShipmentStatus.OPEN:
        raise Conflict("shipment_not_open")
    if shipment.departure_date is None:
        # Orders only go into a real departure (one set as "prochain départ").
        raise Conflict("shipment_not_a_departure")
    for oid in order_ids:
        order = await db.get(Order, oid)
        if order is None or order.status != OrderStatus.PURCHASED:
            raise Conflict("order_not_purchased", str(oid))
        if await db.scalar(select(ShipmentOrder).where(ShipmentOrder.order_id == oid)):
            raise Conflict("order_already_in_shipment", str(oid))
        db.add(ShipmentOrder(shipment_id=shipment.id, order_id=oid))
    await audit(db, actor_type="admin", actor_id=admin_id, action="shipment.orders_added", entity="shipment",
                entity_id=shipment.id, after={"order_ids": order_ids})


async def remove_order_from_shipment(db: AsyncSession, shipment_id: int, order_id: int, admin_id: int) -> None:
    shipment = await db.get(Shipment, shipment_id, with_for_update=True)
    if shipment is None:
        raise NotFound()
    if shipment.status != ShipmentStatus.OPEN:
        raise Conflict("shipment_not_open")
    link = await db.get(ShipmentOrder, (shipment_id, order_id))
    if link is None:
        raise NotFound()
    await db.delete(link)
    await audit(db, actor_type="admin", actor_id=admin_id, action="shipment.order_removed", entity="shipment",
                entity_id=shipment.id, after={"order_id": order_id})


async def _shipment_orders(db: AsyncSession, shipment_id: int) -> list[Order]:
    return list(
        (
            await db.scalars(
                select(Order)
                .join(ShipmentOrder, ShipmentOrder.order_id == Order.id)
                .where(ShipmentOrder.shipment_id == shipment_id)
                .with_for_update(of=Order)
            )
        ).all()
    )


async def depart_shipment(
    db: AsyncSession, shipment_id: int, tracking_ref: str | None, weight_kg: Decimal | None, cost_xof: int | None, admin_id: int, ip: str | None
) -> Shipment:
    shipment = await db.get(Shipment, shipment_id, with_for_update=True)
    if shipment is None:
        raise NotFound()
    if shipment.status != ShipmentStatus.OPEN:
        raise Conflict("shipment_not_open")
    orders = await _shipment_orders(db, shipment.id)
    if not orders:
        raise BadRequest("shipment_empty")
    shipment.status, shipment.departed_at = ShipmentStatus.IN_TRANSIT, utcnow()
    shipment.tracking_ref, shipment.weight_kg, shipment.cost_xof = tracking_ref, weight_kg, cost_xof
    for order in orders:
        if order.status == OrderStatus.PURCHASED:
            await transition_order(db, order, OrderStatus.IN_TRANSIT, actor=f"admin:{admin_id}", actor_type="admin", actor_id=admin_id, ip=ip)
    return shipment


async def arrive_shipment(db: AsyncSession, shipment_id: int, admin_id: int, ip: str | None) -> Shipment:
    shipment = await db.get(Shipment, shipment_id, with_for_update=True)
    if shipment is None:
        raise NotFound()
    if shipment.status != ShipmentStatus.IN_TRANSIT:
        raise Conflict("shipment_not_in_transit")
    shipment.status, shipment.arrived_at = ShipmentStatus.ARRIVED, utcnow()
    for order in await _shipment_orders(db, shipment.id):
        if order.status == OrderStatus.IN_TRANSIT:
            await transition_order(db, order, OrderStatus.ARRIVED, actor=f"admin:{admin_id}", actor_type="admin", actor_id=admin_id, ip=ip)
    return shipment


# ---------------------------------------------------------------- pickups


def _pickup_hash(order_id: int, code: str) -> str:
    return keyed_hash(f"{order_id}:{code}", "pickup")


async def mark_ready_for_pickup(db: AsyncSession, order_id: int, pickup_point_id: int | None, admin_id: int, ip: str | None) -> str:
    """Generates a fresh 6-digit pickup code and sends it to the customer on WhatsApp.
    Calling it again on a READY order re-issues the code (lost message)."""
    order = await _locked_order(db, order_id)
    if order.status not in (OrderStatus.ARRIVED, OrderStatus.READY_FOR_PICKUP):
        raise Conflict("order_not_arrived", order.status)
    if pickup_point_id is not None:
        order.pickup_point_id = pickup_point_id
    point = await db.get(PickupPoint, order.pickup_point_id) if order.pickup_point_id else None
    if point is None or not point.active:
        raise BadRequest("pickup_point_required")
    code = random_digits(6)
    row = await db.get(PickupCode, order.id)
    if row is None:
        db.add(PickupCode(order_id=order.id, code_hash=_pickup_hash(order.id, code)))
    else:
        row.code_hash, row.failed_attempts, row.used_at = _pickup_hash(order.id, code), 0, None
    if order.status == OrderStatus.ARRIVED:
        await transition_order(db, order, OrderStatus.READY_FOR_PICKUP, actor=f"admin:{admin_id}", actor_type="admin", actor_id=admin_id, ip=ip)
    customer = await db.get(Customer, order.customer_id)
    assert customer is not None
    notify.ready_for_pickup(db, customer, order, point, code)
    # Returned once so the admin can send it from their own WhatsApp; only the hash is stored.
    return code


async def confirm_pickup(db: AsyncSession, order_id: int, code: str, admin_id: int, ip: str | None) -> None:
    order = await _locked_order(db, order_id)
    if order.status != OrderStatus.READY_FOR_PICKUP:
        raise Conflict("order_not_ready", order.status)
    row = await db.get(PickupCode, order.id, with_for_update=True)
    if row is None or row.used_at is not None:
        raise Conflict("no_pickup_code")
    if row.failed_attempts >= MAX_PICKUP_ATTEMPTS:
        raise TooManyRequests("pickup_code_locked", "Renvoyer un nouveau code au client")
    if not constant_time_equals(row.code_hash, _pickup_hash(order.id, code)):
        row.failed_attempts += 1
        await audit(db, actor_type="admin", actor_id=admin_id, action="pickup.code_failed", entity="order", entity_id=order.id, ip=ip)
        await db.commit()
        raise BadRequest("wrong_pickup_code")
    row.used_at = utcnow()
    await transition_order(db, order, OrderStatus.PICKED_UP, actor=f"admin:{admin_id}", actor_type="admin", actor_id=admin_id, ip=ip)

