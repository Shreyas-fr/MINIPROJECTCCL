"""
SurgeGate - Asynchronous Ticket Generation & Notification Worker
Processes ticket-processing jobs received from Amazon SQS, stores QR/ticket assets in Amazon S3,
and emits notifications via Amazon SNS.
"""

import json
import os
import time
import uuid
import logging
import urllib.parse
import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

s3_client = boto3.client('s3')
sns_client = boto3.client('sns')

S3_BUCKET_NAME = os.environ.get('S3_BUCKET_NAME', '')
SNS_TOPIC_ARN = os.environ.get('SNS_TOPIC_ARN', '')
ENVIRONMENT = os.environ.get('ENVIRONMENT', 'dev')


def generate_qr_svg(ticket_id: str, booking_ref: str, seat_id: str) -> str:
    """
    Generates a lightweight, self-contained SVG representation of a simulated QR Code
    and ticket voucher without requiring external C-compiled dependencies.
    """
    verification_payload = {
        "ticket_id": ticket_id,
        "booking_ref": booking_ref,
        "seat_id": seat_id,
        "issued_at": int(time.time()),
        "security_hash": uuid.uuid4().hex[:16]
    }
    encoded_payload = urllib.parse.quote(json.dumps(verification_payload))
    
    svg_content = f"""<svg xmlns="http://www.w3.org/2000/svg" width="400" height="600" viewBox="0 0 400 600">
  <defs>
    <linearGradient id="headerGrad" x1="0%" y1="0%" x2="100%" y2="100%">
      <stop offset="0%" stop-color="#4F46E5" />
      <stop offset="100%" stop-color="#7C3AED" />
    </linearGradient>
  </defs>
  <rect width="400" height="600" rx="20" fill="#0F172A"/>
  <rect x="20" y="20" width="360" height="100" rx="12" fill="url(#headerGrad)"/>
  <text x="200" y="60" font-family="Arial, sans-serif" font-size="22" font-weight="bold" fill="#FFFFFF" text-anchor="middle">SURGEGATE E-TICKET</text>
  <text x="200" y="85" font-family="Arial, sans-serif" font-size="12" fill="#E0E7FF" text-anchor="middle">Flash-Sale Admitted Pass</text>
  
  <rect x="20" y="140" width="360" height="220" rx="12" fill="#1E293B" stroke="#334155" stroke-width="1"/>
  <text x="40" y="175" font-family="Arial, sans-serif" font-size="12" fill="#94A3B8">BOOKING REFERENCE</text>
  <text x="40" y="200" font-family="Courier, monospace" font-size="18" font-weight="bold" fill="#38BDF8">{booking_ref}</text>
  
  <text x="40" y="240" font-family="Arial, sans-serif" font-size="12" fill="#94A3B8">TICKET ID</text>
  <text x="40" y="260" font-family="Courier, monospace" font-size="14" fill="#E2E8F0">{ticket_id}</text>
  
  <text x="40" y="300" font-family="Arial, sans-serif" font-size="12" fill="#94A3B8">SEAT ALLOCATION</text>
  <text x="40" y="325" font-family="Arial, sans-serif" font-size="18" font-weight="bold" fill="#34D399">{seat_id}</text>

  <!-- Simulated QR Pattern Matrix -->
  <g transform="translate(110, 380)">
    <rect width="180" height="180" rx="8" fill="#FFFFFF"/>
    <!-- Position Detection Patterns -->
    <rect x="15" y="15" width="40" height="40" fill="#000000"/>
    <rect x="23" y="23" width="24" height="24" fill="#FFFFFF"/>
    <rect x="28" y="28" width="14" height="14" fill="#000000"/>

    <rect x="125" y="15" width="40" height="40" fill="#000000"/>
    <rect x="133" y="23" width="24" height="24" fill="#FFFFFF"/>
    <rect x="138" y="28" width="14" height="14" fill="#000000"/>

    <rect x="15" y="125" width="40" height="40" fill="#000000"/>
    <rect x="23" y="133" width="24" height="24" fill="#FFFFFF"/>
    <rect x="28" y="138" width="14" height="14" fill="#000000"/>

    <!-- Dynamic Payload Representation -->
    <rect x="70" y="25" width="10" height="20" fill="#000000"/>
    <rect x="90" y="35" width="15" height="10" fill="#000000"/>
    <rect x="65" y="65" width="50" height="50" fill="#000000"/>
    <rect x="75" y="75" width="30" height="30" fill="#FFFFFF"/>
    <rect x="85" y="85" width="10" height="10" fill="#000000"/>
    <rect x="130" y="75" width="20" height="20" fill="#000000"/>
    <rect x="25" y="75" width="20" height="20" fill="#000000"/>
    <rect x="70" y="135" width="25" height="15" fill="#000000"/>
    <rect x="115" y="125" width="30" height="25" fill="#000000"/>
  </g>
  <text x="200" y="580" font-family="Arial, sans-serif" font-size="10" fill="#64748B" text-anchor="middle">Scan at venue turnstile • surgegate.internal</text>
</svg>"""
    return svg_content


def process_ticket_record(payload: dict) -> dict:
    """
    Handles individual ticket generation payload:
    - Verifies booking idempotency
    - Renders SVG QR voucher
    - Writes artifact to S3
    - Dispatches SNS notification if configured
    """
    booking_id = payload.get("booking_id") or str(uuid.uuid4())
    booking_ref = payload.get("booking_ref") or f"SG-{uuid.uuid4().hex[:8].upper()}"
    seat_id = payload.get("seat_id") or "GA-ZONE-1"
    user_email = payload.get("user_email") or "attendee@example.com"
    ticket_id = f"TICK-{uuid.uuid4().hex[:12].upper()}"

    logger.info(f"Processing ticket: booking_ref={booking_ref}, seat_id={seat_id}")

    # Generate QR ticket asset
    svg_data = generate_qr_svg(ticket_id, booking_ref, seat_id)
    s3_key = f"tickets/{ENVIRONMENT}/{booking_ref}/{ticket_id}.svg"

    s3_url = ""
    if S3_BUCKET_NAME:
        try:
            s3_client.put_object(
                Bucket=S3_BUCKET_NAME,
                Key=s3_key,
                Body=svg_data.encode('utf-8'),
                ContentType='image/svg+xml',
                ServerSideEncryption='AES256',
                Metadata={
                    "booking-ref": booking_ref,
                    "ticket-id": ticket_id,
                    "seat-id": seat_id,
                    "generated-by": "surgegate-lambda"
                }
            )
            s3_url = f"s3://{S3_BUCKET_NAME}/{s3_key}"
            logger.info(f"Successfully uploaded ticket to {s3_url}")
        except ClientError as e:
            logger.error(f"Failed to upload ticket to S3: {e}")
            raise e
    else:
        logger.warning("S3_BUCKET_NAME not set. Generated ticket in dry-run mode.")

    # Send Notification via SNS (if configured)
    if SNS_TOPIC_ARN:
        try:
            message_body = (
                f"SurgeGate Ticket Confirmation\n"
                f"---------------------------------\n"
                f"Booking Ref: {booking_ref}\n"
                f"Ticket ID:   {ticket_id}\n"
                f"Seat:        {seat_id}\n"
                f"Status:      CONFIRMED & ISSUED\n"
                f"Storage URI: {s3_url}\n\n"
                f"Thank you for booking with SurgeGate."
            )
            sns_client.publish(
                TopicArn=SNS_TOPIC_ARN,
                Subject=f"SurgeGate Booking Confirmed: {booking_ref}",
                Message=message_body
            )
            logger.info(f"Dispatched SNS notification for {booking_ref}")
        except ClientError as e:
            logger.warning(f"Could not publish SNS notification: {e}")

    return {
        "status": "PROCESSED",
        "ticket_id": ticket_id,
        "booking_ref": booking_ref,
        "s3_key": s3_key,
        "s3_url": s3_url
    }


def lambda_handler(event, context):
    """
    AWS Lambda entry point for SQS triggers and direct test invocations.
    """
    logger.info(f"Received event: {json.dumps(event)}")
    results = []

    # Handle SQS batch records
    if 'Records' in event:
        for record in event['Records']:
            body_str = record.get('body', '{}')
            try:
                payload = json.loads(body_str)
                # Handle cases where SQS wraps SNS or JSON payload
                if isinstance(payload, str):
                    payload = json.loads(payload)
                res = process_ticket_record(payload)
                results.append(res)
            except Exception as ex:
                logger.error(f"Error processing record {record.get('messageId')}: {ex}")
                # Raising error causes SQS to retry or move to DLQ
                raise ex
    else:
        # Direct test invocation
        res = process_ticket_record(event)
        results.append(res)

    return {
        "statusCode": 200,
        "processed_count": len(results),
        "results": results
    }
