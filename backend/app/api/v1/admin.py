from datetime import datetime, timedelta
from typing import Optional, Dict, Any
from fastapi import APIRouter, Depends, Query, status
from sqlalchemy.orm import Session
from sqlalchemy import func

from app.core.database import get_db
from app.core.security import get_current_admin
from app.models import User, Event, Seat, Booking, Payment, QueueEntry
from app.services.queue_service import QueueService

router = APIRouter()


@router.post("/queue/{event_id}/admit")
def admit_queue_batch(
    event_id: str,
    batch_size: Optional[int] = Query(None, ge=1, le=100),
    db: Session = Depends(get_db),
    admin: User = Depends(get_current_admin)
):
    admitted = QueueService.admit_next_batch(db, event_id, batch_size=batch_size)
    return {
        "status": "SUCCESS",
        "event_id": event_id,
        "admitted_count": admitted,
        "message": f"Successfully admitted {admitted} users from the virtual waiting room."
    }


@router.get("/queue/{event_id}/metrics")
def get_queue_metrics(
    event_id: str,
    db: Session = Depends(get_db),
    admin: User = Depends(get_current_admin)
):
    now = datetime.utcnow()
    waiting_count = db.query(func.count(QueueEntry.queue_id)).filter(
        QueueEntry.event_id == event_id,
        QueueEntry.status == "WAITING"
    ).scalar() or 0

    admitted_count = db.query(func.count(QueueEntry.queue_id)).filter(
        QueueEntry.event_id == event_id,
        QueueEntry.status == "ADMITTED",
        QueueEntry.admission_expires_at > now
    ).scalar() or 0

    expired_count = db.query(func.count(QueueEntry.queue_id)).filter(
        QueueEntry.event_id == event_id,
        QueueEntry.status == "EXPIRED"
    ).scalar() or 0

    return {
        "event_id": event_id,
        "waiting_users": waiting_count,
        "active_admitted_users": admitted_count,
        "expired_users": expired_count,
        "timestamp": now.isoformat()
    }


@router.get("/overview")
def get_admin_overview(
    db: Session = Depends(get_db),
    admin: User = Depends(get_current_admin)
):
    now = datetime.utcnow()

    total_events = db.query(func.count(Event.event_id)).scalar() or 0
    active_events = db.query(func.count(Event.event_id)).filter(Event.status == "ACTIVE").scalar() or 0
    total_users = db.query(func.count(User.user_id)).scalar() or 0
    total_bookings = db.query(func.count(Booking.booking_id)).scalar() or 0
    confirmed_bookings = db.query(func.count(Booking.booking_id)).filter(Booking.status == "CONFIRMED").scalar() or 0
    
    total_revenue_cents = db.query(func.coalesce(func.sum(Booking.total_amount_cents), 0)).filter(
        Booking.status == "CONFIRMED"
    ).scalar() or 0

    active_seat_holds = db.query(func.count(Seat.seat_id)).filter(
        Seat.status == "RESERVED",
        Seat.reserved_until > now
    ).scalar() or 0

    return {
        "total_events": total_events,
        "active_flash_sales": active_events,
        "total_registered_users": total_users,
        "total_bookings": total_bookings,
        "confirmed_bookings": confirmed_bookings,
        "total_revenue_cents": total_revenue_cents,
        "active_seat_holds": active_seat_holds,
        "timestamp": now.isoformat()
    }
