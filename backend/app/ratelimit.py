"""Moving-window rate limits keyed by customer / admin / IP (Redis in production).

Ivorian carriers put many users behind one IP (CGNAT), so IP limits are loose and
authenticated traffic is limited per account. Failed customer logins are limited per phone
(services/customer_auth.py).
"""

from fastapi import Depends, HTTPException, Request
from limits import parse
from limits.storage import storage_from_string
from limits.strategies import MovingWindowRateLimiter

from app.config import get_settings
from app.models import Customer
from app.security.deps import AdminContext, client_ip, current_admin, current_customer

_limiter: MovingWindowRateLimiter | None = None

IP_LIMIT = parse("120/minute")
CUSTOMER_LIMIT = parse("60/minute")
ADMIN_LIMIT = parse("300/minute")


def limiter() -> MovingWindowRateLimiter:
    global _limiter
    if _limiter is None:
        _limiter = MovingWindowRateLimiter(storage_from_string(get_settings().rate_limit_storage))
    return _limiter


def reset() -> None:
    global _limiter
    _limiter = None


def _hit(item: object, key: str) -> None:
    if not limiter().hit(item, key):  # type: ignore[arg-type]
        raise HTTPException(status_code=429, detail="rate_limited", headers={"Retry-After": "60"})


async def ip_limited(request: Request) -> None:
    _hit(IP_LIMIT, f"ip:{client_ip(request)}")


async def customer_limited(customer: Customer = Depends(current_customer)) -> Customer:
    _hit(CUSTOMER_LIMIT, f"customer:{customer.id}")
    return customer


async def admin_limited(admin: AdminContext = Depends(current_admin)) -> AdminContext:
    _hit(ADMIN_LIMIT, f"admin:{admin.id}")
    return admin
