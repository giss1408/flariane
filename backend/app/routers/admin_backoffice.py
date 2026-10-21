"""Back office (admin web panel): devices, admin users, settings, pickup points, refunds, reports."""

import csv
import io
from datetime import UTC, date, datetime, time, timedelta

import pyotp
from fastapi import APIRouter, Depends, File, Query, Request, UploadFile
from fastapi.responses import StreamingResponse
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.db import get_session
from app.enums import AdminRole, PaymentStatus, RefundStatus
from app.errors import BadRequest, Conflict, NotFound
from app.models import AdminDevice, AdminUser, AuditLog, Customer, Order, Payment, PickupPoint, Quote, Refund, RefreshToken
from app.ratelimit import admin_limited
from typing import Annotated

from pydantic import StringConstraints

from app.schemas import In
from app.schemas import (
    AdminDeviceOut,
    AdminUserCreatedOut,
    AdminUserIn,
    AdminUserOut,
    DispatchGroupOut,
    DispatchOrderOut,
    LocationOut,
    PickupPointIn,
    PickupPointOut,
    RefundCompleteIn,
    RefundOut,
    ReportSummaryOut,
    SettingsIn,
    TempPasswordOut,
)
from app.security.crypto import encrypt, hash_password
from app.security.deps import AdminContext, client_ip, require_role
from app.security.tokens import revoke_device_tokens, utcnow
from app.services import customer_auth, operations
from app.services import location as loc
from app.services.audit import audit
from app.services.settings import get_settings_map, set_setting

router = APIRouter(prefix="/admin", tags=["admin-backoffice"], dependencies=[Depends(admin_limited)])
viewer = Depends(require_role(AdminRole.VIEWER))
operator = Depends(require_role(AdminRole.OPERATOR))
super_admin = Depends(require_role(AdminRole.SUPER_ADMIN))


# ---------------------------------------------------------------- dispatch


@router.get("/dispatch", response_model=list[DispatchGroupOut])
async def dispatch(
    statuses: str = "IN_TRANSIT,ARRIVED,READY_FOR_PICKUP",
    _: AdminContext = viewer,
    db: AsyncSession = Depends(get_session),
) -> list[DispatchGroupOut]:
    """Parcels on their way or arrived, grouped by the customer's commune, to plan dispatch."""
    wanted = [s for s in statuses.split(",") if s]
    rows = (
        await db.execute(
            select(Order, Customer.display_name)
            .join(Customer, Customer.id == Order.customer_id)
            .where(Order.status.in_(wanted))
            .order_by(Order.delivery_commune, Order.public_ref)
        )
    ).all()
    groups: dict[str, list[DispatchOrderOut]] = {}
    for o, name in rows:
        data = loc.unpack(o.delivery_commune, o.delivery_location_enc)
        groups.setdefault(o.delivery_commune or "Non renseignée", []).append(
            DispatchOrderOut(order_id=o.id, public_ref=o.public_ref, status=o.status, customer_name=name,
                             location=LocationOut(**data) if data else None)
        )
    # Biggest communes first; orders without a location at the end.
    ordered = sorted(groups.items(), key=lambda kv: (kv[0] == "Non renseignée", -len(kv[1]), kv[0]))
    return [DispatchGroupOut(commune=c, orders=os) for c, os in ordered]


# ---------------------------------------------------------------- whatsapp


class WhatsAppTestIn(In):
    phone: Annotated[str, StringConstraints(max_length=30)]


@router.post("/whatsapp/test")
async def whatsapp_test(data: WhatsAppTestIn, request: Request, admin: AdminContext = super_admin, db: AsyncSession = Depends(get_session)) -> dict:
    """Sends Meta's `hello_world` template to check the WhatsApp Cloud API credentials."""
    from app.config import get_settings as app_settings
    from app.integrations import whatsapp

    phone = customer_auth.normalize_ci_phone(data.phone)
    mode = app_settings().whatsapp_mode
    try:
        message_id = await whatsapp.send_template(phone, "hello_world", [], lang="en_US")
    except whatsapp.WhatsAppError as exc:
        raise BadRequest("whatsapp_failed", str(exc)[:300]) from None
    await audit(db, actor_type="admin", actor_id=admin.id, action="whatsapp.test", after={"mode": mode, "to": phone[-4:]}, ip=client_ip(request))
    await db.commit()
    return {"mode": mode, "message_id": message_id, "sent": mode == "live"}


# ---------------------------------------------------------------- customers


@router.post("/customers/{customer_id}/reset-password", response_model=TempPasswordOut)
async def reset_customer_password(customer_id: int, request: Request, admin: AdminContext = operator, db: AsyncSession = Depends(get_session)) -> TempPasswordOut:
    """Forgotten password: issue a one-time temporary password for the admin to pass on (WhatsApp/phone).
    All the customer's sessions are signed out and the app asks for a new password at next login."""
    customer = await db.get(Customer, customer_id)
    if customer is None or customer.anonymised_at is not None:
        raise NotFound()
    temp = customer_auth.temporary_password()
    customer.password_hash, customer.must_change_password = hash_password(temp), True
    for t in (await db.scalars(select(RefreshToken).where(RefreshToken.subject_type == "customer", RefreshToken.subject_id == customer.id, RefreshToken.revoked_at.is_(None)))).all():
        t.revoked_at = utcnow()
    await audit(db, actor_type="admin", actor_id=admin.id, action="customer.password_reset", entity="customer", entity_id=customer.id, ip=client_ip(request))
    await db.commit()
    return TempPasswordOut(temporary_password=temp)


# ---------------------------------------------------------------- devices


@router.get("/devices", response_model=list[AdminDeviceOut])
async def devices(_: AdminContext = super_admin, db: AsyncSession = Depends(get_session)) -> list[AdminDevice]:
    return list((await db.scalars(select(AdminDevice).order_by(AdminDevice.id.desc()))).all())


@router.post("/devices/{device_id}/approve", response_model=AdminDeviceOut)
async def approve_device(device_id: int, request: Request, admin: AdminContext = super_admin, db: AsyncSession = Depends(get_session)) -> AdminDevice:
    device = await db.get(AdminDevice, device_id)
    if device is None:
        raise NotFound()
    if device.revoked_at is not None:
        raise Conflict("device_revoked")
    device.approved_by, device.approved_at = admin.id, utcnow()
    await audit(db, actor_type="admin", actor_id=admin.id, action="device.approved", entity="admin_device", entity_id=device.id, ip=client_ip(request))
    await db.commit()
    return device


@router.post("/devices/{device_id}/revoke", response_model=AdminDeviceOut)
async def revoke_device(device_id: int, request: Request, admin: AdminContext = super_admin, db: AsyncSession = Depends(get_session)) -> AdminDevice:
    device = await db.get(AdminDevice, device_id)
    if device is None:
        raise NotFound()
    device.revoked_at = utcnow()
    device.push_token = None
    await revoke_device_tokens(db, device.id)
    await audit(db, actor_type="admin", actor_id=admin.id, action="device.revoked", entity="admin_device", entity_id=device.id, ip=client_ip(request))
    await db.commit()
    return device


# ---------------------------------------------------------------- admin users


@router.get("/users", response_model=list[AdminUserOut])
async def users(_: AdminContext = super_admin, db: AsyncSession = Depends(get_session)) -> list[AdminUser]:
    return list((await db.scalars(select(AdminUser).order_by(AdminUser.id))).all())


@router.post("/users", response_model=AdminUserCreatedOut, status_code=201)
async def create_user(data: AdminUserIn, request: Request, admin: AdminContext = super_admin, db: AsyncSession = Depends(get_session)) -> AdminUserCreatedOut:
    if await db.scalar(select(AdminUser).where(AdminUser.email == data.email)):
        raise Conflict("email_taken")
    secret = pyotp.random_base32()
    user = AdminUser(email=data.email, name=data.name, role=data.role, password_hash=hash_password(data.password), totp_secret_enc=encrypt(secret))
    db.add(user)
    await db.flush()
    await audit(db, actor_type="admin", actor_id=admin.id, action="admin_user.created", entity="admin_user", entity_id=user.id, after={"role": data.role}, ip=client_ip(request))
    await db.commit()
    uri = pyotp.TOTP(secret).provisioning_uri(name=user.email, issuer_name="Flariane Admin")
    return AdminUserCreatedOut(**AdminUserOut.model_validate(user).model_dump(), totp_uri=uri)


@router.post("/users/{user_id}/deactivate", response_model=AdminUserOut)
async def deactivate_user(user_id: int, request: Request, admin: AdminContext = super_admin, db: AsyncSession = Depends(get_session)) -> AdminUser:
    if user_id == admin.id:
        raise BadRequest("cannot_deactivate_self")
    user = await db.get(AdminUser, user_id)
    if user is None:
        raise NotFound()
    user.active = False
    for device in (await db.scalars(select(AdminDevice).where(AdminDevice.admin_user_id == user.id))).all():
        await revoke_device_tokens(db, device.id)
    await audit(db, actor_type="admin", actor_id=admin.id, action="admin_user.deactivated", entity="admin_user", entity_id=user.id, ip=client_ip(request))
    await db.commit()
    return user


# ---------------------------------------------------------------- settings & pickup points


def _public_settings(settings: dict) -> dict:
    out = {k: v for k, v in settings.items() if k != "wave_qr_image"}
    out["has_wave_qr"] = bool(settings.get("wave_qr_image"))
    return out


@router.get("/settings")
async def get_settings(_: AdminContext = viewer, db: AsyncSession = Depends(get_session)) -> dict:
    return _public_settings(await get_settings_map(db))


@router.post("/settings/wave-qr")
async def upload_wave_qr(request: Request, file: UploadFile = File(...), admin: AdminContext = super_admin, db: AsyncSession = Depends(get_session)) -> dict:
    """Your personal Wave QR (screenshot from the Wave app). Stored in the database."""
    import base64

    from app.integrations import storage

    data, content_type, _ = storage.sanitize_image(await file.read(5 * 1024 * 1024 + 1))
    await set_setting(db, "wave_qr_image", {"content_type": content_type, "data_b64": base64.b64encode(data).decode()}, admin.id)
    await audit(db, actor_type="admin", actor_id=admin.id, action="settings.wave_qr", ip=client_ip(request))
    await db.commit()
    return _public_settings(await get_settings_map(db))


@router.put("/settings")
async def update_settings(data: SettingsIn, request: Request, admin: AdminContext = super_admin, db: AsyncSession = Depends(get_session)) -> dict:
    before = _public_settings(await get_settings_map(db))
    changes = data.model_dump(exclude_none=True, mode="json")
    if "fx_rates" in changes:
        changes["fx_rates"] = {**before["fx_rates"], **{k: str(v) for k, v in changes["fx_rates"].items()}, "XOF": "1"}
    for key, value in changes.items():
        await set_setting(db, key, value, admin.id)
    await audit(db, actor_type="admin", actor_id=admin.id, action="settings.updated", before={k: before[k] for k in changes}, after=changes, ip=client_ip(request))
    await db.commit()
    return _public_settings(await get_settings_map(db))


@router.get("/pickup-points", response_model=list[PickupPointOut])
async def list_points(_: AdminContext = viewer, db: AsyncSession = Depends(get_session)) -> list[PickupPoint]:
    return list((await db.scalars(select(PickupPoint).order_by(PickupPoint.name))).all())


@router.post("/pickup-points", response_model=PickupPointOut, status_code=201)
async def create_point(data: PickupPointIn, admin: AdminContext = super_admin, db: AsyncSession = Depends(get_session)) -> PickupPoint:
    point = PickupPoint(**data.model_dump())
    db.add(point)
    await db.flush()
    await audit(db, actor_type="admin", actor_id=admin.id, action="pickup_point.created", entity="pickup_point", entity_id=point.id)
    await db.commit()
    return point


@router.put("/pickup-points/{point_id}", response_model=PickupPointOut)
async def update_point(point_id: int, data: PickupPointIn, admin: AdminContext = super_admin, db: AsyncSession = Depends(get_session)) -> PickupPoint:
    point = await db.get(PickupPoint, point_id)
    if point is None:
        raise NotFound()
    for k, v in data.model_dump().items():
        setattr(point, k, v)
    await audit(db, actor_type="admin", actor_id=admin.id, action="pickup_point.updated", entity="pickup_point", entity_id=point.id)
    await db.commit()
    return point


# ---------------------------------------------------------------- refunds & held payments


@router.get("/refunds", response_model=list[RefundOut])
async def refunds(status: RefundStatus | None = None, _: AdminContext = viewer, db: AsyncSession = Depends(get_session)) -> list[Refund]:
    stmt = select(Refund).order_by(Refund.id.desc()).limit(200)
    if status:
        stmt = stmt.where(Refund.status == status)
    return list((await db.scalars(stmt)).all())


@router.post("/refunds/{refund_id}/complete", response_model=RefundOut)
async def complete_refund(refund_id: int, data: RefundCompleteIn, request: Request, admin: AdminContext = super_admin, db: AsyncSession = Depends(get_session)) -> Refund:
    refund = await operations.complete_refund(db, refund_id, data.external_ref, admin.id, client_ip(request))
    await db.commit()
    return refund


@router.get("/payments/held")
async def held_payments(_: AdminContext = viewer, db: AsyncSession = Depends(get_session)) -> list[dict]:
    rows = (
        await db.execute(
            select(Payment, Order.public_ref).join(Order, Order.id == Payment.order_id).where(Payment.status == PaymentStatus.HELD)
        )
    ).all()
    return [
        {"payment_id": p.id, "order_id": p.order_id, "order_ref": ref, "amount_xof": p.amount_xof,
         "reason": p.status_reason, "provider_txn_id": p.provider_txn_id, "created_at": p.created_at}
        for p, ref in rows
    ]


@router.post("/payments/{payment_id}/refund", response_model=RefundOut)
async def refund_held(payment_id: int, request: Request, admin: AdminContext = super_admin, db: AsyncSession = Depends(get_session)) -> Refund:
    refund = await operations.refund_held_payment(db, payment_id, admin.id, client_ip(request))
    await db.commit()
    return refund


# ---------------------------------------------------------------- reports & audit


def _range(start: date | None, end: date | None) -> tuple[datetime, datetime]:
    end_d = end or date.today()
    start_d = start or end_d - timedelta(days=30)
    return datetime.combine(start_d, time.min, UTC), datetime.combine(end_d + timedelta(days=1), time.min, UTC)


@router.get("/reports/summary", response_model=ReportSummaryOut)
async def summary(start: date | None = None, end: date | None = None, _: AdminContext = viewer, db: AsyncSession = Depends(get_session)) -> ReportSummaryOut:
    lo, hi = _range(start, end)
    by_status = dict(
        (await db.execute(select(Order.status, func.count()).where(Order.created_at >= lo, Order.created_at < hi).group_by(Order.status))).all()
    )
    paid = select(Payment).where(Payment.status.in_([PaymentStatus.SUCCEEDED, PaymentStatus.REFUNDED]), Payment.confirmed_at >= lo, Payment.confirmed_at < hi).subquery()
    revenue = int(await db.scalar(select(func.coalesce(func.sum(paid.c.amount_xof), 0))) or 0)
    paid_orders = await db.scalar(select(func.count()).select_from(paid)) or 0
    fees = int(await db.scalar(
        select(func.coalesce(func.sum(Quote.fee_xof), 0)).join(paid, paid.c.quote_id == Quote.id)
    ) or 0)
    refunded = int(await db.scalar(
        select(func.coalesce(func.sum(Refund.amount_xof), 0)).where(Refund.status == RefundStatus.COMPLETED, Refund.completed_at >= lo, Refund.completed_at < hi)
    ) or 0)
    pending_refunds = await db.scalar(select(func.count()).select_from(Refund).where(Refund.status == RefundStatus.PENDING)) or 0
    return ReportSummaryOut(
        orders_by_status=by_status, revenue_xof=revenue, fees_xof=fees, refunds_xof=refunded,
        pending_refunds=pending_refunds, paid_orders=paid_orders,
    )


def _csv_cell(value: object) -> str:
    """Neutralise spreadsheet formula injection (=, +, -, @ at the start of a cell)."""
    text = "" if value is None else str(value)
    return "'" + text if text[:1] in ("=", "+", "-", "@", "\t", "\r") else text


@router.get("/reports/orders.csv")
async def orders_csv(start: date | None = None, end: date | None = None, admin: AdminContext = viewer, db: AsyncSession = Depends(get_session)) -> StreamingResponse:
    lo, hi = _range(start, end)
    rows = (
        await db.execute(
            select(Order, Customer.display_name, Quote)
            .join(Customer, Customer.id == Order.customer_id)
            .outerjoin(Quote, (Quote.order_id == Order.id) & (Quote.status == "ACCEPTED"))
            .where(Order.created_at >= lo, Order.created_at < hi)
            .order_by(Order.created_at)
        )
    ).all()
    buf = io.StringIO()
    w = csv.writer(buf, delimiter=";")
    w.writerow(["reference", "date", "client", "statut", "articles_xof", "transport_xof", "douane_xof", "frais_xof", "total_xof"])
    for o, name, q in rows:
        w.writerow([_csv_cell(v) for v in (
            o.public_ref, o.created_at.date().isoformat(), name, o.status,
            q.items_xof if q else "", q.freight_xof if q else "", q.customs_xof if q else "", q.fee_xof if q else "", o.total_xof or "",
        )])
    await audit(db, actor_type="admin", actor_id=admin.id, action="report.exported", after={"from": lo.isoformat(), "to": hi.isoformat()})
    await db.commit()
    return StreamingResponse(
        iter(["﻿" + buf.getvalue()]),  # BOM so Excel opens accents correctly
        media_type="text/csv; charset=utf-8",
        headers={"Content-Disposition": f'attachment; filename="commandes_{lo.date()}_{(hi - timedelta(days=1)).date()}.csv"'},
    )


@router.get("/audit-log")
async def audit_log(
    entity: str | None = None, entity_id: int | None = None, limit: int = Query(default=100, le=500),
    _: AdminContext = super_admin, db: AsyncSession = Depends(get_session),
) -> list[dict]:
    stmt = select(AuditLog).order_by(AuditLog.id.desc()).limit(limit)
    if entity:
        stmt = stmt.where(AuditLog.entity == entity)
    if entity_id is not None:
        stmt = stmt.where(AuditLog.entity_id == entity_id)
    return [
        {"id": a.id, "actor_type": a.actor_type, "actor_id": a.actor_id, "action": a.action, "entity": a.entity,
         "entity_id": a.entity_id, "before": a.before, "after": a.after, "ip": a.ip, "created_at": a.created_at}
        for a in (await db.scalars(stmt)).all()
    ]

