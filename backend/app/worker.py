"""Celery worker + beat. Run:
    celery -A app.worker worker -l info
    celery -A app.worker beat -l info
"""

import asyncio
from typing import Any

from celery import Celery
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine
from sqlalchemy.pool import NullPool

from app import tasks
from app.config import get_settings

settings = get_settings()
celery_app = Celery("flariane", broker=settings.redis_url, backend=None)
celery_app.conf.update(
    task_acks_late=True,
    task_reject_on_worker_lost=True,
    worker_prefetch_multiplier=1,
    timezone="Africa/Abidjan",
    beat_schedule={
        "expire-quotes": {"task": "flariane.expire_quotes", "schedule": 300.0},
        "reconcile-payments": {"task": "flariane.reconcile_payments", "schedule": 600.0},
    },
)

# asyncio.run() creates a new event loop per task; pooled asyncpg connections can't cross loops.
_engine = create_async_engine(settings.database_url, poolclass=NullPool)
tasks.session_factory = async_sessionmaker(_engine, expire_on_commit=False)


def _register(name: str) -> None:
    fn = tasks.TASKS[name]

    @celery_app.task(name=f"flariane.{name}", bind=True, max_retries=5, default_retry_delay=30)
    def _task(self: Any, **kwargs: Any) -> Any:
        try:
            return asyncio.run(fn(**kwargs))
        except Exception as exc:
            raise self.retry(exc=exc, countdown=30 * (2**self.request.retries)) from exc


for _name in tasks.TASKS:
    _register(_name)
