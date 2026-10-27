from datetime import datetime
from typing import List, Optional
import uuid
from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy.orm import Session
from sqlalchemy import func

from app.core.database import get_db
from app.core.security import get_current_admin
from app.models import Event, Seat, User
from app.schemas import EventOut, EventCreate, EventDetailOut, SeatOut

router = APIRouter()


@router.get("", response_model=List[EventDetailOut])
def list_events(
    status_filter: Optional[str] = Query(None, alias="status"),
    db: Session = Depends(get_db)
):
    query = db.query(Event)
    if status_filter:
        query = query.filter(Event.status == status_filter)
    events = query.order_by(Event.event_timestamp.asc()).all()

    now = datetime.utcnow()
    results = []
    for evt in events:
        # Calculate pricing range
        prices = db.query(
            func.min(Seat.price_cents),
            func.max(Seat.price_cents)
        ).filter(Seat.event_id == evt.event_id).first()
        min_p = prices[0] if prices else None
        max_p = prices[1] if prices else None

        # Calculate actual available capacity (AVAILABLE or expired RESERVED)
        booked_or_active_reserved = db.query(func.count(Seat.seat_id)).filter(
            Seat.event_id == evt.event_id,
            (Seat.status == "BOOKED") | ((Seat.status == "RESERVED") & (Seat.reserved_until > now))
        ).scalar() or 0

        actual_available = max(0, evt.total_capacity - booked_or_active_reserved)

        detail = EventDetailOut(
            event_id=evt.event_id,
            name=evt.name,
            description=evt.description,
            venue=evt.venue,
            event_timestamp=evt.event_timestamp,
            total_capacity=evt.total_capacity,
            available_capacity=actual_available,
            status=evt.status,
            min_price_cents=min_p,
            max_price_cents=max_p,
            created_at=evt.created_at,
            updated_at=evt.updated_at,
            seats=[]
        )
        results.append(detail)
    return results


@router.get("/{event_id}", response_model=EventDetailOut)
def get_event_detail(event_id: str, db: Session = Depends(get_db)):
    evt = db.query(Event).filter(Event.event_id == event_id).first()
    if not evt:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Event not found")

    now = datetime.utcnow()
    # Compute active availability
    booked_or_active_reserved = db.query(func.count(Seat.seat_id)).filter(
        Seat.event_id == evt.event_id,
        (Seat.status == "BOOKED") | ((Seat.status == "RESERVED") & (Seat.reserved_until > now))
    ).scalar() or 0
    actual_available = max(0, evt.total_capacity - booked_or_active_reserved)

    prices = db.query(
        func.min(Seat.price_cents),
        func.max(Seat.price_cents)
    ).filter(Seat.event_id == evt.event_id).first()

    return EventDetailOut(
        event_id=evt.event_id,
        name=evt.name,
        description=evt.description,
        venue=evt.venue,
        event_timestamp=evt.event_timestamp,
        total_capacity=evt.total_capacity,
        available_capacity=actual_available,
        status=evt.status,
        min_price_cents=prices[0] if prices else None,
        max_price_cents=prices[1] if prices else None,
        created_at=evt.created_at,
        updated_at=evt.updated_at,
        seats=[]
    )


@router.get("/{event_id}/seats", response_model=List[SeatOut])
def get_event_seats(event_id: str, db: Session = Depends(get_db)):
    evt = db.query(Event).filter(Event.event_id == event_id).first()
    if not evt:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Event not found")

    seats = db.query(Seat).filter(Seat.event_id == event_id).order_by(Seat.section.asc(), Seat.row_number.asc(), Seat.seat_number.asc()).all()
    now = datetime.utcnow()

    seat_outs = []
    for s in seats:
        # Evaluate expired locks dynamically
        effective_status = s.status
        if s.status == "RESERVED":
            if not s.reserved_until or s.reserved_until <= now:
                effective_status = "AVAILABLE"

        seat_outs.append(SeatOut(
            seat_id=s.seat_id,
            event_id=s.event_id,
            section=s.section,
            row_number=s.row_number,
            seat_number=s.seat_number,
            price_cents=s.price_cents,
            status=effective_status,
            reserved_by=s.reserved_by if effective_status == "RESERVED" else None,
            reserved_until=s.reserved_until if effective_status == "RESERVED" else None,
            version=s.version
        ))
    return seat_outs


@router.post("", response_model=EventOut, status_code=status.HTTP_201_CREATED)
def create_event(
    event_in: EventCreate,
    db: Session = Depends(get_db),
    admin: User = Depends(get_current_admin)
):
    event_id = str(uuid.uuid4())
    new_event = Event(
        event_id=event_id,
        name=event_in.name,
        description=event_in.description,
        venue=event_in.venue,
        event_timestamp=event_in.event_timestamp,
        total_capacity=event_in.total_capacity,
        available_capacity=event_in.total_capacity,
        status=event_in.status,
        created_at=datetime.utcnow()
    )
    db.add(new_event)

    # Automatically generate default seats if total_capacity > 0
    # Create 2 sections: "Main Orchestra" and "Mezzanine"
    seats_to_create = []
    half = event_in.total_capacity // 2
    rem = event_in.total_capacity - half

    # Orchestra
    for idx in range(1, half + 1):
        row = f"A{((idx - 1) // 10) + 1}"
        seat_num = f"{((idx - 1) % 10) + 1:02d}"
        seats_to_create.append(Seat(
            seat_id=str(uuid.uuid4()),
            event_id=event_id,
            section="Main Orchestra",
            row_number=row,
            seat_number=seat_num,
            price_cents=10000,
            status="AVAILABLE",
            version=1
        ))

    # Mezzanine
    for idx in range(1, rem + 1):
        row = f"B{((idx - 1) // 10) + 1}"
        seat_num = f"{((idx - 1) % 10) + 1:02d}"
        seats_to_create.append(Seat(
            seat_id=str(uuid.uuid4()),
            event_id=event_id,
            section="Mezzanine",
            row_number=row,
            seat_number=seat_num,
            price_cents=6000,
            status="AVAILABLE",
            version=1
        ))

    for s in seats_to_create:
        db.add(s)

    db.commit()
    db.refresh(new_event)
    return EventOut.model_validate(new_event)


@router.patch("/{event_id}/status", response_model=EventOut)
def update_event_status(
    event_id: str,
    new_status: str = Query(..., pattern="^(UPCOMING|ACTIVE|SOLD_OUT|COMPLETED)$"),
    db: Session = Depends(get_db),
    admin: User = Depends(get_current_admin)
):
    evt = db.query(Event).filter(Event.event_id == event_id).first()
    if not evt:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Event not found")
    evt.status = new_status
    db.commit()
    db.refresh(evt)
    return EventOut.model_validate(evt)
