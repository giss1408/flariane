from fastapi import APIRouter, Depends, Request
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.db import get_session
from app.enums import AdminRole
from app.errors import NotFound
from app.models import Order, Shipment, ShipmentOrder
from app.ratelimit import admin_limited
from app.schemas import ShipmentCreateIn, ShipmentDepartIn, ShipmentOrdersIn, ShipmentOut
from app.security.deps import AdminContext, client_ip, require_role
from app.services import operations

router = APIRouter(prefix="/admin/shipments", tags=["admin-shipments"], dependencies=[Depends(admin_limited)])
viewer = Depends(require_role(AdminRole.VIEWER))
operator = Depends(require_role(AdminRole.OPERATOR))


async def _out(db: AsyncSession, shipment: Shipment) -> ShipmentOut:
    refs = (
        await db.scalars(
            select(Order.public_ref).join(ShipmentOrder, ShipmentOrder.order_id == Order.id).where(ShipmentOrder.shipment_id == shipment.id)
        )
    ).all()
    out = ShipmentOut.model_validate(shipment)
    out.order_refs = list(refs)
    return out


@router.get("", response_model=list[ShipmentOut])
async def list_shipments(_: AdminContext = viewer, db: AsyncSession = Depends(get_session)) -> list[ShipmentOut]:
    rows = (await db.scalars(select(Shipment).order_by(Shipment.id.desc()).limit(50))).all()
    return [await _out(db, s) for s in rows]


@router.post("", response_model=ShipmentOut, status_code=201)
async def create(data: ShipmentCreateIn, admin: AdminContext = operator, db: AsyncSession = Depends(get_session)) -> ShipmentOut:
    shipment = await operations.create_shipment(db, data.label, data.forwarder, admin.id)
    await db.commit()
    return await _out(db, shipment)


@router.get("/{shipment_id}", response_model=ShipmentOut)
async def get(shipment_id: int, _: AdminContext = viewer, db: AsyncSession = Depends(get_session)) -> ShipmentOut:
    shipment = await db.get(Shipment, shipment_id)
    if shipment is None:
        raise NotFound()
    return await _out(db, shipment)


@router.post("/{shipment_id}/orders", response_model=ShipmentOut)
async def add_orders(shipment_id: int, data: ShipmentOrdersIn, admin: AdminContext = operator, db: AsyncSession = Depends(get_session)) -> ShipmentOut:
    await operations.add_orders_to_shipment(db, shipment_id, data.order_ids, admin.id)
    await db.commit()
    return await get(shipment_id, admin, db)


@router.delete("/{shipment_id}/orders/{order_id}", response_model=ShipmentOut)
async def remove_order(shipment_id: int, order_id: int, admin: AdminContext = operator, db: AsyncSession = Depends(get_session)) -> ShipmentOut:
    await operations.remove_order_from_shipment(db, shipment_id, order_id, admin.id)
    await db.commit()
    return await get(shipment_id, admin, db)


@router.post("/{shipment_id}/depart", response_model=ShipmentOut)
async def depart(shipment_id: int, data: ShipmentDepartIn, request: Request, admin: AdminContext = operator, db: AsyncSession = Depends(get_session)) -> ShipmentOut:
    shipment = await operations.depart_shipment(db, shipment_id, data.tracking_ref, data.weight_kg, data.cost_xof, admin.id, client_ip(request))
    await db.commit()
    return await _out(db, shipment)


@router.post("/{shipment_id}/arrive", response_model=ShipmentOut)
async def arrive(shipment_id: int, request: Request, admin: AdminContext = operator, db: AsyncSession = Depends(get_session)) -> ShipmentOut:
    shipment = await operations.arrive_shipment(db, shipment_id, admin.id, client_ip(request))
    await db.commit()
    return await _out(db, shipment)
