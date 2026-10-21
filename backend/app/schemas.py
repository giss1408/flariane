"""Request/response models. Requests forbid unknown fields; responses are separate models so
internal columns (hashes, encrypted values) can never leak."""

from datetime import date, datetime
from decimal import Decimal
from typing import Annotated, Literal

from pydantic import BaseModel, ConfigDict, Field, StringConstraints

Str80 = Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=80)]
Str200 = Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=200)]
OptStr40 = Annotated[str, StringConstraints(strip_whitespace=True, max_length=40)] | None
Note = Annotated[str, StringConstraints(strip_whitespace=True, max_length=1000)] | None
Currency = Annotated[str, StringConstraints(pattern=r"^[A-Z]{3}$")]


class In(BaseModel):
    model_config = ConfigDict(extra="forbid")


class Out(BaseModel):
    model_config = ConfigDict(from_attributes=True)


# ---------- auth ----------


Password = Annotated[str, StringConstraints(min_length=1, max_length=200)]


class RegisterIn(In):
    phone: Annotated[str, StringConstraints(max_length=30)]
    password: Password
    display_name: Str80 | None = None
    client: Literal["web", "app"] = "app"


class LoginIn(In):
    phone: Annotated[str, StringConstraints(max_length=30)]
    password: Password
    client: Literal["web", "app"] = "app"


class ChangePasswordIn(In):
    current_password: Password
    new_password: Password


class TempPasswordOut(BaseModel):
    temporary_password: str  # shown once to the admin


class RefreshIn(In):
    refresh_token: str | None = None
    client: Literal["web", "app"] = "web"


class TokenOut(BaseModel):
    access_token: str
    token_type: str = "bearer"
    expires_in: int
    refresh_token: str | None = None


class DeviceIn(In):
    device_id: int | None = None
    device_secret: Annotated[str, StringConstraints(max_length=100)] | None = None
    name: Str80
    platform: Literal["ios", "android", "web"]


class AdminLoginIn(In):
    email: Annotated[str, StringConstraints(strip_whitespace=True, to_lower=True, max_length=200)]
    password: Annotated[str, StringConstraints(max_length=200)]
    totp: Annotated[str, StringConstraints(pattern=r"^\d{6}$")]
    device: DeviceIn


class AdminRefreshIn(In):
    refresh_token: str
    device_id: int
    device_secret: str


class AdminLoginOut(BaseModel):
    status: Literal["ok", "device_pending"]
    device_id: int
    device_secret: str | None = None  # returned once, when the device is first registered
    tokens: TokenOut | None = None


class PushTokenIn(In):
    push_token: Annotated[str, StringConstraints(max_length=4096)]


# ---------- customer ----------


Commune = Literal[
    "Abobo", "Adjamé", "Attécoubé", "Cocody", "Koumassi", "Marcory", "Plateau", "Port-Bouët",
    "Treichville", "Yopougon", "Anyama", "Bingerville", "Songon",
]


class LocationIn(In):
    commune: Commune
    quartier: Str80
    landmark: Annotated[str, StringConstraints(strip_whitespace=True, max_length=200)] | None = None
    lat: Annotated[float, Field(ge=4.9, le=5.8)] | None = None  # roughly the Abidjan area
    lng: Annotated[float, Field(ge=-4.6, le=-3.6)] | None = None


class LocationOut(BaseModel):
    commune: str
    quartier: str
    landmark: str | None
    lat: float | None
    lng: float | None
    maps_url: str | None


class CustomerOut(Out):
    id: int
    display_name: str | None
    locale: str
    phone_masked: str
    must_change_password: bool = False
    location: LocationOut | None = None


class CustomerUpdateIn(In):
    display_name: Str80 | None = None
    locale: Literal["fr", "en"] | None = None


class PickupPointOut(Out):
    id: int
    name: str
    address: str
    commune: str
    opening_hours: str


class OrderCreateIn(In):
    share_text: Annotated[str, StringConstraints(max_length=5000)]
    pickup_point_id: int | None = None  # optional for now; the admin sets it at "ready for pickup"
    note: Note = None


class QuoteLineOut(Out):
    order_item_id: int
    title: str
    size: str | None
    color: str | None
    qty: int
    unit_price_xof: int
    line_total_xof: int


class QuoteOut(Out):
    version: int
    status: str
    items_xof: int
    freight_xof: int
    customs_xof: int
    fee_xof: int
    total_xof: int
    admin_note: str | None
    expires_at: datetime | None
    sent_at: datetime | None
    lines: list[QuoteLineOut]
    screenshot_url: str | None = None  # SHEIN cart as quoted (cart mode)


class StatusEventOut(Out):
    to_status: str
    created_at: datetime


class PaymentOut(BaseModel):
    status: str
    amount_xof: int
    launch_url: str | None


class OrderSummaryOut(BaseModel):
    public_ref: str
    status: str
    total_xof: int | None
    created_at: datetime
    status_changed_at: datetime


class OrderDetailOut(OrderSummaryOut):
    store: str = "SHEIN"
    source_cart_url: str | None
    submitted_links: list[str]
    customer_note: str | None
    pickup_point: PickupPointOut | None
    delivery_location: LocationOut | None = None
    quote: QuoteOut | None
    payment: PaymentOut | None
    history: list[StatusEventOut]
    attachments: int
    can_cancel: bool
    can_request_requote: bool


class AcceptQuoteIn(In):
    sizes_confirmed: bool


class LineChangeIn(In):
    order_item_id: int
    size: OptStr40 = None
    color: OptStr40 = None
    qty: Annotated[int, Field(ge=1, le=50)] | None = None


class ChangeRequestIn(In):
    new_share_text: Annotated[str, StringConstraints(max_length=5000)] | None = None
    removed_item_ids: list[int] = Field(default_factory=list, max_length=100)
    line_changes: list[LineChangeIn] = Field(default_factory=list, max_length=100)
    note: Note = None


# ---------- admin ----------


class DraftItemIn(In):
    id: int | None = None  # existing order_item id; omitted for a new line
    title: Str200
    size: OptStr40 = None
    color: OptStr40 = None
    qty: Annotated[int, Field(ge=1, le=50)]
    source_price: Annotated[Decimal, Field(ge=0, le=100000, decimal_places=2)]
    source_currency: Currency
    source_url: Annotated[str, StringConstraints(max_length=1000)] | None = None


class QuoteDraftIn(In):
    """Two modes. Cart mode (used by the app): `cart_price_xof` = SHEIN cart total in FCFA,
    proven by a cart screenshot; quote = cart + transport. Item mode: one line per article."""

    cart_price_xof: Annotated[int, Field(ge=0, le=50_000_000)] | None = None
    items: list[DraftItemIn] = Field(default_factory=list, max_length=100)
    freight_xof: Annotated[int, Field(ge=0, le=10_000_000)] | None = None
    customs_xof: Annotated[int, Field(ge=0, le=10_000_000)] | None = None
    fee_xof: Annotated[int, Field(ge=0, le=10_000_000)] = 0
    fx_rates: dict[Currency, Annotated[Decimal, Field(gt=0, le=100000)]] | None = None
    admin_note: Note = None
    validity_hours: Annotated[int, Field(ge=1, le=168)] | None = None


class SendQuoteIn(In):
    confirm_low_fee: bool = False


class AdminQuoteOut(QuoteOut):
    id: int
    fx_rates: dict[str, str]
    created_by: int
    answered_at: datetime | None
    min_fee_xof: int
    fee_below_minimum: bool


class ChangeRequestOut(Out):
    quote_id: int
    new_cart_url: str | None
    removed_item_ids: list[int]
    line_changes: list[dict]
    note: str | None
    created_at: datetime


class OrderItemOut(Out):
    id: int
    title: str
    size: str | None
    color: str | None
    qty: int
    source_price: Decimal
    source_currency: str
    source_url: str | None
    item_status: str
    active: bool


class AdminOrderSummaryOut(BaseModel):
    id: int
    public_ref: str
    status: str
    customer_name: str | None
    total_xof: int | None
    created_at: datetime
    status_changed_at: datetime
    has_change_request: bool


class AttachmentOut(BaseModel):
    id: int
    url: str
    content_type: str


class StorePurchaseOut(Out):
    store_order_ref: str
    paid_amount: Decimal
    currency: str
    paid_xof: int
    price_increase_decision: str | None
    purchased_at: datetime


class AdminOrderDetailOut(BaseModel):
    id: int
    public_ref: str
    status: str
    customer_id: int
    customer_name: str | None
    customer_phone_masked: str
    store: str = "SHEIN"
    source_cart_url: str | None
    submitted_links: list[str]
    customer_note: str | None
    pickup_point: PickupPointOut | None
    delivery_location: LocationOut | None = None
    items: list[OrderItemOut]
    quotes: list[AdminQuoteOut]
    change_requests: list[ChangeRequestOut]
    attachments: list[AttachmentOut]
    payments: list[PaymentOut]
    purchase: StorePurchaseOut | None
    history: list[StatusEventOut]
    shipment_id: int | None


class PurchaseIn(In):
    store_order_ref: Annotated[str, StringConstraints(strip_whitespace=True, min_length=3, max_length=80)]
    paid_amount: Annotated[Decimal, Field(ge=0, le=10_000_000, decimal_places=2)]
    currency: Currency
    checked_item_ids: list[int] = Field(default_factory=list)
    refused_item_ids: list[int] = Field(default_factory=list)
    price_increase_decision: Literal["ABSORB", "CONTACT_CUSTOMER"] | None = None


class PurchaseOut(BaseModel):
    status: str
    paid_xof: int
    quoted_items_xof: int
    refund_xof: int
    estimated_margin_xof: int


class ShipmentCreateIn(In):
    label: Str80
    forwarder: Str80 | None = None


class ShipmentOrdersIn(In):
    order_ids: list[int] = Field(min_length=1, max_length=500)


class ShipmentDepartIn(In):
    tracking_ref: Str80 | None = None
    weight_kg: Annotated[Decimal, Field(ge=0, le=100000)] | None = None
    cost_xof: Annotated[int, Field(ge=0)] | None = None


class ShipmentOut(Out):
    id: int
    label: str
    forwarder: str | None
    tracking_ref: str | None
    weight_kg: Decimal | None
    cost_xof: int | None
    status: str
    departed_at: datetime | None
    arrived_at: datetime | None
    order_refs: list[str] = []


class ReadyForPickupIn(In):
    pickup_point_id: int | None = None


class PickupConfirmIn(In):
    code: Annotated[str, StringConstraints(pattern=r"^\d{6}$")]


class CancelItemIn(In):
    reason: Str200 = "Article annulé par le magasin"


class RefundOut(Out):
    id: int
    order_id: int
    payment_id: int
    amount_xof: int
    reason: str
    status: str
    created_at: datetime
    completed_at: datetime | None
    external_ref: str | None


class RefundCompleteIn(In):
    external_ref: Annotated[str, StringConstraints(strip_whitespace=True, min_length=3, max_length=80)]


class SettingsIn(In):
    fx_rates: dict[Currency, Annotated[Decimal, Field(gt=0, le=100000)]] | None = None
    freight_per_item_xof: Annotated[int, Field(ge=0)] | None = None
    customs_rate_percent: Annotated[float, Field(ge=0, le=100)] | None = None
    min_fee_xof: Annotated[int, Field(ge=0)] | None = None
    quote_validity_hours: Annotated[int, Field(ge=1, le=168)] | None = None
    price_increase_buffer_percent: Annotated[float, Field(ge=0, le=100)] | None = None
    store_currency_default: Currency | None = None
    freight_default_xof: Annotated[int, Field(ge=0)] | None = None
    next_departure_date: date | None = None


class PickupPointIn(In):
    name: Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=120)]
    address: Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=300)]
    commune: Str80
    opening_hours: Str200
    active: bool = True


class AdminUserIn(In):
    email: Annotated[str, StringConstraints(strip_whitespace=True, to_lower=True, pattern=r"^[^@\s]+@[^@\s]+$")]
    name: Str80
    role: Literal["VIEWER", "OPERATOR", "SUPER_ADMIN"]
    password: Annotated[str, StringConstraints(min_length=12, max_length=200)]


class AdminUserOut(Out):
    id: int
    email: str
    name: str
    role: str
    active: bool
    last_login_at: datetime | None


class AdminUserCreatedOut(AdminUserOut):
    totp_uri: str  # shown once, to scan in an authenticator app


class AdminDeviceOut(Out):
    id: int
    admin_user_id: int
    name: str
    platform: str
    approved_at: datetime | None
    revoked_at: datetime | None
    last_seen_at: datetime | None
    created_at: datetime


class AdminMeOut(BaseModel):
    id: int
    email: str
    name: str
    role: str
    device_id: int


class DispatchOrderOut(BaseModel):
    order_id: int
    public_ref: str
    status: str
    customer_name: str | None
    location: LocationOut | None


class DispatchGroupOut(BaseModel):
    commune: str  # "Non renseignée" when the customer gave no location
    orders: list[DispatchOrderOut]


class ReportSummaryOut(BaseModel):
    orders_by_status: dict[str, int]
    revenue_xof: int
    fees_xof: int
    refunds_xof: int
    pending_refunds: int
    paid_orders: int
