import asyncio
import contextlib
import logging
from collections.abc import AsyncIterator

from fastapi import FastAPI, Request, Response
from fastapi.middleware.cors import CORSMiddleware

from app.config import get_settings
from app import tasks
from app.errors import install_error_handlers
from app.routers import (
    admin_backoffice,
    admin_orders,
    admin_shipments,
    auth_admin,
    auth_customer,
    customer,
    dev,
    files,
    payment_return,
    webhooks,
)

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")


async def _inline_scheduler() -> None:
    """Without a Celery worker (free hosting), run the periodic jobs inside the API process.
    They only run while the instance is awake, which is fine for testing."""
    log = logging.getLogger("flariane.scheduler")
    ticks = 0
    while True:
        await asyncio.sleep(300)
        ticks += 1
        for name, every in (("expire_quotes", 1), ("reconcile_payments", 2)):
            if ticks % every == 0:
                try:
                    await tasks.TASKS[name]()
                except Exception:
                    log.exception("scheduled task %s failed", name)


@contextlib.asynccontextmanager
async def lifespan(_: FastAPI) -> AsyncIterator[None]:
    job = asyncio.create_task(_inline_scheduler()) if get_settings().task_mode == "inline" else None
    yield
    if job:
        job.cancel()


def create_app() -> FastAPI:
    s = get_settings()
    prod = s.env == "prod"
    if prod and (s.wave_mode != "live" or s.whatsapp_mode != "live"):
        raise RuntimeError("production requires live Wave and WhatsApp")

    app = FastAPI(
        title="Flariane API",
        lifespan=lifespan,
        docs_url=None if prod else "/docs",
        redoc_url=None,
        openapi_url=None if prod else "/openapi.json",
    )
    app.add_middleware(
        CORSMiddleware,
        allow_origins=s.cors_origins,  # explicit list, never "*"
        allow_credentials=True,
        allow_methods=["GET", "POST", "PUT", "PATCH", "DELETE"],
        allow_headers=["Authorization", "Content-Type"],
    )

    @app.middleware("http")
    async def security_headers(request: Request, call_next):  # type: ignore[no-untyped-def]
        response: Response = await call_next(request)
        response.headers["X-Content-Type-Options"] = "nosniff"
        response.headers["Referrer-Policy"] = "no-referrer"
        response.headers.setdefault("X-Frame-Options", "DENY")
        response.headers.setdefault("Cache-Control", "no-store")
        if prod:
            response.headers["Strict-Transport-Security"] = "max-age=63072000; includeSubDomains"
        return response

    install_error_handlers(app)
    for module in (auth_customer, auth_admin, customer, admin_orders, admin_shipments, admin_backoffice, webhooks, files, payment_return):
        app.include_router(module.router)
    if s.dev_routes_enabled and s.wave_mode == "fake":
        app.include_router(dev.router)  # simulated Wave checkout page

    @app.get("/health", include_in_schema=False)
    async def health() -> dict[str, str]:
        return {"status": "ok"}

    return app


app = create_app()
