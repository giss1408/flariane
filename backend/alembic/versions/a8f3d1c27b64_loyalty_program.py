"""loyalty program: referral codes, points ledger, quote discount

Revision ID: a8f3d1c27b64
Revises: f7c20d9e5a18
Create Date: 2026-11-04 16:00:00.000000

"""
import secrets
import unicodedata
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = 'a8f3d1c27b64'
down_revision: Union[str, None] = 'f7c20d9e5a18'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None

_ALPHABET = "23456789ABCDEFGHJKLMNPQRSTUVWXYZ"
_LETTERS = "ABCDEFGHJKLMNPQRSTUVWXYZ"


def _prefix(name: str | None) -> str:
    ascii_name = unicodedata.normalize("NFKD", name or "").encode("ascii", "ignore").decode().upper()
    letters = "".join(c for c in ascii_name if c in _LETTERS)[:3]
    return letters.ljust(3, "X") if letters else "FLR"


def upgrade() -> None:
    op.add_column('customers', sa.Column('referral_code', sa.String(length=12), nullable=True))
    op.add_column('customers', sa.Column('referred_by_id', sa.Integer(), nullable=True))
    op.create_unique_constraint('uq_customers_referral_code', 'customers', ['referral_code'])
    op.create_foreign_key('fk_customers_referred_by', 'customers', 'customers', ['referred_by_id'], ['id'])
    op.create_index('ix_customers_referred_by_id', 'customers', ['referred_by_id'])
    op.add_column('quotes', sa.Column('loyalty_points_used', sa.Integer(), server_default='0', nullable=False))
    op.add_column('quotes', sa.Column('loyalty_discount_xof', sa.BigInteger(), server_default='0', nullable=False))
    op.create_table(
        'loyalty_ledger',
        sa.Column('id', sa.Integer(), primary_key=True),
        sa.Column('customer_id', sa.Integer(), sa.ForeignKey('customers.id'), nullable=False),
        sa.Column('points', sa.Integer(), nullable=False),
        sa.Column('kind', sa.String(length=16), nullable=False),
        sa.Column('order_id', sa.Integer(), sa.ForeignKey('orders.id'), nullable=True),
        sa.Column('quote_id', sa.Integer(), sa.ForeignKey('quotes.id'), nullable=True),
        sa.Column('referred_customer_id', sa.Integer(), sa.ForeignKey('customers.id'), nullable=True),
        sa.Column('created_at', sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
    )
    op.create_index('ix_loyalty_ledger_customer_id', 'loyalty_ledger', ['customer_id'])
    for name, col, kind in [
        ('uq_loyalty_signup', 'referred_customer_id', 'REFERRAL_SIGNUP'),
        ('uq_loyalty_order', 'order_id', 'ORDER'),
        ('uq_loyalty_referred_order', 'referred_customer_id', 'REFERRED_ORDER'),
        ('uq_loyalty_redeem', 'quote_id', 'REDEEM'),
        ('uq_loyalty_release', 'quote_id', 'RELEASE'),
    ]:
        op.create_index(name, 'loyalty_ledger', [col], unique=True, postgresql_where=sa.text(f"kind = '{kind}'"))

    # Existing customers get a code too.
    conn = op.get_bind()
    taken: set[str] = set()
    for cid, name in conn.execute(sa.text("SELECT id, display_name FROM customers")).all():
        while True:
            code = f"{_prefix(name)}-" + "".join(secrets.choice(_ALPHABET) for _ in range(4))
            if code not in taken:
                taken.add(code)
                break
        conn.execute(sa.text("UPDATE customers SET referral_code = :c WHERE id = :i"), {"c": code, "i": cid})


def downgrade() -> None:
    op.drop_table('loyalty_ledger')
    op.drop_column('quotes', 'loyalty_discount_xof')
    op.drop_column('quotes', 'loyalty_points_used')
    op.drop_index('ix_customers_referred_by_id', table_name='customers')
    op.drop_constraint('fk_customers_referred_by', 'customers', type_='foreignkey')
    op.drop_constraint('uq_customers_referral_code', 'customers', type_='unique')
    op.drop_column('customers', 'referred_by_id')
    op.drop_column('customers', 'referral_code')
