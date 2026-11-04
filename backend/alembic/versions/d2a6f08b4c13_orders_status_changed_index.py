"""orders (status, status_changed_at) index

Revision ID: d2a6f08b4c13
Revises: c91d3a7e2f40
Create Date: 2026-11-04 11:00:00.000000

"""
from typing import Sequence, Union

from alembic import op


# revision identifiers, used by Alembic.
revision: str = 'd2a6f08b4c13'
down_revision: Union[str, None] = 'c91d3a7e2f40'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_index('ix_orders_status_changed', 'orders', ['status', 'status_changed_at'], unique=False)


def downgrade() -> None:
    op.drop_index('ix_orders_status_changed', table_name='orders')
