# SurgeGate — Cloud-Based Flash-Sale Ticket Booking & Traffic Management System

**SurgeGate** is an enterprise-grade, cloud-native infrastructure automation toolkit for high-traffic ticket booking events (concerts, championship matches, university festivals). It automates the provisioning, verification, and teardown of a resilient, scalable, and secure AWS infrastructure using the **AWS CLI** without requiring manual configuration in the AWS Management Console.

---

## 1. System Architecture

```text
                                [ User HTTP Traffic ]
                                          │
                                          ▼
                         [ Internet Gateway (surgegate-igw) ]
                                          │
                    ┌─────────────────────┴─────────────────────┐
                    │                                           │
                    ▼                                           ▼
          [ Public Subnet 1 ]                         [ Public Subnet 2 ]
       (surgegate-public-subnet-1)                 (surgegate-public-subnet-2)
                    │                                           │
                    └─────────────────────┬─────────────────────┘
                                          ▼
                      [ Application Load Balancer (ALB) ]
                               (surgegate-alb)
                                          │
                   ┌──────────────────────┴──────────────────────┐
                   ▼                                             ▼
       [ EC2 Auto Scaling Node 1 ]                   [ EC2 Auto Scaling Node 2 ]
         (surgegate-app-instance)                      (surgegate-app-instance)
                   │                                             │
                   └──────────────────────┬──────────────────────┘
                                          │
                 ┌────────────────────────┼────────────────────────┐
                 │                        │                        │
                 ▼                        ▼                        ▼
        [ Amazon SQS Queue ]     [ Amazon RDS MySQL ]     [ CloudWatch Metrics ]
     (surgegate-ticket-queue)      (surgegate-db)         (Alarms & Dashboards)
                 │                   (Private Subnets)
                 ▼
       [ AWS Lambda Worker ]
    (surgegate-ticket-processor)
                 │
        ┌────────┴────────┐
        ▼                 ▼
  [ Amazon S3 ]     [ Amazon SNS ]
(Ticket QR Assets) (Booking Alerts)
```

### Core Architecture Components

| Component | AWS Service | Purpose | Security & Sizing |
|---|---|---|---|
| **Network Isolation** | Amazon VPC | Dedicated network with 2 public & 2 private subnets across multiple AZs | CIDR `10.0.0.0/16`, DNS hostnames enabled |
| **Traffic Distribution**| Application Load Balancer (ALB) | Distributes incoming HTTP traffic across healthy application nodes | Health checks on `/health`, port 80/443 |
| **Compute & Scaling**  | EC2 Auto Scaling Group | Scales application nodes horizontally based on CPU load | `t3.micro`, Amazon Linux 2023, SSM managed |
| **Transactional Storage** | Amazon RDS for MySQL | Manages users, events, seat inventory, locks, and payments | `db.t3.micro`, 20GB gp3, encrypted at rest, private |
| **Traffic Buffer**     | Amazon SQS & DLQ | Buffers ticket-generation jobs to protect the database | Visibility timeout 60s, DLQ maxReceiveCount 3 |
| **Asynchronous Worker**| AWS Lambda | Generates QR ticket vectors and dispatches notifications | Python 3.11, SQS Event Source trigger, 128MB |
| **Asset Storage**      | Amazon S3 | Stores generated QR ticket SVGs and event media | Server-Side Encryption (AES256), Block Public Access |
| **Notifications**      | Amazon SNS | Sends booking confirmations to customers (optional) | Email/SMS protocol |
| **Instance Management**| AWS Systems Manager | Secure instance access without opening inbound SSH port 22 | Role: `AmazonSSMManagedInstanceCore` |
| **Monitoring**         | Amazon CloudWatch | Alarms on EC2 CPU, RDS CPU, and SQS queue backlog | Automated metric alarms |

---

## 🚀 Quickstart: How to Use SurgeGate

Follow this 5-step workflow to configure, test, deploy, verify, and clean up the infrastructure:

```bash
# 1. Prepare configuration
cp config.env.example config.env
chmod 600 config.env

# 2. Preview the deployment plan (No cloud changes made)
./deploy.sh --dry-run

# 3. Provision the AWS infrastructure
./deploy.sh

# 4. Verify health and security compliance
./verify.sh

# 5. Teardown when finished to avoid AWS charges
./cleanup.sh
```

---

## 📖 Comprehensive Step-by-Step Usage Guide

### Step 1: Check Prerequisites & AWS Authentication
Before running the toolkit, ensure your terminal has the required tools and active AWS credentials:
```bash
# Verify CLI tools
aws --version
jq --version
zip -v

# Verify active AWS authentication
aws sts get-caller-identity
```
> [!NOTE]
> Ensure your IAM user has administrative or sufficient permissions to create VPCs, Subnets, EC2, RDS, SQS, S3, IAM roles, and CloudWatch alarms. Do NOT use the root AWS account.

### Step 2: Configure Environment Settings
Create your local `config.env` file from the example template:
```bash
cp config.env.example config.env
chmod 600 config.env
```
Open `config.env` in your editor. For a student project on a limited budget, the defaults are already cost-optimized:
- `AWS_REGION=ap-south-1` (or your nearest AWS region with at least 2 Availability Zones)
- `ENABLE_NAT_GATEWAY=false` (Saves ~$32/month)
- `DB_INSTANCE_CLASS=db.t3.micro` (Free Tier eligible)
- `EC2_INSTANCE_TYPE=t3.micro` (Free Tier eligible)
- `DB_PASSWORD=""` (Leave blank to be prompted securely during deployment, or specify an 8+ character password)

### Step 3: Run in Dry-Run / Planning Mode
Always run the planning mode first to validate your parameters and check existing cloud resources without creating anything:
```bash
./deploy.sh --dry-run
```
Expected output:
- Validates CLI tools (`aws`, `jq`, `zip`, `sed`).
- Displays your AWS Account ID, Region, and selected Availability Zones.
- Prints the formatted **Infrastructure Provisioning Plan**.
- Checks whether SurgeGate resources already exist in your account.
- Confirms zero charges or resource modifications.

### Step 4: Execute Infrastructure Provisioning
Provision the complete AWS cloud architecture:
```bash
./deploy.sh
```
What happens automatically:
1. **Network**: Dedicated VPC (`10.0.0.0/16`), Internet Gateway, 2 public subnets, 2 private subnets, and route tables are created.
2. **Security**: Least-privilege Security Groups configure ALB ingress (port 80) and isolate MySQL (port 3306) to app nodes only (never `0.0.0.0/0`).
3. **Storage**: Secured Amazon S3 bucket with default AES-256 encryption and public access blocks.
4. **Queueing**: Amazon SQS buffer queue and Dead Letter Queue (DLQ) with redrive policy (maxReceiveCount 3).
5. **IAM**: Roles and instance profiles for EC2 (SSM managed, no open SSH) and Lambda execution.
6. **Serverless Worker**: Zips and deploys [`lambda/ticket_processor.py`](file:///lambda/ticket_processor.py) with SQS Event Source Mapping.
7. **Database**: Amazon RDS MySQL (`db.t3.micro`, 20GB gp3) in private subnets (polls until `available`).
8. **Load Balancing & Auto Scaling**: Application Load Balancer with HTTP health checks on `/health`, Launch Template, and Auto Scaling Group.
9. **Monitoring**: CloudWatch metric alarms for CPU and queue backlog.
10. **Outputs Saved**: Outputs are written to [`deployment-outputs.json`](file:///deployment-outputs.json) and [`deployment-outputs.env`](file:///deployment-outputs.env).

### Step 5: Verify & Audit Deployed Resources
Run the automated verification script to audit resource states and security rules:
```bash
./verify.sh
```
The script performs real-time state checks and outputs `[ PASS ]`, `[ FAIL ]`, or `[ SKIP ]`:
- Confirms VPC, Subnets, and ALB are in `available` and `active` states.
- Audits that RDS port 3306 is **not** exposed to `0.0.0.0/0`.
- Audits that SSH port 22 is **closed** to the internet.
- Verifies S3 encryption and Public Access Block.
- Verifies Lambda SQS event mapping and CloudWatch alarms.

### Step 6: Test the Live System End-to-End

#### A. Test Load Balancer Health Endpoint
Retrieve the live ALB endpoint from the deployment output and run:
```bash
source deployment-outputs.env
curl -i "$SURGEGATE_ALB_ENDPOINT/health"
```
Expected response:
```json
{
  "status": "HEALTHY",
  "service": "SurgeGate Edge Node",
  "environment": "dev",
  "sqs_queue": "surgegate-ticket-queue",
  "db_configured": true,
  "message": "SurgeGate traffic management node is operational."
}
```

#### B. Access Application Instances Securely (No SSH Key Needed)
Since SurgeGate instances use AWS Systems Manager Session Manager, you can open an encrypted shell without opening inbound port 22:
```bash
# List instances in the Auto Scaling Group
aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names surgegate-asg \
  --query "AutoScalingGroups[0].Instances[*].InstanceId" \
  --output text

# Connect via SSM Session Manager
aws ssm start-session --target <instance-id>
```

#### C. Initialize the MySQL Database Schema
From an EC2 instance connected via SSM:
```bash
source /opt/surgegate/deployment-outputs.env 2>/dev/null || source deployment-outputs.env
mysql -h "$SURGEGATE_DB_HOST" -u "$SURGEGATE_DB_USER" -p "$SURGEGATE_DB_NAME" < schema/schema.sql
```

#### D. Simulate a High-Traffic Ticket Purchase
Send an asynchronous ticket processing job to the Amazon SQS queue:
```bash
source deployment-outputs.env

aws sqs send-message \
  --queue-url "$SURGEGATE_SQS_URL" \
  --message-body '{
    "booking_ref": "SG-CONCERT-2026",
    "seat_id": "VIP-STAGE-A1",
    "user_email": "fan@example.com"
  }'
```

#### E. Verify Ticket Generation in Amazon S3
Within 5 seconds, AWS Lambda processes the SQS message, generates an SVG QR ticket pass, and saves it to S3:
```bash
# List generated ticket assets in your S3 bucket
aws s3 ls "s3://${SURGEGATE_S3_BUCKET}/tickets/dev/SG-CONCERT-2026/"

# Download the generated ticket SVG to view in your browser
aws s3 cp "s3://${SURGEGATE_S3_BUCKET}/tickets/dev/SG-CONCERT-2026/" ./downloaded_tickets/ --recursive
open ./downloaded_tickets/*.svg   # On macOS (or xdg-open on Linux)
```

### Step 7: Teardown & Clean Up Resources
When you are done testing or demonstrating the project, destroy all resources to avoid recurring AWS charges:
```bash
./cleanup.sh
```
- Type `yes` to confirm deletion of compute, network, and queue resources.
- Type `DELETE-DATA` when prompted if you also want to permanently drop the RDS database and empty the S3 bucket.

---

## 3. Directory Structure

```text
.
├── config.env.example          # Environment configuration template
├── deploy.sh                   # Automated AWS CLI provisioning script (Idempotent)
├── verify.sh                   # Health check, security audit, and status verification
├── cleanup.sh                  # Safe teardown script with data-loss safeguards
├── lambda/
│   └── ticket_processor.py     # Asynchronous ticket processing Lambda code
├── schema/
│   └── schema.sql              # Relational schema with row-level locks & constraints
└── README.md                   # Complete architectural and operational guide
```

---

## 4. Concurrency & Anti-Overselling Mechanism

Flash-sale traffic surges create severe race conditions where thousands of concurrent requests attempt to reserve the same seat. SurgeGate enforces concurrency control through **three coordinated architectural tiers**:

### A. Virtual Waiting Room & Queue Buffer (Ingress Tier)
- High-concurrency requests are queued at the edge.
- SQS acts as an asynchronous buffer, decoupling user admissions from backend processing and smoothing traffic spikes.
- Rate limiters regulate traffic so the transactional database is never overwhelmed by unbounded spikes.

### B. Pessimistic Row-Level Locking (Database Tier)
- Before creating a booking, seat reservation executes the stored procedure [`ReserveSeatAtomic`](file:///schema/schema.sql):
  ```sql
  SELECT status, reserved_until 
  FROM seats 
  WHERE seat_id = ? AND event_id = ? 
  FOR UPDATE;
  ```
- **Row-Level Lock:** `FOR UPDATE` serializes concurrent transactions on that exact seat row.
- **Lock Expiration:** If a user abandons checkout, `reserved_until` expires automatically, returning the seat to `AVAILABLE` without manual database cleanups.

### C. Unique Constraints & Idempotency (Transaction Tier)
- The database enforces uniqueness on active confirmed bookings:
  ```sql
  UNIQUE KEY uq_event_seat (event_id, section, row_number, seat_number)
  UNIQUE KEY uq_active_seat_booking (seat_id, status)
  ```
- Duplicate booking requests or retried HTTP calls provide an `idempotency_key`, preventing double charges and redundant ticket generation.

---

## 5. Configuration Reference

All settings are managed via `config.env`:

| Variable | Default Value | Description |
|---|---|---|
| `AWS_REGION` | `ap-south-1` | Target AWS region (must have >= 2 Availability Zones) |
| `PROJECT_NAME` | `surgegate` | Prefix used for AWS resource naming and tags |
| `ENVIRONMENT` | `dev` | Environment label (`dev`, `staging`, `prod`) |
| `VPC_CIDR` | `10.0.0.0/16` | CIDR block for the dedicated VPC |
| `ENABLE_NAT_GATEWAY` | `false` | **Set to false for student budget!** (Saves ~$32/month) |
| `DB_NAME` | `surgegate` | MySQL database name |
| `DB_USERNAME` | `surgegate_admin` | Master administrative user |
| `DB_PASSWORD` | `""` | Master password (prompted securely if empty) |
| `DB_INSTANCE_CLASS` | `db.t3.micro` | Eligible for AWS Free Tier |
| `DB_ALLOCATED_STORAGE` | `20` | Storage allocation in GB (gp3) |
| `EC2_INSTANCE_TYPE` | `t3.micro` | Application worker instance size |
| `APP_PORT` | `3000` | Application backend port |
| `ASG_MIN_SIZE` | `1` | Minimum running instances |
| `ASG_DESIRED_CAPACITY` | `1` | Target instance count |
| `ASG_MAX_SIZE` | `2` | Maximum scaling ceiling |
| `ENABLE_ALB` | `true` | Deploy Application Load Balancer |
| `ENABLE_AUTOSCALING` | `true` | Deploy Launch Template & ASG |
| `ENABLE_RDS` | `true` | Deploy Amazon RDS MySQL |
| `ENABLE_SQS` | `true` | Deploy SQS buffer queue & DLQ |
| `ENABLE_LAMBDA` | `true` | Deploy serverless ticket worker |
| `ENABLE_CLOUDWATCH_ALARMS` | `true` | Deploy CPU and queue backlog alarms |

---

## 6. Application Integration Guide

Once `deploy.sh` finishes, it writes your cluster configuration to `deployment-outputs.env`.

### 1. Connecting Your Backend Service
Source the environment variables in your Node.js, Python, or Go application:
```bash
source deployment-outputs.env
```

Your application can read standard configuration variables:
- `SURGEGATE_DB_HOST`: Hostname of the private RDS MySQL instance.
- `SURGEGATE_DB_PORT`: `3306`
- `SURGEGATE_DB_NAME`: `surgegate`
- `SURGEGATE_SQS_URL`: The Amazon SQS endpoint to send ticket generation jobs.
- `SURGEGATE_S3_BUCKET`: The S3 bucket name for assets.

### 2. Initializing the Database Schema
From an EC2 instance in the VPC or via an SSM session:
```bash
mysql -h "$SURGEGATE_DB_HOST" -u "$SURGEGATE_DB_USER" -p "$SURGEGATE_DB_NAME" < schema/schema.sql
```

### 3. Pushing a Ticket Job to SQS
When a user completes payment simulation, the web application submits a job to SQS:
```bash
aws sqs send-message \
  --queue-url "$SURGEGATE_SQS_URL" \
  --message-body '{
    "booking_ref": "SG-FEST-2026",
    "seat_id": "VIP-A-12",
    "user_email": "student@example.edu"
  }'
```
The Lambda worker automatically dequeues this message, generates an SVG QR ticket, uploads it to S3, and logs the outcome.

---

## 7. Clean Up & Cost Teardown

To avoid ongoing AWS charges after testing, run the cleanup script:
```bash
./cleanup.sh
```

**Safety Safeguards:**
- Prompts for explicit typed confirmation (`yes`) before removing any compute or network resources.
- Displays the target AWS Account ID and region.
- Detects persistent data stores (RDS Database and S3 Bucket) and requires a secondary explicit confirmation (`DELETE-DATA`) before destroying data.
- Removes resources in reverse dependency order (Alarms -> ASG -> ALB -> Lambda -> SQS -> RDS -> S3 -> IAM -> Security Groups -> VPC).

---

## 8. Student Budget & Cost Optimization

| Service | Student Free Tier / Cost Profile | SurgeGate Optimization |
|---|---|---|
| **EC2** | 750 hours/month of `t2.micro` or `t3.micro` | Min 1, Desired 1, Max 2 instances. |
| **RDS MySQL** | 750 hours/month of Single-AZ `db.t3.micro` + 20GB storage | Single-AZ `db.t3.micro` with gp3 storage. |
| **SQS** | 1,000,000 free requests/month | Zero base cost; standard pricing negligible. |
| **Lambda** | 1,000,000 free requests & 3.2M seconds compute/month | 128MB lightweight Python runtime. |
| **S3** | 5GB standard storage free for 12 months | SVG tickets are < 3KB each. |
| **ALB** | ~$16 - $20/month (~$0.0225/hour) | Clean up via `./cleanup.sh` when testing is complete. |
| **NAT Gateway** | ~$32/month per gateway | **Disabled by default** (`ENABLE_NAT_GATEWAY=false`). |

> [!WARNING]
> While EC2, RDS, and S3 are covered under the 12-month AWS Free Tier for eligible accounts, the **Application Load Balancer** incurs a small hourly cost while active. Run `./cleanup.sh` when you finish demonstration sessions.

---

## 9. Troubleshooting & Common Issues

### 1. `UnauthorizedOperation` or IAM Permission Errors
- **Cause:** Your AWS IAM user/role lacks sufficient permissions to create VPCs, RDS, or IAM roles.
- **Solution:** Ensure your IAM user has administrative policies or specific permissions for EC2, RDS, SQS, Lambda, IAM, and CloudWatch.

### 2. `InvalidParameterCombination` / `db.t3.micro` Unavailable
- **Cause:** Some older AWS Availability Zones or newer regions do not support `db.t3.micro`.
- **Solution:** Change `DB_INSTANCE_CLASS=db.t4g.micro` in `config.env`.

### 3. ALB Target Group Health Check Failing (`Unhealthy`)
- **Cause:** Application instance is not responding with HTTP 200 on `/health`.
- **Solution:** Check the systemd service on EC2:
  ```bash
  aws ssm start-session --target <instance-id>
  sudo systemctl status surgegate.service
  curl http://localhost:3000/health
  ```

### 4. S3 Bucket Name Already Taken
- **Cause:** S3 bucket names are globally unique across all AWS accounts.
- **Solution:** The script automatically appends your AWS Account ID and region suffix. If you manually specify `S3_BUCKET_NAME` in `config.env`, ensure it is unique.

---

## 10. Application Quickstart & Local Demonstration Guide

SurgeGate includes a complete React frontend and FastAPI backend designed to run locally on Docker Compose or natively on Windows (PowerShell) and macOS/Linux.

### System Access Points

| Service | Local URL | Description |
|---|---|---|
| **React Frontend** | `http://localhost:5173` | Interactive customer portal & admin operations dashboard |
| **FastAPI Backend** | `http://localhost:8000` | High-concurrency REST API & Health checks |
| **Interactive OpenAPI Docs** | `http://localhost:8000/docs` | Swagger UI documentation with direct execution |
| **MySQL 8 Database** | `localhost:3306` | Transactional database with row locks & FIFO queue |

### Default Seed Accounts

| Account Type | Email | Password | Role |
|---|---|---|---|
| **System Administrator** | `admin@surgegate.internal` | `AdminPass123!` | `ADMIN` (Queue Controls, Telemetry) |
| **Customer User 1** | `student@example.edu` | `StudentPass123!` | `CUSTOMER` (Waiting Room & Booking) |
| **Customer User 2** | `attendee@surgegate.internal` | `AttendeePass123!` | `CUSTOMER` (Waiting Room & Booking) |

---

### Option A: Running with Docker Compose (Recommended)

Make sure Docker Desktop is running, then execute from the project root:

```bash
# 1. Start all services (MySQL 8, Backend, Frontend)
docker compose up --build -d

# 2. View logs
docker compose logs -f

# 3. Stop services
docker compose down
```

---

### Option B: Windows PowerShell Setup & Native Execution

Follow these exact commands in **Windows PowerShell (Run as Administrator or standard terminal)**:

#### 1. Setup Backend (PowerShell)
```powershell
# Navigate to project backend
cd backend

# Create Python virtual environment
python -m venv .venv

# Activate virtual environment
.\.venv\Scripts\Activate.ps1

# Upgrade pip and install all dependencies
pip install --upgrade pip
pip install -r requirements.txt

# Run database migrations and seed realistic events/users
python -m app.seed

# Start FastAPI backend server
uvicorn app.main:app --host 0.0.0.0 --port 8000 --reload
```

#### 2. Setup Frontend (New PowerShell Terminal)
```powershell
# Navigate to frontend directory
cd frontend

# Install Node dependencies
npm install

# Start Vite dev server with proxy
npm run dev
```
Open **`http://localhost:5173`** in your browser.

---

### 11. Running Automated Tests & Load Simulations

#### 1. Run Complete Automated Pytest Suite
```bash
# Windows PowerShell
$env:PYTHONPATH=".\backend"
.\backend\.venv\Scripts\pytest backend\tests -v

# macOS / Linux
PYTHONPATH=./backend ./backend/.venv/bin/pytest backend/tests -v
```

#### 2. Run High-Concurrency Anti-Overselling Race Test
```bash
# Windows PowerShell
$env:PYTHONPATH=".\backend"
.\backend\.venv\Scripts\pytest backend\tests\test_race_conditions.py -v

# macOS / Linux
PYTHONPATH=./backend ./backend/.venv/bin/pytest backend/tests/test_race_conditions.py -v
```

#### 3. Run Headless Locust Load Test (Traffic Surge Simulation)
```bash
# Windows PowerShell
$env:PYTHONPATH=".\backend"
.\backend\.venv\Scripts\locust -f load_testing\locustfile.py --headless -u 20 -r 5 --run-time 30s --host http://localhost:8000

# macOS / Linux
PYTHONPATH=./backend ./backend/.venv/bin/locust -f load_testing/locustfile.py --headless -u 20 -r 5 --run-time 30s --host http://localhost:8000
```

---

## 12. Remaining AWS Cloud Deployment Tasks (Team Handoff)

The application layer is fully tested and verified. The other team member responsible for AWS deployment can follow these remaining steps:

1. Copy `config.env.example` to `config.env` and set `AWS_REGION` and `DB_PASSWORD`.
2. Run `./deploy.sh` to provision the VPC, RDS MySQL, SQS queue, Lambda function, S3 bucket, and ALB.
3. Verify cloud infrastructure health using `./verify.sh`.
4. Run schema initialization against the provisioned RDS instance:
   ```bash
   source deployment-outputs.env
   mysql -h "$SURGEGATE_DB_HOST" -u "$SURGEGATE_DB_USER" -p "$SURGEGATE_DB_NAME" < schema/schema.sql
   ```
5. Deploy application code to the EC2 Auto Scaling instances by setting `USE_AWS_MOCK=false`.
6. Run `./cleanup.sh` when demonstration is finished to destroy all resources and avoid unwanted cloud charges.
