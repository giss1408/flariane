from datetime import datetime
from typing import Annotated, Literal

from pydantic import BaseModel, ConfigDict, StringConstraints

from fastapi import APIRouter, Depends, File, Query, Request, Response, UploadFile
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload, undefer

from app.db import get_session
from app.enums import AdminRole, OrderStatus, QuoteStatus
from app.errors import Conflict, DomainError, Forbidden, NotFound
from app.integrations import storage
from app.models import (
    Customer,
    Order,
    OrderAttachment,
    OrderItem,
    OrderStatusHistory,
    Payment,
    PickupPoint,
    Quote,
    QuoteChangeRequest,
    ShipmentOrder,
    StorePurchase,
)
from app.ratelimit import admin_limited
from app.schemas import (
    AdminOrderDetailOut,
    AdminOrderSummaryOut,
    AdminQuoteOut,
    AttachmentOut,
    CancelItemIn,
    ChangeRequestOut,
    LocationOut,
    OrderItemOut,
    PaymentOut,
    PickupConfirmIn,
    PickupPointOut,
    PurchaseIn,
    PurchaseOut,
    QuoteDraftIn,
    QuoteLineOut,
    ReadyForPickupIn,
    RefundOut,
    SendQuoteIn,
    StatusEventOut,
    StorePurchaseOut,
)
from app.security.crypto import decrypt, mask_phone, phone_hash
from app.security.deps import AdminContext, client_ip, require_pickup_access, require_role
from app.services import customer_auth
from app.services import location as loc
from app.services import wa_messages as wa
from app.services import operations, quotes
from app.services import payments as payments_service
from app.security.tokens import utcnow
from app.services.audit import audit
from app.services.settings import get_settings_map

router = APIRouter(prefix="/admin/orders", tags=["admin-orders"], dependencies=[Depends(admin_limited)])
viewer = Depends(require_role(AdminRole.VIEWER))
operator = Depends(require_role(AdminRole.OPERATOR))
pickup_desk = Depends(require_pickup_access())

TABS: dict[str, list[OrderStatus]] = {
    "to_quote": [OrderStatus.QUOTE_REQUESTED],
    "quoted": [OrderStatus.QUOTED, OrderStatus.AWAITING_PAYMENT],
    "to_buy": [OrderStatus.PAID],
    "to_ship": [OrderStatus.PURCHASED],
    "in_transit": [OrderStatus.IN_TRANSIT],
    "pickups": [OrderStatus.ARRIVED, OrderStatus.READY_FOR_PICKUP],
    "refunds": [OrderStatus.REFUND_PENDING],
    "done": [OrderStatus.PICKED_UP, OrderStatus.CANCELLED, OrderStatus.REFUNDED],
}


def admin_quote_out(q: Quote, min_fee: int, screenshot_url: str | None = None) -> AdminQuoteOut:
    return AdminQuoteOut(
        id=q.id, version=q.version, status=q.status, items_xof=q.items_xof, freight_xof=q.freight_xof,
        customs_xof=q.customs_xof, fee_xof=q.fee_xof, total_xof=q.total_xof, admin_note=q.admin_note,
        expires_at=q.expires_at, sent_at=q.sent_at, fx_rates=q.fx_rates, created_by=q.created_by,
        answered_at=q.answered_at, min_fee_xof=min_fee, fee_below_minimum=q.fee_xof < min_fee,
        lines=[QuoteLineOut.model_validate(line) for line in q.lines],
        screenshot_url=screenshot_url,
        cart_source_amount=q.cart_source_amount,
        cart_source_currency=q.cart_source_currency,
    )


@router.get("", response_model=list[AdminOrderSummaryOut])
async def inbox(
    tab: Literal["to_quote", "quoted", "to_buy", "to_ship", "in_transit", "pickups", "refunds", "done", "all"] = "to_quote",
    q: str | None = Query(default=None, max_length=20),
    store: Literal["SHEIN", "TEMU"] | None = None,
    _: AdminContext = viewer,
    db: AsyncSession = Depends(get_session),
) -> list[AdminOrderSummaryOut]:
    stmt = select(Order, Customer.display_name).join(Customer, Customer.id == Order.customer_id)
    if store:
        stmt = stmt.where(Order.store == store)
    if q:
        stmt = stmt.where(Order.public_ref.ilike(f"%{q.strip().upper()}%"))
    elif tab != "all":
        stmt = stmt.where(Order.status.in_(TABS[tab]), Order.archived_at.is_(None))
    order_desc = tab in ("done", "all") or bool(q)
    stmt = stmt.order_by(Order.status_changed_at.desc() if order_desc else Order.status_changed_at.asc()).limit(200)
    rows = (await db.execute(stmt)).all()

    ids = [o.id for o, _ in rows]
    change_requested: set[int] = set()
    if ids:
        latest = (
            await db.execute(
                select(Quote.order_id, Quote.status)
                .where(Quote.order_id.in_(ids), Quote.status != QuoteStatus.DRAFT)
                .order_by(Quote.order_id, Quote.version.desc())
                .distinct(Quote.order_id)
            )
        ).all()
        change_requested = {oid for oid, st in latest if st == QuoteStatus.CHANGE_REQUESTED}
    return [
        AdminOrderSummaryOut(
            id=o.id, public_ref=o.public_ref, status=o.status, store=o.store, customer_name=name, total_xof=o.total_xof,
            created_at=o.created_at, status_changed_at=o.status_changed_at, has_change_request=o.id in change_requested,
        )
        for o, name in rows
    ]


async def _shot_url(db: AsyncSession, quote_id: int) -> str | None:
    shot = await quotes.quote_screenshot(db, quote_id)
    return storage.signed_url(shot.storage_key) if shot else None


def _location(commune: str | None, blob: bytes | None) -> LocationOut | None:
    data = loc.unpack(commune, blob)
    return LocationOut(**data) if data else None


async def _detail(db: AsyncSession, order_id: int) -> AdminOrderDetailOut:
    order = await db.get(Order, order_id)
    if order is None:
        raise NotFound()
    customer = await db.get(Customer, order.customer_id)
    assert customer is not None
    settings = await get_settings_map(db)
    min_fee = int(settings["min_fee_xof"])
    all_quotes = (
        await db.scalars(select(Quote).where(Quote.order_id == order.id).order_by(Quote.version.desc()).options(selectinload(Quote.lines)))
    ).all()
    quote_ids = [q.id for q in all_quotes]
    changes = (
        await db.scalars(select(QuoteChangeRequest).where(QuoteChangeRequest.quote_id.in_(quote_ids)).order_by(QuoteChangeRequest.id.desc()))
    ).all() if quote_ids else []
    items = (await db.scalars(select(OrderItem).where(OrderItem.order_id == order.id).order_by(OrderItem.id))).all()
    attachments = (await db.scalars(select(OrderAttachment).where(OrderAttachment.order_id == order.id, OrderAttachment.kind == "CART_SCREENSHOT"))).all()
    payments = (await db.scalars(select(Payment).where(Payment.order_id == order.id).order_by(Payment.id.desc()))).all()
    purchase = await db.scalar(select(StorePurchase).where(StorePurchase.order_id == order.id))
    history = (await db.scalars(select(OrderStatusHistory).where(OrderStatusHistory.order_id == order.id).order_by(OrderStatusHistory.id))).all()
    point = await db.get(PickupPoint, order.pickup_point_id) if order.pickup_point_id else None
    shipment_id = await db.scalar(select(ShipmentOrder.shipment_id).where(ShipmentOrder.order_id == order.id))
    phone = decrypt(customer.phone_enc) if customer.phone_enc else ""
    return AdminOrderDetailOut(
        id=order.id,
        public_ref=order.public_ref,
        status=order.status,
        customer_id=customer.id,
        customer_name=customer.display_name,
        customer_phone_masked=mask_phone(phone) if phone else "",
        store=order.store,
        source_cart_url=order.source_cart_url,
        submitted_links=order.submitted_links,
        customer_note=order.customer_note,
        pickup_point=PickupPointOut.model_validate(point) if point else None,
        delivery_location=_location(order.delivery_commune, order.delivery_location_enc),
        items=[OrderItemOut.model_validate(i) for i in items],
        quotes=[admin_quote_out(q, min_fee, await _shot_url(db, q.id)) for q in all_quotes],
        change_requests=[ChangeRequestOut.model_validate(c) for c in changes],
        attachments=[AttachmentOut(id=a.id, url=storage.signed_url(a.storage_key), content_type=a.content_type) for a in attachments],
        payments=[PaymentOut.of(p, launch=False) for p in payments],
        purchase=StorePurchaseOut.model_validate(purchase) if purchase else None,
        history=[StatusEventOut.model_validate(h) for h in history],
        shipment_id=shipment_id,
    )


@router.get("/attention")
async def attention(_: AdminContext = viewer, db: AsyncSession = Depends(get_session)) -> dict[str, int]:
    """What waits for an admin, polled by the app (no push service)."""
    async def count(stmt) -> int:  # type: ignore[no-untyped-def]
        return int(await db.scalar(stmt) or 0)

    return {
        "to_quote": await count(select(func.count()).select_from(Order).where(Order.status == OrderStatus.QUOTE_REQUESTED)),
        "to_buy": await count(select(func.count()).select_from(Order).where(Order.status == OrderStatus.PAID)),
        "payments_to_confirm": await count(
            select(func.count()).select_from(Payment).where(Payment.status == "PENDING", Payment.status_reason == "declared")
        ),
        "registrations_to_verify": await count(
            select(func.count()).select_from(Customer).where(
                Customer.phone_verified_at.is_(None), Customer.anonymised_at.is_(None), Customer.phone_enc.is_not(None))
        ),
        "to_hand_over": await count(select(func.count()).select_from(Order).where(Order.status == OrderStatus.ARRIVED)),
    }


class PickupOrderOut(BaseModel):
    id: int
    public_ref: str
    status: str
    store: str
    customer_name: str | None
    customer_phone_masked: str
    pickup_point: PickupPointOut | None
    status_changed_at: datetime


@router.get("/pickup-desk", response_model=list[PickupOrderOut])
async def pickup_desk_search(
    q: str | None = Query(default=None, max_length=30),
    _: AdminContext = pickup_desk,
    db: AsyncSession = Depends(get_session),
) -> list[PickupOrderOut]:
    """Parcels arrived or ready for pickup. `q` = order reference (FLR-…) or the customer's phone."""
    stmt = (
        select(Order, Customer)
        .join(Customer, Customer.id == Order.customer_id)
        .where(Order.status.in_([OrderStatus.ARRIVED, OrderStatus.READY_FOR_PICKUP, OrderStatus.PICKED_UP]))
    )
    term = (q or "").strip()
    if term:
        try:
            ph = phone_hash(customer_auth.normalize_ci_phone(term))
            stmt = stmt.where(Customer.phone_hash == ph)
        except DomainError:
            stmt = stmt.where(Order.public_ref.ilike(f"%{term.upper()}%"))
    else:
        stmt = stmt.where(Order.status != OrderStatus.PICKED_UP)
    rows = (await db.execute(stmt.order_by(Order.status_changed_at.desc()).limit(100))).all()
    out = []
    for o, c in rows:
        point = await db.get(PickupPoint, o.pickup_point_id) if o.pickup_point_id else None
        phone = decrypt(c.phone_enc) if c.phone_enc else ""
        out.append(PickupOrderOut(
            id=o.id, public_ref=o.public_ref, status=o.status, store=o.store, customer_name=c.display_name,
            customer_phone_masked=mask_phone(phone) if phone else "",
            pickup_point=PickupPointOut.model_validate(point) if point else None, status_changed_at=o.status_changed_at,
        ))
    return out


@router.get("/{order_id}", response_model=AdminOrderDetailOut)
async def detail(order_id: int, _: AdminContext = viewer, db: AsyncSession = Depends(get_session)) -> AdminOrderDetailOut:
    return await _detail(db, order_id)


@router.post("/{order_id}/reveal-phone")
async def reveal_phone(order_id: int, request: Request, admin: AdminContext = pickup_desk, db: AsyncSession = Depends(get_session)) -> dict[str, str]:
    order = await db.get(Order, order_id)
    customer = await db.get(Customer, order.customer_id) if order else None
    if customer is None or customer.phone_enc is None:
        raise NotFound()
    await audit(db, actor_type="admin", actor_id=admin.id, action="customer.phone_revealed", entity="customer", entity_id=customer.id, ip=client_ip(request))
    await db.commit()
    return {"phone": decrypt(customer.phone_enc)}


@router.put("/{order_id}/quote-draft", response_model=AdminQuoteOut)
async def save_draft(order_id: int, data: QuoteDraftIn, admin: AdminContext = operator, db: AsyncSession = Depends(get_session)) -> AdminQuoteOut:
    quote, meta = await quotes.save_draft(db, order_id, data, admin.id)
    await db.commit()
    await db.refresh(quote, ["lines"])
    return admin_quote_out(quote, meta["min_fee_xof"], await _shot_url(db, quote.id))


@router.post("/{order_id}/quote-screenshot", response_model=AdminQuoteOut)
async def upload_quote_screenshot(order_id: int, file: UploadFile = File(...), admin: AdminContext = operator, db: AsyncSession = Depends(get_session)) -> AdminQuoteOut:
    """Screenshot of the SHEIN cart as quoted; shown to the customer before she pays."""
    raw = await file.read(10 * 1024 * 1024 + 1)
    data, content_type, ext = storage.sanitize_image(raw)
    key = storage.new_key(order_id, ext)
    storage.put(key, data, content_type)
    quote = await quotes.attach_quote_screenshot(db, order_id, key, content_type)
    settings = await get_settings_map(db)
    await db.commit()
    await db.refresh(quote, ["lines"])
    return admin_quote_out(quote, int(settings["min_fee_xof"]), storage.signed_url(key))


@router.post("/{order_id}/quotes/{version}/send", response_model=AdminQuoteOut)
async def send(order_id: int, version: int, data: SendQuoteIn, request: Request, admin: AdminContext = operator, db: AsyncSession = Depends(get_session)) -> AdminQuoteOut:
    quote = await quotes.send_quote(db, order_id, version, admin.id, data.confirm_low_fee, client_ip(request))
    settings = await get_settings_map(db)
    await db.commit()
    await db.refresh(quote, ["lines"])
    return admin_quote_out(quote, int(settings["min_fee_xof"]), await _shot_url(db, quote.id))


@router.post("/{order_id}/purchase", response_model=PurchaseOut)
async def purchase(order_id: int, data: PurchaseIn, request: Request, admin: AdminContext = operator, db: AsyncSession = Depends(get_session)) -> PurchaseOut:
    result = await operations.record_purchase(db, order_id, data, admin.id, client_ip(request))
    await db.commit()
    return PurchaseOut(**result)  # type: ignore[arg-type]


@router.post("/{order_id}/items/{item_id}/cancel-by-store", response_model=RefundOut)
async def cancel_item(order_id: int, item_id: int, data: CancelItemIn, request: Request, admin: AdminContext = operator, db: AsyncSession = Depends(get_session)) -> RefundOut:
    refund = await operations.cancel_item_by_store(db, order_id, item_id, data.reason, admin.id, client_ip(request))
    await db.commit()
    return RefundOut.model_validate(refund)


@router.post("/{order_id}/ready-for-pickup")
async def ready_for_pickup(order_id: int, data: ReadyForPickupIn, request: Request, admin: AdminContext = pickup_desk, db: AsyncSession = Depends(get_session)) -> dict[str, str]:
    code = await operations.mark_ready_for_pickup(db, order_id, data.pickup_point_id, admin.id, client_ip(request))
    await db.commit()
    return {"code": code}


class ConfirmPaymentIn(BaseModel):
    model_config = ConfigDict(extra="forbid")
    transaction_ref: Annotated[str, StringConstraints(strip_whitespace=True, max_length=80)] | None = None


@router.post("/{order_id}/confirm-payment", status_code=204)
async def confirm_payment(order_id: int, data: ConfirmPaymentIn, request: Request, admin: AdminContext = operator, db: AsyncSession = Depends(get_session)) -> None:
    """Wave QR: the admin saw the money in their Wave app. Marks the payment received and the order paid."""
    await payments_service.confirm_manual_payment(db, order_id, data.transaction_ref, admin.id, client_ip(request))
    await db.commit()


@router.get("/{order_id}/payment-proof")
async def payment_proof(order_id: int, _: AdminContext = viewer, db: AsyncSession = Depends(get_session)) -> Response:
    """The customer's payment screenshot (latest one), admins only."""
    payment = await db.scalar(
        select(Payment).where(Payment.order_id == order_id, Payment.proof_content_type.is_not(None))
        .order_by(Payment.id.desc()).limit(1).options(undefer(Payment.proof_image))
    )
    if payment is None or payment.proof_image is None:
        raise NotFound()
    return Response(payment.proof_image, media_type=payment.proof_content_type or "image/jpeg", headers={"Cache-Control": "private, no-store"})


class WhatsAppMessageIn(BaseModel):
    model_config = ConfigDict(extra="forbid")
    kind: Literal["quote", "payment", "pickup"]
    code: Annotated[str, StringConstraints(pattern=r"^\d{6}$")] | None = None


@router.post("/{order_id}/archive", status_code=204)
async def archive_order(order_id: int, request: Request, admin: AdminContext = operator, db: AsyncSession = Depends(get_session)) -> None:
    """Remove a finished order from the admin lists (collected, cancelled or refunded). Kept for history."""
    order = await db.get(Order, order_id)
    if order is None:
        raise NotFound()
    if order.status not in (OrderStatus.PICKED_UP, OrderStatus.CANCELLED, OrderStatus.REFUNDED):
        raise Conflict("order_not_finished")
    order.archived_at = utcnow()
    await audit(db, actor_type="admin", actor_id=admin.id, action="order.archived", entity="order", entity_id=order.id, ip=client_ip(request))
    await db.commit()


@router.post("/{order_id}/whatsapp")
async def whatsapp_message(order_id: int, data: WhatsAppMessageIn, request: Request, admin: AdminContext = pickup_desk, db: AsyncSession = Depends(get_session)) -> dict[str, str]:
    """Pre-written message + wa.me link: the admin sends it from their own WhatsApp."""
    if admin.role == AdminRole.PICKUP and data.kind != "pickup":
        raise Forbidden("forbidden")
    order = await db.get(Order, order_id)
    customer = await db.get(Customer, order.customer_id) if order else None
    if order is None or customer is None or customer.phone_enc is None:
        raise NotFound()
    quote = await quotes.latest_non_draft(db, order.id)
    point = await db.get(PickupPoint, order.pickup_point_id) if order.pickup_point_id else None
    if data.kind == "quote" and quote is None:
        raise Conflict("no_quote")
    if data.kind == "pickup" and (point is None or data.code is None):
        raise Conflict("pickup_not_ready")
    text = wa.text_for(data.kind, customer, order, quote, point, data.code)
    await audit(db, actor_type="admin", actor_id=admin.id, action=f"whatsapp.{data.kind}", entity="order", entity_id=order.id, ip=client_ip(request))
    await db.commit()
    return {"url": wa.wa_link(decrypt(customer.phone_enc), text), "text": text}


@router.post("/{order_id}/pickup", status_code=204)
async def confirm_pickup(order_id: int, data: PickupConfirmIn, request: Request, admin: AdminContext = pickup_desk, db: AsyncSession = Depends(get_session)) -> None:
    await operations.confirm_pickup(db, order_id, data.code, admin.id, client_ip(request))
    await db.commit()
