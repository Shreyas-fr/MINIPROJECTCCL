from datetime import datetime
import uuid
from sqlalchemy import Column, String, Integer, DateTime, Text, Enum, ForeignKey, UniqueConstraint, Index, CheckConstraint
from sqlalchemy.orm import relationship
from app.core.database import Base


class User(Base):
    __tablename__ = "users"

    user_id = Column(String(36), primary_key=True, default=lambda: str(uuid.uuid4()))
    email = Column(String(255), unique=True, nullable=False, index=True)
    full_name = Column(String(255), nullable=False)
    password_hash = Column(String(255), nullable=True)
    role = Column(String(20), nullable=False, default="CUSTOMER")  # CUSTOMER, ADMIN
    created_at = Column(DateTime, default=datetime.utcnow)

    bookings = relationship("Booking", back_populates="user")
    queue_entries = relationship("QueueEntry", back_populates="user")


class Event(Base):
    __tablename__ = "events"

    event_id = Column(String(36), primary_key=True, default=lambda: str(uuid.uuid4()))
    name = Column(String(255), nullable=False)
    description = Column(Text, nullable=True)
    venue = Column(String(255), nullable=False)
    event_timestamp = Column(DateTime, nullable=False)
    total_capacity = Column(Integer, nullable=False)
    available_capacity = Column(Integer, nullable=False)
    status = Column(Enum("UPCOMING", "ACTIVE", "SOLD_OUT", "COMPLETED", name="event_status_enum"), default="UPCOMING")
    created_at = Column(DateTime, default=datetime.utcnow)
    updated_at = Column(DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)

    seats = relationship("Seat", back_populates="event", cascade="all, delete-orphan")
    bookings = relationship("Booking", back_populates="event")
    queue_entries = relationship("QueueEntry", back_populates="event")

    __table_args__ = (
        CheckConstraint("available_capacity >= 0", name="chk_capacity"),
    )


class Seat(Base):
    __tablename__ = "seats"

    seat_id = Column(String(36), primary_key=True, default=lambda: str(uuid.uuid4()))
    event_id = Column(String(36), ForeignKey("events.event_id", ondelete="CASCADE"), nullable=False)
    section = Column(String(50), nullable=False)
    row_number = Column("row_number", String(20), nullable=False, quote=True)
    seat_number = Column(String(20), nullable=False)
    price_cents = Column(Integer, nullable=False)
    status = Column(Enum("AVAILABLE", "RESERVED", "BOOKED", name="seat_status_enum"), default="AVAILABLE")
    reserved_by = Column(String(36), nullable=True)
    reserved_until = Column(DateTime, nullable=True)
    version = Column(Integer, nullable=False, default=1)
    created_at = Column(DateTime, default=datetime.utcnow)
    updated_at = Column(DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)

    event = relationship("Event", back_populates="seats")
    bookings = relationship("Booking", back_populates="seat")

    __table_args__ = (
        UniqueConstraint("event_id", "section", "row_number", "seat_number", name="uq_event_seat"),
        Index("idx_seat_status_lookup", "event_id", "status", "reserved_until"),
    )


class Booking(Base):
    __tablename__ = "bookings"

    booking_id = Column(String(36), primary_key=True, default=lambda: str(uuid.uuid4()))
    booking_ref = Column(String(32), unique=True, nullable=False, index=True)
    idempotency_key = Column(String(128), unique=True, nullable=False, index=True)
    user_id = Column(String(36), ForeignKey("users.user_id"), nullable=False)
    event_id = Column(String(36), ForeignKey("events.event_id"), nullable=False)
    seat_id = Column(String(36), ForeignKey("seats.seat_id"), nullable=False)
    total_amount_cents = Column(Integer, nullable=False)
    status = Column(Enum("PENDING_PAYMENT", "CONFIRMED", "CANCELLED", "EXPIRED", name="booking_status_enum"), default="PENDING_PAYMENT")
    ticket_id = Column(String(64), nullable=True)
    ticket_s3_url = Column(String(512), nullable=True)
    created_at = Column(DateTime, default=datetime.utcnow)
    updated_at = Column(DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)

    user = relationship("User", back_populates="bookings")
    event = relationship("Event", back_populates="bookings")
    seat = relationship("Seat", back_populates="bookings")
    payment = relationship("Payment", back_populates="booking", uselist=False)

    __table_args__ = (
        UniqueConstraint("seat_id", "status", name="uq_active_seat_booking"),
    )


class Payment(Base):
    __tablename__ = "payments"

    payment_id = Column(String(36), primary_key=True, default=lambda: str(uuid.uuid4()))
    booking_id = Column(String(36), ForeignKey("bookings.booking_id"), nullable=False)
    transaction_ref = Column(String(64), unique=True, nullable=False, index=True)
    amount_cents = Column(Integer, nullable=False)
    currency = Column(String(3), default="USD")
    payment_status = Column(Enum("INITIATED", "SUCCESS", "FAILED", name="payment_status_enum"), default="INITIATED")
    payment_method = Column(String(50), default="SIMULATED_CARD")
    created_at = Column(DateTime, default=datetime.utcnow)

    booking = relationship("Booking", back_populates="payment")


class QueueEntry(Base):
    __tablename__ = "queue_entries"

    queue_id = Column(String(36), primary_key=True, default=lambda: str(uuid.uuid4()))
    event_id = Column(String(36), ForeignKey("events.event_id", ondelete="CASCADE"), nullable=False, index=True)
    user_id = Column(String(36), ForeignKey("users.user_id", ondelete="CASCADE"), nullable=False, index=True)
    queue_number = Column(Integer, nullable=False)
    status = Column(String(20), default="WAITING", nullable=False)  # WAITING, ADMITTED, EXPIRED, LEFT
    admission_token = Column(String(128), unique=True, nullable=True, index=True)
    joined_at = Column(DateTime, default=datetime.utcnow, nullable=False)
    last_heartbeat = Column(DateTime, default=datetime.utcnow, nullable=False)
    admitted_at = Column(DateTime, nullable=True)
    admission_expires_at = Column(DateTime, nullable=True)

    user = relationship("User", back_populates="queue_entries")
    event = relationship("Event", back_populates="queue_entries")

    __table_args__ = (
        Index("idx_queue_event_status_num", "event_id", "status", "queue_number"),
    )
