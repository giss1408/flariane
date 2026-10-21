from collections.abc import AsyncIterator, Callable
from typing import Any

from sqlalchemy import event
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine
from sqlalchemy.orm import DeclarativeBase, Session
from sqlalchemy.pool import NullPool

from app.config import get_settings


class Base(DeclarativeBase):
    pass


_settings = get_settings()
# Neon's pooled endpoint (PgBouncer, transaction mode) can't keep prepared statements between
# transactions: disable asyncpg's statement cache there.
_connect_args = {"statement_cache_size": 0} if "-pooler." in _settings.database_url else {}
# Tests run each case in its own event loop; pooled asyncpg connections can't cross loops.
engine = (
    create_async_engine(_settings.database_url, poolclass=NullPool)
    if _settings.env == "test"
    else create_async_engine(_settings.database_url, pool_pre_ping=True, pool_size=5, max_overflow=5, connect_args=_connect_args)
)
SessionLocal = async_sessionmaker(engine, expire_on_commit=False)


async def get_session() -> AsyncIterator[AsyncSession]:
    async with SessionLocal() as session:
        yield session


def on_commit(db: AsyncSession, fn: Callable[[], Any]) -> None:
    """Run `fn` only after the current transaction commits (e.g. enqueue a notification)."""
    db.sync_session.info.setdefault("after_commit", []).append(fn)


@event.listens_for(Session, "after_commit")
def _run_after_commit(session: Session) -> None:
    callbacks = session.info.pop("after_commit", [])
    for fn in callbacks:
        fn()


@event.listens_for(Session, "after_rollback")
def _drop_after_commit(session: Session) -> None:
    session.info.pop("after_commit", None)
