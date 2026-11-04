"""Payment proofs live in storage; proofs stored in the database before that keep working until migrated."""

import io
from pathlib import Path

from httpx import AsyncClient
from PIL import Image
from sqlalchemy import select
from sqlalchemy.orm import undefer

from app.cli import migrate_proofs
from app.config import get_settings
from app.db import SessionLocal
from app.integrations import storage
from app.models import Payment, PickupPoint
from tests.conftest import AdminFixture, create_order, order_id, quote_and_send


def _put_local(key: str, data: bytes) -> None:
    path = Path(get_settings().storage_local_dir) / key
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)


def _get_local(key: str) -> bytes | None:
    path = Path(get_settings().storage_local_dir) / key
    return path.read_bytes() if path.is_file() else None


def _jpeg(color: str) -> bytes:
    buf = io.BytesIO()
    Image.new("RGB", (40, 60), color).save(buf, format="JPEG")
    return buf.getvalue()


async def _payment(oid: int) -> Payment:
    async with SessionLocal() as db:
        return await db.scalar(select(Payment).where(Payment.order_id == oid).options(undefer(Payment.proof_image)))  # type: ignore[return-value]


async def test_proof_goes_to_storage_and_legacy_is_migrated(client: AsyncClient, customer: dict, admin: AdminFixture, pickup_point: PickupPoint, monkeypatch) -> None:  # type: ignore[no-untyped-def]
    monkeypatch.setattr(get_settings(), "storage_mode", "s3")
    monkeypatch.setattr(storage, "put", lambda key, data, ct: _put_local(key, data))
    monkeypatch.setattr(storage, "get", lambda key: _get_local(key))
    monkeypatch.setattr(storage, "delete", lambda key: (Path(get_settings().storage_local_dir) / key).unlink(missing_ok=True))
    await client.put("/admin/settings", json={"payment_mode": "manual", "payment_accounts": {"WAVE": "0700000000"}}, headers=admin.headers)
    ref = (await create_order(client, customer, pickup_point))["public_ref"]
    oid = await order_id(ref)
    await quote_and_send(client, admin, oid)
    await client.post(f"/orders/{ref}/quotes/1/accept", json={"sizes_confirmed": True}, headers=customer)

    async def declare(color: str) -> None:
        r = await client.post(f"/orders/{ref}/payment/declare", data={"method": "WAVE"}, files={"file": ("p.jpg", _jpeg(color), "image/jpeg")}, headers=customer)
        assert r.status_code == 200, r.text

    await declare("orange")
    p = await _payment(oid)
    assert p.proof_image is None and p.proof_key and (Path(get_settings().storage_local_dir) / p.proof_key).is_file()
    r = await client.get(f"/admin/orders/{oid}/payment-proof", headers=admin.headers)
    assert r.status_code == 200 and r.headers["content-type"] == "image/jpeg"

    # A second screenshot replaces the first one, and the old file is removed.
    first_key = p.proof_key
    await declare("blue")
    p = await _payment(oid)
    assert p.proof_key != first_key and not (Path(get_settings().storage_local_dir) / first_key).exists()

    # A proof saved in the database before the move still opens, then migrate-proofs moves it.
    legacy = _jpeg("green")
    async with SessionLocal() as db:
        row = await db.get(Payment, p.id)
        row.proof_key, row.proof_image = None, legacy  # type: ignore[union-attr]
        await db.commit()
    assert (await client.get(f"/admin/orders/{oid}/payment-proof", headers=admin.headers)).content == legacy
    await migrate_proofs()
    p = await _payment(oid)
    assert p.proof_image is None and p.proof_key
    assert (await client.get(f"/admin/orders/{oid}/payment-proof", headers=admin.headers)).content == legacy


async def test_proof_stays_in_database_while_storage_is_local(client: AsyncClient, customer: dict, admin: AdminFixture, pickup_point: PickupPoint) -> None:
    """Local disk is lost at restart: until S3 is configured the proof must live in the database."""
    await client.put("/admin/settings", json={"payment_mode": "manual", "payment_accounts": {"WAVE": "0700000000"}}, headers=admin.headers)
    ref = (await create_order(client, customer, pickup_point))["public_ref"]
    oid = await order_id(ref)
    await quote_and_send(client, admin, oid)
    await client.post(f"/orders/{ref}/quotes/1/accept", json={"sizes_confirmed": True}, headers=customer)
    r = await client.post(f"/orders/{ref}/payment/declare", data={"method": "WAVE"}, files={"file": ("p.jpg", _jpeg("red"), "image/jpeg")}, headers=customer)
    assert r.status_code == 200
    p = await _payment(oid)
    assert p.proof_key is None and p.proof_image
    assert (await client.get(f"/admin/orders/{oid}/payment-proof", headers=admin.headers)).status_code == 200
