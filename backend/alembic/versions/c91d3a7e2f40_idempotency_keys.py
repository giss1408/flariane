"""idempotency keys

Revision ID: c91d3a7e2f40
Revises: b7e24d1a9c05
Create Date: 2026-11-04 10:00:00.000000

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = 'c91d3a7e2f40'
down_revision: Union[str, None] = 'b7e24d1a9c05'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table('idempotency_keys',
    sa.Column('id', sa.Integer(), nullable=False),
    sa.Column('customer_id', sa.Integer(), nullable=False),
    sa.Column('endpoint', sa.String(length=60), nullable=False),
    sa.Column('key', sa.String(length=80), nullable=False),
    sa.Column('response', sa.JSON(), nullable=True),
    sa.Column('created_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
    sa.ForeignKeyConstraint(['customer_id'], ['customers.id'], ),
    sa.PrimaryKeyConstraint('id'),
    sa.UniqueConstraint('customer_id', 'endpoint', 'key')
    )
    op.create_index(op.f('ix_idempotency_keys_customer_id'), 'idempotency_keys', ['customer_id'], unique=False)
    op.create_index(op.f('ix_idempotency_keys_created_at'), 'idempotency_keys', ['created_at'], unique=False)


def downgrade() -> None:
    op.drop_index(op.f('ix_idempotency_keys_created_at'), table_name='idempotency_keys')
    op.drop_index(op.f('ix_idempotency_keys_customer_id'), table_name='idempotency_keys')
    op.drop_table('idempotency_keys')
