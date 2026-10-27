from fastapi import APIRouter, Depends, HTTPException, Response, status
from pydantic import BaseModel
from sqlalchemy.orm import Session

from app.core.database import get_db
from app.core.security import get_current_user, get_current_admin
from app.models import User, Booking, Seat
from app.schemas import TicketVerificationResponse
from app.services.ticket_processor import TicketProcessorService, generate_qr_svg
from app.adapters.storage import get_storage_adapter

router = APIRouter()


class TicketVerifyRequest(BaseModel):
    ticket_id_or_ref: str


@router.get("/{booking_ref}")
def get_ticket_svg(
    booking_ref: str,
    db: Session = Depends(get_db)
):
    booking = db.query(Booking).filter(Booking.booking_ref == booking_ref).first()
    if not booking:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Booking not found")

    storage = get_storage_adapter()
    svg = storage.get_ticket(booking_ref, booking.ticket_id or "TICK-DEFAULT")
    if not svg:
        # Fallback generate if not yet stored
        seat = db.query(Seat).filter(Seat.seat_id == booking.seat_id).first()
        seat_desc = f"{seat.section}-{seat.row_number}-{seat.seat_number}" if seat else "GA-1"
        svg = generate_qr_svg(booking.ticket_id or "TICK-DEFAULT", booking.booking_ref, seat_desc)
        storage.save_ticket(booking_ref, booking.ticket_id or "TICK-DEFAULT", svg)

    return Response(content=svg, media_type="image/svg+xml")


@router.post("/verify", response_model=TicketVerificationResponse)
def verify_ticket(
    request: TicketVerifyRequest,
    db: Session = Depends(get_db)
):
    return TicketProcessorService.verify_ticket(db, request.ticket_id_or_ref)


@router.post("/{booking_ref}/regenerate")
def regenerate_ticket(
    booking_ref: str,
    db: Session = Depends(get_db),
    admin: User = Depends(get_current_admin)
):
    booking = db.query(Booking).filter(Booking.booking_ref == booking_ref).first()
    if not booking:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Booking not found")

    seat = db.query(Seat).filter(Seat.seat_id == booking.seat_id).first()
    seat_desc = f"{seat.section}-{seat.row_number}-{seat.seat_number}" if seat else "GA-1"
    res = TicketProcessorService.process_ticket(db, {
        "booking_id": booking.booking_id,
        "booking_ref": booking.booking_ref,
        "seat_id": seat_desc,
        "user_email": "attendee@example.com"
    })
    return {"status": "SUCCESS", "result": res}
