import os
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles

from app.core.config import settings
from app.api.v1.health import router as health_router
from app.api.v1.auth import router as auth_router
from app.api.v1.events import router as events_router
from app.api.v1.queue import router as queue_router
from app.api.v1.admin import router as admin_router
from app.api.v1.seats import router as seats_router
from app.api.v1.bookings import router as bookings_router

app = FastAPI(
    title="SurgeGate API",
    description="High-concurrency flash-sale ticket booking and traffic management system",
    version="1.0.0",
    docs_url="/docs",
    redoc_url="/redoc",
)

# CORS
app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.CORS_ORIGINS,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Root-level health check endpoints for ALB target group compliance
@app.get("/health", tags=["Health"])
@app.get("/", tags=["Health"])
def root_health():
    return {
        "status": "HEALTHY",
        "service": "SurgeGate Edge Node",
        "environment": settings.ENVIRONMENT,
        "sqs_queue": settings.SURGEGATE_SQS_URL or "surgegate-ticket-queue (mock/local)",
        "db_configured": bool(settings.get_database_url()),
        "message": "SurgeGate traffic management node is operational."
    }

# Register V1 API routers
app.include_router(health_router, prefix=settings.API_V1_PREFIX, tags=["Health"])
app.include_router(auth_router, prefix=f"{settings.API_V1_PREFIX}/auth", tags=["Auth"])
app.include_router(events_router, prefix=f"{settings.API_V1_PREFIX}/events", tags=["Events"])
app.include_router(queue_router, prefix=f"{settings.API_V1_PREFIX}/queue", tags=["Queue"])
app.include_router(admin_router, prefix=f"{settings.API_V1_PREFIX}/admin", tags=["Admin"])
app.include_router(seats_router, prefix=f"{settings.API_V1_PREFIX}/seats", tags=["Seats"])
app.include_router(bookings_router, prefix=f"{settings.API_V1_PREFIX}/bookings", tags=["Bookings"])

# Ensure local storage directory exists for mock/local ticket assets
os.makedirs(settings.LOCAL_STORAGE_DIR, exist_ok=True)
app.mount("/storage", StaticFiles(directory=settings.LOCAL_STORAGE_DIR), name="storage")


if __name__ == "__main__":
    import uvicorn
    uvicorn.run("app.main:app", host="0.0.0.0", port=settings.APP_PORT, reload=True)
