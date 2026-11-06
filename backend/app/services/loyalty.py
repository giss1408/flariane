"""Loyalty points: earned when parcels are collected and friends join, spent as a service-fee reduction.

The ledger is append-only (balance = sum of points). Every credit goes through `_add`, which relies on the
partial unique indexes of `loyalty_ledger` to stay idempotent: a replayed transition or retry inserts nothing.
"""

import secrets
import unicodedata
from typing import Any

from sqlalchemy import func, select
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.errors import BadRequest
from app.models import Customer, LoyaltyLedger, Order, Quote
from app.schemas import LoyaltyEventOut, LoyaltyOut
from app.services.settings import get_settings_map

REFERRAL_SIGNUP, ORDER, REFERRED_ORDER, REDEEM, RELEASE = "REFERRAL_SIGNUP", "ORDER", "REFERRED_ORDER", "REDEEM", "RELEASE"

# No 0/O/1/I: codes are read aloud and typed on a phone.
_ALPHABET = "23456789ABCDEFGHJKLMNPQRSTUVWXYZ"
_LETTERS = "ABCDEFGHJKLMNPQRSTUVWXYZ"


def normalize_code(raw: str) -> str:
    return raw.strip().upper().replace(" ", "")


def _prefix(display_name: str | None) -> str:
    ascii_name = unicodedata.normalize("NFKD", display_name or "").encode("ascii", "ignore").decode().upper()
    letters = "".join(c for c in ascii_name if c in _LETTERS)[:3]
    return letters.ljust(3, "X") if letters else "FLR"


def _new_code(display_name: str | None) -> str:
    return f"{_prefix(display_name)}-" + "".join(secrets.choice(_ALPHABET) for _ in range(4))


async def assign_referral_code(db: AsyncSession, customer: Customer) -> str:
    for _ in range(20):
        code = _new_code(customer.display_name)
        if await db.scalar(select(Customer.id).where(Customer.referral_code == code)) is None:
            customer.referral_code = code
            return code
    raise RuntimeError("could not generate a unique referral code")


async def referrer_for_code(db: AsyncSession, raw: str) -> Customer:
    referrer = await db.scalar(select(Customer).where(Customer.referral_code == normalize_code(raw)))
    if referrer is None or referrer.anonymised_at is not None:
        raise BadRequest("referral_code_invalid", "Code de parrainage inconnu")
    return referrer


async def balance(db: AsyncSession, customer_id: int) -> int:
    return int(await db.scalar(select(func.coalesce(func.sum(LoyaltyLedger.points), 0)).where(LoyaltyLedger.customer_id == customer_id)) or 0)


async def _add(db: AsyncSession, customer_id: int, points: int, kind: str, **refs: Any) -> bool:
    """Insert a ledger row unless the idempotency index says it already exists. Returns whether it was added."""
    if points == 0:
        return False
    stmt = insert(LoyaltyLedger).values(customer_id=customer_id, points=points, kind=kind, **refs).on_conflict_do_nothing()
    return (await db.execute(stmt)).rowcount == 1


async def credit_signup(db: AsyncSession, friend: Customer) -> None:
    """The friend's phone was just verified: the referrer earns the signup points."""
    if friend.referred_by_id is None:
        return
    referrer = await db.get(Customer, friend.referred_by_id)
    if referrer is None or referrer.anonymised_at is not None:
        return
    points = int((await get_settings_map(db))["loyalty_points_referral_signup"])
    await _add(db, referrer.id, points, REFERRAL_SIGNUP, referred_customer_id=friend.id)


async def credit_pickup(db: AsyncSession, order: Order) -> None:
    """The order was collected: the customer earns points, and her referrer the first time."""
    settings = await get_settings_map(db)
    await _add(db, order.customer_id, int(settings["loyalty_points_per_order"]), ORDER, order_id=order.id)
    customer = await db.get(Customer, order.customer_id)
    if customer is None or customer.referred_by_id is None:
        return
    referrer = await db.get(Customer, customer.referred_by_id)
    if referrer is None or referrer.anonymised_at is not None:
        return
    await _add(db, referrer.id, int(settings["loyalty_points_referred_order"]), REFERRED_ORDER, order_id=order.id, referred_customer_id=customer.id)


def discount_for(fee_xof: int, percent: int) -> int:
    return fee_xof * percent // 100


async def redeem(db: AsyncSession, customer_id: int, order: Order, quote: Quote) -> None:
    """Spend the redeem block of points on this quote. Called inside the quote-acceptance transaction."""
    settings = await get_settings_map(db)
    cost = int(settings["loyalty_redeem_points"])
    discount = discount_for(quote.fee_xof, int(settings["loyalty_discount_percent_of_fee"]))
    if discount <= 0:
        raise BadRequest("loyalty_not_available", "Pas de frais de service à réduire")
    await db.execute(select(Customer.id).where(Customer.id == customer_id).with_for_update())  # serialise concurrent redemptions
    if await balance(db, customer_id) < cost:
        raise BadRequest("loyalty_not_available", "Points insuffisants")
    if not await _add(db, customer_id, -cost, REDEEM, order_id=order.id, quote_id=quote.id):
        raise BadRequest("loyalty_not_available")
    quote.loyalty_points_used, quote.loyalty_discount_xof = cost, discount


async def release_for_order(db: AsyncSession, order: Order) -> None:
    """The order left the unpaid state (change request, cancellation): give back the points redeemed on it."""
    rows = (await db.scalars(select(LoyaltyLedger).where(LoyaltyLedger.order_id == order.id, LoyaltyLedger.kind == REDEEM))).all()
    for row in rows:
        quote = await db.get(Quote, row.quote_id)
        assert quote is not None
        if await _add(db, row.customer_id, -row.points, RELEASE, order_id=order.id, quote_id=quote.id):
            quote.loyalty_points_used, quote.loyalty_discount_xof = 0, 0


async def points_earned(db: AsyncSession, order_id: int, customer_id: int) -> int:
    return int(await db.scalar(
        select(func.coalesce(func.sum(LoyaltyLedger.points), 0)).where(
            LoyaltyLedger.order_id == order_id, LoyaltyLedger.customer_id == customer_id, LoyaltyLedger.kind == ORDER)
    ) or 0)


async def summary(db: AsyncSession, customer: Customer) -> LoyaltyOut:
    settings = await get_settings_map(db)
    rows = (await db.execute(
        select(LoyaltyLedger, Order.public_ref, Customer.display_name)
        .outerjoin(Order, Order.id == LoyaltyLedger.order_id)
        .outerjoin(Customer, Customer.id == LoyaltyLedger.referred_customer_id)
        .where(LoyaltyLedger.customer_id == customer.id)
        .order_by(LoyaltyLedger.id.desc())
        .limit(100)
    )).all()
    history = [
        LoyaltyEventOut(kind=r.kind, points=r.points, created_at=r.created_at, order_ref=ref,
                        friend_name=(name or "Une amie") if r.referred_customer_id else None)
        for r, ref, name in rows
    ]
    return LoyaltyOut(
        balance=await balance(db, customer.id), referral_code=customer.referral_code,
        redeem_points=int(settings["loyalty_redeem_points"]), discount_percent=int(settings["loyalty_discount_percent_of_fee"]),
        points_per_order=int(settings["loyalty_points_per_order"]),
        points_referral_signup=int(settings["loyalty_points_referral_signup"]),
        points_referred_order=int(settings["loyalty_points_referred_order"]),
        history=history,
    )
