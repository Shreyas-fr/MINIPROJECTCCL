from datetime import datetime, timedelta
from typing import Optional, Dict, Any, List
import uuid
import secrets
import threading
from sqlalchemy.orm import Session
from sqlalchemy import func, or_
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
    MAX_SEATS_PER_BOOKING = 4
    _sqlite_lock = threading.Lock()

    @staticmethod
    def _now() -> datetime:
        return datetime.utcnow()

    @classmethod
    def _format_booking_out(cls, db: Session, bookings: List[Booking]) -> BookingOut:
        if not bookings:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Booking not found")

        primary = bookings[0]
        event = db.query(Event).filter(Event.event_id == primary.event_id).first()
        primary_seat = db.query(Seat).filter(Seat.seat_id == primary.seat_id).first()
        total_cents = sum(b.total_amount_cents for b in bookings)

        out_list = []
        for b in bookings:
            s = db.query(Seat).filter(Seat.seat_id == b.seat_id).first()
            item = BookingOut.model_validate(b)
            if event:
                item.event_name = event.name
                item.venue = event.venue
                item.event_timestamp = event.event_timestamp
            if s:
                item.section = s.section
                item.row_number = s.row_number
                item.seat_number = s.seat_number
                item.seat_info = f"{s.section} • Row {s.row_number}, Seat {s.seat_number}"
            out_list.append(item)

        primary_out = BookingOut.model_validate(primary)
        if event:
            primary_out.event_name = event.name
            primary_out.venue = event.venue
            primary_out.event_timestamp = event.event_timestamp
        if primary_seat:
            primary_out.section = primary_seat.section
            primary_out.row_number = primary_seat.row_number
            primary_out.seat_number = primary_seat.seat_number
            if len(bookings) == 1:
                primary_out.seat_info = f"{primary_seat.section} • Row {primary_seat.row_number}, Seat {primary_seat.seat_number}"
            else:
                seat_labels = [f"{b.seat.section}-{b.seat.seat_number}" if b.seat else b.seat_id for b in bookings]
                primary_out.seat_info = f"{len(bookings)} Seats ({', '.join(seat_labels)})"

        primary_out.total_amount_cents = total_cents
        primary_out.booking_ids = [b.booking_id for b in bookings]
        primary_out.bookings = out_list
        return primary_out

    @classmethod
    def hold_seat(
        cls,
        db: Session,
        user: User,
        event_id: str,
        seat_id: Optional[str] = None,
        seat_ids: Optional[List[str]] = None,
        admission_token: str = ""
    ) -> SeatReserveResponse:
        # On in-memory SQLite (used during unit tests with StaticPool), Python's sqlite3 driver
        # shares a single connection context across all test threads without thread isolation.
        # We synchronize SQLite executions to prevent connection transaction crosstalk.
        # In production on MySQL 8, this lock is bypassed and real InnoDB row-level locking
        # (SELECT ... FOR UPDATE) handles concurrent transactions independently.
        if db.bind and db.bind.dialect.name == "sqlite":
            with cls._sqlite_lock:
                return cls._execute_hold_seat(db, user, event_id, seat_id, seat_ids, admission_token)
        return cls._execute_hold_seat(db, user, event_id, seat_id, seat_ids, admission_token)

    @classmethod
    def _execute_hold_seat(
        cls,
        db: Session,
        user: User,
        event_id: str,
        seat_id: Optional[str] = None,
        seat_ids: Optional[List[str]] = None,
        admission_token: str = ""
    ) -> SeatReserveResponse:
        """
        Pessimistic row-level lock (SELECT ... FOR UPDATE) to hold up to 4 seats for 5 minutes.
        Requires active admission token from the virtual waiting room.
        Locks seats in sorted order to prevent database deadlocks.
        """
        # 1. Validate admission token
        QueueService.validate_admission_token(db, user, event_id, admission_token)

        target_seat_ids = seat_ids if seat_ids else ([seat_id] if seat_id else [])
        if not target_seat_ids:
            raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="At least one seat_id must be provided")

        if len(target_seat_ids) > cls.MAX_SEATS_PER_BOOKING:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail=f"Maximum ticket limit exceeded. You may select at most {cls.MAX_SEATS_PER_BOOKING} seats per reservation."
            )

        # Enforce overall per-user confirmed ticket limit for this event
        confirmed_count = db.query(func.count(Booking.booking_id)).filter(
            Booking.event_id == event_id,
            Booking.user_id == user.user_id,
            Booking.status == "CONFIRMED"
        ).scalar() or 0

        if confirmed_count + len(target_seat_ids) > cls.MAX_SEATS_PER_BOOKING:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail=f"Ticket limit exceeded. Customers may purchase at most {cls.MAX_SEATS_PER_BOOKING} seats per event (you have {confirmed_count} confirmed)."
            )

        # Deduplicate and sort IDs for deadlock-safe locking
        target_seat_ids = sorted(list(set(target_seat_ids)))
        now = cls._now()
        hold_duration = settings.SEAT_HOLD_DURATION_SECONDS
        reserved_until = now + timedelta(seconds=hold_duration)

        # 2. Acquire pessimistic lock on seat rows in consistent ascending alphabetical order
        seats = db.query(Seat).filter(
            Seat.seat_id.in_(target_seat_ids),
            Seat.event_id == event_id
        ).order_by(Seat.seat_id.asc()).with_for_update().all()

        if len(seats) != len(target_seat_ids):
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="One or more seats not found for this event")

        # 3. Validate seat availability atomically
        for s in seats:
            if s.status == "BOOKED":
                raise HTTPException(
                    status_code=status.HTTP_409_CONFLICT,
                    detail=f"Seat {s.section} Row {s.row_number} Seat {s.seat_number} is already permanently booked"
                )
            if s.status == "RESERVED" and s.reserved_until and s.reserved_until > now:
                if s.reserved_by != user.user_id:
                    raise HTTPException(
                        status_code=status.HTTP_409_CONFLICT,
                        detail=f"Seat {s.section} Row {s.row_number} Seat {s.seat_number} is currently reserved by another customer."
                    )

        # 4. Atomically hold all requested seats with optimistic concurrency version check
        # Ensures multi-seat reservations are strictly atomic: either all requested seats are held or none are.
        held_seat_ids = []
        for s in seats:
            observed_version = s.version
            updated_rows = db.query(Seat).filter(
                Seat.seat_id == s.seat_id,
                Seat.event_id == event_id,
                Seat.version == observed_version,
                (Seat.status == "AVAILABLE") | 
                ((Seat.status == "RESERVED") & ((Seat.reserved_until <= now) | (Seat.reserved_by == user.user_id)))
            ).update({
                Seat.status: "RESERVED",
                Seat.reserved_by: user.user_id,
                Seat.reserved_until: reserved_until,
                Seat.version: Seat.version + 1
            }, synchronize_session=False)

            if updated_rows == 0:
                if held_seat_ids:
                    db.rollback()
                raise HTTPException(
                    status_code=status.HTTP_409_CONFLICT,
                    detail=f"Seat {s.section} Row {s.row_number} Seat {s.seat_number} is currently reserved by another customer. Please select another seat."
                )
            held_seat_ids.append(s.seat_id)

        db.commit()
        for s in seats:
            db.refresh(s)

        return SeatReserveResponse(
            success=True,
            message=f"{len(seats)} seat(s) successfully held for 5 minutes",
            seat_id=seats[0].seat_id,
            seat_ids=[s.seat_id for s in seats],
            status="RESERVED",
            reserved_until=reserved_until,
            hold_duration_seconds=hold_duration
        )

    @classmethod
    def release_seat(
        cls,
        db: Session,
        user: User,
        event_id: str,
        seat_id: Optional[str] = None,
        seat_ids: Optional[List[str]] = None
    ) -> Dict[str, Any]:
        query = db.query(Seat).filter(
            Seat.event_id == event_id,
            Seat.reserved_by == user.user_id,
            Seat.status == "RESERVED"
        )
        if seat_ids:
            query = query.filter(Seat.seat_id.in_(seat_ids))
        elif seat_id:
            query = query.filter(Seat.seat_id == seat_id)

        seats = query.with_for_update().all()
        if seats:
            for s in seats:
                s.status = "AVAILABLE"
                s.reserved_by = None
                s.reserved_until = None
                s.version += 1
            db.commit()
            return {"status": "SUCCESS", "message": f"{len(seats)} seat hold(s) released"}
        return {"status": "NOOP", "message": "No seats were held by this user"}

    @classmethod
    def create_booking(
        cls,
        db: Session,
        user: User,
        payload: BookingCreateRequest
    ) -> BookingOut:
        """
        Idempotent booking initialization for single or multiple seats (up to 4).
        Ensures seats are actively held by the user and creates PENDING_PAYMENT booking records.
        """
        # Validate admission token
        QueueService.validate_admission_token(db, user, payload.event_id, payload.admission_token)

        target_seat_ids = payload.seat_ids if payload.seat_ids else ([payload.seat_id] if payload.seat_id else [])
        if not target_seat_ids:
            raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="At least one seat must be selected for booking")

        if len(target_seat_ids) > cls.MAX_SEATS_PER_BOOKING:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail=f"Cannot book more than {cls.MAX_SEATS_PER_BOOKING} seats per checkout"
            )

        target_seat_ids = sorted(list(set(target_seat_ids)))

        # 1. Check idempotency: match exact key or batch keys
        existing_bookings = db.query(Booking).filter(
            or_(
                Booking.idempotency_key == payload.idempotency_key,
                Booking.idempotency_key.like(f"{payload.idempotency_key}-%")
            )
        ).order_by(Booking.created_at.asc()).all()

        if existing_bookings:
            if any(b.user_id != user.user_id for b in existing_bookings):
                raise HTTPException(
                    status_code=status.HTTP_409_CONFLICT,
                    detail="Idempotency key collision from another user"
                )
            return cls._format_booking_out(db, existing_bookings)

        now = cls._now()

        # 2. Lock seat rows in sorted order FOR UPDATE
        seats = db.query(Seat).filter(
            Seat.seat_id.in_(target_seat_ids),
            Seat.event_id == payload.event_id
        ).order_by(Seat.seat_id.asc()).with_for_update().all()

        if len(seats) != len(target_seat_ids):
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="One or more seats not found")

        for s in seats:
            if s.status != "RESERVED" or s.reserved_by != user.user_id:
                raise HTTPException(
                    status_code=status.HTTP_400_BAD_REQUEST,
                    detail=f"Seat {s.section} Row {s.row_number} Seat {s.seat_number} is not actively reserved by you. Please hold the seat first."
                )
            if not s.reserved_until or s.reserved_until <= now:
                s.status = "AVAILABLE"
                s.reserved_by = None
                s.reserved_until = None
                db.commit()
                raise HTTPException(
                    status_code=status.HTTP_400_BAD_REQUEST,
                    detail="Your 5-minute seat hold has expired. Please select the seats again."
                )

        # 3. Create booking records atomically
        created_bookings: List[Booking] = []
        for i, seat in enumerate(seats):
            booking_ref = f"SG-{secrets.token_hex(4).upper()}"
            booking_id = str(uuid.uuid4())
            booking_key = payload.idempotency_key if len(seats) == 1 else f"{payload.idempotency_key}-{i}"

            new_booking = Booking(
                booking_id=booking_id,
                booking_ref=booking_ref,
                idempotency_key=booking_key,
                user_id=user.user_id,
                event_id=payload.event_id,
                seat_id=seat.seat_id,
                total_amount_cents=seat.price_cents,
                status="PENDING_PAYMENT",
                created_at=now
            )
            db.add(new_booking)
            created_bookings.append(new_booking)

        db.commit()
        for b in created_bookings:
            db.refresh(b)

        return cls._format_booking_out(db, created_bookings)

    @classmethod
    def simulate_payment_checkout(
        cls,
        db: Session,
        user: User,
        payload: PaymentSimulateRequest
    ) -> PaymentResponse:
        """
        Processes simulated payment, enforces transaction safety, prevents double-booking,
        and transitions bookings and seats to CONFIRMED / BOOKED atomically.
        Supports single or batch booking checkouts and resilient retry upon simulated decline.
        """
        now = cls._now()
        target_booking_ids = payload.booking_ids if payload.booking_ids else ([payload.booking_id] if payload.booking_id else [])
        if not target_booking_ids:
            raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="At least one booking_id required for checkout")

        # 1. Lock booking rows FOR UPDATE
        bookings = db.query(Booking).filter(
            Booking.booking_id.in_(target_booking_ids),
            Booking.user_id == user.user_id
        ).with_for_update().all()

        if len(bookings) != len(target_booking_ids):
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="One or more bookings not found for this user")

        # Check if already confirmed
        if all(b.status == "CONFIRMED" for b in bookings):
            return PaymentResponse(
                payment_id=str(uuid.uuid4()),
                transaction_ref=f"TX-{payload.idempotency_key}",
                booking_id=bookings[0].booking_id,
                amount_cents=sum(b.total_amount_cents for b in bookings),
                status="SUCCESS",
                message="Bookings already confirmed.",
                booking_ids=[b.booking_id for b in bookings]
            )

        # 2. Check payment idempotency (allow retry if previous attempt failed)
        existing_payment = db.query(Payment).filter(
            Payment.transaction_ref == f"TX-{payload.idempotency_key}"
        ).first()

        if existing_payment and existing_payment.payment_status == "SUCCESS":
            return PaymentResponse(
                payment_id=existing_payment.payment_id,
                transaction_ref=existing_payment.transaction_ref,
                booking_id=bookings[0].booking_id,
                amount_cents=existing_payment.amount_cents,
                status=existing_payment.payment_status,
                message="Idempotent replay: previous successful payment transaction retrieved.",
                booking_ids=[b.booking_id for b in bookings]
            )

        # Generate unique transaction reference for this attempt (ensures retry after failure succeeds)
        if existing_payment and existing_payment.payment_status == "FAILED":
            transaction_ref = f"TX-{payload.idempotency_key}-retry-{secrets.token_hex(3)}"
        else:
            transaction_ref = f"TX-{payload.idempotency_key}"

        # 3. Lock seat rows in sorted order FOR UPDATE
        seat_ids = [b.seat_id for b in bookings]
        seats = db.query(Seat).filter(
            Seat.seat_id.in_(seat_ids)
        ).order_by(Seat.seat_id.asc()).with_for_update().all()

        for seat in seats:
            if seat.status != "RESERVED" or not seat.reserved_until or seat.reserved_until <= now:
                for b in bookings:
                    b.status = "EXPIRED"
                for s in seats:
                    s.status = "AVAILABLE"
                    s.reserved_by = None
                    s.reserved_until = None
                db.commit()
                raise HTTPException(
                    status_code=status.HTTP_400_BAD_REQUEST,
                    detail="Seat reservation expired before checkout completion."
                )

        total_amount = sum(b.total_amount_cents for b in bookings)
        payment_id = str(uuid.uuid4())

        # 4. Handle Simulated Failure
        if payload.simulate_failure:
            payment = Payment(
                payment_id=payment_id,
                booking_id=bookings[0].booking_id,
                transaction_ref=transaction_ref,
                amount_cents=total_amount,
                currency="USD",
                payment_status="FAILED",
                payment_method=payload.payment_method,
                created_at=now
            )
            db.add(payment)
            db.commit()
            raise HTTPException(
                status_code=status.HTTP_402_PAYMENT_REQUIRED,
                detail="Payment simulation failed: card declined or insufficient funds. Seat holds remain active for retry."
            )

        # 5. Successful Payment & Atomic Confirmation
        payment = Payment(
            payment_id=payment_id,
            booking_id=bookings[0].booking_id,
            transaction_ref=transaction_ref,
            amount_cents=total_amount,
            currency="USD",
            payment_status="SUCCESS",
            payment_method=payload.payment_method,
            created_at=now
        )
        db.add(payment)

        # Transition all Bookings and Seats atomically
        from app.services.ticket_processor import TicketProcessorService
        event = db.query(Event).filter(Event.event_id == bookings[0].event_id).with_for_update().first()

        for b in bookings:
            b.status = "CONFIRMED"
            ticket_id = f"TICK-{uuid.uuid4().hex[:12].upper()}"
            b.ticket_id = ticket_id

        for s in seats:
            s.status = "BOOKED"
            s.reserved_until = None
            s.version += 1

        if event and event.available_capacity > 0:
            event.available_capacity = max(0, event.available_capacity - len(bookings))
            if event.available_capacity == 0:
                event.status = "SOLD_OUT"

        db.commit()
        for b in bookings:
            db.refresh(b)

        # Dispatch async ticket generation jobs
        for b in bookings:
            s = next((seat for seat in seats if seat.seat_id == b.seat_id), None)
            if s:
                TicketProcessorService.dispatch_ticket_job(db, b, s, user)

        return PaymentResponse(
            payment_id=payment.payment_id,
            transaction_ref=payment.transaction_ref,
            booking_id=bookings[0].booking_id,
            amount_cents=total_amount,
            status="SUCCESS",
            message=f"Payment completed successfully. {len(bookings)} booking(s) confirmed!",
            booking_ids=[b.booking_id for b in bookings]
        )
