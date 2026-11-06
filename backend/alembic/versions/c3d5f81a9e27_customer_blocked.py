"""customers.blocked_at: accounts a super admin has blocked

Revision ID: c3d5f81a9e27
Revises: b9c4e72d1a35
Create Date: 2026-11-06 14:00:00.000000

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = 'c3d5f81a9e27'
down_revision: Union[str, None] = 'b9c4e72d1a35'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column('customers', sa.Column('blocked_at', sa.DateTime(timezone=True), nullable=True))


def downgrade() -> None:
    op.drop_column('customers', 'blocked_at')
