"""payments.proof_key

Revision ID: e5b81c37a9d2
Revises: d2a6f08b4c13
Create Date: 2026-11-04 12:00:00.000000

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = 'e5b81c37a9d2'
down_revision: Union[str, None] = 'd2a6f08b4c13'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column('payments', sa.Column('proof_key', sa.String(length=160), nullable=True))


def downgrade() -> None:
    op.drop_column('payments', 'proof_key')
