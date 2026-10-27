from typing import Optional
from fastapi import APIRouter, Depends, Query, status
from sqlalchemy.orm import Session

from app.core.database import get_db
from app.core.security import get_current_user
from app.models import User
from app.schemas import SeatReserveRequest, SeatReserveResponse
from app.services.booking_service import BookingService

router = APIRouter()


@router.post("/hold", response_model=SeatReserveResponse)
def hold_seat(
    request: SeatReserveRequest,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user)
):
    return BookingService.hold_seat(
        db=db,
        user=current_user,
        event_id=request.event_id,
        seat_id=request.seat_id,
        seat_ids=request.seat_ids,
        admission_token=request.admission_token
    )


@router.post("/release")
def release_seat(
    event_id: str = Query(...),
    seat_id: Optional[str] = Query(None),
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user)
):
    return BookingService.release_seat(
        db=db,
        user=current_user,
        event_id=event_id,
        seat_id=seat_id
    )
