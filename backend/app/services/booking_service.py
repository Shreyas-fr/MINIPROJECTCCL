from datetime import datetime, timedelta
from typing import Optional, Dict, Any, List
import uuid
import secrets
from sqlalchemy.orm import Session
from sqlalchemy import func
from fastapi import HTTPException, status

from app.core.config import settings
from app.models import Seat, Booking, Payment, Event, User, QueueEntry
from app.services.queue_service import QueueService
from app.schemas import (
    SeatReserveResponse,
    BookingOut,
    PaymentResponse,
    PaymentSimulateRequest,
    BookingCreateRequest
)


class BookingService:
    @staticmethod
    def _now() -> datetime:
        return datetime.utcnow()

    @classmethod
    def hold_seat(
        cls,
        db: Session,
        user: User,
        event_id: str,
        seat_id: str,
        admission_token: str
    ) -> SeatReserveResponse:
        """
        Pessimistic row-level lock (SELECT ... FOR UPDATE) to hold a seat for 5 minutes.
        Requires active admission token from the virtual waiting room.
        """
        # 1. Validate admission token
        QueueService.validate_admission_token(db, user, event_id, admission_token)

        now = cls._now()
        hold_duration = settings.SEAT_HOLD_DURATION_SECONDS

        # 2. Acquire pessimistic lock on seat row
        seat = db.query(Seat).filter(
            Seat.seat_id == seat_id,
            Seat.event_id == event_id
        ).with_for_update().first()

        if not seat:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Seat not found for this event")

        if seat.status == "BOOKED":
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail="Seat is already permanently booked"
            )

        if seat.status == "RESERVED" and seat.reserved_until and seat.reserved_until > now:
            # Check if reserved by current user (extend hold) or another user (reject)
            if seat.reserved_by != user.user_id:
                raise HTTPException(
                    status_code=status.HTTP_409_CONFLICT,
                    detail="Seat is currently reserved by another customer. Please select another seat."
                )

        # 3. Reserve seat for 5 minutes
        reserved_until = now + timedelta(seconds=hold_duration)
        seat.status = "RESERVED"
        seat.reserved_by = user.user_id
        seat.reserved_until = reserved_until
        seat.version += 1

        db.commit()
        db.refresh(seat)

        return SeatReserveResponse(
            success=True,
            message="Seat successfully held for 5 minutes",
            seat_id=seat.seat_id,
            status="RESERVED",
            reserved_until=reserved_until,
            hold_duration_seconds=hold_duration
        )

    @classmethod
    def release_seat(cls, db: Session, user: User, event_id: str, seat_id: str) -> Dict[str, Any]:
        seat = db.query(Seat).filter(
            Seat.seat_id == seat_id,
            Seat.event_id == event_id,
            Seat.reserved_by == user.user_id,
            Seat.status == "RESERVED"
        ).with_for_update().first()

        if seat:
            seat.status = "AVAILABLE"
            seat.reserved_by = None
            seat.reserved_until = None
            seat.version += 1
            db.commit()
            return {"status": "SUCCESS", "message": "Seat hold released"}
        return {"status": "NOOP", "message": "Seat was not held by this user"}

    @classmethod
    def create_booking(
        cls,
        db: Session,
        user: User,
        payload: BookingCreateRequest
    ) -> BookingOut:
        """
        Idempotent booking initialization.
        Ensures seat is locked by user and creates a PENDING_PAYMENT booking.
        """
        # Validate admission token
        QueueService.validate_admission_token(db, user, payload.event_id, payload.admission_token)

        # 1. Check idempotency: if booking already exists with this idempotency key
        existing_booking = db.query(Booking).filter(
            Booking.idempotency_key == payload.idempotency_key
        ).first()

        if existing_booking:
            if existing_booking.user_id != user.user_id:
                raise HTTPException(
                    status_code=status.HTTP_409_CONFLICT,
                    detail="Idempotency key collision from another user"
                )
            return BookingOut.model_validate(existing_booking)

        now = cls._now()

        # 2. Lock seat row FOR UPDATE
        seat = db.query(Seat).filter(
            Seat.seat_id == payload.seat_id,
            Seat.event_id == payload.event_id
        ).with_for_update().first()

        if not seat:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Seat not found")

        if seat.status != "RESERVED" or seat.reserved_by != user.user_id:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="Seat is not actively reserved by you. Please hold the seat first."
            )

        if not seat.reserved_until or seat.reserved_until <= now:
            seat.status = "AVAILABLE"
            seat.reserved_by = None
            seat.reserved_until = None
            db.commit()
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="Your 5-minute seat hold has expired. Please select the seat again."
            )

        # Generate human-friendly booking reference: SG-XXXX-XXXX
        booking_ref = f"SG-{secrets.token_hex(4).upper()}"
        booking_id = str(uuid.uuid4())

        new_booking = Booking(
            booking_id=booking_id,
            booking_ref=booking_ref,
            idempotency_key=payload.idempotency_key,
            user_id=user.user_id,
            event_id=payload.event_id,
            seat_id=payload.seat_id,
            total_amount_cents=seat.price_cents,
            status="PENDING_PAYMENT",
            created_at=now
        )
        db.add(new_booking)
        db.commit()
        db.refresh(new_booking)

        return BookingOut.model_validate(new_booking)

    @classmethod
    def simulate_payment_checkout(
        cls,
        db: Session,
        user: User,
        payload: PaymentSimulateRequest
    ) -> PaymentResponse:
        """
        Processes mock payment, enforces transaction safety, prevents double-booking,
        and transitions booking to CONFIRMED.
        """
        now = cls._now()

        # Check payment idempotency
        existing_payment = db.query(Payment).filter(
            Payment.transaction_ref == f"TX-{payload.idempotency_key}"
        ).first()
        if existing_payment:
            return PaymentResponse(
                payment_id=existing_payment.payment_id,
                transaction_ref=existing_payment.transaction_ref,
                booking_id=existing_payment.booking_id,
                amount_cents=existing_payment.amount_cents,
                status=existing_payment.payment_status,
                message="Idempotent replay: previous payment transaction retrieved."
            )

        # Lock booking row FOR UPDATE
        booking = db.query(Booking).filter(
            Booking.booking_id == payload.booking_id,
            Booking.user_id == user.user_id
        ).with_for_update().first()

        if not booking:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Booking not found")

        if booking.status == "CONFIRMED":
            return PaymentResponse(
                payment_id=str(uuid.uuid4()),
                transaction_ref=f"TX-{payload.idempotency_key}",
                booking_id=booking.booking_id,
                amount_cents=booking.total_amount_cents,
                status="SUCCESS",
                message="Booking already confirmed."
            )

        # Lock seat row FOR UPDATE
        seat = db.query(Seat).filter(
            Seat.seat_id == booking.seat_id
        ).with_for_update().first()

        if not seat:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Seat associated with booking not found")

        # Check if reservation lock expired
        if seat.status != "RESERVED" or not seat.reserved_until or seat.reserved_until <= now:
            booking.status = "EXPIRED"
            seat.status = "AVAILABLE"
            seat.reserved_by = None
            seat.reserved_until = None
            db.commit()
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="Seat reservation expired before checkout completion."
            )

        transaction_ref = f"TX-{payload.idempotency_key}"
        payment_id = str(uuid.uuid4())

        # Handle Simulated Failure
        if payload.simulate_failure:
            payment = Payment(
                payment_id=payment_id,
                booking_id=booking.booking_id,
                transaction_ref=transaction_ref,
                amount_cents=booking.total_amount_cents,
                currency="USD",
                payment_status="FAILED",
                payment_method=payload.payment_method,
                created_at=now
            )
            db.add(payment)
            db.commit()
            raise HTTPException(
                status_code=status.HTTP_402_PAYMENT_REQUIRED,
                detail="Payment simulation failed: card declined or insufficient funds."
            )

        # Successful Payment & Atomic Confirmation
        payment = Payment(
            payment_id=payment_id,
            booking_id=booking.booking_id,
            transaction_ref=transaction_ref,
            amount_cents=booking.total_amount_cents,
            currency="USD",
            payment_status="SUCCESS",
            payment_method=payload.payment_method,
            created_at=now
        )
        db.add(payment)

        # Transition Booking and Seat atomically
        booking.status = "CONFIRMED"
        ticket_id = f"TICK-{uuid.uuid4().hex[:12].upper()}"
        booking.ticket_id = ticket_id

        seat.status = "BOOKED"
        seat.reserved_until = None

        # Decrement event available capacity
        event = db.query(Event).filter(Event.event_id == booking.event_id).with_for_update().first()
        if event and event.available_capacity > 0:
            event.available_capacity -= 1
            if event.available_capacity == 0:
                event.status = "SOLD_OUT"

        db.commit()
        db.refresh(booking)

        return PaymentResponse(
            payment_id=payment.payment_id,
            transaction_ref=payment.transaction_ref,
            booking_id=booking.booking_id,
            amount_cents=payment.amount_cents,
            status="SUCCESS",
            message="Payment completed successfully. Booking confirmed!"
        )
