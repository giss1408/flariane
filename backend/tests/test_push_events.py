"""Admins must be pushed when a customer creates an order, with or without an Idempotency-Key."""

import pytest
from httpx import AsyncClient

from app import tasks
from app.models import PickupPoint
from tests.conftest import CART_SHARE


@pytest.mark.parametrize("key", [None, "push-k1"])
async def test_admin_push_on_new_order(client: AsyncClient, customer: dict, pickup_point: PickupPoint, key: str | None) -> None:
    headers = {**customer, **({"Idempotency-Key": key} if key else {})}
    before = len(tasks.RECORDED)
    r = await client.post("/orders", json={"share_text": CART_SHARE, "pickup_point_id": pickup_point.id}, headers=headers)
    assert r.status_code == 201
    events = [kw["event"] for name, kw in tasks.RECORDED[before:] if name == "push_admins"]
    assert events == ["quote_requested"]


async def test_push_diagnostics_for_super_admin(client: AsyncClient, admin) -> None:  # type: ignore[no-untyped-def]
    r = await client.get("/admin/notifications/push", headers=admin.headers)
    assert r.status_code == 200 and r.json()["mode"] == "log" and r.json()["has_service_account"] is False
    # The fixture device has no push token yet: the test endpoint says so instead of failing.
    r = await client.post("/admin/notifications/push-test", headers=admin.headers)
    assert r.status_code == 200 and r.json()["ok"] is False and "no_push_token" in r.json()["error"]
