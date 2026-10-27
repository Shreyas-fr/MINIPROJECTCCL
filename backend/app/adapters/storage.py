import os
from abc import ABC, abstractmethod
from typing import Optional
import boto3
from botocore.exceptions import ClientError

from app.core.config import settings


class StorageAdapter(ABC):
    @abstractmethod
    def save_ticket(self, booking_ref: str, ticket_id: str, content: str) -> str:
        """Saves SVG ticket content and returns public/accessible URI"""
        pass

    @abstractmethod
    def get_ticket(self, booking_ref: str, ticket_id: str) -> Optional[str]:
        """Retrieves SVG ticket content"""
        pass


class LocalStorageAdapter(StorageAdapter):
    def __init__(self, base_dir: Optional[str] = None):
        self.base_dir = base_dir or settings.LOCAL_STORAGE_DIR
        os.makedirs(self.base_dir, exist_ok=True)

    def _get_path(self, booking_ref: str, ticket_id: str) -> str:
        ticket_dir = os.path.join(self.base_dir, "tickets", booking_ref)
        os.makedirs(ticket_dir, exist_ok=True)
        return os.path.join(ticket_dir, f"{ticket_id}.svg")

    def save_ticket(self, booking_ref: str, ticket_id: str, content: str) -> str:
        file_path = self._get_path(booking_ref, ticket_id)
        with open(file_path, "w", encoding="utf-8") as f:
            f.write(content)
        # Return URL path accessible via FastAPI static mount
        return f"/storage/tickets/{booking_ref}/{ticket_id}.svg"

    def get_ticket(self, booking_ref: str, ticket_id: str) -> Optional[str]:
        file_path = self._get_path(booking_ref, ticket_id)
        if os.path.exists(file_path):
            with open(file_path, "r", encoding="utf-8") as f:
                return f.read()
        return None


class S3StorageAdapter(StorageAdapter):
    def __init__(self, bucket_name: Optional[str] = None, region: Optional[str] = None):
        self.bucket_name = bucket_name or settings.SURGEGATE_S3_BUCKET or "surgegate-tickets-dev"
        self.region = region or settings.AWS_REGION
        self.s3_client = boto3.client("s3", region_name=self.region)

    def save_ticket(self, booking_ref: str, ticket_id: str, content: str) -> str:
        s3_key = f"tickets/{settings.ENVIRONMENT}/{booking_ref}/{ticket_id}.svg"
        try:
            self.s3_client.put_object(
                Bucket=self.bucket_name,
                Key=s3_key,
                Body=content.encode("utf-8"),
                ContentType="image/svg+xml",
                ServerSideEncryption="AES256",
                Metadata={
                    "booking-ref": booking_ref,
                    "ticket-id": ticket_id,
                    "generated-by": "surgegate-backend"
                }
            )
            return f"s3://{self.bucket_name}/{s3_key}"
        except ClientError as e:
            raise e

    def get_ticket(self, booking_ref: str, ticket_id: str) -> Optional[str]:
        s3_key = f"tickets/{settings.ENVIRONMENT}/{booking_ref}/{ticket_id}.svg"
        try:
            resp = self.s3_client.get_object(Bucket=self.bucket_name, Key=s3_key)
            return resp["Body"].read().decode("utf-8")
        except ClientError:
            return None


def get_storage_adapter() -> StorageAdapter:
    if settings.USE_AWS_MOCK or not settings.SURGEGATE_S3_BUCKET:
        return LocalStorageAdapter()
    return S3StorageAdapter()
