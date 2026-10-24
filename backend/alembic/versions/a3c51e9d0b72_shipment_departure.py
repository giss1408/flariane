"""shipment departure_date and order_deadline

Revision ID: a3c51e9d0b72
Revises: f826ea6f43dc
Create Date: 2026-10-24 10:00:00.000000

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = 'a3c51e9d0b72'
down_revision: Union[str, None] = 'f826ea6f43dc'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column('shipments', sa.Column('departure_date', sa.Date(), nullable=True))
    op.add_column('shipments', sa.Column('order_deadline', sa.Date(), nullable=True))
    op.create_unique_constraint('uq_shipments_departure_date', 'shipments', ['departure_date'])


def downgrade() -> None:
    op.drop_constraint('uq_shipments_departure_date', 'shipments', type_='unique')
    op.drop_column('shipments', 'order_deadline')
    op.drop_column('shipments', 'departure_date')
