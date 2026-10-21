from typing import Literal

from fastapi import APIRouter, Depends, Query, Request
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.db import get_session
from app.enums import AdminRole, OrderStatus, QuoteStatus
from app.errors import NotFound
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
from app.security.crypto import decrypt, mask_phone
from app.security.deps import AdminContext, client_ip, require_role
from app.services import location as loc
from app.services import operations, quotes
from app.services.audit import audit
from app.services.settings import get_settings_map

router = APIRouter(prefix="/admin/orders", tags=["admin-orders"], dependencies=[Depends(admin_limited)])
viewer = Depends(require_role(AdminRole.VIEWER))
operator = Depends(require_role(AdminRole.OPERATOR))

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


def admin_quote_out(q: Quote, min_fee: int) -> AdminQuoteOut:
    return AdminQuoteOut(
        id=q.id, version=q.version, status=q.status, items_xof=q.items_xof, freight_xof=q.freight_xof,
        customs_xof=q.customs_xof, fee_xof=q.fee_xof, total_xof=q.total_xof, admin_note=q.admin_note,
        expires_at=q.expires_at, sent_at=q.sent_at, fx_rates=q.fx_rates, created_by=q.created_by,
        answered_at=q.answered_at, min_fee_xof=min_fee, fee_below_minimum=q.fee_xof < min_fee,
        lines=[QuoteLineOut.model_validate(line) for line in q.lines],
    )


@router.get("", response_model=list[AdminOrderSummaryOut])
async def inbox(
    tab: Literal["to_quote", "quoted", "to_buy", "to_ship", "in_transit", "pickups", "refunds", "done", "all"] = "to_quote",
    q: str | None = Query(default=None, max_length=20),
    _: AdminContext = viewer,
    db: AsyncSession = Depends(get_session),
) -> list[AdminOrderSummaryOut]:
    stmt = select(Order, Customer.display_name).join(Customer, Customer.id == Order.customer_id)
    if q:
        stmt = stmt.where(Order.public_ref.ilike(f"%{q.strip().upper()}%"))
    elif tab != "all":
        stmt = stmt.where(Order.status.in_(TABS[tab]))
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
            id=o.id, public_ref=o.public_ref, status=o.status, customer_name=name, total_xof=o.total_xof,
            created_at=o.created_at, status_changed_at=o.status_changed_at, has_change_request=o.id in change_requested,
        )
        for o, name in rows
    ]


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
    attachments = (await db.scalars(select(OrderAttachment).where(OrderAttachment.order_id == order.id))).all()
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
        source_cart_url=order.source_cart_url,
        submitted_links=order.submitted_links,
        customer_note=order.customer_note,
        pickup_point=PickupPointOut.model_validate(point) if point else None,
        delivery_location=_location(order.delivery_commune, order.delivery_location_enc),
        items=[OrderItemOut.model_validate(i) for i in items],
        quotes=[admin_quote_out(q, min_fee) for q in all_quotes],
        change_requests=[ChangeRequestOut.model_validate(c) for c in changes],
        attachments=[AttachmentOut(id=a.id, url=storage.signed_url(a.storage_key), content_type=a.content_type) for a in attachments],
        payments=[PaymentOut(status=p.status, amount_xof=p.amount_xof, launch_url=None) for p in payments],
        purchase=StorePurchaseOut.model_validate(purchase) if purchase else None,
        history=[StatusEventOut.model_validate(h) for h in history],
        shipment_id=shipment_id,
    )


@router.get("/{order_id}", response_model=AdminOrderDetailOut)
async def detail(order_id: int, _: AdminContext = viewer, db: AsyncSession = Depends(get_session)) -> AdminOrderDetailOut:
    return await _detail(db, order_id)


@router.post("/{order_id}/reveal-phone")
async def reveal_phone(order_id: int, request: Request, admin: AdminContext = operator, db: AsyncSession = Depends(get_session)) -> dict[str, str]:
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
    return admin_quote_out(quote, meta["min_fee_xof"])


@router.post("/{order_id}/quotes/{version}/send", response_model=AdminQuoteOut)
async def send(order_id: int, version: int, data: SendQuoteIn, request: Request, admin: AdminContext = operator, db: AsyncSession = Depends(get_session)) -> AdminQuoteOut:
    quote = await quotes.send_quote(db, order_id, version, admin.id, data.confirm_low_fee, client_ip(request))
    settings = await get_settings_map(db)
    await db.commit()
    await db.refresh(quote, ["lines"])
    return admin_quote_out(quote, int(settings["min_fee_xof"]))


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


@router.post("/{order_id}/ready-for-pickup", status_code=204)
async def ready_for_pickup(order_id: int, data: ReadyForPickupIn, request: Request, admin: AdminContext = operator, db: AsyncSession = Depends(get_session)) -> None:
    await operations.mark_ready_for_pickup(db, order_id, data.pickup_point_id, admin.id, client_ip(request))
    await db.commit()


@router.post("/{order_id}/pickup", status_code=204)
async def confirm_pickup(order_id: int, data: PickupConfirmIn, request: Request, admin: AdminContext = operator, db: AsyncSession = Depends(get_session)) -> None:
    await operations.confirm_pickup(db, order_id, data.code, admin.id, client_ip(request))
    await db.commit()
