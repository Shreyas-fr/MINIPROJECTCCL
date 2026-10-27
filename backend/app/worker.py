import asyncio
import logging
import signal
import sys

from app.core.config import settings
from app.services.queue_scheduler import QueueAdmissionScheduler

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s"
)
logger = logging.getLogger("surgegate.worker")


async def main():
    logger.info("Starting SurgeGate Queue Admission Worker...")
    QueueAdmissionScheduler.start(settings.QUEUE_ADMISSION_INTERVAL_SECONDS)

    stop_event = asyncio.Event()

    def handle_exit():
        logger.info("Received termination signal, shutting down worker...")
        stop_event.set()

    loop = asyncio.get_running_loop()
    if sys.platform != "win32":
        for sig in (signal.SIGINT, signal.SIGTERM):
            loop.add_signal_handler(sig, handle_exit)

    try:
        if sys.platform == "win32":
            while not stop_event.is_set():
                await asyncio.sleep(1)
        else:
            await stop_event.wait()
    except (KeyboardInterrupt, asyncio.CancelledError):
        logger.info("Worker interrupted by user.")
    finally:
        await QueueAdmissionScheduler.stop()
        logger.info("SurgeGate Queue Admission Worker cleanly terminated.")


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
