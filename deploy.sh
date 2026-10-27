#!/usr/bin/env bash
# ==============================================================================
# SurgeGate - Cloud Infrastructure Provisioning Automation Script
# Provisions VPC, Subnets, Security Groups, S3, SQS, SNS, IAM, Lambda, RDS, ALB & ASG
# Designed for idempotency, safety, and student budget controls.
# ==============================================================================

set -Eeuo pipefail

# ------------------------------------------------------------------------------
# Formatting and Color Helpers
# ------------------------------------------------------------------------------
BOLD="\033[1m"
GREEN="\033[0;32m"
BLUE="\033[0;34m"
YELLOW="\033[1;33m"
RED="\033[0;31m"
CYAN="\033[0;36m"
NC="\033[0m" # No Color

log_info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_step()    { echo -e "\n${BOLD}${CYAN}==> $*${NC}"; }

# ------------------------------------------------------------------------------
# Error Trap Handler
# ------------------------------------------------------------------------------
cleanup_on_error() {
    local exit_code=$?
    local line_no=$1
    if [ $exit_code -ne 0 ]; then
        log_error "Deployment failed at line ${line_no} with exit code ${exit_code}."
        log_error "Inspect the logs above. Existing resources remain intact and can be cleaned up using ./cleanup.sh."
    fi
    exit $exit_code
}
trap 'cleanup_on_error $LINENO' ERR

# ------------------------------------------------------------------------------
# Script Flags & Environment Loading
# ------------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.env"
OUTPUTS_JSON="${SCRIPT_DIR}/deployment-outputs.json"
OUTPUTS_ENV="${SCRIPT_DIR}/deployment-outputs.env"
DRY_RUN=false

for arg in "$@"; do
    case "$arg" in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --help|-h)
            echo "Usage: ./deploy.sh [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --dry-run    Validate prerequisites, check existing resources and display execution plan without creating resources."
            echo "  --help, -h   Show this help message."
            exit 0
            ;;
    esac
done

echo -e "${BOLD}${CYAN}"
echo "=============================================================================="
echo "          SurgeGate - AWS Infrastructure Provisioning Automation             "
echo "=============================================================================="
echo -e "${NC}"

# Check for config.env
if [[ ! -f "$CONFIG_FILE" ]]; then
    if [[ -f "${SCRIPT_DIR}/config.env.example" ]]; then
        log_warn "config.env not found. Creating from config.env.example with defaults..."
        cp "${SCRIPT_DIR}/config.env.example" "$CONFIG_FILE"
        chmod 600 "$CONFIG_FILE"
    else
        log_error "Neither config.env nor config.env.example was found!"
        exit 1
    fi
fi

log_info "Loading configuration from ${CONFIG_FILE}..."
# shellcheck disable=SC1090
source "$CONFIG_FILE"

# Set defaults if not provided
AWS_REGION="${AWS_REGION:-ap-south-1}"
PROJECT_NAME="${PROJECT_NAME:-surgegate}"
ENVIRONMENT="${ENVIRONMENT:-dev}"
VPC_CIDR="${VPC_CIDR:-10.0.0.0/16}"
PUBLIC_SUBNET_1_CIDR="${PUBLIC_SUBNET_1_CIDR:-10.0.1.0/24}"
PUBLIC_SUBNET_2_CIDR="${PUBLIC_SUBNET_2_CIDR:-10.0.2.0/24}"
PRIVATE_SUBNET_1_CIDR="${PRIVATE_SUBNET_1_CIDR:-10.0.11.0/24}"
PRIVATE_SUBNET_2_CIDR="${PRIVATE_SUBNET_2_CIDR:-10.0.12.0/24}"
ENABLE_NAT_GATEWAY="${ENABLE_NAT_GATEWAY:-false}"
APP_PORT="${APP_PORT:-3000}"
EC2_INSTANCE_TYPE="${EC2_INSTANCE_TYPE:-t3.micro}"
ALLOWED_HTTP_CIDR="${ALLOWED_HTTP_CIDR:-0.0.0.0/0}"
ASG_MIN_SIZE="${ASG_MIN_SIZE:-1}"
ASG_DESIRED_CAPACITY="${ASG_DESIRED_CAPACITY:-1}"
ASG_MAX_SIZE="${ASG_MAX_SIZE:-2}"
ASG_TARGET_CPU_UTILIZATION="${ASG_TARGET_CPU_UTILIZATION:-70.0}"
ENABLE_RDS="${ENABLE_RDS:-true}"
DB_NAME="${DB_NAME:-surgegate}"
DB_USERNAME="${DB_USERNAME:-surgegate_admin}"
DB_INSTANCE_CLASS="${DB_INSTANCE_CLASS:-db.t3.micro}"
DB_ALLOCATED_STORAGE="${DB_ALLOCATED_STORAGE:-20}"
DB_MAX_ALLOCATED_STORAGE="${DB_MAX_ALLOCATED_STORAGE:-50}"
DB_STORAGE_TYPE="${DB_STORAGE_TYPE:-gp3}"
ENABLE_SQS="${ENABLE_SQS:-true}"
SQS_QUEUE_NAME="${SQS_QUEUE_NAME:-surgegate-ticket-queue}"
SQS_DLQ_NAME="${SQS_DLQ_NAME:-surgegate-ticket-dlq}"
SQS_VISIBILITY_TIMEOUT="${SQS_VISIBILITY_TIMEOUT:-60}"
SQS_MAX_RECEIVE_COUNT="${SQS_MAX_RECEIVE_COUNT:-3}"
ENABLE_LAMBDA="${ENABLE_LAMBDA:-true}"
LAMBDA_FUNCTION_NAME="${LAMBDA_FUNCTION_NAME:-surgegate-ticket-processor}"
LAMBDA_RUNTIME="${LAMBDA_RUNTIME:-python3.11}"
LAMBDA_TIMEOUT="${LAMBDA_TIMEOUT:-30}"
LAMBDA_MEMORY_SIZE="${LAMBDA_MEMORY_SIZE:-128}"
ENABLE_SNS="${ENABLE_SNS:-false}"
SNS_TOPIC_NAME="${SNS_TOPIC_NAME:-surgegate-booking-notifications}"
NOTIFICATION_EMAIL="${NOTIFICATION_EMAIL:-}"
S3_BUCKET_NAME="${S3_BUCKET_NAME:-}"
ENABLE_CLOUDWATCH_ALARMS="${ENABLE_CLOUDWATCH_ALARMS:-true}"
ENABLE_ALB="${ENABLE_ALB:-true}"
ENABLE_AUTOSCALING="${ENABLE_AUTOSCALING:-true}"

export AWS_DEFAULT_REGION="$AWS_REGION"
TAG_SPEC="Key=Project,Value=SurgeGate Key=Environment,Value=${ENVIRONMENT} Key=ManagedBy,Value=deploy.sh"

# ------------------------------------------------------------------------------
# 1. Dependency and Credential Verification
# ------------------------------------------------------------------------------
log_step "1. Validating Prerequisites and AWS CLI Environment"

for tool in aws sed; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        log_error "Missing required command-line tool: '$tool'. Please install it before proceeding."
        exit 1
    fi
done

# Check for Python or zip/jq
PYTHON_BIN=""
if command -v python3 >/dev/null 2>&1; then
    PYTHON_BIN="python3"
elif command -v python >/dev/null 2>&1; then
    PYTHON_BIN="python"
fi

if ! command -v jq >/dev/null 2>&1 && [[ -z "$PYTHON_BIN" ]]; then
    log_error "Neither 'jq' nor 'python' was found. Please install either jq or python."
    exit 1
fi
log_success "Command-line environment verified (aws, sed, $(command -v jq >/dev/null 2>&1 && echo 'jq' || echo 'python json fallback'))."

log_info "Verifying AWS credentials via STS caller identity..."
CALLER_IDENTITY=$(aws sts get-caller-identity --output json 2>&1) || {
    log_error "AWS authentication failed. Please configure credentials via 'aws configure' or export AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY."
    log_error "AWS STS Error: $CALLER_IDENTITY"
    exit 1
}

ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text 2>/dev/null || echo "$CALLER_IDENTITY" | jq -r '.Account')
CALLER_ARN=$(aws sts get-caller-identity --query "Arn" --output text 2>/dev/null || echo "$CALLER_IDENTITY" | jq -r '.Arn')
log_success "Authenticated as: ${CALLER_ARN} (Account ID: ${ACCOUNT_ID}, Region: ${AWS_REGION})"

# Check regional Availability Zones (at least 2 required, filter to standard availability zones)
AVAILABLE_AZS=($(aws ec2 describe-availability-zones --region "$AWS_REGION" --filters "Name=state,Values=available" "Name=zone-type,Values=availability-zone" --query "AvailabilityZones[].ZoneName" --output text 2>/dev/null || true))
if [ "${#AVAILABLE_AZS[@]}" -lt 2 ]; then
    # Fallback without zone-type filter if region metadata differs
    AVAILABLE_AZS=($(aws ec2 describe-availability-zones --region "$AWS_REGION" --filters "Name=state,Values=available" --query "AvailabilityZones[].ZoneName" --output text))
fi

if [ "${#AVAILABLE_AZS[@]}" -lt 2 ]; then
    log_error "Region ${AWS_REGION} must have at least 2 available AZs. Found: ${AVAILABLE_AZS[*]}"
    exit 1
fi
AZ_A="${AVAILABLE_AZS[0]}"
AZ_B="${AVAILABLE_AZS[1]}"
log_info "Selected Availability Zones: ${AZ_A}, ${AZ_B}"

# ------------------------------------------------------------------------------
# 2. Database Password Validation / Prompt
# ------------------------------------------------------------------------------
if [[ "$ENABLE_RDS" == "true" ]]; then
    if [[ -z "${DB_PASSWORD:-}" ]]; then
        if [[ "$DRY_RUN" == "true" ]]; then
            DB_PASSWORD="[DRY-RUN-MASKED-PASSWORD]"
        else
            if [[ -t 0 ]]; then
                echo ""
                log_warn "DB_PASSWORD is empty in config.env."
                echo -n "Enter a secure master password for Amazon RDS MySQL (or press Enter to auto-generate): "
                read -r -s DB_PASSWORD || DB_PASSWORD=""
                echo ""
            fi
            if [[ -z "$DB_PASSWORD" ]]; then
                if [[ -n "$PYTHON_BIN" ]]; then
                    DB_PASSWORD=$("$PYTHON_BIN" -c "import secrets, string; alphabet = string.ascii_letters + string.digits; print(''.join(secrets.choice(alphabet) for _ in range(16)))")
                elif command -v openssl >/dev/null 2>&1; then
                    DB_PASSWORD=$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9' | head -c 16)
                else
                    DB_PASSWORD="SurgeGatePass$(date +%s)"
                fi
                log_info "Auto-generated secure master password for Amazon RDS."
            elif [[ ${#DB_PASSWORD} -lt 8 ]]; then
                log_error "Password must be at least 8 characters long."
                exit 1
            fi
        fi
    fi
fi

# ------------------------------------------------------------------------------
# 3. Dry-Run / Plan Summary
# ------------------------------------------------------------------------------
echo ""
echo -e "${BOLD}${YELLOW}----------------------------------------------------------------------"
echo -e "                   INFRASTRUCTURE PROVISIONING PLAN                   "
echo -e "----------------------------------------------------------------------${NC}"
echo -e " Project Name:         ${CYAN}${PROJECT_NAME}${NC}"
echo -e " Environment:          ${CYAN}${ENVIRONMENT}${NC}"
echo -e " AWS Region:           ${CYAN}${AWS_REGION}${NC}"
echo -e " Account ID:           ${CYAN}${ACCOUNT_ID}${NC}"
echo -e " VPC CIDR:             ${CYAN}${VPC_CIDR}${NC}"
echo -e " Availability Zones:   ${CYAN}${AZ_A}, ${AZ_B}${NC}"
echo -e " Enable NAT Gateway:   ${CYAN}${ENABLE_NAT_GATEWAY}${NC} (False saves ~\$32/month)"
echo -e " Enable RDS MySQL:     ${CYAN}${ENABLE_RDS}${NC} (${DB_INSTANCE_CLASS}, 20GB gp3)"
echo -e " Enable SQS & DLQ:     ${CYAN}${ENABLE_SQS}${NC}"
echo -e " Enable Lambda Worker: ${CYAN}${ENABLE_LAMBDA}${NC} (${LAMBDA_RUNTIME})"
echo -e " Enable ALB & ASG:     ${CYAN}${ENABLE_ALB} / ${ENABLE_AUTOSCALING}${NC} (${EC2_INSTANCE_TYPE})"
echo -e " Enable CloudWatch:    ${CYAN}${ENABLE_CLOUDWATCH_ALARMS}${NC}"
echo -e "${BOLD}${YELLOW}----------------------------------------------------------------------${NC}"

if [[ "$DRY_RUN" == "true" ]]; then
    log_info "Running in DRY-RUN mode. Checking resource existence without making changes..."
fi

# Initialize dictionary/variable tracking for outputs
VPC_ID=""
IGW_ID=""
PUB_SUB_A_ID=""
PUB_SUB_B_ID=""
PRIV_SUB_A_ID=""
PRIV_SUB_B_ID=""
PUB_RT_ID=""
PRIV_RT_ID=""
ALB_SG_ID=""
EC2_SG_ID=""
RDS_SG_ID=""
LAMBDA_SG_ID=""
S3_BUCKET=""
SQS_QUEUE_URL=""
SQS_QUEUE_ARN=""
SQS_DLQ_URL=""
SQS_DLQ_ARN=""
SNS_TOPIC_ARN=""
EC2_ROLE_ARN=""
EC2_PROFILE_NAME=""
LAMBDA_ROLE_ARN=""
LAMBDA_ARN=""
DB_SUBNET_GROUP=""
DB_ENDPOINT=""
TARGET_GROUP_ARN=""
ALB_ARN=""
ALB_DNS_NAME=""
LAUNCH_TEMPLATE_ID=""
ASG_NAME=""

# ------------------------------------------------------------------------------
# 4. Amazon VPC & Subnets
# ------------------------------------------------------------------------------
log_step "2. Amazon VPC and Subnets Configuration"

# Check if VPC exists
EXISTING_VPC=$(aws ec2 describe-vpcs --filters "Name=tag:Project,Values=SurgeGate" "Name=tag:Environment,Values=${ENVIRONMENT}" "Name=tag:Name,Values=surgegate-vpc" --query "Vpcs[0].VpcId" --output text 2>/dev/null || true)

if [[ -n "$EXISTING_VPC" && "$EXISTING_VPC" != "None" ]]; then
    VPC_ID="$EXISTING_VPC"
    log_success "Found existing SurgeGate VPC: ${VPC_ID}"
else
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] Would create VPC (${VPC_CIDR}) with DNS hostnames enabled."
        VPC_ID="vpc-dryrunplaceholder"
    else
        log_info "Creating VPC with CIDR: ${VPC_CIDR}..."
        VPC_ID=$(aws ec2 create-vpc --cidr-block "$VPC_CIDR" \
            --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=surgegate-vpc},${TAG_SPEC}]" \
            --query "Vpc.VpcId" --output text)
        aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-hostnames "{\"Value\":true}"
        aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-support "{\"Value\":true}"
        log_success "Created VPC: ${VPC_ID}"
    fi
fi

# Internet Gateway
EXISTING_IGW=$(aws ec2 describe-internet-gateways --filters "Name=tag:Name,Values=surgegate-igw" "Name=tag:Project,Values=SurgeGate" --query "InternetGateways[0].InternetGatewayId" --output text 2>/dev/null || true)
if [[ -n "$EXISTING_IGW" && "$EXISTING_IGW" != "None" ]]; then
    IGW_ID="$EXISTING_IGW"
    log_success "Found existing Internet Gateway: ${IGW_ID}"
else
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] Would create Internet Gateway and attach to VPC."
        IGW_ID="igw-dryrunplaceholder"
    else
        log_info "Creating and attaching Internet Gateway..."
        IGW_ID=$(aws ec2 create-internet-gateway \
            --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Name,Value=surgegate-igw},${TAG_SPEC}]" \
            --query "InternetGateway.InternetGatewayId" --output text)
        aws ec2 attach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID"
        log_success "Attached Internet Gateway: ${IGW_ID}"
    fi
fi

# Subnet Helper function
find_or_create_subnet() {
    local name=$1
    local cidr=$2
    local az=$3
    local is_public=$4
    local sub_id=""

    sub_id=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=${VPC_ID}" "Name=cidr-block,Values=${cidr}" --query "Subnets[0].SubnetId" --output text 2>/dev/null || true)
    if [[ -n "$sub_id" && "$sub_id" != "None" ]]; then
        log_success "Found existing Subnet ${name}: ${sub_id}"
    else
        if [[ "$DRY_RUN" == "true" ]]; then
            log_info "[DRY-RUN] Would create Subnet ${name} (${cidr}) in ${az}"
            sub_id="subnet-dryrunplaceholder"
        else
            log_info "Creating Subnet ${name} (${cidr}) in ${az}..."
            sub_id=$(aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block "$cidr" --availability-zone "$az" \
                --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${name}},${TAG_SPEC}]" \
                --query "Subnet.SubnetId" --output text)
            if [[ "$is_public" == "true" ]]; then
                aws ec2 modify-subnet-attribute --subnet-id "$sub_id" --map-public-ip-on-launch
            fi
            log_success "Created Subnet ${name}: ${sub_id}"
        fi
    fi
    echo "$sub_id"
}

PUB_SUB_A_ID=$(find_or_create_subnet "surgegate-public-subnet-1" "$PUBLIC_SUBNET_1_CIDR" "$AZ_A" "true")
PUB_SUB_B_ID=$(find_or_create_subnet "surgegate-public-subnet-2" "$PUBLIC_SUBNET_2_CIDR" "$AZ_B" "true")
PRIV_SUB_A_ID=$(find_or_create_subnet "surgegate-private-subnet-1" "$PRIVATE_SUBNET_1_CIDR" "$AZ_A" "false")
PRIV_SUB_B_ID=$(find_or_create_subnet "surgegate-private-subnet-2" "$PRIVATE_SUBNET_2_CIDR" "$AZ_B" "false")

# Route Table for Public Subnets
EXISTING_PUB_RT=$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=${VPC_ID}" "Name=tag:Name,Values=surgegate-public-rt" --query "RouteTables[0].RouteTableId" --output text 2>/dev/null || true)
if [[ -n "$EXISTING_PUB_RT" && "$EXISTING_PUB_RT" != "None" ]]; then
    PUB_RT_ID="$EXISTING_PUB_RT"
    log_success "Found existing Public Route Table: ${PUB_RT_ID}"
else
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] Would create Public Route Table with route 0.0.0.0/0 -> IGW."
        PUB_RT_ID="rtb-dryrunplaceholder"
    else
        log_info "Configuring Public Route Table..."
        PUB_RT_ID=$(aws ec2 create-route-table --vpc-id "$VPC_ID" \
            --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=surgegate-public-rt},${TAG_SPEC}]" \
            --query "RouteTable.RouteTableId" --output text)
        aws ec2 create-route --route-table-id "$PUB_RT_ID" --destination-cidr-block 0.0.0.0/0 --gateway-id "$IGW_ID" >/dev/null
        aws ec2 associate-route-table --subnet-id "$PUB_SUB_A_ID" --route-table-id "$PUB_RT_ID" >/dev/null
        aws ec2 associate-route-table --subnet-id "$PUB_SUB_B_ID" --route-table-id "$PUB_RT_ID" >/dev/null
        log_success "Created and associated Public Route Table: ${PUB_RT_ID}"
    fi
fi

# Private Route Table
EXISTING_PRIV_RT=$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=${VPC_ID}" "Name=tag:Name,Values=surgegate-private-rt" --query "RouteTables[0].RouteTableId" --output text 2>/dev/null || true)
if [[ -n "$EXISTING_PRIV_RT" && "$EXISTING_PRIV_RT" != "None" ]]; then
    PRIV_RT_ID="$EXISTING_PRIV_RT"
    log_success "Found existing Private Route Table: ${PRIV_RT_ID}"
else
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] Would create Private Route Table."
        PRIV_RT_ID="rtb-priv-dryrunplaceholder"
    else
        PRIV_RT_ID=$(aws ec2 create-route-table --vpc-id "$VPC_ID" \
            --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=surgegate-private-rt},${TAG_SPEC}]" \
            --query "RouteTable.RouteTableId" --output text)
        aws ec2 associate-route-table --subnet-id "$PRIV_SUB_A_ID" --route-table-id "$PRIV_RT_ID" >/dev/null
        aws ec2 associate-route-table --subnet-id "$PRIV_SUB_B_ID" --route-table-id "$PRIV_RT_ID" >/dev/null
        log_success "Created and associated Private Route Table: ${PRIV_RT_ID}"
    fi
fi

# ------------------------------------------------------------------------------
# 5. Security Groups (Least-Privilege Separation)
# ------------------------------------------------------------------------------
log_step "3. Security Groups Configuration"

find_or_create_sg() {
    local name=$1
    local desc=$2
    local sg_id=""

    sg_id=$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=${VPC_ID}" "Name=group-name,Values=${name}" --query "SecurityGroups[0].GroupId" --output text 2>/dev/null || true)
    if [[ -n "$sg_id" && "$sg_id" != "None" ]]; then
        log_success "Found existing Security Group ${name}: ${sg_id}"
    else
        if [[ "$DRY_RUN" == "true" ]]; then
            log_info "[DRY-RUN] Would create Security Group ${name}"
            sg_id="sg-dryrunplaceholder"
        else
            sg_id=$(aws ec2 create-security-group --group-name "$name" --description "$desc" --vpc-id "$VPC_ID" \
                --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=${name}},${TAG_SPEC}]" \
                --query "GroupId" --output text)
            log_success "Created Security Group ${name}: ${sg_id}"
        fi
    fi
    echo "$sg_id"
}

ALB_SG_ID=$(find_or_create_sg "surgegate-alb-sg" "SurgeGate ALB Public Ingress")
EC2_SG_ID=$(find_or_create_sg "surgegate-ec2-sg" "SurgeGate EC2 Application Ingress from ALB")
RDS_SG_ID=$(find_or_create_sg "surgegate-db-sg" "SurgeGate Private RDS MySQL Ingress from App")
LAMBDA_SG_ID=$(find_or_create_sg "surgegate-lambda-sg" "SurgeGate Lambda Worker Ingress/Egress")

if [[ "$DRY_RUN" == "false" ]]; then
    # Rule 1: ALB allows HTTP (port 80) from allowed CIDR
    aws ec2 authorize-security-group-ingress --group-id "$ALB_SG_ID" \
        --protocol tcp --port 80 --cidr "$ALLOWED_HTTP_CIDR" 2>/dev/null || true

    # Rule 2: EC2 allows application port from ALB SG only
    aws ec2 authorize-security-group-ingress --group-id "$EC2_SG_ID" \
        --protocol tcp --port "$APP_PORT" --source-group "$ALB_SG_ID" 2>/dev/null || true
    # Also allow port 80 if app serves directly or for test
    aws ec2 authorize-security-group-ingress --group-id "$EC2_SG_ID" \
        --protocol tcp --port 80 --source-group "$ALB_SG_ID" 2>/dev/null || true

    # Rule 3: RDS allows MySQL 3306 ONLY from EC2 SG and Lambda SG (NEVER 0.0.0.0/0)
    aws ec2 authorize-security-group-ingress --group-id "$RDS_SG_ID" \
        --protocol tcp --port 3306 --source-group "$EC2_SG_ID" 2>/dev/null || true
    aws ec2 authorize-security-group-ingress --group-id "$RDS_SG_ID" \
        --protocol tcp --port 3306 --source-group "$LAMBDA_SG_ID" 2>/dev/null || true

    log_success "Configured least-privilege Security Group ingress rules."
fi

# ------------------------------------------------------------------------------
# 6. Amazon S3 Bucket (Ticket QR Codes & Artifacts)
# ------------------------------------------------------------------------------
log_step "4. Amazon S3 Storage Configuration"

if [[ -z "$S3_BUCKET_NAME" ]]; then
    # Generate account-scoped predictable bucket name
    REGION_CLEAN=$(echo "$AWS_REGION" | tr -d '-')
    S3_BUCKET="surgegate-tickets-${ENVIRONMENT}-${ACCOUNT_ID}-${REGION_CLEAN}"
else
    S3_BUCKET="$S3_BUCKET_NAME"
fi

BUCKET_EXISTS=$(aws s3api head-bucket --bucket "$S3_BUCKET" 2>&1 || true)
if echo "$BUCKET_EXISTS" | grep -q '404' || echo "$BUCKET_EXISTS" | grep -q 'NoSuchBucket'; then
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] Would create S3 Bucket: ${S3_BUCKET} with encryption and public access blocked."
    else
        log_info "Creating S3 bucket: ${S3_BUCKET}..."
        if [[ "$AWS_REGION" == "us-east-1" ]]; then
            aws s3api create-bucket --bucket "$S3_BUCKET"
        else
            aws s3api create-bucket --bucket "$S3_BUCKET" \
                --create-bucket-configuration "LocationConstraint=${AWS_REGION}"
        fi

        # Block all public access
        aws s3api put-public-access-block --bucket "$S3_BUCKET" \
            --public-access-block-configuration "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

        # Enable Default Server-Side Encryption (SSE-S3 AES256)
        aws s3api put-bucket-encryption --bucket "$S3_BUCKET" \
            --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

        # Apply Tags
        aws s3api put-bucket-tagging --bucket "$S3_BUCKET" \
            --tagging "TagSet=[{Key=Project,Value=SurgeGate},{Key=Environment,Value=${ENVIRONMENT}}]"

        log_success "Created secured S3 bucket: ${S3_BUCKET}"
    fi
else
    log_success "Found existing accessible S3 bucket: ${S3_BUCKET}"
fi

# ------------------------------------------------------------------------------
# 7. Amazon SQS Queues (Main Buffer + Dead Letter Queue)
# ------------------------------------------------------------------------------
log_step "5. Amazon SQS Queues Configuration"

if [[ "$ENABLE_SQS" == "true" ]]; then
    # 1. Dead Letter Queue
    SQS_DLQ_URL=$(aws sqs get-queue-url --queue-name "$SQS_DLQ_NAME" --query "QueueUrl" --output text 2>/dev/null || true)
    if [[ -n "$SQS_DLQ_URL" && "$SQS_DLQ_URL" != "None" ]]; then
        log_success "Found existing DLQ: ${SQS_DLQ_URL}"
        SQS_DLQ_ARN=$(aws sqs get-queue-attributes --queue-url "$SQS_DLQ_URL" --attribute-names QueueArn --query "Attributes.QueueArn" --output text)
    else
        if [[ "$DRY_RUN" == "true" ]]; then
            log_info "[DRY-RUN] Would create SQS DLQ: ${SQS_DLQ_NAME}"
            SQS_DLQ_URL="https://sqs.${AWS_REGION}.amazonaws.com/${ACCOUNT_ID}/${SQS_DLQ_NAME}"
            SQS_DLQ_ARN="arn:aws:sqs:${AWS_REGION}:${ACCOUNT_ID}:${SQS_DLQ_NAME}"
        else
            log_info "Creating Dead Letter Queue: ${SQS_DLQ_NAME}..."
            SQS_DLQ_URL=$(aws sqs create-queue --queue-name "$SQS_DLQ_NAME" \
                --tags "Project=SurgeGate,Environment=${ENVIRONMENT}" \
                --query "QueueUrl" --output text)
            SQS_DLQ_ARN=$(aws sqs get-queue-attributes --queue-url "$SQS_DLQ_URL" --attribute-names QueueArn --query "Attributes.QueueArn" --output text)
            log_success "Created DLQ: ${SQS_DLQ_URL}"
        fi
    fi

    # 2. Main Ticket Buffer Queue with RedrivePolicy
    SQS_QUEUE_URL=$(aws sqs get-queue-url --queue-name "$SQS_QUEUE_NAME" --query "QueueUrl" --output text 2>/dev/null || true)
    if [[ -n "$SQS_QUEUE_URL" && "$SQS_QUEUE_URL" != "None" ]]; then
        log_success "Found existing SQS Ticket Queue: ${SQS_QUEUE_URL}"
        SQS_QUEUE_ARN=$(aws sqs get-queue-attributes --queue-url "$SQS_QUEUE_URL" --attribute-names QueueArn --query "Attributes.QueueArn" --output text)
    else
        if [[ "$DRY_RUN" == "true" ]]; then
            log_info "[DRY-RUN] Would create SQS Queue: ${SQS_QUEUE_NAME} with RedrivePolicy to DLQ"
            SQS_QUEUE_URL="https://sqs.${AWS_REGION}.amazonaws.com/${ACCOUNT_ID}/${SQS_QUEUE_NAME}"
            SQS_QUEUE_ARN="arn:aws:sqs:${AWS_REGION}:${ACCOUNT_ID}:${SQS_QUEUE_NAME}"
        else
            log_info "Creating Main Ticket Buffer Queue: ${SQS_QUEUE_NAME}..."
            REDRIVE_JSON="{\"deadLetterTargetArn\":\"${SQS_DLQ_ARN}\",\"maxReceiveCount\":${SQS_MAX_RECEIVE_COUNT}}"
            SQS_ATTRS_JSON="{\"VisibilityTimeout\":\"${SQS_VISIBILITY_TIMEOUT}\",\"RedrivePolicy\":\"$(echo "$REDRIVE_JSON" | sed 's/"/\\"/g')\"}"
            SQS_QUEUE_URL=$(aws sqs create-queue --queue-name "$SQS_QUEUE_NAME" \
                --attributes "$SQS_ATTRS_JSON" \
                --tags "Project=SurgeGate,Environment=${ENVIRONMENT}" \
                --query "QueueUrl" --output text)
            SQS_QUEUE_ARN=$(aws sqs get-queue-attributes --queue-url "$SQS_QUEUE_URL" --attribute-names QueueArn --query "Attributes.QueueArn" --output text)
            log_success "Created Main SQS Queue: ${SQS_QUEUE_URL}"
        fi
    fi
fi

# ------------------------------------------------------------------------------
# 8. Amazon SNS Topic (Optional Booking Notifications)
# ------------------------------------------------------------------------------
if [[ "$ENABLE_SNS" == "true" ]]; then
    log_step "6. Amazon SNS Notification Topic"
    SNS_TOPIC_ARN=$(aws sns create-topic --name "$SNS_TOPIC_NAME" \
        --tags "Key=Project,Value=SurgeGate" "Key=Environment,Value=${ENVIRONMENT}" \
        --query "TopicArn" --output text 2>/dev/null || true)
    log_success "Configured SNS Topic: ${SNS_TOPIC_ARN}"

    if [[ -n "$NOTIFICATION_EMAIL" && "$DRY_RUN" == "false" ]]; then
        aws sns subscribe --topic-arn "$SNS_TOPIC_ARN" --protocol email --notification-endpoint "$NOTIFICATION_EMAIL" >/dev/null || true
        log_info "Sent subscription confirmation to ${NOTIFICATION_EMAIL}."
    fi
fi

# ------------------------------------------------------------------------------
# 9. IAM Roles and Instance Profiles
# ------------------------------------------------------------------------------
log_step "7. IAM Least-Privilege Roles Configuration"

# A. EC2 Instance Role & Profile (SSM + SQS + S3)
EC2_ROLE_NAME="surgegate-ec2-role"
EC2_PROFILE_NAME="surgegate-ec2-profile"

EXISTING_EC2_ROLE=$(aws iam get-role --role-name "$EC2_ROLE_NAME" --query "Role.Arn" --output text 2>/dev/null || true)
if [[ -n "$EXISTING_EC2_ROLE" && "$EXISTING_EC2_ROLE" != "None" ]]; then
    EC2_ROLE_ARN="$EXISTING_EC2_ROLE"
    log_success "Found existing IAM Role: ${EC2_ROLE_NAME}"
else
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] Would create IAM Role: ${EC2_ROLE_NAME} with SSM and App policies."
        EC2_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${EC2_ROLE_NAME}"
    else
        log_info "Creating IAM Role: ${EC2_ROLE_NAME}..."
        EC2_TRUST_POLICY='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
        EC2_ROLE_ARN=$(aws iam create-role --role-name "$EC2_ROLE_NAME" \
            --assume-role-policy-document "$EC2_TRUST_POLICY" \
            --tags "Key=Project,Value=SurgeGate" "Key=Environment,Value=${ENVIRONMENT}" \
            --query "Role.Arn" --output text)

        # Attach SSM Session Manager managed policy
        aws iam attach-role-policy --role-name "$EC2_ROLE_NAME" \
            --policy-arn "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"

        # Attach App specific least privilege policy (SQS send, S3 read/write, SSM parameter read)
        EC2_APP_POLICY=$(cat <<EOF
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
            "Resource": "${SQS_QUEUE_ARN:-*}"
        },
        {
            "Effect": "Allow",
            "Action": [
                "s3:PutObject",
                "s3:GetObject"
            ],
            "Resource": "arn:aws:s3:::${S3_BUCKET}/*"
        },
        {
            "Effect": "Allow",
            "Action": [
                "ssm:GetParameter",
                "ssm:GetParameters",
                "ssm:GetParametersByPath"
            ],
            "Resource": "arn:aws:ssm:${AWS_REGION}:${ACCOUNT_ID}:parameter/surgegate/*"
        }
    ]
}
EOF
)
        aws iam put-role-policy --role-name "$EC2_ROLE_NAME" \
            --policy-name "SurgeGateEC2AppPolicy" \
            --policy-document "$EC2_APP_POLICY"
        log_success "Created and configured IAM Role: ${EC2_ROLE_NAME}"
    fi
fi

# Instance Profile
EXISTING_PROFILE=$(aws iam get-instance-profile --instance-profile-name "$EC2_PROFILE_NAME" --query "InstanceProfile.InstanceProfileName" --output text 2>/dev/null || true)
if [[ -z "$EXISTING_PROFILE" || "$EXISTING_PROFILE" == "None" ]]; then
    if [[ "$DRY_RUN" == "false" ]]; then
        aws iam create-instance-profile --instance-profile-name "$EC2_PROFILE_NAME" >/dev/null
        aws iam add-role-to-instance-profile --instance-profile-name "$EC2_PROFILE_NAME" --role-name "$EC2_ROLE_NAME" >/dev/null
        log_success "Created and associated Instance Profile: ${EC2_PROFILE_NAME}"
        # Give IAM propagation a moment
        sleep 5
    fi
else
    log_success "Found existing Instance Profile: ${EC2_PROFILE_NAME}"
fi

# B. Lambda Execution Role
LAMBDA_ROLE_NAME="surgegate-lambda-role"
EXISTING_LAMBDA_ROLE=$(aws iam get-role --role-name "$LAMBDA_ROLE_NAME" --query "Role.Arn" --output text 2>/dev/null || true)
if [[ -n "$EXISTING_LAMBDA_ROLE" && "$EXISTING_LAMBDA_ROLE" != "None" ]]; then
    LAMBDA_ROLE_ARN="$EXISTING_LAMBDA_ROLE"
    log_success "Found existing IAM Role: ${LAMBDA_ROLE_NAME}"
else
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] Would create IAM Role: ${LAMBDA_ROLE_NAME} for Lambda execution."
        LAMBDA_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${LAMBDA_ROLE_NAME}"
    else
        log_info "Creating IAM Role: ${LAMBDA_ROLE_NAME}..."
        LAMBDA_TRUST_POLICY='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
        LAMBDA_ROLE_ARN=$(aws iam create-role --role-name "$LAMBDA_ROLE_NAME" \
            --assume-role-policy-document "$LAMBDA_TRUST_POLICY" \
            --tags "Key=Project,Value=SurgeGate" "Key=Environment,Value=${ENVIRONMENT}" \
            --query "Role.Arn" --output text)

        # Attach Basic Lambda logging execution policy
        aws iam attach-role-policy --role-name "$LAMBDA_ROLE_NAME" \
            --policy-arn "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"

        # Worker specific inline policy: SQS consume, S3 put, SNS publish
        LAMBDA_POLICY=$(cat <<EOF
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
            "Resource": "${SQS_QUEUE_ARN:-*}"
        },
        {
            "Effect": "Allow",
            "Action": [
                "s3:PutObject",
                "s3:GetObject"
            ],
            "Resource": "arn:aws:s3:::${S3_BUCKET}/*"
        },
        {
            "Effect": "Allow",
            "Action": [
                "sns:Publish"
            ],
            "Resource": "${SNS_TOPIC_ARN:-*}"
        }
    ]
}
EOF
)
        aws iam put-role-policy --role-name "$LAMBDA_ROLE_NAME" \
            --policy-name "SurgeGateLambdaWorkerPolicy" \
            --policy-document "$LAMBDA_POLICY"
        log_success "Created and configured IAM Role: ${LAMBDA_ROLE_NAME}"
        sleep 5
    fi
fi

# ------------------------------------------------------------------------------
# 10. AWS Lambda Function (Asynchronous Ticket Processing)
# ------------------------------------------------------------------------------
if [[ "$ENABLE_LAMBDA" == "true" ]]; then
    log_step "8. AWS Lambda Ticket Worker Deployment"

    LAMBDA_DIR="${SCRIPT_DIR}/lambda"
    ZIP_PATH="${SCRIPT_DIR}/lambda_payload.zip"

    if [[ ! -f "${LAMBDA_DIR}/ticket_processor.py" ]]; then
        log_error "Lambda handler file ${LAMBDA_DIR}/ticket_processor.py not found!"
        exit 1
    fi

    log_info "Packaging Lambda code into ${ZIP_PATH}..."
    if command -v zip >/dev/null 2>&1; then
        (cd "$LAMBDA_DIR" && zip -q -r "$ZIP_PATH" ticket_processor.py)
    elif [[ -n "$PYTHON_BIN" ]]; then
        (cd "$LAMBDA_DIR" && "$PYTHON_BIN" -m zipfile -c "$ZIP_PATH" ticket_processor.py)
    else
        log_error "Neither 'zip' nor 'python' was found to archive Lambda code."
        exit 1
    fi

    EXISTING_LAMBDA=$(aws lambda get-function --function-name "$LAMBDA_FUNCTION_NAME" --query "Configuration.FunctionArn" --output text 2>/dev/null || true)
    if [[ -n "$EXISTING_LAMBDA" && "$EXISTING_LAMBDA" != "None" ]]; then
        LAMBDA_ARN="$EXISTING_LAMBDA"
        log_success "Found existing Lambda function: ${LAMBDA_ARN}"
        if [[ "$DRY_RUN" == "false" ]]; then
            log_info "Updating Lambda code and configuration..."
            aws lambda update-function-code --function-name "$LAMBDA_FUNCTION_NAME" \
                --zip-file "fileb://${ZIP_PATH}" >/dev/null
            aws lambda update-function-configuration --function-name "$LAMBDA_FUNCTION_NAME" \
                --environment "Variables={S3_BUCKET_NAME=${S3_BUCKET},SNS_TOPIC_ARN=${SNS_TOPIC_ARN:-},ENVIRONMENT=${ENVIRONMENT}}" >/dev/null
        fi
    else
        if [[ "$DRY_RUN" == "true" ]]; then
            log_info "[DRY-RUN] Would create Lambda Function ${LAMBDA_FUNCTION_NAME} (${LAMBDA_RUNTIME})"
            LAMBDA_ARN="arn:aws:lambda:${AWS_REGION}:${ACCOUNT_ID}:function:${LAMBDA_FUNCTION_NAME}"
        else
            log_info "Creating Lambda function: ${LAMBDA_FUNCTION_NAME}..."
            log_info "Waiting for IAM role propagation..."
            sleep 8
            LAMBDA_ARN=""
            for attempt in {1..6}; do
                if LAMBDA_ARN=$(aws lambda create-function \
                    --function-name "$LAMBDA_FUNCTION_NAME" \
                    --runtime "$LAMBDA_RUNTIME" \
                    --role "$LAMBDA_ROLE_ARN" \
                    --handler "ticket_processor.lambda_handler" \
                    --timeout "$LAMBDA_TIMEOUT" \
                    --memory-size "$LAMBDA_MEMORY_SIZE" \
                    --zip-file "fileb://${ZIP_PATH}" \
                    --environment "Variables={S3_BUCKET_NAME=${S3_BUCKET},SNS_TOPIC_ARN=${SNS_TOPIC_ARN:-},ENVIRONMENT=${ENVIRONMENT}}" \
                    --tags "Project=SurgeGate,Environment=${ENVIRONMENT}" \
                    --query "FunctionArn" --output text 2>/dev/null); then
                    break
                else
                    log_warn "IAM role not yet propagated in STS (attempt ${attempt}/6). Retrying in 5s..."
                    sleep 5
                fi
            done

            if [[ -z "$LAMBDA_ARN" || "$LAMBDA_ARN" == "None" ]]; then
                log_error "Failed to create Lambda function after 6 IAM propagation attempts."
                exit 1
            fi
            log_success "Created Lambda function: ${LAMBDA_ARN}"
        fi
    fi

    # Connect SQS to Lambda via Event Source Mapping
    if [[ "$ENABLE_SQS" == "true" && "$DRY_RUN" == "false" ]]; then
        EXISTING_MAPPING=$(aws lambda list-event-source-mappings --function-name "$LAMBDA_FUNCTION_NAME" \
            --query "EventSourceMappings[?EventSourceArn=='${SQS_QUEUE_ARN}'].UUID" --output text 2>/dev/null || true)
        if [[ -z "$EXISTING_MAPPING" || "$EXISTING_MAPPING" == "None" ]]; then
            log_info "Configuring SQS Trigger -> Lambda Event Source Mapping..."
            aws lambda create-event-source-mapping \
                --function-name "$LAMBDA_FUNCTION_NAME" \
                --event-source-arn "$SQS_QUEUE_ARN" \
                --batch-size 5 \
                --enabled >/dev/null
            log_success "Connected SQS queue to Lambda ticket processor."
        else
            log_success "SQS to Lambda Event Source Mapping already active."
        fi
    fi
    rm -f "$ZIP_PATH"
fi

# ------------------------------------------------------------------------------
# 11. Amazon RDS for MySQL Database
# ------------------------------------------------------------------------------
if [[ "$ENABLE_RDS" == "true" ]]; then
    log_step "9. Amazon RDS for MySQL Database Deployment"

    DB_SUBNET_GROUP="surgegate-db-subnet-group"
    DB_INSTANCE_ID="surgegate-db"

    # DB Subnet Group across private subnets
    EXISTING_DB_SUBNET_GROUP=$(aws rds describe-db-subnet-groups --db-subnet-group-name "$DB_SUBNET_GROUP" --query "DBSubnetGroups[0].DBSubnetGroupName" --output text 2>/dev/null || true)
    if [[ -z "$EXISTING_DB_SUBNET_GROUP" || "$EXISTING_DB_SUBNET_GROUP" == "None" ]]; then
        if [[ "$DRY_RUN" == "true" ]]; then
            log_info "[DRY-RUN] Would create RDS DB Subnet Group: ${DB_SUBNET_GROUP}"
        else
            log_info "Creating DB Subnet Group: ${DB_SUBNET_GROUP} across private subnets..."
            aws rds create-db-subnet-group \
                --db-subnet-group-name "$DB_SUBNET_GROUP" \
                --db-subnet-group-description "SurgeGate private database subnets" \
                --subnet-ids "$PRIV_SUB_A_ID" "$PRIV_SUB_B_ID" \
                --tags "Key=Project,Value=SurgeGate" "Key=Environment,Value=${ENVIRONMENT}" >/dev/null
            log_success "Created DB Subnet Group: ${DB_SUBNET_GROUP}"
        fi
    else
        log_success "Found existing DB Subnet Group: ${DB_SUBNET_GROUP}"
    fi

    # Check RDS Instance status
    EXISTING_RDS_STATUS=$(aws rds describe-db-instances --db-instance-identifier "$DB_INSTANCE_ID" --query "DBInstances[0].DBInstanceStatus" --output text 2>/dev/null || true)
    if [[ -n "$EXISTING_RDS_STATUS" && "$EXISTING_RDS_STATUS" != "None" ]]; then
        log_info "RDS Instance ${DB_INSTANCE_ID} exists (Status: ${EXISTING_RDS_STATUS})."
        if [[ "$EXISTING_RDS_STATUS" == "available" ]]; then
            DB_ENDPOINT=$(aws rds describe-db-instances --db-instance-identifier "$DB_INSTANCE_ID" --query "DBInstances[0].Endpoint.Address" --output text)
            log_success "RDS Database available at: ${DB_ENDPOINT}:3306"
        else
            log_warn "RDS Instance is currently in status '${EXISTING_RDS_STATUS}'. Waiting for it to become available..."
            if [[ "$DRY_RUN" == "false" ]]; then
                aws rds wait db-instance-available --db-instance-identifier "$DB_INSTANCE_ID"
                DB_ENDPOINT=$(aws rds describe-db-instances --db-instance-identifier "$DB_INSTANCE_ID" --query "DBInstances[0].Endpoint.Address" --output text)
                log_success "RDS Database is now available at: ${DB_ENDPOINT}:3306"
            fi
        fi
    else
        if [[ "$DRY_RUN" == "true" ]]; then
            log_info "[DRY-RUN] Would create RDS MySQL Instance: ${DB_INSTANCE_ID} (${DB_INSTANCE_CLASS}, 20GB gp3, encrypted)"
            DB_ENDPOINT="surgegate-db.placeholder.rds.amazonaws.com"
        else
            log_info "Provisioning RDS MySQL Instance: ${DB_INSTANCE_ID}..."
            log_info "Configuration: ${DB_INSTANCE_CLASS}, ${DB_ALLOCATED_STORAGE}GB ${DB_STORAGE_TYPE}, Single-AZ (Student Budget)."
            log_info "Note: RDS provisioning takes 5-8 minutes in AWS. Please wait..."

            aws rds create-db-instance \
                --db-instance-identifier "$DB_INSTANCE_ID" \
                --db-name "$DB_NAME" \
                --engine mysql \
                --engine-version "8.0" \
                --master-username "$DB_USERNAME" \
                --master-user-password "$DB_PASSWORD" \
                --db-instance-class "$DB_INSTANCE_CLASS" \
                --allocated-storage "$DB_ALLOCATED_STORAGE" \
                --max-allocated-storage "$DB_MAX_ALLOCATED_STORAGE" \
                --storage-type "$DB_STORAGE_TYPE" \
                --storage-encrypted \
                --db-subnet-group-name "$DB_SUBNET_GROUP" \
                --vpc-security-group-ids "$RDS_SG_ID" \
                --no-publicly-accessible \
                --backup-retention-period 1 \
                --auto-minor-version-upgrade \
                --tags "Key=Project,Value=SurgeGate" "Key=Environment,Value=${ENVIRONMENT}" >/dev/null

            log_info "Waiting for RDS instance to reach 'available' state..."
            aws rds wait db-instance-available --db-instance-identifier "$DB_INSTANCE_ID"
            DB_ENDPOINT=$(aws rds describe-db-instances --db-instance-identifier "$DB_INSTANCE_ID" --query "DBInstances[0].Endpoint.Address" --output text)
            log_success "RDS Database provisioned successfully: ${DB_ENDPOINT}:3306"
        fi
    fi
fi

# ------------------------------------------------------------------------------
# 12. Application Load Balancer & Auto Scaling Group
# ------------------------------------------------------------------------------
if [[ "$ENABLE_ALB" == "true" ]]; then
    log_step "10. Application Load Balancer (ALB) Configuration"

    TG_NAME="surgegate-tg"
    ALB_NAME="surgegate-alb"

    # Target Group
    EXISTING_TG=$(aws elbv2 describe-target-groups --names "$TG_NAME" --query "TargetGroups[0].TargetGroupArn" --output text 2>/dev/null || true)
    if [[ -n "$EXISTING_TG" && "$EXISTING_TG" != "None" ]]; then
        TARGET_GROUP_ARN="$EXISTING_TG"
        log_success "Found existing Target Group: ${TARGET_GROUP_ARN}"
    else
        if [[ "$DRY_RUN" == "true" ]]; then
            log_info "[DRY-RUN] Would create Target Group: ${TG_NAME} (Port ${APP_PORT}, health check /health)"
            TARGET_GROUP_ARN="arn:aws:elasticloadbalancing:${AWS_REGION}:${ACCOUNT_ID}:targetgroup/${TG_NAME}/dryrun"
        else
            log_info "Creating Target Group: ${TG_NAME}..."
            TARGET_GROUP_ARN=$(aws elbv2 create-target-group \
                --name "$TG_NAME" \
                --protocol HTTP \
                --port "$APP_PORT" \
                --vpc-id "$VPC_ID" \
                --target-type instance \
                --health-check-protocol HTTP \
                --health-check-port "$APP_PORT" \
                --health-check-path "/health" \
                --health-check-interval-seconds 30 \
                --healthy-threshold-count 2 \
                --unhealthy-threshold-count 3 \
                --tags "Key=Project,Value=SurgeGate" "Key=Environment,Value=${ENVIRONMENT}" \
                --query "TargetGroups[0].TargetGroupArn" --output text)
            log_success "Created Target Group: ${TARGET_GROUP_ARN}"
        fi
    fi

    # Application Load Balancer
    EXISTING_ALB=$(aws elbv2 describe-load-balancers --names "$ALB_NAME" --query "LoadBalancers[0].LoadBalancerArn" --output text 2>/dev/null || true)
    if [[ -n "$EXISTING_ALB" && "$EXISTING_ALB" != "None" ]]; then
        ALB_ARN="$EXISTING_ALB"
        ALB_DNS_NAME=$(aws elbv2 describe-load-balancers --load-balancer-arns "$ALB_ARN" --query "LoadBalancers[0].DNSName" --output text)
        log_success "Found existing ALB: ${ALB_DNS_NAME}"
    else
        if [[ "$DRY_RUN" == "true" ]]; then
            log_info "[DRY-RUN] Would create Application Load Balancer across ${PUB_SUB_A_ID} and ${PUB_SUB_B_ID}"
            ALB_ARN="arn:aws:elasticloadbalancing:${AWS_REGION}:${ACCOUNT_ID}:loadbalancer/app/${ALB_NAME}/dryrun"
            ALB_DNS_NAME="surgegate-alb-dryrun.elb.amazonaws.com"
        else
            log_info "Creating Application Load Balancer: ${ALB_NAME}..."
            ALB_ARN=$(aws elbv2 create-load-balancer \
                --name "$ALB_NAME" \
                --subnets "$PUB_SUB_A_ID" "$PUB_SUB_B_ID" \
                --security-groups "$ALB_SG_ID" \
                --scheme internet-facing \
                --type application \
                --ip-address-type ipv4 \
                --tags "Key=Project,Value=SurgeGate" "Key=Environment,Value=${ENVIRONMENT}" \
                --query "LoadBalancers[0].LoadBalancerArn" --output text)
            
            log_info "Waiting for ALB to become active..."
            aws elbv2 wait load-balancer-available --load-balancer-arns "$ALB_ARN"
            ALB_DNS_NAME=$(aws elbv2 describe-load-balancers --load-balancer-arns "$ALB_ARN" --query "LoadBalancers[0].DNSName" --output text)
            log_success "ALB is active at: http://${ALB_DNS_NAME}"

            # Create HTTP Listener forwarding to Target Group
            log_info "Configuring ALB HTTP Listener on port 80..."
            aws elbv2 create-listener \
                --load-balancer-arn "$ALB_ARN" \
                --protocol HTTP \
                --port 80 \
                --default-actions Type=forward,TargetGroupArn="$TARGET_GROUP_ARN" >/dev/null
            log_success "Configured ALB port 80 listener -> Target Group."
        fi
    fi
fi

# ------------------------------------------------------------------------------
# 13. EC2 Launch Template & Auto Scaling Group
# ------------------------------------------------------------------------------
if [[ "$ENABLE_AUTOSCALING" == "true" ]]; then
    log_step "11. EC2 Launch Template & Auto Scaling Group Configuration"

    LT_NAME="surgegate-lt"
    ASG_NAME="surgegate-asg"

    # Query latest Amazon Linux 2023 AMI
    LATEST_AMI=$(aws ssm get-parameter --name "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64" --query "Parameter.Value" --output text 2>/dev/null || true)
    if [[ -z "$LATEST_AMI" || "$LATEST_AMI" == "None" ]]; then
        # Fallback to direct EC2 AMI lookup
        LATEST_AMI=$(aws ec2 describe-images --owners amazon --filters "Name=name,Values=al2023-ami-2023.*-x86_64" "Name=state,Values=available" --query "reverse(sort_by(Images, &CreationDate))[0].ImageId" --output text 2>/dev/null || true)
    fi
    log_info "Using Amazon Linux 2023 AMI: ${LATEST_AMI}"

    # Generate User Data Script
    # Provides built-in lightweight health check endpoint and application stub
    USER_DATA_CONTENT=$(cat <<EOF
#!/usr/bin/env bash
exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1
echo "Starting SurgeGate bootstrap..."
yum update -y
yum install -y python3-pip jq

# Create SurgeGate Application Directory
mkdir -p /opt/surgegate
cat << 'APP_EOF' > /opt/surgegate/server.py
import http.server
import socketserver
import json
import os

PORT = ${APP_PORT}

class SurgeGateHandler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/health' or self.path == '/':
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            response = {
                "status": "HEALTHY",
                "service": "SurgeGate Edge Node",
                "environment": "${ENVIRONMENT}",
                "sqs_queue": "${SQS_QUEUE_NAME}",
                "db_configured": bool("${DB_ENDPOINT}"),
                "message": "SurgeGate traffic management node is operational."
            }
            self.wfile.write(json.dumps(response).encode('utf-8'))
        else:
            self.send_response(404)
            self.end_headers()

with socketserver.TCPServer(("", PORT), SurgeGateHandler) as httpd:
    print(f"Serving SurgeGate on port {PORT}")
    httpd.serve_forever()
APP_EOF

# Setup systemd service
cat << 'SERVICE_EOF' > /etc/systemd/system/surgegate.service
[Unit]
Description=SurgeGate Application Node
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/surgegate
ExecStart=/usr/bin/python3 /opt/surgegate/server.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SERVICE_EOF

systemctl daemon-reload
systemctl enable --now surgegate.service
echo "SurgeGate node bootstrap completed."
EOF
)

    USER_DATA_B64=$(echo "$USER_DATA_CONTENT" | base64 | tr -d '\n')

    # Launch Template
    EXISTING_LT=$(aws ec2 describe-launch-templates --launch-template-names "$LT_NAME" --query "LaunchTemplates[0].LaunchTemplateId" --output text 2>/dev/null || true)
    if [[ -n "$EXISTING_LT" && "$EXISTING_LT" != "None" ]]; then
        LAUNCH_TEMPLATE_ID="$EXISTING_LT"
        log_success "Found existing Launch Template: ${LAUNCH_TEMPLATE_ID}"
    else
        if [[ "$DRY_RUN" == "true" ]]; then
            log_info "[DRY-RUN] Would create Launch Template ${LT_NAME} (${EC2_INSTANCE_TYPE})"
            LAUNCH_TEMPLATE_ID="lt-dryrunplaceholder"
        else
            log_info "Creating Launch Template: ${LT_NAME}..."
            LT_DATA=$(cat <<EOF
{
    "ImageId": "${LATEST_AMI}",
    "InstanceType": "${EC2_INSTANCE_TYPE}",
    "IamInstanceProfile": {"Name": "${EC2_PROFILE_NAME}"},
    "SecurityGroupIds": ["${EC2_SG_ID}"],
    "UserData": "${USER_DATA_B64}",
    "TagSpecifications": [
        {
            "ResourceType": "instance",
            "Tags": [
                {"Key": "Name", "Value": "surgegate-app-worker"},
                {"Key": "Project", "Value": "SurgeGate"},
                {"Key": "Environment", "Value": "${ENVIRONMENT}"}
            ]
        }
    ]
}
EOF
)
            LAUNCH_TEMPLATE_ID=""
            for attempt in {1..5}; do
                if LAUNCH_TEMPLATE_ID=$(aws ec2 create-launch-template \
                    --launch-template-name "$LT_NAME" \
                    --launch-template-data "$LT_DATA" \
                    --tag-specifications "ResourceType=launch-template,Tags=[{Key=Name,Value=${LT_NAME}},${TAG_SPEC}]" \
                    --query "LaunchTemplate.LaunchTemplateId" --output text 2>/dev/null); then
                    break
                else
                    log_warn "IAM Instance profile not yet visible in EC2 (attempt ${attempt}/5). Retrying in 4s..."
                    sleep 4
                fi
            done

            if [[ -z "$LAUNCH_TEMPLATE_ID" || "$LAUNCH_TEMPLATE_ID" == "None" ]]; then
                log_error "Failed to create Launch Template after multiple attempts."
                exit 1
            fi
            log_success "Created Launch Template: ${LAUNCH_TEMPLATE_ID}"
        fi
    fi

    # Auto Scaling Group
    EXISTING_ASG=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG_NAME" --query "AutoScalingGroups[0].AutoScalingGroupName" --output text 2>/dev/null || true)
    if [[ -n "$EXISTING_ASG" && "$EXISTING_ASG" != "None" ]]; then
        log_success "Found existing Auto Scaling Group: ${ASG_NAME}"
    else
        if [[ "$DRY_RUN" == "true" ]]; then
            log_info "[DRY-RUN] Would create Auto Scaling Group ${ASG_NAME} (Min: ${ASG_MIN_SIZE}, Desired: ${ASG_DESIRED_CAPACITY}, Max: ${ASG_MAX_SIZE})"
        else
            log_info "Creating Auto Scaling Group: ${ASG_NAME}..."
            # For cost safety, instances run in public subnets with public IP when NAT gateway is disabled
            SUBNET_LIST="${PUB_SUB_A_ID},${PUB_SUB_B_ID}"

            aws autoscaling create-auto-scaling-group \
                --auto-scaling-group-name "$ASG_NAME" \
                --launch-template "LaunchTemplateId=${LAUNCH_TEMPLATE_ID},Version=\$Latest" \
                --min-size "$ASG_MIN_SIZE" \
                --max-size "$ASG_MAX_SIZE" \
                --desired-capacity "$ASG_DESIRED_CAPACITY" \
                --vpc-zone-identifier "$SUBNET_LIST" \
                --target-group-arns "${TARGET_GROUP_ARN:-}" \
                --health-check-type "ELB" \
                --health-check-grace-period 180 \
                --tags "Key=Project,Value=SurgeGate,PropagateAtLaunch=true" "Key=Environment,Value=${ENVIRONMENT},PropagateAtLaunch=true" "Key=Name,Value=surgegate-app-instance,PropagateAtLaunch=true" >/dev/null

            # Target tracking scaling policy based on CPU
            aws autoscaling put-scaling-policy \
                --auto-scaling-group-name "$ASG_NAME" \
                --policy-name "surgegate-cpu-target-tracking" \
                --policy-type "TargetTrackingScaling" \
                --target-tracking-configuration "{\"TargetValue\": ${ASG_TARGET_CPU_UTILIZATION}, \"PredefinedMetricSpecification\": {\"PredefinedMetricType\": \"ASGAverageCPUUtilization\"}}" >/dev/null

            log_success "Created Auto Scaling Group and CPU Target Tracking Policy."
        fi
    fi
fi

# ------------------------------------------------------------------------------
# 14. Amazon CloudWatch Alarms
# ------------------------------------------------------------------------------
if [[ "$ENABLE_CLOUDWATCH_ALARMS" == "true" && "$DRY_RUN" == "false" ]]; then
    log_step "12. Amazon CloudWatch Alarms Configuration"

    # Alarm 1: ASG CPU Utilization High (> 75%)
    if [[ -n "$ASG_NAME" ]]; then
        aws cloudwatch put-metric-alarm \
            --alarm-name "surgegate-asg-high-cpu" \
            --alarm-description "SurgeGate ASG CPU Utilization exceeds 75%" \
            --metric-name CPUUtilization \
            --namespace AWS/EC2 \
            --statistic Average \
            --period 120 \
            --threshold 75 \
            --comparison-operator GreaterThanThreshold \
            --dimensions "Name=AutoScalingGroupName,Value=${ASG_NAME}" \
            --evaluation-periods 2 \
            --unit Percent \
            --tags "Key=Project,Value=SurgeGate" "Key=Environment,Value=${ENVIRONMENT}" >/dev/null || true
        log_success "Created CloudWatch Alarm: surgegate-asg-high-cpu"
    fi

    # Alarm 2: SQS Queue Backlog (> 50 visible messages)
    if [[ "$ENABLE_SQS" == "true" ]]; then
        aws cloudwatch put-metric-alarm \
            --alarm-name "surgegate-sqs-queue-backlog" \
            --alarm-description "SurgeGate SQS buffer exceeds 50 waiting messages" \
            --metric-name ApproximateNumberOfMessagesVisible \
            --namespace AWS/SQS \
            --statistic Average \
            --period 60 \
            --threshold 50 \
            --comparison-operator GreaterThanThreshold \
            --dimensions "Name=QueueName,Value=${SQS_QUEUE_NAME}" \
            --evaluation-periods 1 \
            --tags "Key=Project,Value=SurgeGate" "Key=Environment,Value=${ENVIRONMENT}" >/dev/null || true
        log_success "Created CloudWatch Alarm: surgegate-sqs-queue-backlog"
    fi

    # Alarm 3: RDS High CPU (> 80%)
    if [[ "$ENABLE_RDS" == "true" ]]; then
        aws cloudwatch put-metric-alarm \
            --alarm-name "surgegate-rds-high-cpu" \
            --alarm-description "SurgeGate RDS MySQL CPU utilization exceeds 80%" \
            --metric-name CPUUtilization \
            --namespace AWS/RDS \
            --statistic Average \
            --period 300 \
            --threshold 80 \
            --comparison-operator GreaterThanThreshold \
            --dimensions "Name=DBInstanceIdentifier,Value=surgegate-db" \
            --evaluation-periods 2 \
            --unit Percent \
            --tags "Key=Project,Value=SurgeGate" "Key=Environment,Value=${ENVIRONMENT}" >/dev/null || true
        log_success "Created CloudWatch Alarm: surgegate-rds-high-cpu"
    fi
fi

# ------------------------------------------------------------------------------
# 15. AWS Systems Manager Parameter Store Configuration
# ------------------------------------------------------------------------------
log_step "13. AWS Systems Manager Parameter Store Configuration"
SSM_PREFIX="/surgegate/${ENVIRONMENT}"
if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY-RUN] Would store infrastructure outputs and secrets in SSM Parameter Store under ${SSM_PREFIX}/*"
else
    log_info "Storing infrastructure outputs and secrets in SSM Parameter Store..."
    put_ssm_param() {
        local param_key="$1"
        local param_val="$2"
        local param_type="${3:-String}"
        if [[ -n "$param_val" && "$param_val" != "None" ]]; then
            aws ssm put-parameter \
                --name "${SSM_PREFIX}/${param_key}" \
                --value "$param_val" \
                --type "$param_type" \
                --overwrite \
                --tags "Key=Project,Value=SurgeGate" "Key=Environment,Value=${ENVIRONMENT}" >/dev/null 2>&1 || true
        fi
    }

    put_ssm_param "vpc_id" "$VPC_ID"
    put_ssm_param "public_subnet_1" "$PUB_SUB_A_ID"
    put_ssm_param "public_subnet_2" "$PUB_SUB_B_ID"
    put_ssm_param "private_subnet_1" "$PRIV_SUB_A_ID"
    put_ssm_param "private_subnet_2" "$PRIV_SUB_B_ID"
    put_ssm_param "alb_arn" "$ALB_ARN"
    put_ssm_param "alb_dns_name" "$ALB_DNS_NAME"
    put_ssm_param "alb_endpoint" "http://${ALB_DNS_NAME}"
    put_ssm_param "target_group_arn" "$TARGET_GROUP_ARN"
    put_ssm_param "ec2_security_group" "$EC2_SG_ID"
    put_ssm_param "rds_security_group" "$RDS_SG_ID"
    put_ssm_param "db_host" "$DB_ENDPOINT"
    put_ssm_param "db_port" "3306"
    put_ssm_param "db_name" "$DB_NAME"
    put_ssm_param "db_user" "$DB_USERNAME"
    if [[ -n "${DB_PASSWORD:-}" && "$DB_PASSWORD" != "[DRY-RUN-MASKED-PASSWORD]" ]]; then
        put_ssm_param "db_password" "$DB_PASSWORD" "SecureString"
    fi
    put_ssm_param "s3_bucket" "$S3_BUCKET"
    put_ssm_param "sqs_url" "$SQS_QUEUE_URL"
    put_ssm_param "sqs_dlq_url" "$SQS_DLQ_URL"
    put_ssm_param "lambda_arn" "$LAMBDA_ARN"
    put_ssm_param "asg_name" "$ASG_NAME"
    log_success "Stored all infrastructure parameters securely in SSM Parameter Store under ${SSM_PREFIX}/*"
fi

# ------------------------------------------------------------------------------
# 16. Save Deployment Outputs
# ------------------------------------------------------------------------------
log_step "14. Saving Deployment Outputs"

if [[ "$DRY_RUN" == "false" ]]; then
    cat <<EOF > "$OUTPUTS_JSON"
{
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "account_id": "${ACCOUNT_ID}",
  "region": "${AWS_REGION}",
  "project_name": "${PROJECT_NAME}",
  "environment": "${ENVIRONMENT}",
  "vpc_id": "${VPC_ID}",
  "internet_gateway_id": "${IGW_ID}",
  "public_subnet_1": "${PUB_SUB_A_ID}",
  "public_subnet_2": "${PUB_SUB_B_ID}",
  "private_subnet_1": "${PRIV_SUB_A_ID}",
  "private_subnet_2": "${PRIV_SUB_B_ID}",
  "alb_security_group": "${ALB_SG_ID}",
  "ec2_security_group": "${EC2_SG_ID}",
  "rds_security_group": "${RDS_SG_ID}",
  "lambda_security_group": "${LAMBDA_SG_ID}",
  "s3_bucket": "${S3_BUCKET}",
  "sqs_queue_url": "${SQS_QUEUE_URL}",
  "sqs_queue_arn": "${SQS_QUEUE_ARN}",
  "sqs_dlq_url": "${SQS_DLQ_URL}",
  "sqs_dlq_arn": "${SQS_DLQ_ARN}",
  "sns_topic_arn": "${SNS_TOPIC_ARN}",
  "ec2_role_arn": "${EC2_ROLE_ARN}",
  "ec2_instance_profile": "${EC2_PROFILE_NAME}",
  "lambda_role_arn": "${LAMBDA_ROLE_ARN}",
  "lambda_function_arn": "${LAMBDA_ARN}",
  "db_instance_identifier": "$([ "$ENABLE_RDS" = "true" ] && echo "surgegate-db" || echo "")",
  "db_endpoint": "${DB_ENDPOINT}",
  "db_port": 3306,
  "db_name": "${DB_NAME}",
  "db_user": "${DB_USERNAME}",
  "target_group_arn": "${TARGET_GROUP_ARN}",
  "alb_arn": "${ALB_ARN}",
  "alb_dns_name": "${ALB_DNS_NAME}",
  "launch_template_id": "${LAUNCH_TEMPLATE_ID}",
  "asg_name": "${ASG_NAME}"
}
EOF

    cat <<EOF > "$OUTPUTS_ENV"
# SurgeGate Deployed Infrastructure Endpoints
SURGEGATE_VPC_ID=${VPC_ID}
SURGEGATE_ALB_ENDPOINT=http://${ALB_DNS_NAME}
SURGEGATE_DB_HOST=${DB_ENDPOINT}
SURGEGATE_DB_PORT=3306
SURGEGATE_DB_NAME=${DB_NAME}
SURGEGATE_DB_USER=${DB_USERNAME}
SURGEGATE_SQS_URL=${SQS_QUEUE_URL}
SURGEGATE_SQS_DLQ_URL=${SQS_DLQ_URL}
SURGEGATE_S3_BUCKET=${S3_BUCKET}
SURGEGATE_LAMBDA_ARN=${LAMBDA_ARN}
SURGEGATE_SNS_ARN=${SNS_TOPIC_ARN}
EOF
    log_success "Saved JSON metadata to: ${OUTPUTS_JSON}"
    log_success "Saved environment variables to: ${OUTPUTS_ENV}"
fi

# ------------------------------------------------------------------------------
# 16. Final Summary
# ------------------------------------------------------------------------------
echo ""
echo -e "${BOLD}${GREEN}=============================================================================="
if [[ "$DRY_RUN" == "true" ]]; then
    echo "          SurgeGate DRY-RUN Completed Successfully! No changes made.         "
else
    echo "          SurgeGate Infrastructure Provisioned Successfully!                 "
fi
echo "=============================================================================="
echo -e "${NC}"

if [[ "$DRY_RUN" == "false" ]]; then
    echo -e "${BOLD}Resource Summary:${NC}"
    echo -e " • Application Load Balancer: ${CYAN}http://${ALB_DNS_NAME}${NC}"
    echo -e " • VPC ID:                    ${CYAN}${VPC_ID}${NC}"
    echo -e " • RDS MySQL Endpoint:        ${CYAN}${DB_ENDPOINT}:3306${NC}"
    echo -e " • S3 Ticket Bucket:          ${CYAN}s3://${S3_BUCKET}${NC}"
    echo -e " • SQS Ticket Buffer:         ${CYAN}${SQS_QUEUE_URL}${NC}"
    echo -e " • SQS Dead Letter Queue:     ${CYAN}${SQS_DLQ_URL}${NC}"
    echo -e " • Lambda Worker:             ${CYAN}${LAMBDA_ARN}${NC}"
    echo -e " • Auto Scaling Group:        ${CYAN}${ASG_NAME}${NC}"
    echo ""
    echo -e "${BOLD}Next Steps:${NC}"
    echo -e " 1. Run ${CYAN}./verify.sh${NC} to run comprehensive health and security checks."
    echo -e " 2. Connect your application by sourcing ${CYAN}deployment-outputs.env${NC}."
    echo -e " 3. Populate initial database schema with: ${CYAN}mysql -h ${DB_ENDPOINT} -u ${DB_USERNAME} -p ${DB_NAME} < schema/schema.sql${NC}."
fi
echo ""
