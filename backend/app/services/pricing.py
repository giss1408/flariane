"""Quote arithmetic. Pure functions: the server is the only place totals are computed."""

from dataclasses import dataclass
from decimal import ROUND_CEILING, Decimal


@dataclass(frozen=True)
class LineInput:
    qty: int
    source_price: Decimal
    source_currency: str


@dataclass(frozen=True)
class LineAmounts:
    unit_price_xof: int
    line_total_xof: int


@dataclass(frozen=True)
class QuoteAmounts:
    lines: list[LineAmounts]
    items_xof: int
    freight_xof: int
    customs_xof: int
    fee_xof: int
    total_xof: int


def to_xof(amount: Decimal, currency: str, fx_rates: dict[str, str]) -> int:
    """Convert to XOF and round up to the next franc (never under-charge on FX)."""
    if currency not in fx_rates:
        raise ValueError(f"no FX rate for {currency}")
    return int((amount * Decimal(fx_rates[currency])).to_integral_value(rounding=ROUND_CEILING))


def compute_quote(
    lines: list[LineInput],
    fx_rates: dict[str, str],
    *,
    freight_xof: int,
    customs_xof: int,
    fee_xof: int,
) -> QuoteAmounts:
    if any(v < 0 for v in (freight_xof, customs_xof, fee_xof)):
        raise ValueError("amounts must be positive")
    computed = []
    for line in lines:
        unit = to_xof(line.source_price, line.source_currency, fx_rates)
        computed.append(LineAmounts(unit_price_xof=unit, line_total_xof=unit * line.qty))
    items = sum(c.line_total_xof for c in computed)
    return QuoteAmounts(
        lines=computed,
        items_xof=items,
        freight_xof=freight_xof,
        customs_xof=customs_xof,
        fee_xof=fee_xof,
        total_xof=items + freight_xof + customs_xof + fee_xof,
    )


def default_freight(item_count: int, per_item_xof: int) -> int:
    return item_count * per_item_xof


def default_customs(items_xof: int, rate_percent: int | float) -> int:
    return int((Decimal(items_xof) * Decimal(str(rate_percent)) / 100).to_integral_value(rounding=ROUND_CEILING))
