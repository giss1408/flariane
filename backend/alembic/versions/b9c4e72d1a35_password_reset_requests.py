"""forgotten-password requests for the admins, temporary password expiry

Revision ID: b9c4e72d1a35
Revises: a8f3d1c27b64
Create Date: 2026-11-06 10:00:00.000000

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = 'b9c4e72d1a35'
down_revision: Union[str, None] = 'a8f3d1c27b64'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column('customers', sa.Column('password_reset_requested_at', sa.DateTime(timezone=True), nullable=True))
    op.add_column('customers', sa.Column('temp_password_expires_at', sa.DateTime(timezone=True), nullable=True))


def downgrade() -> None:
    op.drop_column('customers', 'temp_password_expires_at')
    op.drop_column('customers', 'password_reset_requested_at')
