"""Wave Checkout API client.

Docs: https://docs.wave.com/checkout — verify field names against the current docs before going live.
`fake` mode serves a local checkout page (see routers/dev.py) that sends correctly signed webhooks,
so the whole payment flow can be exercised without a Wave Business account.
"""

import hashlib
import hmac
import time
import uuid
from dataclasses import dataclass
from typing import Any

import httpx

from app.config import get_settings
from app.errors import PaymentProviderError


@dataclass
class CheckoutSession:
    id: str
    launch_url: str
    checkout_status: str
    payment_status: str | None
    amount: str
    currency: str
    client_reference: str | None
    transaction_id: str | None = None


def _parse(data: dict[str, Any]) -> CheckoutSession:
    return CheckoutSession(
        id=data["id"],
        launch_url=data.get("wave_launch_url", ""),
        checkout_status=data.get("checkout_status", ""),
        payment_status=data.get("payment_status"),
        amount=str(data.get("amount", "")),
        currency=data.get("currency", ""),
        client_reference=data.get("client_reference"),
        transaction_id=data.get("transaction_id"),
    )


# In-memory store for fake mode (dev/test only).
FAKE_SESSIONS: dict[str, dict[str, Any]] = {}


async def create_checkout_session(
    *, amount_xof: int, client_reference: str, success_url: str, error_url: str, idempotency_key: str
) -> CheckoutSession:
    s = get_settings()
    body = {
        "amount": str(amount_xof),  # XOF: integer amount, sent as a string
        "currency": "XOF",
        "client_reference": client_reference,
        "success_url": success_url,
        "error_url": error_url,
    }
    if s.wave_mode == "fake":
        existing = next((v for v in FAKE_SESSIONS.values() if v["_idem"] == idempotency_key), None)
        if existing:
            return _parse(existing)
        sid = f"cos-fake-{uuid.uuid4().hex[:12]}"
        FAKE_SESSIONS[sid] = {
            **body,
            "id": sid,
            "_idem": idempotency_key,
            "checkout_status": "open",
            "payment_status": "processing",
            "wave_launch_url": f"{s.api_base_url}/dev/wave/checkout/{sid}",
        }
        return _parse(FAKE_SESSIONS[sid])

    async with httpx.AsyncClient(base_url=s.wave_api_base, timeout=15) as client:
        resp = await client.post(
            "/v1/checkout/sessions",
            json=body,
            headers={"Authorization": f"Bearer {s.wave_api_key}", "Idempotency-Key": idempotency_key},
        )
    if resp.status_code >= 400:
        raise PaymentProviderError("wave_error", f"{resp.status_code}")
    return _parse(resp.json())


async def get_checkout_session(session_id: str) -> CheckoutSession:
    s = get_settings()
    if s.wave_mode == "fake":
        return _parse(FAKE_SESSIONS[session_id])
    async with httpx.AsyncClient(base_url=s.wave_api_base, timeout=15) as client:
        resp = await client.get(
            f"/v1/checkout/sessions/{session_id}", headers={"Authorization": f"Bearer {s.wave_api_key}"}
        )
    if resp.status_code >= 400:
        raise PaymentProviderError("wave_error", f"{resp.status_code}")
    return _parse(resp.json())


def sign_payload(body: bytes, secret: str, timestamp: int | None = None) -> str:
    """Build a Wave-Signature header value. Used by fake mode and tests."""
    t = str(timestamp if timestamp is not None else int(time.time()))
    sig = hmac.new(secret.encode(), t.encode() + body, hashlib.sha256).hexdigest()
    return f"t={t},v1={sig}"


def verify_signature(header: str | None, body: bytes, secret: str, tolerance: int) -> bool:
    if not header:
        return False
    parts = [p.split("=", 1) for p in header.split(",") if "=" in p]
    t = next((v for k, v in parts if k.strip() == "t"), None)
    sigs = [v for k, v in parts if k.strip() == "v1"]
    if not t or not t.isdigit() or not sigs:
        return False
    # Reject replays of old, validly signed requests.
    if abs(time.time() - int(t)) > tolerance:
        return False
    expected = hmac.new(secret.encode(), t.encode() + body, hashlib.sha256).hexdigest().encode()
    return any(hmac.compare_digest(expected, s.encode()) for s in sigs if s.isascii())
