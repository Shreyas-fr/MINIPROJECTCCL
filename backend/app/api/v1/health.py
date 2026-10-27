from fastapi import APIRouter, Depends
from sqlalchemy.orm import Session
from sqlalchemy import text
from app.core.database import get_db
from app.core.config import settings
from app.schemas import HealthCheckResponse

router = APIRouter()


@router.get("/health", response_model=HealthCheckResponse)
def check_health(db: Session = Depends(get_db)):
    db_connected = False
    try:
        db.execute(text("SELECT 1"))
        db_connected = True
    except Exception:
        db_connected = False

    return HealthCheckResponse(
        status="HEALTHY" if db_connected else "DEGRADED",
        service="SurgeGate Backend",
        environment=settings.ENVIRONMENT,
        database_connected=db_connected,
        message="SurgeGate traffic management node is operational."
    )
