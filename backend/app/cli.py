"""Bootstrap commands.

    python -m app.cli create-admin --email you@x.ci --name "Régis" --role SUPER_ADMIN
    python -m app.cli approve-device --device-id 1
    python -m app.cli seed-pickup-points
    python -m app.cli gen-keys
"""

import argparse
import asyncio
import base64
import getpass
import os

import pyotp
from sqlalchemy import select

from app.db import SessionLocal
from app.models import AdminDevice, AdminUser, PickupPoint
from app.security.crypto import encrypt, hash_password
from app.security.tokens import utcnow


async def create_admin(email: str, name: str, role: str) -> None:
    password = os.environ.get("FLR_ADMIN_PASSWORD") or getpass.getpass("Mot de passe (12+ caractères): ")
    if len(password) < 12:
        raise SystemExit("password too short")
    secret = pyotp.random_base32()
    async with SessionLocal() as db:
        if await db.scalar(select(AdminUser).where(AdminUser.email == email.lower())):
            raise SystemExit("email already exists")
        db.add(AdminUser(email=email.lower(), name=name, role=role, password_hash=hash_password(password), totp_secret_enc=encrypt(secret)))
        await db.commit()
    print("Admin created. Add this to your authenticator app (Google Authenticator, 1Password…):")
    print(pyotp.TOTP(secret).provisioning_uri(name=email.lower(), issuer_name="Flariane Admin"))


async def approve_device(device_id: int) -> None:
    async with SessionLocal() as db:
        device = await db.get(AdminDevice, device_id)
        if device is None:
            raise SystemExit("no such device")
        device.approved_at = utcnow()
        await db.commit()
    print(f"Device {device_id} ({device.name}, {device.platform}) approved.")


async def list_devices() -> None:
    async with SessionLocal() as db:
        for d in (await db.scalars(select(AdminDevice).order_by(AdminDevice.id))).all():
            state = "revoked" if d.revoked_at else ("approved" if d.approved_at else "PENDING")
            print(f"{d.id:>4}  admin={d.admin_user_id}  {d.platform:<8} {d.name:<30} {state}")


async def seed_pickup_points() -> None:
    points = [
        ("Flariane Cocody", "Rue des Jardins, Riviera 2", "Cocody", "Lun–Sam 9h–19h"),
        ("Flariane Yopougon", "Carrefour Siporex", "Yopougon", "Lun–Sam 9h–18h"),
    ]
    async with SessionLocal() as db:
        if await db.scalar(select(PickupPoint.id).limit(1)):
            print("pickup points already exist")
            return
        for name, address, commune, hours in points:
            db.add(PickupPoint(name=name, address=address, commune=commune, opening_hours=hours))
        await db.commit()
    print("Seeded example pickup points — edit them in the admin app (Compte → Points de retrait).")


def gen_keys() -> None:
    for name in ("FLR_JWT_SECRET", "FLR_FIELD_ENCRYPTION_KEY", "FLR_HASH_KEY", "FLR_WAVE_WEBHOOK_SECRET"):
        print(f"{name}={base64.b64encode(os.urandom(32)).decode()}")


def main() -> None:
    parser = argparse.ArgumentParser(prog="python -m app.cli")
    sub = parser.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("create-admin")
    p.add_argument("--email", required=True)
    p.add_argument("--name", required=True)
    p.add_argument("--role", default="SUPER_ADMIN", choices=["VIEWER", "OPERATOR", "SUPER_ADMIN"])
    p = sub.add_parser("approve-device")
    p.add_argument("--device-id", type=int, required=True)
    sub.add_parser("list-devices")
    sub.add_parser("seed-pickup-points")
    sub.add_parser("gen-keys")
    args = parser.parse_args()

    if args.cmd == "gen-keys":
        gen_keys()
    elif args.cmd == "create-admin":
        asyncio.run(create_admin(args.email, args.name, args.role))
    elif args.cmd == "approve-device":
        asyncio.run(approve_device(args.device_id))
    elif args.cmd == "list-devices":
        asyncio.run(list_devices())
    elif args.cmd == "seed-pickup-points":
        asyncio.run(seed_pickup_points())


if __name__ == "__main__":
    main()
