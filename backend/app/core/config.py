import os
from typing import List, Optional
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    PROJECT_NAME: str = "SurgeGate"
    ENVIRONMENT: str = "dev"
    API_V1_PREFIX: str = "/api/v1"
    APP_PORT: int = 8000

    # Database
    # Default to local MySQL if running with docker-compose, or fallback to local SQLite for fast isolated tests
    DB_HOST: str = "localhost"
    DB_PORT: int = 3306
    DB_NAME: str = "surgegate"
    DB_USER: str = "surgegate_admin"
    DB_PASSWORD: str = "surgegate_secret"
    DATABASE_URL: Optional[str] = None

    # JWT Authentication
    JWT_SECRET_KEY: str = "surgegate-super-secret-jwt-key-2026-ccl-mini-project"
    JWT_ALGORITHM: str = "HS256"
    ACCESS_TOKEN_EXPIRE_MINUTES: int = 60 * 24  # 24 hours

    # Virtual Waiting Room Settings
    QUEUE_ADMISSION_BATCH_SIZE: int = 5
    QUEUE_ADMISSION_INTERVAL_SECONDS: int = 5
    QUEUE_TOKEN_TTL_MINUTES: int = 15
    QUEUE_HEARTBEAT_TIMEOUT_SECONDS: int = 45

    # Seat Hold Settings
    SEAT_HOLD_DURATION_SECONDS: int = 300  # 5 minutes

    # AWS Integration & Local Mock Adapter Settings
    USE_AWS_MOCK: bool = True
    AWS_REGION: str = "ap-south-1"
    SURGEGATE_SQS_URL: Optional[str] = None
    SURGEGATE_S3_BUCKET: Optional[str] = None
    LOCAL_STORAGE_DIR: str = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))), "storage")

    # CORS
    CORS_ORIGINS: List[str] = [
        "http://localhost:5173",
        "http://127.0.0.1:5173",
        "http://localhost:3000",
        "http://127.0.0.1:3000",
        "*"
    ]

    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        extra="ignore"
    )

    def get_database_url(self) -> str:
        if self.DATABASE_URL:
            return self.DATABASE_URL
        return f"mysql+pymysql://{self.DB_USER}:{self.DB_PASSWORD}@{self.DB_HOST}:{self.DB_PORT}/{self.DB_NAME}?charset=utf8mb4"


settings = Settings()
