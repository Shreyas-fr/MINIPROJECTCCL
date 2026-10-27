from datetime import datetime, timedelta, timezone
from typing import Optional, Dict, Any, Tuple
import secrets
import uuid
from sqlalchemy.orm import Session
from sqlalchemy import func, and_
from fastapi import HTTPException, status

from app.core.config import settings
from app.models import QueueEntry, Event, User
from app.schemas import QueueStatusResponse


class QueueService:
    @staticmethod
    def _now() -> datetime:
        return datetime.utcnow()

    @classmethod
    def join_queue(cls, db: Session, user: User, event_id: str) -> QueueStatusResponse:
        now = cls._now()
        event = db.query(Event).filter(Event.event_id == event_id).first()
        if not event:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Event not found")
        if event.status != "ACTIVE":
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail=f"Waiting room is only active for ACTIVE flash-sale events (current status: {event.status})"
            )

        heartbeat_cutoff = now - timedelta(seconds=settings.QUEUE_HEARTBEAT_TIMEOUT_SECONDS)

        # Check existing queue entry for this user and event
        entry = db.query(QueueEntry).filter(
            QueueEntry.event_id == event_id,
            QueueEntry.user_id == user.user_id
        ).order_by(QueueEntry.joined_at.desc()).first()

        if entry:
            # If already admitted and not expired, refresh heartbeat and return
            if entry.status == "ADMITTED":
                if entry.admission_expires_at and entry.admission_expires_at > now:
                    entry.last_heartbeat = now
                    db.commit()
                    return cls.get_queue_status(db, user, event_id)
                else:
                    entry.status = "EXPIRED"
                    entry.admission_token = None
                    db.commit()

            # If waiting and heartbeat is fresh, refresh heartbeat and return
            elif entry.status == "WAITING":
                if entry.last_heartbeat >= heartbeat_cutoff:
                    entry.last_heartbeat = now
                    db.commit()
                    return cls.get_queue_status(db, user, event_id)
                else:
                    entry.status = "EXPIRED"
                    db.commit()

        # Prevent duplicate active entries: mark any other active entries as EXPIRED
        db.query(QueueEntry).filter(
            QueueEntry.event_id == event_id,
            QueueEntry.user_id == user.user_id,
            QueueEntry.status.in_(["WAITING", "ADMITTED"])
        ).update({"status": "EXPIRED", "admission_token": None}, synchronize_session=False)
        db.commit()

        # Acquire next queue number atomically for this event (FIFO placed at end of line)
        max_num = db.query(func.coalesce(func.max(QueueEntry.queue_number), 0)).filter(
            QueueEntry.event_id == event_id
        ).scalar() or 0
        next_queue_number = max_num + 1

        new_entry = QueueEntry(
            queue_id=str(uuid.uuid4()),
            event_id=event_id,
            user_id=user.user_id,
            queue_number=next_queue_number,
            status="WAITING",
            joined_at=now,
            last_heartbeat=now,
        )
        db.add(new_entry)
        db.commit()
        db.refresh(new_entry)

        return cls.get_queue_status(db, user, event_id)

    @classmethod
    def get_queue_status(cls, db: Session, user: User, event_id: str) -> QueueStatusResponse:
        now = cls._now()
        heartbeat_cutoff = now - timedelta(seconds=settings.QUEUE_HEARTBEAT_TIMEOUT_SECONDS)

        entry = db.query(QueueEntry).filter(
            QueueEntry.event_id == event_id,
            QueueEntry.user_id == user.user_id
        ).order_by(QueueEntry.joined_at.desc()).first()

        if not entry:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND,
                detail="User has not joined the waiting room for this event"
            )

        # Check if admitted token has expired
        if entry.status == "ADMITTED" and entry.admission_expires_at and entry.admission_expires_at <= now:
            entry.status = "EXPIRED"
            entry.admission_token = None
            db.commit()

        # Update heartbeat
        entry.last_heartbeat = now
        db.commit()

        if entry.status == "ADMITTED":
            return QueueStatusResponse(
                queue_id=entry.queue_id,
                event_id=entry.event_id,
                status="ADMITTED",
                queue_number=entry.queue_number,
                position_ahead=0,
                estimated_wait_seconds=0,
                admission_token=entry.admission_token,
                admission_expires_at=entry.admission_expires_at,
                total_waiting=0
            )

        if entry.status != "WAITING":
            return QueueStatusResponse(
                queue_id=entry.queue_id,
                event_id=entry.event_id,
                status=entry.status,
                queue_number=entry.queue_number,
                position_ahead=-1,
                estimated_wait_seconds=0,
                admission_token=None,
                admission_expires_at=None,
                total_waiting=0
            )

        # Count active waiting users ahead
        position_ahead = db.query(func.count(QueueEntry.queue_id)).filter(
            QueueEntry.event_id == event_id,
            QueueEntry.status == "WAITING",
            QueueEntry.queue_number < entry.queue_number,
            QueueEntry.last_heartbeat >= heartbeat_cutoff
        ).scalar() or 0

        total_waiting = db.query(func.count(QueueEntry.queue_id)).filter(
            QueueEntry.event_id == event_id,
            QueueEntry.status == "WAITING",
            QueueEntry.last_heartbeat >= heartbeat_cutoff
        ).scalar() or 0

        # Estimate wait time based on batch size and interval
        batches_ahead = (position_ahead // settings.QUEUE_ADMISSION_BATCH_SIZE)
        estimated_wait_seconds = max(0, batches_ahead * settings.QUEUE_ADMISSION_INTERVAL_SECONDS)

        return QueueStatusResponse(
            queue_id=entry.queue_id,
            event_id=entry.event_id,
            status="WAITING",
            queue_number=entry.queue_number,
            position_ahead=position_ahead,
            estimated_wait_seconds=estimated_wait_seconds,
            admission_token=None,
            admission_expires_at=None,
            total_waiting=total_waiting
        )

    @classmethod
    def heartbeat(cls, db: Session, user: User, queue_id: str) -> Dict[str, Any]:
        now = cls._now()
        entry = db.query(QueueEntry).filter(
            QueueEntry.queue_id == queue_id,
            QueueEntry.user_id == user.user_id
        ).first()
        if not entry:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Queue entry not found")

        entry.last_heartbeat = now
        db.commit()
        return {"status": "OK", "timestamp": now.isoformat()}

    @classmethod
    def leave_queue(cls, db: Session, user: User, event_id: str) -> Dict[str, Any]:
        """
        Explicitly cancels active queue entries and invalidates any admission token.
        Also releases any held seats by this user for this event.
        """
        db.query(QueueEntry).filter(
            QueueEntry.event_id == event_id,
            QueueEntry.user_id == user.user_id,
            QueueEntry.status.in_(["WAITING", "ADMITTED"])
        ).update({
            "status": "LEFT",
            "admission_token": None,
            "admission_expires_at": None
        }, synchronize_session=False)

        # Release any active seat holds by this user for this event
        from app.models import Seat
        db.query(Seat).filter(
            Seat.event_id == event_id,
            Seat.reserved_by == user.user_id,
            Seat.status == "RESERVED"
        ).update({
            "status": "AVAILABLE",
            "reserved_by": None,
            "reserved_until": None,
            "version": Seat.version + 1
        }, synchronize_session=False)

        db.commit()
        return {"status": "SUCCESS", "message": "Left waiting room and invalidated active passes"}

    @classmethod
    def admit_next_batch(cls, db: Session, event_id: str, batch_size: Optional[int] = None) -> int:
        """
        Admit next N active waiting users in FIFO order with cryptographic admission token
        """
        now = cls._now()
        size = batch_size or settings.QUEUE_ADMISSION_BATCH_SIZE
        heartbeat_cutoff = now - timedelta(seconds=settings.QUEUE_HEARTBEAT_TIMEOUT_SECONDS)

        # Production queue control: check event exists, is ACTIVE, and has available capacity
        event = db.query(Event).filter(Event.event_id == event_id).first()
        if not event or event.status != "ACTIVE" or event.available_capacity <= 0:
            return 0

        # Cap batch size by available event capacity
        size = min(size, event.available_capacity)
        if size <= 0:
            return 0

        # 1. Clean up expired admissions
        db.query(QueueEntry).filter(
            QueueEntry.event_id == event_id,
            QueueEntry.status == "ADMITTED",
            QueueEntry.admission_expires_at <= now
        ).update({"status": "EXPIRED", "admission_token": None}, synchronize_session=False)

        # 2. Select next waiting users with active heartbeat
        query = db.query(QueueEntry).filter(
            QueueEntry.event_id == event_id,
            QueueEntry.status == "WAITING",
            QueueEntry.last_heartbeat >= heartbeat_cutoff
        ).order_by(QueueEntry.queue_number.asc()).limit(size)

        if db.bind and hasattr(db.bind, "dialect") and db.bind.dialect.name == "mysql":
            query = query.with_for_update(skip_locked=True)

        candidates = query.all()

        admitted_count = 0
        ttl_minutes = settings.QUEUE_TOKEN_TTL_MINUTES

        for cand in candidates:
            cand.status = "ADMITTED"
            cand.admission_token = secrets.token_hex(24)
            cand.admitted_at = now
            cand.admission_expires_at = now + timedelta(minutes=ttl_minutes)
            admitted_count += 1

        db.commit()
        return admitted_count

    @classmethod
    def validate_admission_token(cls, db: Session, user: User, event_id: str, token: Optional[str]) -> QueueEntry:
        if not token:
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail="Queue admission token required. Please enter through the virtual waiting room."
            )

        now = cls._now()
        entry = db.query(QueueEntry).filter(
            QueueEntry.event_id == event_id,
            QueueEntry.user_id == user.user_id,
            QueueEntry.admission_token == token,
            QueueEntry.status == "ADMITTED"
        ).first()

        if not entry:
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail="Queue admission token required. Please enter through the virtual waiting room."
            )

        if entry.admission_expires_at and entry.admission_expires_at <= now:
            entry.status = "EXPIRED"
            entry.admission_token = None
            db.commit()
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail="Your queue admission pass has expired. Please rejoin the waiting room."
            )

        return entry
