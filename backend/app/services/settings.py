"""Business settings editable by a SUPER_ADMIN; defaults apply until overridden in `app_settings`."""

from typing import Any

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models import AppSetting

DEFAULTS: dict[str, Any] = {
    # Units of XOF per 1 unit of the source currency, as strings to keep Decimal precision.
    "fx_rates": {"EUR": "655.957", "USD": "610", "XOF": "1"},
    "freight_per_item_xof": 3000,
    "customs_rate_percent": 20,
    "min_fee_xof": 2000,
    "quote_validity_hours": 48,
    "price_increase_buffer_percent": 5,
    "store_currency_default": "EUR",
    # wave_qr: customer pays your personal Wave QR / number, admin confirms by hand.
    # wave_checkout: Wave Business Checkout API (automatic confirmation).
    "payment_mode": "wave_qr",
    "wave_phone": None,
    "wave_qr_image": None,  # {"content_type": ..., "data_b64": ...}: kept in the DB, survives redeploys
    # Transport pre-filled on cart-mode quotes.
    "freight_default_xof": 5000,
    # Next weekly shipment leaving for Abidjan (ISO date), shown to customers. None hides the card.
    "next_departure_date": None,
}


async def get_settings_map(db: AsyncSession) -> dict[str, Any]:
    rows = (await db.scalars(select(AppSetting))).all()
    merged = dict(DEFAULTS)
    merged.update({r.key: r.value for r in rows})
    return merged


async def set_setting(db: AsyncSession, key: str, value: Any, admin_id: int) -> None:
    if key not in DEFAULTS:
        raise KeyError(key)
    row = await db.get(AppSetting, key)
    if row is None:
        db.add(AppSetting(key=key, value=value, updated_by=admin_id))
    else:
        row.value = value
        row.updated_by = admin_id
