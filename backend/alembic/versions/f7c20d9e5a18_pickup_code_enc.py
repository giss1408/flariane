"""pickup_codes.code_enc

Revision ID: f7c20d9e5a18
Revises: e5b81c37a9d2
Create Date: 2026-11-04 14:00:00.000000

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = 'f7c20d9e5a18'
down_revision: Union[str, None] = 'e5b81c37a9d2'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column('pickup_codes', sa.Column('code_enc', sa.LargeBinary(), nullable=True))


def downgrade() -> None:
    op.drop_column('pickup_codes', 'code_enc')
