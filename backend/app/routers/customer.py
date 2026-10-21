from datetime import timedelta

from fastapi import APIRouter, Depends, File, Request, UploadFile
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import get_settings
from app.db import get_session
from app.enums import OrderStatus, QuoteStatus
from app.errors import BadRequest, Conflict, NotFound
from app.integrations import storage
from app.models import (
    Customer,
    Order,
    OrderAttachment,
    OrderStatusHistory,
    Payment,
    PickupPoint,
    RefreshToken,
)
from app.ratelimit import customer_limited
from app.schemas import (
    AcceptQuoteIn,
    ChangeRequestIn,
    CustomerOut,
    ChangePasswordIn,
    CustomerUpdateIn,
    OrderCreateIn,
    OrderDetailOut,
    OrderSummaryOut,
    PaymentOut,
    PickupPointOut,
    QuoteLineOut,
    QuoteOut,
    StatusEventOut,
)
from app.security.crypto import decrypt, mask_phone
from app.security.deps import client_ip
from app.security.tokens import utcnow
from app.services import customer_auth, notify, quotes
from app.services.audit import audit
from app.services.links import extract_shein_urls
from app.services.orders import unique_public_ref
from app.services.payments import start_checkout

router = APIRouter(tags=["customer"])
authed = Depends(customer_limited)


def _customer_out(c: Customer) -> CustomerOut:
    phone = decrypt(c.phone_enc) if c.phone_enc else ""
    return CustomerOut(
        id=c.id, display_name=c.display_name, locale=c.locale,
        phone_masked=mask_phone(phone) if phone else "", must_change_password=c.must_change_password,
    )


@router.get("/me", response_model=CustomerOut)
async def me(customer: Customer = authed) -> CustomerOut:
    return _customer_out(customer)


@router.patch("/me", response_model=CustomerOut)
async def update_me(data: CustomerUpdateIn, customer: Customer = authed, db: AsyncSession = Depends(get_session)) -> CustomerOut:
    if data.display_name is not None:
        customer.display_name = data.display_name
    if data.locale is not None:
        customer.locale = data.locale
    await db.commit()
    return _customer_out(customer)


@router.post("/me/password", status_code=204)
async def change_password(data: ChangePasswordIn, request: Request, customer: Customer = authed, db: AsyncSession = Depends(get_session)) -> None:
    await customer_auth.change_password(customer, data.current_password, data.new_password)
    await audit(db, actor_type="customer", actor_id=customer.id, action="auth.password_changed", ip=client_ip(request))
    await db.commit()


@router.get("/me/export")
async def export_me(customer: Customer = authed, db: AsyncSession = Depends(get_session)) -> dict:
    """Data export (ARTCI, law 2013-450)."""
    orders = (await db.scalars(select(Order).where(Order.customer_id == customer.id))).all()
    return {
        "customer": {
            "display_name": customer.display_name,
            "phone": decrypt(customer.phone_enc) if customer.phone_enc else None,
            "locale": customer.locale,
            "created_at": customer.created_at.isoformat(),
        },
        "orders": [
            {"ref": o.public_ref, "status": o.status, "total_xof": o.total_xof, "created_at": o.created_at.isoformat(),
             "cart_url": o.source_cart_url}
            for o in orders
        ],
    }


@router.delete("/me", status_code=204)
async def delete_me(request: Request, customer: Customer = authed, db: AsyncSession = Depends(get_session)) -> None:
    """Anonymise the customer. Orders and payments stay for accounting, detached from any identity."""
    open_statuses = {OrderStatus.PAID, OrderStatus.PURCHASED, OrderStatus.IN_TRANSIT, OrderStatus.ARRIVED,
                     OrderStatus.READY_FOR_PICKUP, OrderStatus.REFUND_PENDING}
    if await db.scalar(select(func.count()).select_from(Order).where(Order.customer_id == customer.id, Order.status.in_(open_statuses))):
        raise Conflict("orders_in_progress")
    customer.display_name, customer.phone_enc, customer.phone_hash, customer.password_hash = None, None, None, None
    customer.anonymised_at = utcnow()
    for o in (await db.scalars(select(Order).where(Order.customer_id == customer.id))).all():
        o.source_cart_url, o.submitted_links, o.customer_note = None, [], None
    for t in (await db.scalars(select(RefreshToken).where(RefreshToken.subject_type == "customer", RefreshToken.subject_id == customer.id))).all():
        t.revoked_at = utcnow()
    await audit(db, actor_type="customer", actor_id=customer.id, action="customer.anonymised", ip=client_ip(request))
    await db.commit()


@router.get("/pickup-points", response_model=list[PickupPointOut])
async def pickup_points(db: AsyncSession = Depends(get_session)) -> list[PickupPoint]:
    return list((await db.scalars(select(PickupPoint).where(PickupPoint.active.is_(True)).order_by(PickupPoint.name))).all())


# ---------------------------------------------------------------- orders


async def _order_for(db: AsyncSession, customer: Customer, ref: str) -> Order:
    order = await db.scalar(select(Order).where(Order.public_ref == ref, Order.customer_id == customer.id))
    if order is None:
        raise NotFound()
    return order


def _quote_out(q) -> QuoteOut:  # type: ignore[no-untyped-def]
    return QuoteOut(
        version=q.version, status=q.status, items_xof=q.items_xof, freight_xof=q.freight_xof,
        customs_xof=q.customs_xof, fee_xof=q.fee_xof, total_xof=q.total_xof, admin_note=q.admin_note,
        expires_at=q.expires_at, sent_at=q.sent_at,
        lines=[QuoteLineOut.model_validate(line) for line in q.lines],
    )


async def _detail(db: AsyncSession, order: Order) -> OrderDetailOut:
    quote = await quotes.latest_non_draft(db, order.id)  # drafts are never shown to customers
    payment = await db.scalar(select(Payment).where(Payment.order_id == order.id).order_by(Payment.id.desc()).limit(1))
    history = (await db.scalars(select(OrderStatusHistory).where(OrderStatusHistory.order_id == order.id).order_by(OrderStatusHistory.id))).all()
    point = await db.get(PickupPoint, order.pickup_point_id) if order.pickup_point_id else None
    attachments = await db.scalar(select(func.count()).select_from(OrderAttachment).where(OrderAttachment.order_id == order.id)) or 0
    expired = quote is not None and (
        quote.status == QuoteStatus.EXPIRED
        or (quote.status == QuoteStatus.SENT and quote.expires_at is not None and quote.expires_at <= utcnow())
    )
    return OrderDetailOut(
        public_ref=order.public_ref,
        status=order.status,
        total_xof=order.total_xof,
        created_at=order.created_at,
        status_changed_at=order.status_changed_at,
        source_cart_url=order.source_cart_url,
        submitted_links=order.submitted_links,
        customer_note=order.customer_note,
        pickup_point=PickupPointOut.model_validate(point) if point else None,
        quote=_quote_out(quote) if quote else None,
        payment=PaymentOut(status=payment.status, amount_xof=payment.amount_xof, launch_url=payment.launch_url) if payment else None,
        history=[StatusEventOut.model_validate(h) for h in history],
        attachments=attachments,
        can_cancel=await quotes.can_cancel(db, order),
        can_request_requote=order.status == OrderStatus.QUOTED and expired,
    )


@router.post("/orders", response_model=OrderDetailOut, status_code=201)
async def create_order(data: OrderCreateIn, request: Request, customer: Customer = authed, db: AsyncSession = Depends(get_session)) -> OrderDetailOut:
    urls = extract_shein_urls(data.share_text)
    if not urls:
        raise BadRequest("no_shein_link", "Collez le lien de partage de votre panier SHEIN")
    point = await db.get(PickupPoint, data.pickup_point_id)
    if point is None or not point.active:
        raise BadRequest("invalid_pickup_point")
    cart_url = next((u for u in urls if "onelink.shein.com" in u), urls[0])

    # The same cart sent twice within 24 h returns the existing open order.
    recent = await db.scalar(
        select(Order).where(
            Order.customer_id == customer.id,
            Order.source_cart_url == cart_url,
            Order.status.in_([OrderStatus.QUOTE_REQUESTED, OrderStatus.QUOTED]),
            Order.created_at >= utcnow() - timedelta(hours=24),
        )
    )
    if recent is not None:
        return await _detail(db, recent)

    order = Order(
        public_ref=await unique_public_ref(db),
        customer_id=customer.id,
        source_cart_url=cart_url,
        submitted_links=[u for u in urls if u != cart_url],
        customer_note=data.note,
        status=OrderStatus.QUOTE_REQUESTED,
        pickup_point_id=point.id,
    )
    db.add(order)
    await db.flush()
    db.add(OrderStatusHistory(order_id=order.id, from_status=None, to_status=OrderStatus.QUOTE_REQUESTED, actor=f"customer:{customer.id}"))
    await audit(db, actor_type="customer", actor_id=customer.id, action="order.created", entity="order", entity_id=order.id, ip=client_ip(request))
    notify.admins(db, "quote_requested", order)
    await db.commit()
    return await _detail(db, order)


@router.get("/orders", response_model=list[OrderSummaryOut])
async def list_orders(customer: Customer = authed, db: AsyncSession = Depends(get_session)) -> list[OrderSummaryOut]:
    rows = (await db.scalars(select(Order).where(Order.customer_id == customer.id).order_by(Order.created_at.desc()).limit(100))).all()
    return [OrderSummaryOut(public_ref=o.public_ref, status=o.status, total_xof=o.total_xof, created_at=o.created_at, status_changed_at=o.status_changed_at) for o in rows]


@router.get("/orders/{ref}", response_model=OrderDetailOut)
async def get_order(ref: str, customer: Customer = authed, db: AsyncSession = Depends(get_session)) -> OrderDetailOut:
    return await _detail(db, await _order_for(db, customer, ref))


@router.post("/orders/{ref}/attachments", status_code=201)
async def upload_attachment(ref: str, file: UploadFile = File(...), customer: Customer = authed, db: AsyncSession = Depends(get_session)) -> dict[str, int]:
    order = await _order_for(db, customer, ref)
    if order.status not in (OrderStatus.QUOTE_REQUESTED, OrderStatus.QUOTED):
        raise Conflict("attachments_closed")
    count = await db.scalar(select(func.count()).select_from(OrderAttachment).where(OrderAttachment.order_id == order.id)) or 0
    if count >= get_settings().max_attachments_per_order:
        raise Conflict("too_many_attachments")
    raw = await file.read(get_settings().max_upload_mb * 1024 * 1024 + 1)
    data, content_type, ext = storage.sanitize_image(raw)
    key = storage.new_key(order.id, ext)
    storage.put(key, data, content_type)
    db.add(OrderAttachment(order_id=order.id, storage_key=key, content_type=content_type))
    await db.commit()
    return {"attachments": count + 1}


@router.post("/orders/{ref}/quotes/{version}/accept", response_model=PaymentOut)
async def accept(ref: str, version: int, data: AcceptQuoteIn, request: Request, customer: Customer = authed, db: AsyncSession = Depends(get_session)) -> PaymentOut:
    payment = await quotes.accept_quote(db, customer.id, ref, version, data.sizes_confirmed, client_ip(request))
    await db.commit()
    payment = await start_checkout(db, payment.id, ref)
    return PaymentOut(status=payment.status, amount_xof=payment.amount_xof, launch_url=payment.launch_url)


@router.post("/orders/{ref}/payment", response_model=PaymentOut)
async def retry_payment(ref: str, customer: Customer = authed, db: AsyncSession = Depends(get_session)) -> PaymentOut:
    payment = await quotes.retry_payment(db, customer.id, ref)
    await db.commit()
    payment = await start_checkout(db, payment.id, ref)
    return PaymentOut(status=payment.status, amount_xof=payment.amount_xof, launch_url=payment.launch_url)


@router.post("/orders/{ref}/quotes/{version}/change-request", status_code=201)
async def change_request(ref: str, version: int, data: ChangeRequestIn, request: Request, customer: Customer = authed, db: AsyncSession = Depends(get_session)) -> dict[str, str]:
    await quotes.request_change(db, customer.id, ref, version, data, client_ip(request))
    await db.commit()
    return {"status": "QUOTE_REQUESTED"}


@router.post("/orders/{ref}/requote", status_code=201)
async def requote(ref: str, request: Request, customer: Customer = authed, db: AsyncSession = Depends(get_session)) -> dict[str, str]:
    await quotes.request_requote(db, customer.id, ref, client_ip(request))
    await db.commit()
    return {"status": "QUOTE_REQUESTED"}


@router.post("/orders/{ref}/cancel", status_code=204)
async def cancel(ref: str, request: Request, customer: Customer = authed, db: AsyncSession = Depends(get_session)) -> None:
    await quotes.cancel_by_customer(db, customer.id, ref, client_ip(request))
    await db.commit()

