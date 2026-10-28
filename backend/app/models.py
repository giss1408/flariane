"""Domain model. All money is integer XOF (no minor unit). Enum columns are plain strings."""

from datetime import date, datetime
from decimal import Decimal
from typing import Any

from sqlalchemy import (
    JSON,
    BigInteger,
    Boolean,
    Date,
    DateTime,
    ForeignKey,
    Integer,
    LargeBinary,
    Numeric,
    String,
    Text,
    UniqueConstraint,
    func,
)
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.db import Base


def _ts(nullable: bool = True) -> Mapped[datetime | None]:
    return mapped_column(DateTime(timezone=True), nullable=nullable)


class TimestampMixin:
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())


class Customer(TimestampMixin, Base):
    __tablename__ = "customers"
    id: Mapped[int] = mapped_column(primary_key=True)
    display_name: Mapped[str | None] = mapped_column(String(80))
    phone_enc: Mapped[bytes | None] = mapped_column(LargeBinary)  # AES-GCM; None once anonymised
    phone_hash: Mapped[str | None] = mapped_column(String(64), unique=True, index=True)
    locale: Mapped[str] = mapped_column(String(5), default="fr")
    password_hash: Mapped[str | None] = mapped_column(String(200))  # argon2id
    must_change_password: Mapped[bool] = mapped_column(Boolean, default=False)  # after an admin reset
    # Number ownership, proven with a code the admin sends from their WhatsApp. No orders before that.
    phone_verified_at: Mapped[datetime | None] = _ts()
    verify_code_hash: Mapped[str | None] = mapped_column(String(64))
    verify_code_expires_at: Mapped[datetime | None] = _ts()
    verify_attempts: Mapped[int] = mapped_column(Integer, default=0, server_default="0")
    # Consent to the privacy policy and to WhatsApp contact about orders (law 2013-450 / ARTCI).
    consent_at: Mapped[datetime | None] = _ts()
    consent_version: Mapped[str | None] = mapped_column(String(20))
    # Set when an admin couldn't verify the number: it is released and she must enter a correct one.
    phone_rejected_at: Mapped[datetime | None] = _ts()
    # Where she lives in Abidjan, for dispatch planning. Commune in clear (grouping);
    # quartier, landmark and GPS encrypted as JSON (AES-GCM), like the phone number.
    location_commune: Mapped[str | None] = mapped_column(String(40), index=True)
    location_enc: Mapped[bytes | None] = mapped_column(LargeBinary)
    location_updated_at: Mapped[datetime | None] = _ts()
    anonymised_at: Mapped[datetime | None] = _ts()


class AdminUser(TimestampMixin, Base):
    __tablename__ = "admin_users"
    id: Mapped[int] = mapped_column(primary_key=True)
    email: Mapped[str] = mapped_column(String(200), unique=True)
    name: Mapped[str] = mapped_column(String(80))
    password_hash: Mapped[str] = mapped_column(String(200))
    totp_secret_enc: Mapped[bytes] = mapped_column(LargeBinary)
    totp_last_step: Mapped[int] = mapped_column(BigInteger, default=0)  # blocks replay of a used code
    # False: email + password only, and only from an approved device. Always True for super admins.
    totp_required: Mapped[bool] = mapped_column(Boolean, default=True, server_default="true")
    role: Mapped[str] = mapped_column(String(16))
    active: Mapped[bool] = mapped_column(Boolean, default=True)
    last_login_at: Mapped[datetime | None] = _ts()


class AdminDevice(TimestampMixin, Base):
    __tablename__ = "admin_devices"
    id: Mapped[int] = mapped_column(primary_key=True)
    admin_user_id: Mapped[int] = mapped_column(ForeignKey("admin_users.id"), index=True)
    name: Mapped[str] = mapped_column(String(80))
    platform: Mapped[str] = mapped_column(String(16))  # ios | android | web
    secret_hash: Mapped[str] = mapped_column(String(64))
    push_token: Mapped[str | None] = mapped_column(Text)
    approved_by: Mapped[int | None] = mapped_column(ForeignKey("admin_users.id"))
    approved_at: Mapped[datetime | None] = _ts()
    revoked_at: Mapped[datetime | None] = _ts()
    last_seen_at: Mapped[datetime | None] = _ts()


class RefreshToken(TimestampMixin, Base):
    __tablename__ = "refresh_tokens"
    id: Mapped[int] = mapped_column(primary_key=True)
    subject_type: Mapped[str] = mapped_column(String(8))  # customer | admin
    subject_id: Mapped[int] = mapped_column(Integer, index=True)
    device_id: Mapped[int | None] = mapped_column(ForeignKey("admin_devices.id"))
    family_id: Mapped[str] = mapped_column(String(36), index=True)
    token_hash: Mapped[str] = mapped_column(String(64), unique=True)
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    family_expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    rotated_at: Mapped[datetime | None] = _ts()
    revoked_at: Mapped[datetime | None] = _ts()


class PickupPoint(TimestampMixin, Base):
    __tablename__ = "pickup_points"
    id: Mapped[int] = mapped_column(primary_key=True)
    name: Mapped[str] = mapped_column(String(120))
    address: Mapped[str] = mapped_column(String(300))
    commune: Mapped[str] = mapped_column(String(80))
    opening_hours: Mapped[str] = mapped_column(String(200))
    active: Mapped[bool] = mapped_column(Boolean, default=True)


class Order(TimestampMixin, Base):
    __tablename__ = "orders"
    id: Mapped[int] = mapped_column(primary_key=True)
    public_ref: Mapped[str] = mapped_column(String(16), unique=True)
    customer_id: Mapped[int] = mapped_column(ForeignKey("customers.id"), index=True)
    source_cart_url: Mapped[str | None] = mapped_column(Text)
    store: Mapped[str] = mapped_column(String(16), default="SHEIN", server_default="SHEIN")  # SHEIN | TEMU
    submitted_links: Mapped[list[str]] = mapped_column(JSON, default=list)
    customer_note: Mapped[str | None] = mapped_column(Text)
    # Snapshot of the customer's location when the order was created (or last updated before purchase).
    delivery_commune: Mapped[str | None] = mapped_column(String(40), index=True)
    delivery_location_enc: Mapped[bytes | None] = mapped_column(LargeBinary)
    status: Mapped[str] = mapped_column(String(24), index=True)
    pickup_point_id: Mapped[int | None] = mapped_column(ForeignKey("pickup_points.id"))
    total_xof: Mapped[int | None] = mapped_column(BigInteger)
    status_changed_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    # Hidden from admin lists (delivered orders the admin cleared). Kept for history and reports.
    archived_at: Mapped[datetime | None] = _ts()
    # Finished orders the customer cleared from her own list. The business keeps the order.
    customer_hidden_at: Mapped[datetime | None] = _ts()

    customer: Mapped[Customer] = relationship(lazy="raise")
    pickup_point: Mapped[PickupPoint | None] = relationship(lazy="raise")


class OrderItem(TimestampMixin, Base):
    """A line of the order. Created by the admin while quoting; customers never write these."""

    __tablename__ = "order_items"
    id: Mapped[int] = mapped_column(primary_key=True)
    order_id: Mapped[int] = mapped_column(ForeignKey("orders.id"), index=True)
    source: Mapped[str] = mapped_column(String(16), default="SHEIN")
    source_url: Mapped[str | None] = mapped_column(Text)
    source_product_id: Mapped[str | None] = mapped_column(String(40))
    title: Mapped[str] = mapped_column(String(200))
    size: Mapped[str | None] = mapped_column(String(40))
    color: Mapped[str | None] = mapped_column(String(40))
    qty: Mapped[int] = mapped_column(Integer)
    source_price: Mapped[Decimal] = mapped_column(Numeric(12, 2))
    source_currency: Mapped[str] = mapped_column(String(3))
    item_status: Mapped[str] = mapped_column(String(24), default="OK")
    active: Mapped[bool] = mapped_column(Boolean, default=True)  # False once removed in a later quote version


class OrderAttachment(TimestampMixin, Base):
    __tablename__ = "order_attachments"
    id: Mapped[int] = mapped_column(primary_key=True)
    order_id: Mapped[int] = mapped_column(ForeignKey("orders.id"), index=True)
    kind: Mapped[str] = mapped_column(String(24), default="CART_SCREENSHOT")  # | QUOTE_SCREENSHOT
    quote_id: Mapped[int | None] = mapped_column(ForeignKey("quotes.id"), index=True)  # QUOTE_SCREENSHOT only
    storage_key: Mapped[str] = mapped_column(String(200))
    content_type: Mapped[str] = mapped_column(String(40))


class Quote(TimestampMixin, Base):
    __tablename__ = "quotes"
    __table_args__ = (UniqueConstraint("order_id", "version"),)
    id: Mapped[int] = mapped_column(primary_key=True)
    order_id: Mapped[int] = mapped_column(ForeignKey("orders.id"), index=True)
    version: Mapped[int] = mapped_column(Integer)
    status: Mapped[str] = mapped_column(String(24))
    items_xof: Mapped[int] = mapped_column(BigInteger, default=0)
    freight_xof: Mapped[int] = mapped_column(BigInteger, default=0)
    customs_xof: Mapped[int] = mapped_column(BigInteger, default=0)
    fee_xof: Mapped[int] = mapped_column(BigInteger, default=0)
    total_xof: Mapped[int] = mapped_column(BigInteger, default=0)
    fx_rates: Mapped[dict[str, str]] = mapped_column(JSON, default=dict)  # {"EUR": "655.957"}
    admin_note: Mapped[str | None] = mapped_column(Text)
    validity_hours: Mapped[int] = mapped_column(Integer, default=48)
    # Cart mode: the store price as entered (e.g. 49.90 EUR), converted into items_xof.
    cart_source_amount: Mapped[Decimal | None] = mapped_column(Numeric(12, 2))
    cart_source_currency: Mapped[str | None] = mapped_column(String(3))
    expires_at: Mapped[datetime | None] = _ts()  # set when sent
    created_by: Mapped[int] = mapped_column(ForeignKey("admin_users.id"))
    sent_at: Mapped[datetime | None] = _ts()
    answered_at: Mapped[datetime | None] = _ts()
    sizes_confirmed: Mapped[bool] = mapped_column(Boolean, default=False)

    lines: Mapped[list["QuoteLine"]] = relationship(
        lazy="raise", cascade="all, delete-orphan", order_by="QuoteLine.position"
    )


class QuoteLine(Base):
    """Snapshot of what the customer saw; never changes once the quote is sent."""

    __tablename__ = "quote_lines"
    id: Mapped[int] = mapped_column(primary_key=True)
    quote_id: Mapped[int] = mapped_column(ForeignKey("quotes.id"), index=True)
    order_item_id: Mapped[int] = mapped_column(ForeignKey("order_items.id"))
    position: Mapped[int] = mapped_column(Integer)
    title: Mapped[str] = mapped_column(String(200))
    size: Mapped[str | None] = mapped_column(String(40))
    color: Mapped[str | None] = mapped_column(String(40))
    qty: Mapped[int] = mapped_column(Integer)
    source_price: Mapped[Decimal] = mapped_column(Numeric(12, 2))
    source_currency: Mapped[str] = mapped_column(String(3))
    unit_price_xof: Mapped[int] = mapped_column(BigInteger)
    line_total_xof: Mapped[int] = mapped_column(BigInteger)


class QuoteChangeRequest(TimestampMixin, Base):
    __tablename__ = "quote_change_requests"
    id: Mapped[int] = mapped_column(primary_key=True)
    quote_id: Mapped[int] = mapped_column(ForeignKey("quotes.id"), index=True)
    new_cart_url: Mapped[str | None] = mapped_column(Text)
    removed_item_ids: Mapped[list[int]] = mapped_column(JSON, default=list)
    line_changes: Mapped[list[dict[str, Any]]] = mapped_column(JSON, default=list)
    note: Mapped[str | None] = mapped_column(Text)


class Payment(TimestampMixin, Base):
    __tablename__ = "payments"
    id: Mapped[int] = mapped_column(primary_key=True)
    order_id: Mapped[int] = mapped_column(ForeignKey("orders.id"), index=True)
    quote_id: Mapped[int] = mapped_column(ForeignKey("quotes.id"), index=True)
    provider: Mapped[str] = mapped_column(String(16), default="WAVE")
    checkout_session_id: Mapped[str | None] = mapped_column(String(80), unique=True)
    launch_url: Mapped[str | None] = mapped_column(Text)
    provider_txn_id: Mapped[str | None] = mapped_column(String(80))
    amount_xof: Mapped[int] = mapped_column(BigInteger)
    status: Mapped[str] = mapped_column(String(16))
    idempotency_key: Mapped[str] = mapped_column(String(80), unique=True)
    confirmed_at: Mapped[datetime | None] = _ts()
    status_reason: Mapped[str | None] = mapped_column(Text)
    # Manual mobile-money payments: method chosen and the customer's screenshot (kept in the DB).
    method: Mapped[str | None] = mapped_column(String(8))  # WAVE | ORANGE | MOOV
    proof_image: Mapped[bytes | None] = mapped_column(LargeBinary, deferred=True)
    proof_content_type: Mapped[str | None] = mapped_column(String(40))


class Refund(TimestampMixin, Base):
    __tablename__ = "refunds"
    id: Mapped[int] = mapped_column(primary_key=True)
    payment_id: Mapped[int] = mapped_column(ForeignKey("payments.id"), index=True)
    order_id: Mapped[int] = mapped_column(ForeignKey("orders.id"), index=True)
    amount_xof: Mapped[int] = mapped_column(BigInteger)
    reason: Mapped[str] = mapped_column(String(200))
    status: Mapped[str] = mapped_column(String(16), default="PENDING")
    created_by: Mapped[int | None] = mapped_column(ForeignKey("admin_users.id"))
    completed_by: Mapped[int | None] = mapped_column(ForeignKey("admin_users.id"))
    completed_at: Mapped[datetime | None] = _ts()
    external_ref: Mapped[str | None] = mapped_column(String(80))


class StorePurchase(TimestampMixin, Base):
    __tablename__ = "store_purchases"
    id: Mapped[int] = mapped_column(primary_key=True)
    order_id: Mapped[int] = mapped_column(ForeignKey("orders.id"), unique=True)
    store: Mapped[str] = mapped_column(String(16), default="SHEIN")
    store_order_ref: Mapped[str] = mapped_column(String(80))
    paid_amount: Mapped[Decimal] = mapped_column(Numeric(12, 2))
    currency: Mapped[str] = mapped_column(String(3))
    paid_xof: Mapped[int] = mapped_column(BigInteger)
    price_increase_decision: Mapped[str | None] = mapped_column(String(24))
    purchased_by: Mapped[int] = mapped_column(ForeignKey("admin_users.id"))
    purchased_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())


class Shipment(TimestampMixin, Base):
    __tablename__ = "shipments"
    id: Mapped[int] = mapped_column(primary_key=True)
    label: Mapped[str] = mapped_column(String(80))
    forwarder: Mapped[str | None] = mapped_column(String(80))
    tracking_ref: Mapped[str | None] = mapped_column(String(80))
    weight_kg: Mapped[Decimal | None] = mapped_column(Numeric(8, 2))
    cost_xof: Mapped[int | None] = mapped_column(BigInteger)
    status: Mapped[str] = mapped_column(String(16), default="OPEN")
    # Set from the "prochain départ" setting: one shipment per planned departure.
    departure_date: Mapped[date | None] = mapped_column(Date, unique=True)
    order_deadline: Mapped[date | None] = mapped_column(Date)
    departed_at: Mapped[datetime | None] = _ts()
    arrived_at: Mapped[datetime | None] = _ts()


class ShipmentOrder(Base):
    __tablename__ = "shipment_orders"
    shipment_id: Mapped[int] = mapped_column(ForeignKey("shipments.id"), primary_key=True)
    order_id: Mapped[int] = mapped_column(ForeignKey("orders.id"), primary_key=True, unique=True)


class PickupCode(TimestampMixin, Base):
    __tablename__ = "pickup_codes"
    order_id: Mapped[int] = mapped_column(ForeignKey("orders.id"), primary_key=True)
    code_hash: Mapped[str] = mapped_column(String(64))
    failed_attempts: Mapped[int] = mapped_column(Integer, default=0)
    used_at: Mapped[datetime | None] = _ts()


class WebhookEvent(Base):
    __tablename__ = "webhook_events"
    __table_args__ = (UniqueConstraint("provider", "event_id"),)
    id: Mapped[int] = mapped_column(primary_key=True)
    provider: Mapped[str] = mapped_column(String(16))
    event_id: Mapped[str] = mapped_column(String(120))
    type: Mapped[str] = mapped_column(String(80))
    received_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    processed_at: Mapped[datetime | None] = _ts()


class Notification(TimestampMixin, Base):
    __tablename__ = "notifications"
    id: Mapped[int] = mapped_column(primary_key=True)
    channel: Mapped[str] = mapped_column(String(16))  # whatsapp | push
    customer_id: Mapped[int | None] = mapped_column(ForeignKey("customers.id"))
    admin_device_id: Mapped[int | None] = mapped_column(ForeignKey("admin_devices.id"))
    template: Mapped[str] = mapped_column(String(60))
    status: Mapped[str] = mapped_column(String(16), default="QUEUED")
    provider_message_id: Mapped[str | None] = mapped_column(String(120), index=True)
    error: Mapped[str | None] = mapped_column(Text)


class AppSetting(Base):
    __tablename__ = "app_settings"
    key: Mapped[str] = mapped_column(String(60), primary_key=True)
    value: Mapped[Any] = mapped_column(JSON)
    updated_by: Mapped[int | None] = mapped_column(ForeignKey("admin_users.id"))
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now()
    )


class Offer(TimestampMixin, Base):
    """A promotion the admin shows on every customer's home screen until it ends or is switched off."""

    __tablename__ = "offers"
    id: Mapped[int] = mapped_column(primary_key=True)
    title: Mapped[str] = mapped_column(String(80))
    message: Mapped[str] = mapped_column(String(240), default="", server_default="")
    active: Mapped[bool] = mapped_column(Boolean, default=True, server_default="true")
    ends_at: Mapped[datetime | None] = _ts()
    created_by: Mapped[int | None] = mapped_column(ForeignKey("admin_users.id"))


class OrderStatusHistory(Base):
    __tablename__ = "order_status_history"
    id: Mapped[int] = mapped_column(primary_key=True)
    order_id: Mapped[int] = mapped_column(ForeignKey("orders.id"), index=True)
    from_status: Mapped[str | None] = mapped_column(String(24))
    to_status: Mapped[str] = mapped_column(String(24))
    actor: Mapped[str] = mapped_column(String(40))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())


class AuditLog(Base):
    """Append-only. Never store OTPs, tokens or full phone numbers here."""

    __tablename__ = "audit_log"
    id: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    actor_type: Mapped[str] = mapped_column(String(16))
    actor_id: Mapped[int | None] = mapped_column(Integer)
    action: Mapped[str] = mapped_column(String(60), index=True)
    entity: Mapped[str | None] = mapped_column(String(40))
    entity_id: Mapped[int | None] = mapped_column(Integer)
    before: Mapped[dict[str, Any] | None] = mapped_column(JSON)
    after: Mapped[dict[str, Any] | None] = mapped_column(JSON)
    ip: Mapped[str | None] = mapped_column(String(45))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
