# SurgeGate — AWS Integration Contract & Deployment Specification

This document details the exact integration contract between the SurgeGate application tiers (FastAPI backend & React frontend) and the AWS Cloud Infrastructure provisioned by `deploy.sh`.

---

## 1. System Integration Architecture

```text
[ React Frontend ] 
       │ (HTTP / JSON / Vite Proxy)
       ▼
[ Application Load Balancer / Edge ]
       │ (Port 80 -> Port 8000 / 3000)
       ▼
[ FastAPI Backend Instances (EC2 / ASG) ]
  ├── 1. Virtual Waiting Room (Durable FIFO Queue) ──► [ Amazon RDS MySQL 8.0 ]
  ├── 2. Atomic Row-Level Locks (SELECT FOR UPDATE) ──► [ Amazon RDS MySQL 8.0 ]
  ├── 3. Async Ticket Generation Job ─────────────────► [ Amazon SQS Ticket Queue ]
                                                                   │
                                                                   ▼
                                                     [ AWS Lambda Worker ]
                                                                   │
                                                                   ├──► [ Amazon S3 Bucket (SVG Tickets) ]
                                                                   └──► [ Amazon SNS (Optional SMS/Email) ]
```

---

## 2. Required Environment Variables

When `deploy.sh` executes, it exports `deployment-outputs.env`. The backend application ingests the following variables:

| Variable | Description | Example Value |
|---|---|---|
| `SURGEGATE_DB_HOST` | Hostname of the private RDS MySQL instance | `surgegate-db.c123456789.ap-south-1.rds.amazonaws.com` |
| `SURGEGATE_DB_PORT` | MySQL database listening port | `3306` |
| `SURGEGATE_DB_NAME` | Database schema name | `surgegate` |
| `SURGEGATE_DB_USER` | Master/application user | `surgegate_admin` |
| `SURGEGATE_DB_PASS` | Password for database user | Secure generated string |
| `SURGEGATE_SQS_URL` | Amazon SQS FIFO/Standard queue endpoint | `https://sqs.ap-south-1.amazonaws.com/123456789012/surgegate-ticket-queue` |
| `SURGEGATE_S3_BUCKET`| S3 bucket name for ticket assets | `surgegate-tickets-dev-123456789012` |
| `AWS_REGION` | Active AWS deployment region | `ap-south-1` |
| `ENVIRONMENT` | Target environment label | `dev` / `staging` / `prod` |
| `USE_AWS_MOCK` | Toggle between local adapters and live AWS SDK | `false` in cloud, `true` in local testing |

---

## 3. SQS Message Contract (Producer -> Consumer)

### Producer (FastAPI Backend)
When payment simulation succeeds in `POST /api/v1/bookings/checkout`, the backend dispatches a message to `SURGEGATE_SQS_URL`.

#### Payload Schema (JSON)
```json
{
  "booking_id": "9b1deb4d-3b7d-4bad-9bdd-2b0d7b3dcb6d",
  "booking_ref": "SG-A1B2C3D4",
  "seat_id": "VIP Lounge-VIP-A-01",
  "user_email": "student@example.edu"
}
```

#### Message Attributes
- `EventType`: `TicketGeneration` (String)
- `BookingRef`: `SG-A1B2C3D4` (String)

---

## 4. Lambda Ticket Processor Contract ([`lambda/ticket_processor.py`](file:///Users/shreyasdivekar/Documents/ccl%20mini%20project%20/lambda/ticket_processor.py))

### Trigger
- **Event Source:** Amazon SQS trigger configured on `surgegate-ticket-queue`.
- **Batch Size:** 1 – 10 messages per batch.

### Processing Logic
1. Parses SQS body: extracts `booking_ref`, `seat_id`, and `user_email`.
2. Generates self-contained SVG voucher with embedded dynamic QR matrix.
3. Uploads SVG to Amazon S3:
   - **Key Pattern:** `tickets/{ENVIRONMENT}/{booking_ref}/{ticket_id}.svg`
   - **Content-Type:** `image/svg+xml`
   - **Encryption:** `AES256` (SSE-S3)
   - **Metadata:**
     - `booking-ref`: `SG-A1B2C3D4`
     - `ticket-id`: `TICK-123456789ABC`
     - `generated-by`: `surgegate-lambda`
4. Dispatches SNS notification if `SNS_TOPIC_ARN` is configured.
5. In case of transient failure, raises exception so SQS triggers retry or dead-letters to `surgegate-ticket-dlq` after 3 attempts (`SQS_MAX_RECEIVE_COUNT=3`).

---

## 5. Amazon S3 Object Structure

```text
s3://surgegate-tickets-dev-<account_id>/
└── tickets/
    └── dev/
        ├── SG-A1B2C3D4/
        │   └── TICK-9876543210AB.svg
        └── SG-E5F6G7H8/
            └── TICK-4567890123CD.svg
```

---

## 6. IAM Permissions Required

### Application EC2 Instance Profile (`SurgeGateEC2Profile`)
The backend instances running on EC2 require an attached IAM role with:
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "sqs:SendMessage",
        "sqs:GetQueueUrl",
        "sqs:GetQueueAttributes"
      ],
      "Resource": "arn:aws:sqs:ap-south-1:*:surgegate-ticket-*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "s3:PutObject",
        "s3:GetObject"
      ],
      "Resource": "arn:aws:s3:::surgegate-tickets-*/*"
    }
  ]
}
```

### Lambda Execution Role (`SurgeGateLambdaRole`)
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "sqs:ReceiveMessage",
        "sqs:DeleteMessage",
        "sqs:GetQueueAttributes"
      ],
      "Resource": "arn:aws:sqs:ap-south-1:*:surgegate-ticket-queue"
    },
    {
      "Effect": "Allow",
      "Action": [
        "s3:PutObject"
      ],
      "Resource": "arn:aws:s3:::surgegate-tickets-*/*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "sns:Publish"
      ],
      "Resource": "arn:aws:sns:ap-south-1:*:surgegate-booking-notifications"
    },
    {
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ],
      "Resource": "arn:aws:logs:*:*:*"
    }
  ]
}
```

---

## 7. Deployment Boundaries & Team Division of Responsibility

| Task / Deliverable | Owner | Status |
|---|---|---|
| Complete FastAPI Backend & Models | **App Team** | Complete & Tested |
| React + TypeScript + Tailwind Frontend | **App Team** | Complete & Tested |
| Local Docker Compose & Virtual Waiting Room | **App Team** | Complete & Tested |
| Concurrency Protection & Idempotent Checkout | **App Team** | Complete & Tested |
| Automated Pytest & Headless Load Tests | **App Team** | Complete & Tested |
| AWS Account Credentials & Free Tier Budget | **Infra Team** | Partner Responsibility |
| Execution of `./deploy.sh` on AWS | **Infra Team** | Partner Responsibility |
| Infrastructure Audit via `./verify.sh` | **Infra Team** | Partner Responsibility |
| Teardown via `./cleanup.sh` | **Infra Team** | Partner Responsibility |
