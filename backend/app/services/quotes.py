"""Versioned quotes: admin drafts and sends; the customer accepts or asks for changes.

Rules:
- Sent quotes are immutable. A fix is a new version; the previous SENT one becomes SUPERSEDED.
- Only the latest SENT, unexpired version can be accepted, under a row lock on the order.
- Totals are computed here, never taken from a client.
"""

from datetime import timedelta
from decimal import Decimal
from typing import Any

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.enums import OrderStatus, PaymentStatus, QuoteStatus
from app.errors import BadRequest, Conflict, NotFound
from app.models import Customer, Order, OrderAttachment, OrderItem, Payment, Quote, QuoteChangeRequest, QuoteLine
from app.schemas import ChangeRequestIn, QuoteDraftIn
from app.security.tokens import utcnow
from app.services import notify
from app.services.audit import audit
from app.services.links import extract_shein_urls, product_id_from_url, store_of
from app.services.orders import lock_order, transition_order
from app.services.pricing import LineInput, compute_quote, default_customs, default_freight, to_xof
from app.services.settings import get_settings_map

ACTIVE_PAYMENT = (PaymentStatus.INITIATED, PaymentStatus.PENDING, PaymentStatus.SUCCEEDED, PaymentStatus.HELD)


async def latest_quote(db: AsyncSession, order_id: int, *, with_lines: bool = False) -> Quote | None:
    stmt = select(Quote).where(Quote.order_id == order_id).order_by(Quote.version.desc()).limit(1)
    if with_lines:
        stmt = stmt.options(selectinload(Quote.lines))
    return await db.scalar(stmt)


async def latest_non_draft(db: AsyncSession, order_id: int) -> Quote | None:
    return await db.scalar(
        select(Quote)
        .where(Quote.order_id == order_id, Quote.status != QuoteStatus.DRAFT)
        .order_by(Quote.version.desc())
        .limit(1)
        .options(selectinload(Quote.lines))
    )


async def accepted_quote(db: AsyncSession, order_id: int) -> Quote | None:
    return await db.scalar(
        select(Quote)
        .where(Quote.order_id == order_id, Quote.status == QuoteStatus.ACCEPTED)
        .options(selectinload(Quote.lines))
    )


# ---------------------------------------------------------------- admin side


async def save_draft(db: AsyncSession, order_id: int, data: QuoteDraftIn, admin_id: int) -> tuple[Quote, dict[str, Any]]:
    order = await lock_order(db, id=order_id)
    if order is None:
        raise NotFound()
    if order.status not in (OrderStatus.QUOTE_REQUESTED, OrderStatus.QUOTED):
        raise Conflict("order_not_quotable", order.status)

    settings = await get_settings_map(db)
    if data.cart_price_xof is not None or data.cart_price is not None:
        return await _save_cart_draft(db, order, data, admin_id, settings)
    if not data.items:
        raise BadRequest("empty_quote")
    fx_rates = {k: str(v) for k, v in (data.fx_rates or {}).items()} or dict(settings["fx_rates"])
    for item in data.items:
        if item.source_currency not in fx_rates:
            raise BadRequest("missing_fx_rate", item.source_currency)

    # Upsert the order's items: lines in the payload stay active, the others are deactivated.
    existing = {i.id: i for i in (await db.scalars(select(OrderItem).where(OrderItem.order_id == order.id))).all()}
    kept: list[OrderItem] = []
    for item in data.items:
        if item.id is not None:
            row = existing.get(item.id)
            if row is None:
                raise BadRequest("unknown_item", str(item.id))
        else:
            row = OrderItem(order_id=order.id)
            db.add(row)
        row.title, row.size, row.color, row.qty = item.title, item.size, item.color, item.qty
        row.source_price, row.source_currency = item.source_price, item.source_currency
        row.source_url = item.source_url
        row.source_product_id = product_id_from_url(item.source_url)
        row.active = True
        kept.append(row)
    kept_ids = {id(r) for r in kept}
    for row in existing.values():
        if id(row) not in kept_ids:
            row.active = False
    await db.flush()

    lines_in = [LineInput(i.qty, Decimal(i.source_price), i.source_currency) for i in data.items]
    items_only = compute_quote(lines_in, fx_rates, freight_xof=0, customs_xof=0, fee_xof=0)
    freight = (
        data.freight_xof
        if data.freight_xof is not None
        else default_freight(sum(i.qty for i in data.items), int(settings["freight_per_item_xof"]))
    )
    customs = (
        data.customs_xof
        if data.customs_xof is not None
        else default_customs(items_only.items_xof, settings["customs_rate_percent"])
    )
    amounts = compute_quote(lines_in, fx_rates, freight_xof=freight, customs_xof=customs, fee_xof=data.fee_xof)

    latest = await latest_quote(db, order.id)
    if latest is not None and latest.status == QuoteStatus.DRAFT:
        quote = latest
        await db.refresh(quote, ["lines"])
        quote.lines.clear()
    else:
        quote = Quote(
            order_id=order.id,
            version=(latest.version + 1) if latest else 1,
            status=QuoteStatus.DRAFT,
            created_by=admin_id,
            lines=[],
        )
        db.add(quote)
    quote.items_xof, quote.freight_xof, quote.customs_xof = amounts.items_xof, freight, customs
    quote.fee_xof, quote.total_xof = amounts.fee_xof, amounts.total_xof
    quote.fx_rates, quote.admin_note = fx_rates, data.admin_note
    validity = data.validity_hours or int(settings["quote_validity_hours"])
    quote.expires_at = None
    for pos, (row, line_amt) in enumerate(zip(kept, amounts.lines, strict=True)):
        quote.lines.append(
            QuoteLine(
                order_item_id=row.id,
                position=pos,
                title=row.title,
                size=row.size,
                color=row.color,
                qty=row.qty,
                source_price=row.source_price,
                source_currency=row.source_currency,
                unit_price_xof=line_amt.unit_price_xof,
                line_total_xof=line_amt.line_total_xof,
            )
        )
    await db.flush()
    quote.validity_hours = validity
    meta = {"min_fee_xof": int(settings["min_fee_xof"])}
    return quote, meta


async def _draft_for(db: AsyncSession, order: Order, admin_id: int) -> Quote:
    """The open draft, or a new version. A new version reuses the previous cart screenshot."""
    latest = await latest_quote(db, order.id)
    if latest is not None and latest.status == QuoteStatus.DRAFT:
        await db.refresh(latest, ["lines"])
        latest.lines.clear()
        return latest
    quote = Quote(order_id=order.id, version=(latest.version + 1) if latest else 1, status=QuoteStatus.DRAFT, created_by=admin_id, lines=[])
    db.add(quote)
    await db.flush()
    if latest is not None:
        prev = await quote_screenshot(db, latest.id)
        if prev is not None:
            db.add(OrderAttachment(order_id=order.id, kind="QUOTE_SCREENSHOT", quote_id=quote.id,
                                   storage_key=prev.storage_key, content_type=prev.content_type))
    return quote


async def _save_cart_draft(db: AsyncSession, order: Order, data: QuoteDraftIn, admin_id: int, settings: dict[str, Any]) -> tuple[Quote, dict[str, Any]]:
    quote = await _draft_for(db, order, admin_id)
    if data.cart_price is not None:
        fx = {**settings["fx_rates"], "XOF": "1"}
        if data.cart_currency not in fx:
            raise BadRequest("missing_fx_rate", data.cart_currency)
        cart_xof = to_xof(Decimal(data.cart_price), data.cart_currency, fx)
        quote.cart_source_amount, quote.cart_source_currency = Decimal(data.cart_price), data.cart_currency
    else:
        cart_xof = data.cart_price_xof or 0
        quote.cart_source_amount, quote.cart_source_currency = Decimal(cart_xof), "XOF"
    freight = data.freight_xof if data.freight_xof is not None else int(settings["freight_default_xof"])
    customs = data.customs_xof or 0
    quote.items_xof, quote.freight_xof, quote.customs_xof, quote.fee_xof = cart_xof, freight, customs, data.fee_xof
    quote.total_xof = cart_xof + freight + customs + data.fee_xof
    quote.fx_rates, quote.admin_note, quote.expires_at = dict(settings["fx_rates"]), data.admin_note, None
    quote.validity_hours = data.validity_hours or int(settings["quote_validity_hours"])
    await db.flush()
    return quote, {"min_fee_xof": int(settings["min_fee_xof"])}


async def quote_screenshot(db: AsyncSession, quote_id: int) -> OrderAttachment | None:
    return await db.scalar(
        select(OrderAttachment)
        .where(OrderAttachment.quote_id == quote_id, OrderAttachment.kind == "QUOTE_SCREENSHOT")
        .order_by(OrderAttachment.id.desc())
        .limit(1)
    )


async def attach_quote_screenshot(db: AsyncSession, order_id: int, storage_key: str, content_type: str) -> Quote:
    order = await lock_order(db, id=order_id)
    if order is None:
        raise NotFound()
    quote = await latest_quote(db, order.id)
    if quote is None or quote.status != QuoteStatus.DRAFT:
        raise Conflict("no_draft")
    db.add(OrderAttachment(order_id=order.id, kind="QUOTE_SCREENSHOT", quote_id=quote.id, storage_key=storage_key, content_type=content_type))
    return quote


async def send_quote(db: AsyncSession, order_id: int, version: int, admin_id: int, confirm_low_fee: bool, ip: str | None) -> Quote:
    order = await lock_order(db, id=order_id)
    if order is None:
        raise NotFound()
    quote = await latest_quote(db, order.id, with_lines=True)
    if quote is None or quote.version != version or quote.status != QuoteStatus.DRAFT:
        raise Conflict("draft_outdated")
    cart_mode = not quote.lines
    if cart_mode and (quote.items_xof <= 0 or await quote_screenshot(db, quote.id) is None):
        raise BadRequest("cart_quote_incomplete", "Capture du panier et prix SHEIN requis")
    if order.status not in (OrderStatus.QUOTE_REQUESTED, OrderStatus.QUOTED):
        raise Conflict("order_not_quotable", order.status)
    settings = await get_settings_map(db)
    if not cart_mode and quote.fee_xof < int(settings["min_fee_xof"]) and not confirm_low_fee:
        raise Conflict("fee_below_minimum", str(settings["min_fee_xof"]))

    now = utcnow()
    previous = (
        await db.scalars(select(Quote).where(Quote.order_id == order.id, Quote.status == QuoteStatus.SENT))
    ).all()
    for p in previous:
        p.status = QuoteStatus.SUPERSEDED
    quote.status, quote.sent_at = QuoteStatus.SENT, now
    quote.expires_at = now + timedelta(hours=quote.validity_hours)
    order.total_xof = quote.total_xof
    if order.status == OrderStatus.QUOTE_REQUESTED:
        await transition_order(db, order, OrderStatus.QUOTED, actor=f"admin:{admin_id}", actor_type="admin", actor_id=admin_id, ip=ip)
    await audit(
        db,
        actor_type="admin",
        actor_id=admin_id,
        action="quote.sent",
        entity="quote",
        entity_id=quote.id,
        after={"version": quote.version, "total_xof": quote.total_xof, "fee_xof": quote.fee_xof},
        ip=ip,
    )
    customer = await db.get(Customer, order.customer_id)
    assert customer is not None
    notify.quote_ready(db, customer, order, quote)
    return quote


# ---------------------------------------------------------------- customer side


async def _customer_order_locked(db: AsyncSession, customer_id: int, ref: str) -> Order:
    order = await lock_order(db, public_ref=ref, customer_id=customer_id)
    if order is None:
        raise NotFound()
    return order


async def _active_payment(db: AsyncSession, quote_id: int) -> Payment | None:
    return await db.scalar(
        select(Payment)
        .where(Payment.quote_id == quote_id, Payment.status.in_(ACTIVE_PAYMENT))
        .order_by(Payment.id.desc())
        .limit(1)
    )


async def accept_quote(
    db: AsyncSession, customer_id: int, ref: str, version: int, sizes_confirmed: bool, ip: str | None
) -> Payment:
    """Accept a quote and create the payment row. The caller creates the Wave session after commit."""
    if not sizes_confirmed:
        raise BadRequest("sizes_not_confirmed")
    order = await _customer_order_locked(db, customer_id, ref)
    quote = await latest_non_draft(db, order.id)

    # Same version already accepted (double tap, refresh): hand back the existing payment.
    if quote is not None and quote.version == version and quote.status == QuoteStatus.ACCEPTED:
        payment = await _active_payment(db, quote.id)
        if payment is not None:
            return payment
        return await new_payment_attempt(db, order, quote)

    if quote is None or quote.version != version or quote.status != QuoteStatus.SENT:
        raise Conflict("quote_outdated")
    if quote.expires_at is None or quote.expires_at <= utcnow():
        raise Conflict("quote_expired")

    quote.status, quote.answered_at, quote.sizes_confirmed = QuoteStatus.ACCEPTED, utcnow(), True
    await transition_order(
        db, order, OrderStatus.AWAITING_PAYMENT, actor=f"customer:{customer_id}", actor_type="customer", actor_id=customer_id, ip=ip
    )
    notify.admins(db, "quote_accepted", order)
    return await new_payment_attempt(db, order, quote)


async def new_payment_attempt(db: AsyncSession, order: Order, quote: Quote) -> Payment:
    attempts = await db.scalar(select(func.count()).select_from(Payment).where(Payment.quote_id == quote.id)) or 0
    payment = Payment(
        order_id=order.id,
        quote_id=quote.id,
        provider="WAVE",
        amount_xof=quote.total_xof,  # from the frozen quote, never from the request
        idempotency_key=f"quote-{quote.id}-{attempts + 1}",  # one Wave checkout per attempt
        status=PaymentStatus.INITIATED,
    )
    db.add(payment)
    await db.flush()
    return payment


async def retry_payment(db: AsyncSession, customer_id: int, ref: str) -> Payment:
    order = await _customer_order_locked(db, customer_id, ref)
    if order.status != OrderStatus.AWAITING_PAYMENT:
        raise Conflict("not_awaiting_payment")
    quote = await accepted_quote(db, order.id)
    if quote is None:
        raise Conflict("no_accepted_quote")
    payment = await _active_payment(db, quote.id)
    if payment is not None:
        return payment
    return await new_payment_attempt(db, order, quote)


async def request_change(db: AsyncSession, customer_id: int, ref: str, version: int, data: ChangeRequestIn, ip: str | None) -> QuoteChangeRequest:
    order = await _customer_order_locked(db, customer_id, ref)
    quote = await latest_non_draft(db, order.id)
    if quote is None or quote.version != version:
        raise Conflict("quote_outdated")
    if quote.status == QuoteStatus.ACCEPTED:
        if await _active_payment(db, quote.id) is not None:
            raise Conflict("payment_in_progress")
    elif quote.status not in (QuoteStatus.SENT, QuoteStatus.EXPIRED):
        raise Conflict("quote_outdated")

    new_url: str | None = None
    if data.new_share_text:
        urls = extract_shein_urls(data.new_share_text)
        if not urls:
            raise BadRequest("no_shein_link")
        new_url = urls[0]
    line_item_ids = {line.order_item_id for line in quote.lines}
    if not set(data.removed_item_ids) <= line_item_ids:
        raise BadRequest("unknown_item")
    if not {c.order_item_id for c in data.line_changes} <= line_item_ids:
        raise BadRequest("unknown_item")
    if not (new_url or data.removed_item_ids or data.line_changes or data.note):
        raise BadRequest("empty_change_request")

    change = QuoteChangeRequest(
        quote_id=quote.id,
        new_cart_url=new_url,
        removed_item_ids=data.removed_item_ids,
        line_changes=[c.model_dump(exclude_none=True) for c in data.line_changes],
        note=data.note,
    )
    db.add(change)
    quote.status, quote.answered_at = QuoteStatus.CHANGE_REQUESTED, utcnow()
    if new_url:
        if order.source_cart_url:
            order.submitted_links = [*order.submitted_links, order.source_cart_url]
        order.source_cart_url = new_url
        order.store = store_of(new_url)
    await transition_order(
        db, order, OrderStatus.QUOTE_REQUESTED, actor=f"customer:{customer_id}", actor_type="customer", actor_id=customer_id, ip=ip
    )
    notify.admins(db, "change_requested", order)
    return change


async def request_requote(db: AsyncSession, customer_id: int, ref: str, ip: str | None) -> None:
    order = await _customer_order_locked(db, customer_id, ref)
    quote = await latest_non_draft(db, order.id)
    expired = quote is not None and (
        quote.status == QuoteStatus.EXPIRED
        or (quote.status == QuoteStatus.SENT and quote.expires_at is not None and quote.expires_at <= utcnow())
    )
    if order.status != OrderStatus.QUOTED or not expired:
        raise Conflict("requote_not_allowed")
    assert quote is not None
    quote.status = QuoteStatus.EXPIRED
    await transition_order(
        db, order, OrderStatus.QUOTE_REQUESTED, actor=f"customer:{customer_id}", actor_type="customer", actor_id=customer_id, ip=ip
    )
    notify.admins(db, "quote_requested", order)


async def cancel_by_customer(db: AsyncSession, customer_id: int, ref: str, ip: str | None) -> None:
    order = await _customer_order_locked(db, customer_id, ref)
    if not await can_cancel(db, order):
        raise Conflict("cannot_cancel")
    quote = await latest_non_draft(db, order.id)
    if quote is not None and quote.status in (QuoteStatus.SENT, QuoteStatus.ACCEPTED):
        quote.status = QuoteStatus.SUPERSEDED
    await transition_order(
        db, order, OrderStatus.CANCELLED, actor=f"customer:{customer_id}", actor_type="customer", actor_id=customer_id, ip=ip
    )


async def can_cancel(db: AsyncSession, order: Order) -> bool:
    if order.status in (OrderStatus.QUOTE_REQUESTED, OrderStatus.QUOTED):
        return True
    if order.status == OrderStatus.AWAITING_PAYMENT:
        quote = await accepted_quote(db, order.id)
        return quote is None or await _active_payment(db, quote.id) is None
    return False
