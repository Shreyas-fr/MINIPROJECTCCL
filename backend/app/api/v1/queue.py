from fastapi import APIRouter, Depends, status
from sqlalchemy.orm import Session

from app.core.database import get_db
from app.core.security import get_current_user
from app.models import User
from app.schemas import QueueJoinRequest, QueueStatusResponse, QueueHeartbeatRequest
from app.services.queue_service import QueueService

router = APIRouter()


@router.post("/join", response_model=QueueStatusResponse, status_code=status.HTTP_200_OK)
def join_waiting_room(
    request: QueueJoinRequest,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user)
):
    return QueueService.join_queue(db, current_user, request.event_id)


@router.get("/{event_id}/status", response_model=QueueStatusResponse)
def get_waiting_room_status(
    event_id: str,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user)
):
    return QueueService.get_queue_status(db, current_user, event_id)


@router.post("/heartbeat")
def send_queue_heartbeat(
    request: QueueHeartbeatRequest,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user)
):
    return QueueService.heartbeat(db, current_user, request.queue_id)


@router.post("/{event_id}/leave")
def leave_waiting_room(
    event_id: str,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user)
):
    return QueueService.leave_queue(db, current_user, event_id)
