import asyncio
import logging
from typing import Optional
from sqlalchemy.orm import Session

from app.core.config import settings
from app.core.database import SessionLocal
from app.models import Event, QueueEntry
from app.services.queue_service import QueueService

logger = logging.getLogger("surgegate.queue_scheduler")


class QueueAdmissionScheduler:
    _task: Optional[asyncio.Task] = None
    _is_running: bool = False

    @classmethod
    def run_admission_cycle(cls, db: Session) -> int:
        """
        Executes one admission cycle across all ACTIVE events with available capacity.
        Preserves strict FIFO ordering and production queue controls.
        Returns the total number of admitted users.
        """
        try:
            active_events = db.query(Event).filter(
                Event.status == "ACTIVE",
                Event.available_capacity > 0
            ).all()

            total_admitted = 0
            for event in active_events:
                # Check if there are active waiting users before admitting
                waiting_count = db.query(QueueEntry).filter(
                    QueueEntry.event_id == event.event_id,
                    QueueEntry.status == "WAITING"
                ).count()

                if waiting_count > 0:
                    admitted = QueueService.admit_next_batch(
                        db=db,
                        event_id=event.event_id,
                        batch_size=settings.QUEUE_ADMISSION_BATCH_SIZE
                    )
                    if admitted > 0:
                        logger.info(
                            f"[QueueAdmissionScheduler] Admitted {admitted} users for event {event.name} ({event.event_id})"
                        )
                        total_admitted += admitted

            return total_admitted
        except Exception as e:
            logger.error(f"[QueueAdmissionScheduler] Error in admission cycle: {e}", exc_info=True)
            return 0

    @classmethod
    def _cycle_wrapper(cls) -> int:
        db = SessionLocal()
        try:
            return cls.run_admission_cycle(db)
        finally:
            db.close()

    @classmethod
    async def _scheduler_loop(cls, interval_seconds: int):
        logger.info(f"[QueueAdmissionScheduler] Started background worker (interval: {interval_seconds}s)")
        cls._is_running = True
        try:
            while cls._is_running:
                await asyncio.to_thread(cls._cycle_wrapper)
                await asyncio.sleep(interval_seconds)
        except asyncio.CancelledError:
            logger.info("[QueueAdmissionScheduler] Worker loop cancelled.")
        except Exception as e:
            logger.error(f"[QueueAdmissionScheduler] Worker encountered an error: {e}", exc_info=True)
        finally:
            cls._is_running = False

    @classmethod
    def start(cls, interval_seconds: Optional[int] = None) -> None:
        if cls._task and not cls._task.done():
            logger.info("[QueueAdmissionScheduler] Scheduler already running.")
            return

        interval = interval_seconds or settings.QUEUE_ADMISSION_INTERVAL_SECONDS
        cls._task = asyncio.create_task(cls._scheduler_loop(interval))

    @classmethod
    async def stop(cls) -> None:
        cls._is_running = False
        if cls._task and not cls._task.done():
            cls._task.cancel()
            try:
                await cls._task
            except asyncio.CancelledError:
                pass
            cls._task = None
        logger.info("[QueueAdmissionScheduler] Scheduler stopped.")

    @classmethod
    def is_running(cls) -> bool:
        return cls._task is not None and not cls._task.done() and cls._is_running
