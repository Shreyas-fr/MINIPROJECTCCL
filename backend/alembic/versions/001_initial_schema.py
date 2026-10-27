"""Initial schema with users, events, seats, bookings, payments, and queue_entries

Revision ID: 001_initial_schema
Revises: 
Create Date: 2026-10-27 10:00:00.000000

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa

revision: str = '001_initial_schema'
down_revision: Union[str, None] = None
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    # 1. users
    op.create_table(
        'users',
        sa.Column('user_id', sa.String(length=36), nullable=False),
        sa.Column('email', sa.String(length=255), nullable=False),
        sa.Column('full_name', sa.String(length=255), nullable=False),
        sa.Column('password_hash', sa.String(length=255), nullable=True),
        sa.Column('role', sa.String(length=20), server_default='CUSTOMER', nullable=False),
        sa.Column('created_at', sa.DateTime(), nullable=True),
        sa.PrimaryKeyConstraint('user_id'),
        sa.UniqueConstraint('email')
    )
    op.create_index(op.f('ix_users_email'), 'users', ['email'], unique=True)

    # 2. events
    op.create_table(
        'events',
        sa.Column('event_id', sa.String(length=36), nullable=False),
        sa.Column('name', sa.String(length=255), nullable=False),
        sa.Column('description', sa.Text(), nullable=True),
        sa.Column('venue', sa.String(length=255), nullable=False),
        sa.Column('event_timestamp', sa.DateTime(), nullable=False),
        sa.Column('total_capacity', sa.Integer(), nullable=False),
        sa.Column('available_capacity', sa.Integer(), nullable=False),
        sa.Column('status', sa.Enum('UPCOMING', 'ACTIVE', 'SOLD_OUT', 'COMPLETED', name='event_status_enum'), server_default='UPCOMING', nullable=True),
        sa.Column('created_at', sa.DateTime(), nullable=True),
        sa.Column('updated_at', sa.DateTime(), nullable=True),
        sa.PrimaryKeyConstraint('event_id')
    )

    # 3. seats
    op.create_table(
        'seats',
        sa.Column('seat_id', sa.String(length=36), nullable=False),
        sa.Column('event_id', sa.String(length=36), nullable=False),
        sa.Column('section', sa.String(length=50), nullable=False),
        sa.Column('row_number', sa.String(length=20), nullable=False, quote=True),
        sa.Column('seat_number', sa.String(length=20), nullable=False),
        sa.Column('price_cents', sa.Integer(), nullable=False),
        sa.Column('status', sa.Enum('AVAILABLE', 'RESERVED', 'BOOKED', name='seat_status_enum'), server_default='AVAILABLE', nullable=True),
        sa.Column('reserved_by', sa.String(length=36), nullable=True),
        sa.Column('reserved_until', sa.DateTime(), nullable=True),
        sa.Column('version', sa.Integer(), server_default='1', nullable=False),
        sa.Column('created_at', sa.DateTime(), nullable=True),
        sa.Column('updated_at', sa.DateTime(), nullable=True),
        sa.ForeignKeyConstraint(['event_id'], ['events.event_id'], ondelete='CASCADE'),
        sa.PrimaryKeyConstraint('seat_id'),
        sa.UniqueConstraint('event_id', 'section', 'row_number', 'seat_number', name='uq_event_seat')
    )
    op.create_index('idx_seat_status_lookup', 'seats', ['event_id', 'status', 'reserved_until'], unique=False)

    # 4. bookings
    op.create_table(
        'bookings',
        sa.Column('booking_id', sa.String(length=36), nullable=False),
        sa.Column('booking_ref', sa.String(length=32), nullable=False),
        sa.Column('idempotency_key', sa.String(length=128), nullable=False),
        sa.Column('user_id', sa.String(length=36), nullable=False),
        sa.Column('event_id', sa.String(length=36), nullable=False),
        sa.Column('seat_id', sa.String(length=36), nullable=False),
        sa.Column('total_amount_cents', sa.Integer(), nullable=False),
        sa.Column('status', sa.Enum('PENDING_PAYMENT', 'CONFIRMED', 'CANCELLED', 'EXPIRED', name='booking_status_enum'), server_default='PENDING_PAYMENT', nullable=True),
        sa.Column('ticket_id', sa.String(length=64), nullable=True),
        sa.Column('ticket_s3_url', sa.String(length=512), nullable=True),
        sa.Column('created_at', sa.DateTime(), nullable=True),
        sa.Column('updated_at', sa.DateTime(), nullable=True),
        sa.ForeignKeyConstraint(['event_id'], ['events.event_id']),
        sa.ForeignKeyConstraint(['seat_id'], ['seats.seat_id']),
        sa.ForeignKeyConstraint(['user_id'], ['users.user_id']),
        sa.PrimaryKeyConstraint('booking_id'),
        sa.UniqueConstraint('booking_ref'),
        sa.UniqueConstraint('idempotency_key'),
        sa.UniqueConstraint('seat_id', 'status', name='uq_active_seat_booking')
    )
    op.create_index(op.f('ix_bookings_booking_ref'), 'bookings', ['booking_ref'], unique=True)
    op.create_index(op.f('ix_bookings_idempotency_key'), 'bookings', ['idempotency_key'], unique=True)

    # 5. payments
    op.create_table(
        'payments',
        sa.Column('payment_id', sa.String(length=36), nullable=False),
        sa.Column('booking_id', sa.String(length=36), nullable=False),
        sa.Column('transaction_ref', sa.String(length=64), nullable=False),
        sa.Column('amount_cents', sa.Integer(), nullable=False),
        sa.Column('currency', sa.String(length=3), server_default='USD', nullable=True),
        sa.Column('payment_status', sa.Enum('INITIATED', 'SUCCESS', 'FAILED', name='payment_status_enum'), server_default='INITIATED', nullable=True),
        sa.Column('payment_method', sa.String(length=50), server_default='SIMULATED_CARD', nullable=True),
        sa.Column('created_at', sa.DateTime(), nullable=True),
        sa.ForeignKeyConstraint(['booking_id'], ['bookings.booking_id']),
        sa.PrimaryKeyConstraint('payment_id'),
        sa.UniqueConstraint('transaction_ref')
    )
    op.create_index(op.f('ix_payments_transaction_ref'), 'payments', ['transaction_ref'], unique=True)

    # 6. queue_entries (Durable Virtual Waiting Room)
    op.create_table(
        'queue_entries',
        sa.Column('queue_id', sa.String(length=36), nullable=False),
        sa.Column('event_id', sa.String(length=36), nullable=False),
        sa.Column('user_id', sa.String(length=36), nullable=False),
        sa.Column('queue_number', sa.Integer(), nullable=False),
        sa.Column('status', sa.String(length=20), server_default='WAITING', nullable=False),
        sa.Column('admission_token', sa.String(length=128), nullable=True),
        sa.Column('joined_at', sa.DateTime(), nullable=False),
        sa.Column('last_heartbeat', sa.DateTime(), nullable=False),
        sa.Column('admitted_at', sa.DateTime(), nullable=True),
        sa.Column('admission_expires_at', sa.DateTime(), nullable=True),
        sa.ForeignKeyConstraint(['event_id'], ['events.event_id'], ondelete='CASCADE'),
        sa.ForeignKeyConstraint(['user_id'], ['users.user_id'], ondelete='CASCADE'),
        sa.PrimaryKeyConstraint('queue_id'),
        sa.UniqueConstraint('admission_token')
    )
    op.create_index('idx_queue_event_status_num', 'queue_entries', ['event_id', 'status', 'queue_number'], unique=False)
    op.create_index(op.f('ix_queue_entries_event_id'), 'queue_entries', ['event_id'], unique=False)
    op.create_index(op.f('ix_queue_entries_user_id'), 'queue_entries', ['user_id'], unique=False)
    op.create_index(op.f('ix_queue_entries_admission_token'), 'queue_entries', ['admission_token'], unique=True)


def downgrade() -> None:
    op.drop_table('queue_entries')
    op.drop_table('payments')
    op.drop_table('bookings')
    op.drop_table('seats')
    op.drop_table('events')
    op.drop_table('users')
