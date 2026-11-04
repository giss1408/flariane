"""Idempotency-Key support for customer POSTs that create something.

The key is claimed (unique per customer + endpoint) before the work starts. A concurrent or later retry
with the same key waits on the unique index, then gets the stored response; if the first attempt failed
the claim is released so the client can retry for real.
"""

from collections.abc import Awaitable, Callable
from typing import Any

from pydantic import BaseModel
from sqlalchemy import delete, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.errors import Conflict
from app.models import IdempotencyKey


async def run(
    db: AsyncSession, customer_id: int, endpoint: str, key: str | None, work: Callable[[], Awaitable[BaseModel]]
) -> BaseModel | dict[str, Any]:
    """Run `work` once per (customer, endpoint, key). Without a key, just run it. `work` commits itself."""
    if not key:
        return await work()
    try:
        async with db.begin_nested():
            db.add(IdempotencyKey(customer_id=customer_id, endpoint=endpoint, key=key))
            await db.flush()
    except IntegrityError:
        existing = await db.scalar(
            select(IdempotencyKey).where(
                IdempotencyKey.customer_id == customer_id, IdempotencyKey.endpoint == endpoint, IdempotencyKey.key == key
            )
        )
        if existing is not None and existing.response is not None:
            return existing.response
        raise Conflict("request_in_progress") from None
    try:
        result = await work()
    except BaseException:
        await db.rollback()
        await db.execute(
            delete(IdempotencyKey).where(
                IdempotencyKey.customer_id == customer_id, IdempotencyKey.endpoint == endpoint, IdempotencyKey.key == key
            )
        )
        await db.commit()
        raise
    row = await db.scalar(
        select(IdempotencyKey).where(
            IdempotencyKey.customer_id == customer_id, IdempotencyKey.endpoint == endpoint, IdempotencyKey.key == key
        )
    )
    if row is not None:
        row.response = result.model_dump(mode="json")
        await db.commit()
    return result
