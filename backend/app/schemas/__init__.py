from datetime import datetime
from typing import List, Optional
from pydantic import BaseModel, EmailStr, Field, ConfigDict


# Health Check
class HealthCheckResponse(BaseModel):
    status: str = "HEALTHY"
    service: str = "SurgeGate Backend"
    environment: str = "dev"
    database_connected: bool = True
    message: str = "SurgeGate traffic management node is operational."


# Auth & User
class UserRegister(BaseModel):
    email: EmailStr
    full_name: str
    password: str = Field(..., min_length=6)
    role: Optional[str] = "CUSTOMER"


class UserLogin(BaseModel):
    email: EmailStr
    password: str


class UserOut(BaseModel):
    user_id: str
    email: str
    full_name: str
    role: str
    created_at: Optional[datetime] = None

    model_config = ConfigDict(from_attributes=True)


class Token(BaseModel):
    access_token: str
    token_type: str = "bearer"
    user: UserOut


# Event
class EventBase(BaseModel):
    name: str
    description: Optional[str] = None
    venue: str
    event_timestamp: datetime
    total_capacity: int
    available_capacity: int
    status: str = "UPCOMING"


class EventCreate(EventBase):
    pass


class EventOut(EventBase):
    event_id: str
    created_at: Optional[datetime] = None
    updated_at: Optional[datetime] = None

    model_config = ConfigDict(from_attributes=True)


# Seat
class SeatOut(BaseModel):
    seat_id: str
    event_id: str
    section: str
    row_number: str
    seat_number: str
    price_cents: int
    status: str
    reserved_by: Optional[str] = None
    reserved_until: Optional[datetime] = None
    version: int

    model_config = ConfigDict(from_attributes=True)


class EventDetailOut(EventOut):
    seats: List[SeatOut] = []
    min_price_cents: Optional[int] = None
    max_price_cents: Optional[int] = None


# Virtual Waiting Room
class QueueJoinRequest(BaseModel):
    event_id: str


class QueueStatusResponse(BaseModel):
    queue_id: str
    event_id: str
    status: str  # WAITING, ADMITTED, EXPIRED, LEFT
    queue_number: int
    position_ahead: int
    estimated_wait_seconds: int
    admission_token: Optional[str] = None
    admission_expires_at: Optional[datetime] = None
    total_waiting: int


class QueueHeartbeatRequest(BaseModel):
    queue_id: str


# Seat Reservation (5-minute hold)
class SeatReserveRequest(BaseModel):
    event_id: str
    seat_id: Optional[str] = None
    seat_ids: Optional[List[str]] = None
    admission_token: str


class SeatReserveResponse(BaseModel):
    success: bool
    message: str
    seat_id: Optional[str] = None
    seat_ids: Optional[List[str]] = None
    status: str
    reserved_until: Optional[datetime] = None
    hold_duration_seconds: int = 300


# Booking & Mock Payment
class BookingCreateRequest(BaseModel):
    event_id: str
    seat_id: Optional[str] = None
    seat_ids: Optional[List[str]] = None
    idempotency_key: str
    admission_token: str


class PaymentSimulateRequest(BaseModel):
    booking_id: Optional[str] = None
    booking_ids: Optional[List[str]] = None
    idempotency_key: str
    simulate_failure: bool = False
    payment_method: str = "SIMULATED_CARD"


class PaymentResponse(BaseModel):
    payment_id: str
    transaction_ref: str
    booking_id: str
    amount_cents: int
    status: str
    message: str
    booking_ids: Optional[List[str]] = None


class BookingOut(BaseModel):
    booking_id: str
    booking_ref: str
    idempotency_key: str
    user_id: str
    event_id: str
    seat_id: str
    total_amount_cents: int
    status: str
    ticket_id: Optional[str] = None
    ticket_s3_url: Optional[str] = None
    created_at: Optional[datetime] = None
    updated_at: Optional[datetime] = None
    # Rich details for UI display & multi-seat checkout
    event_name: Optional[str] = None
    venue: Optional[str] = None
    event_timestamp: Optional[datetime] = None
    seat_info: Optional[str] = None
    section: Optional[str] = None
    row_number: Optional[str] = None
    seat_number: Optional[str] = None
    booking_ids: Optional[List[str]] = None
    bookings: Optional[List['BookingOut']] = None

    model_config = ConfigDict(from_attributes=True)


class TicketVerificationResponse(BaseModel):
    is_valid: bool
    ticket_id: str
    booking_ref: str
    event_name: str
    event_timestamp: datetime
    venue: str
    section: str
    row_number: str
    seat_number: str
    attendee_name: str
    status: str
