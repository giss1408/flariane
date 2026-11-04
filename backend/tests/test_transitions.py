"""The order status table in services/orders.py is the only way an order changes status."""

import re
from pathlib import Path

import pytest

from app.enums import OrderStatus as S
from app.errors import Conflict
from app.models import Order
from app.services.orders import TRANSITIONS, transition_order


def test_every_status_has_an_entry_and_targets_exist() -> None:
    assert set(TRANSITIONS) == set(S)
    assert all(targets <= set(S) for targets in TRANSITIONS.values())


def test_terminal_statuses_and_happy_path() -> None:
    assert [s for s, t in TRANSITIONS.items() if not t] == [S.PICKED_UP, S.CANCELLED, S.REFUNDED]
    path = [S.QUOTE_REQUESTED, S.QUOTED, S.AWAITING_PAYMENT, S.PAID, S.PURCHASED, S.IN_TRANSIT, S.ARRIVED, S.READY_FOR_PICKUP, S.PICKED_UP]
    assert all(b in TRANSITIONS[a] for a, b in zip(path, path[1:]))


def test_nothing_leaves_a_paid_order_except_purchase_or_refund() -> None:
    # After payment the money is taken: cancelling must go through a refund, never straight to CANCELLED.
    assert TRANSITIONS[S.PAID] == {S.PURCHASED, S.REFUND_PENDING}
    assert all(S.CANCELLED not in t for s, t in TRANSITIONS.items() if s not in (S.QUOTE_REQUESTED, S.QUOTED, S.AWAITING_PAYMENT))


async def test_invalid_transition_is_refused() -> None:
    order = Order(status=S.PICKED_UP)
    with pytest.raises(Conflict) as exc:
        await transition_order(None, order, S.QUOTED, actor="test")  # type: ignore[arg-type]
    assert exc.value.code == "invalid_transition" and order.status == S.PICKED_UP


def test_no_code_sets_order_status_directly() -> None:
    offenders = []
    for path in Path("app").rglob("*.py"):
        if path.name == "orders.py" and path.parent.name == "services":
            continue
        for n, line in enumerate(path.read_text().splitlines(), 1):
            if re.search(r"\b(order|o)\.status\s*=[^=]", line):
                offenders.append(f"{path}:{n}")
    assert not offenders, f"use transition_order(): {offenders}"
