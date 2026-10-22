import base64
from datetime import timedelta

from typing import Literal

from fastapi import APIRouter, Depends, File, Form, Request, Response, UploadFile
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import get_settings
from app.db import get_session
from app.enums import OrderStatus, PaymentStatus, QuoteStatus
from app.errors import BadRequest, Conflict, Forbidden, NotFound
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
    VerifyPhoneIn,
    LocationIn,
    LocationOut,
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
from app.services import customer_auth, notify, phone_verification, quotes
from app.services.audit import audit
from app.services import location as loc
from app.services.links import extract_shein_urls, pick_cart_url, store_of
from app.services.settings import get_settings_map
from app.services.orders import unique_public_ref
from app.services.payments import MANUAL_PROVIDERS, start_checkout, transition_payment

router = APIRouter(tags=["customer"])
authed = Depends(customer_limited)


def _customer_out(c: Customer) -> CustomerOut:
    phone = decrypt(c.phone_enc) if c.phone_enc else ""
    return CustomerOut(
        id=c.id, display_name=c.display_name, locale=c.locale,
        phone_masked=mask_phone(phone) if phone else "", must_change_password=c.must_change_password,
        location=_location_out(c.location_commune, c.location_enc),
        phone_verified=c.phone_verified_at is not None,
    )


def _location_out(commune: str | None, blob: bytes | None) -> LocationOut | None:
    data = loc.unpack(commune, blob)
    return LocationOut(**data) if data else None


# Orders whose parcel hasn't been handed over yet follow the customer's latest location.
LOCATION_FOLLOWS = (
    OrderStatus.QUOTE_REQUESTED, OrderStatus.QUOTED, OrderStatus.AWAITING_PAYMENT, OrderStatus.PAID,
    OrderStatus.PURCHASED, OrderStatus.IN_TRANSIT, OrderStatus.ARRIVED,
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


@router.post("/me/verify-phone", response_model=CustomerOut)
async def verify_phone(data: VerifyPhoneIn, request: Request, customer: Customer = authed, db: AsyncSession = Depends(get_session)) -> CustomerOut:
    try:
        phone_verification.check_code(customer, data.code)
    finally:
        await db.commit()  # keep the failed-attempt counter
    await audit(db, actor_type="customer", actor_id=customer.id, action="customer.phone_verified", ip=client_ip(request))
    await db.commit()
    return _customer_out(customer)


@router.put("/me/location", response_model=CustomerOut)
async def set_location(data: LocationIn, request: Request, customer: Customer = authed, db: AsyncSession = Depends(get_session)) -> CustomerOut:
    """Her place in Abidjan, used to plan dispatch when parcels arrive."""
    if (data.lat is None) != (data.lng is None):
        raise BadRequest("incomplete_gps")
    blob = loc.pack(data.quartier, data.landmark, data.lat, data.lng)
    customer.location_commune, customer.location_enc, customer.location_updated_at = data.commune, blob, utcnow()
    for o in (await db.scalars(select(Order).where(Order.customer_id == customer.id, Order.status.in_(LOCATION_FOLLOWS)))).all():
        o.delivery_commune, o.delivery_location_enc = data.commune, blob
    await audit(db, actor_type="customer", actor_id=customer.id, action="customer.location_set", after={"commune": data.commune}, ip=client_ip(request))
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
    customer.location_commune, customer.location_enc = None, None
    customer.anonymised_at = utcnow()
    for o in (await db.scalars(select(Order).where(Order.customer_id == customer.id))).all():
        o.source_cart_url, o.submitted_links, o.customer_note = None, [], None
        o.delivery_commune, o.delivery_location_enc = None, None
    for t in (await db.scalars(select(RefreshToken).where(RefreshToken.subject_type == "customer", RefreshToken.subject_id == customer.id))).all():
        t.revoked_at = utcnow()
    await audit(db, actor_type="customer", actor_id=customer.id, action="customer.anonymised", ip=client_ip(request))
    await db.commit()


@router.get("/public/info")
async def public_info(db: AsyncSession = Depends(get_session)) -> dict:
    """Shown in the customer app. No auth: nothing private here."""
    settings = await get_settings_map(db)
    return {
        "next_departure_date": settings.get("next_departure_date"),
        "payment_mode": settings["payment_mode"],
        "wave_phone": settings.get("wave_phone"),
        "has_wave_qr": bool(settings.get("wave_qr_image")),
        # Only methods with a number are offered to customers.
        "payment_accounts": {k: v for k, v in (settings.get("payment_accounts") or {}).items() if v}
        or ({"WAVE": settings["wave_phone"]} if settings.get("wave_phone") else {}),
    }


@router.get("/public/wave-qr")
async def wave_qr(db: AsyncSession = Depends(get_session)) -> Response:
    img = (await get_settings_map(db)).get("wave_qr_image")
    if not img:
        raise NotFound()
    return Response(base64.b64decode(img["data_b64"]), media_type=img["content_type"], headers={"Cache-Control": "public, max-age=300"})


@router.get("/pickup-points", response_model=list[PickupPointOut])
async def pickup_points(db: AsyncSession = Depends(get_session)) -> list[PickupPoint]:
    return list((await db.scalars(select(PickupPoint).where(PickupPoint.active.is_(True)).order_by(PickupPoint.name))).all())


# ---------------------------------------------------------------- orders


async def _order_for(db: AsyncSession, customer: Customer, ref: str) -> Order:
    order = await db.scalar(select(Order).where(Order.public_ref == ref, Order.customer_id == customer.id))
    if order is None:
        raise NotFound()
    return order


def _quote_out(q, screenshot_url: str | None = None) -> QuoteOut:  # type: ignore[no-untyped-def]
    return QuoteOut(
        version=q.version, status=q.status, items_xof=q.items_xof, freight_xof=q.freight_xof,
        customs_xof=q.customs_xof, fee_xof=q.fee_xof, total_xof=q.total_xof, admin_note=q.admin_note,
        expires_at=q.expires_at, sent_at=q.sent_at,
        lines=[QuoteLineOut.model_validate(line) for line in q.lines],
        screenshot_url=screenshot_url,
        # Customers see FCFA only: the store's euro price stays internal.
    )


async def _quote_shot(db: AsyncSession, quote_id: int) -> str | None:
    shot = await quotes.quote_screenshot(db, quote_id)
    return storage.signed_url(shot.storage_key) if shot else None


async def _detail(db: AsyncSession, order: Order) -> OrderDetailOut:
    quote = await quotes.latest_non_draft(db, order.id)  # drafts are never shown to customers
    payment = await db.scalar(select(Payment).where(Payment.order_id == order.id).order_by(Payment.id.desc()).limit(1))
    history = (await db.scalars(select(OrderStatusHistory).where(OrderStatusHistory.order_id == order.id).order_by(OrderStatusHistory.id))).all()
    point = await db.get(PickupPoint, order.pickup_point_id) if order.pickup_point_id else None
    attachments = await db.scalar(select(func.count()).select_from(OrderAttachment).where(OrderAttachment.order_id == order.id, OrderAttachment.kind == "CART_SCREENSHOT")) or 0
    expired = quote is not None and (
        quote.status == QuoteStatus.EXPIRED
        or (quote.status == QuoteStatus.SENT and quote.expires_at is not None and quote.expires_at <= utcnow())
    )
    return OrderDetailOut(
        public_ref=order.public_ref,
        status=order.status,
        store=order.store,
        total_xof=order.total_xof,
        created_at=order.created_at,
        status_changed_at=order.status_changed_at,
        source_cart_url=order.source_cart_url,
        submitted_links=order.submitted_links,
        customer_note=order.customer_note,
        pickup_point=PickupPointOut.model_validate(point) if point else None,
        delivery_location=_location_out(order.delivery_commune, order.delivery_location_enc),
        quote=_quote_out(quote, await _quote_shot(db, quote.id)) if quote else None,
        payment=PaymentOut.of(payment) if payment else None,
        history=[StatusEventOut.model_validate(h) for h in history],
        attachments=attachments,
        can_cancel=await quotes.can_cancel(db, order),
        can_request_requote=order.status == OrderStatus.QUOTED and expired,
    )


@router.post("/orders", response_model=OrderDetailOut, status_code=201)
async def create_order(data: OrderCreateIn, request: Request, customer: Customer = authed, db: AsyncSession = Depends(get_session)) -> OrderDetailOut:
    if customer.phone_verified_at is None:
        raise Forbidden("phone_not_verified")
    urls = extract_shein_urls(data.share_text)
    if not urls:
        raise BadRequest("no_shein_link", "Collez le lien de partage de votre panier SHEIN ou Temu")
    point = None
    if data.pickup_point_id is not None:
        point = await db.get(PickupPoint, data.pickup_point_id)
        if point is None or not point.active:
            raise BadRequest("invalid_pickup_point")
    cart_url = pick_cart_url(urls)

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
        store=store_of(cart_url),
        submitted_links=[u for u in urls if u != cart_url],
        customer_note=data.note,
        status=OrderStatus.QUOTE_REQUESTED,
        pickup_point_id=point.id if point else None,
        delivery_commune=customer.location_commune,
        delivery_location_enc=customer.location_enc,
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
    return [OrderSummaryOut(public_ref=o.public_ref, status=o.status, store=o.store, total_xof=o.total_xof, created_at=o.created_at, status_changed_at=o.status_changed_at) for o in rows]


@router.get("/orders/{ref}", response_model=OrderDetailOut)
async def get_order(ref: str, customer: Customer = authed, db: AsyncSession = Depends(get_session)) -> OrderDetailOut:
    return await _detail(db, await _order_for(db, customer, ref))


@router.post("/orders/{ref}/attachments", status_code=201)
async def upload_attachment(ref: str, file: UploadFile = File(...), customer: Customer = authed, db: AsyncSession = Depends(get_session)) -> dict[str, int]:
    order = await _order_for(db, customer, ref)
    if order.status not in (OrderStatus.QUOTE_REQUESTED, OrderStatus.QUOTED):
        raise Conflict("attachments_closed")
    count = await db.scalar(select(func.count()).select_from(OrderAttachment).where(OrderAttachment.order_id == order.id, OrderAttachment.kind == "CART_SCREENSHOT")) or 0
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
    return await _start_payment(db, payment, ref)


@router.post("/orders/{ref}/payment", response_model=PaymentOut)
async def retry_payment(ref: str, customer: Customer = authed, db: AsyncSession = Depends(get_session)) -> PaymentOut:
    payment = await quotes.retry_payment(db, customer.id, ref)
    await db.commit()
    return await _start_payment(db, payment, ref)


async def _start_payment(db: AsyncSession, payment: Payment, ref: str) -> PaymentOut:
    """Wave Checkout (business account) or manual Wave QR, depending on the payment_mode setting."""
    settings = await get_settings_map(db)
    if settings["payment_mode"] != "wave_checkout":
        if payment.status == PaymentStatus.INITIATED:
            payment.provider = "MANUAL"
            await transition_payment(db, payment, PaymentStatus.PENDING, actor="system")
            await db.commit()
        return PaymentOut.of(payment, launch=False)
    payment = await start_checkout(db, payment.id, ref)
    return PaymentOut.of(payment)


@router.post("/orders/{ref}/payment/declare", response_model=PaymentOut)
async def declare_payment(
    ref: str,
    request: Request,
    method: Literal["WAVE", "ORANGE", "MOOV"] = Form(...),
    file: UploadFile = File(...),
    customer: Customer = authed,
    db: AsyncSession = Depends(get_session),
) -> PaymentOut:
    """She paid from her Wave / Orange Money / Moov Money app and sends the screenshot.
    An admin checks it against their account and confirms."""
    order = await _order_for(db, customer, ref)
    payment = await db.scalar(
        select(Payment).where(Payment.order_id == order.id, Payment.provider.in_(MANUAL_PROVIDERS), Payment.status == PaymentStatus.PENDING)
        .order_by(Payment.id.desc()).limit(1)
    )
    if payment is None:
        raise Conflict("no_pending_payment")
    data, content_type, _ = storage.sanitize_image(await file.read(10 * 1024 * 1024 + 1))
    payment.method, payment.proof_image, payment.proof_content_type = method, data, content_type
    payment.status_reason = "declared"
    await audit(db, actor_type="customer", actor_id=customer.id, action="payment.declared", entity="payment", entity_id=payment.id,
                after={"method": method}, ip=client_ip(request))
    notify.admins(db, "payment_declared", order)
    await db.commit()
    return PaymentOut.of(payment, launch=False)


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

