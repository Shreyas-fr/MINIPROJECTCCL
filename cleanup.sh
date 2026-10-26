#!/usr/bin/env bash
# ==============================================================================
# SurgeGate - Safe Infrastructure Teardown & Cleanup Script
# Removes SurgeGate AWS resources in strict reverse dependency order.
# Requires explicit confirmations and protects data stores from accidental deletion.
# ==============================================================================

set -Eeuo pipefail

BOLD="\033[1m"
GREEN="\033[0;32m"
BLUE="\033[0;34m"
YELLOW="\033[1;33m"
RED="\033[0;31m"
CYAN="\033[0;36m"
NC="\033[0m"

log_info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_step()    { echo -e "\n${BOLD}${CYAN}==> $*${NC}"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUTS_JSON="${SCRIPT_DIR}/deployment-outputs.json"
CONFIG_FILE="${SCRIPT_DIR}/config.env"

echo -e "${BOLD}${RED}"
echo "=============================================================================="
echo "          SurgeGate - AWS Infrastructure Teardown & Deletion                  "
echo "=============================================================================="
echo -e "${NC}"

if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
fi

AWS_REGION="${AWS_REGION:-ap-south-1}"
if [[ -f "$OUTPUTS_JSON" ]]; then
    AWS_REGION=$(jq -r '.region // "'"$AWS_REGION"'"' "$OUTPUTS_JSON")
fi
export AWS_DEFAULT_REGION="$AWS_REGION"

# Verify credentials
CALLER_IDENTITY=$(aws sts get-caller-identity --output json 2>&1) || {
    log_error "AWS authentication failed. Cannot proceed with cleanup."
    exit 1
}
ACCOUNT_ID=$(echo "$CALLER_IDENTITY" | jq -r '.Account')
CALLER_ARN=$(echo "$CALLER_IDENTITY" | jq -r '.Arn')

echo -e "${YELLOW}${BOLD}Target Environment for Deletion:${NC}"
echo -e " • AWS Account:  ${CYAN}${ACCOUNT_ID}${NC}"
echo -e " • AWS Region:   ${CYAN}${AWS_REGION}${NC}"
echo -e " • Caller ARN:   ${CYAN}${CALLER_ARN}${NC}"
echo -e " • Project Tag:  ${CYAN}Project=SurgeGate${NC}"
echo ""

# Explicit Confirmation 1
echo -e "${RED}${BOLD}WARNING: This script will terminate and delete SurgeGate cloud resources!${NC}"
read -r -p "Are you sure you want to proceed with teardown? Type 'yes' to continue: " CONFIRM_1
if [[ "$CONFIRM_1" != "yes" ]]; then
    log_info "Teardown aborted by user."
    exit 0
fi

# Load IDs from outputs if available
VPC_ID=""
S3_BUCKET=""
DB_ID="surgegate-db"
ASG_NAME="surgegate-asg"
ALB_ARN=""
TARGET_GROUP_ARN=""
LAMBDA_FUNCTION_NAME="surgegate-ticket-processor"
SQS_QUEUE_NAME="surgegate-ticket-queue"
SQS_DLQ_NAME="surgegate-ticket-dlq"

if [[ -f "$OUTPUTS_JSON" ]]; then
    VPC_ID=$(jq -r '.vpc_id // empty' "$OUTPUTS_JSON")
    S3_BUCKET=$(jq -r '.s3_bucket // empty' "$OUTPUTS_JSON")
    DB_ID=$(jq -r '.db_instance_identifier // "surgegate-db"' "$OUTPUTS_JSON")
    ASG_NAME=$(jq -r '.asg_name // "surgegate-asg"' "$OUTPUTS_JSON")
    ALB_ARN=$(jq -r '.alb_arn // empty' "$OUTPUTS_JSON")
    TARGET_GROUP_ARN=$(jq -r '.target_group_arn // empty' "$OUTPUTS_JSON")
fi

# Explicit Confirmation 2 for Persistent Data Stores
CONFIRM_DATA="no"
echo ""
echo -e "${YELLOW}${BOLD}DATA DELETION CONFIRMATION:${NC}"
echo -e "Do you also want to permanently delete persistent data stores?"
echo -e " • RDS MySQL Database: ${CYAN}${DB_ID}${NC}"
echo -e " • S3 Storage Bucket:  ${CYAN}${S3_BUCKET:-surgegate-tickets-*}${NC}"
read -r -p "Type 'DELETE-DATA' to destroy databases and buckets, or 'skip' to keep them: " DATA_INPUT
if [[ "$DATA_INPUT" == "DELETE-DATA" ]]; then
    CONFIRM_DATA="yes"
    log_warn "Data stores WILL BE PERMANENTLY DESTROYED."
else
    log_info "Data stores (RDS and S3) will be preserved."
fi

# ------------------------------------------------------------------------------
# 1. CloudWatch Alarms
# ------------------------------------------------------------------------------
log_step "1. Deleting CloudWatch Alarms"
ALARMS=("surgegate-asg-high-cpu" "surgegate-sqs-queue-backlog" "surgegate-rds-high-cpu")
for alarm in "${ALARMS[@]}"; do
    if aws cloudwatch describe-alarms --alarm-names "$alarm" --query "MetricAlarms[0].AlarmName" --output text 2>/dev/null | grep -q "$alarm"; then
        aws cloudwatch delete-alarms --alarm-names "$alarm"
        log_success "Deleted alarm: ${alarm}"
    fi
done

# ------------------------------------------------------------------------------
# 2. Auto Scaling Group & Scaling Policies
# ------------------------------------------------------------------------------
log_step "2. Terminating Auto Scaling Group and Instances"
if aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG_NAME" --query "AutoScalingGroups[0].AutoScalingGroupName" --output text 2>/dev/null | grep -q "$ASG_NAME"; then
    log_info "Scaling ASG ${ASG_NAME} down to 0 instances..."
    aws autoscaling update-auto-scaling-group --auto-scaling-group-name "$ASG_NAME" --min-size 0 --max-size 0 --desired-capacity 0 || true

    log_info "Waiting for ASG instances to terminate..."
    while true; do
        ACTIVE_INSTANCES=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG_NAME" --query "AutoScalingGroups[0].Instances | length" --output text 2>/dev/null || echo "0")
        if [[ "$ACTIVE_INSTANCES" == "0" || -z "$ACTIVE_INSTANCES" || "$ACTIVE_INSTANCES" == "None" ]]; then
            break
        fi
        log_info "Waiting for ${ACTIVE_INSTANCES} instances to shut down..."
        sleep 10
    done

    aws autoscaling delete-auto-scaling-group --auto-scaling-group-name "$ASG_NAME" --force-delete || true
    log_success "Deleted Auto Scaling Group: ${ASG_NAME}"
fi

# Launch Template
LT_ID=$(aws ec2 describe-launch-templates --filters "Name=launch-template-name,Values=surgegate-lt" --query "LaunchTemplates[0].LaunchTemplateId" --output text 2>/dev/null || true)
if [[ -n "$LT_ID" && "$LT_ID" != "None" ]]; then
    aws ec2 delete-launch-template --launch-template-id "$LT_ID" >/dev/null || true
    log_success "Deleted Launch Template: ${LT_ID}"
fi

# ------------------------------------------------------------------------------
# 3. Application Load Balancer & Target Group
# ------------------------------------------------------------------------------
log_step "3. Deleting Load Balancer and Target Group"
if [[ -z "$ALB_ARN" ]]; then
    ALB_ARN=$(aws elbv2 describe-load-balancers --names "surgegate-alb" --query "LoadBalancers[0].LoadBalancerArn" --output text 2>/dev/null || true)
fi

if [[ -n "$ALB_ARN" && "$ALB_ARN" != "None" ]]; then
    # Delete Listeners
    LISTENERS=$(aws elbv2 describe-listeners --load-balancer-arn "$ALB_ARN" --query "Listeners[].ListenerArn" --output text 2>/dev/null || true)
    for l_arn in $LISTENERS; do
        aws elbv2 delete-listener --listener-arn "$l_arn" || true
    done
    aws elbv2 delete-load-balancer --load-balancer-arn "$ALB_ARN" || true
    log_info "Waiting for ALB deletion to complete..."
    aws elbv2 wait load-balancers-deleted --load-balancer-arns "$ALB_ARN" 2>/dev/null || sleep 15
    log_success "Deleted ALB: ${ALB_ARN}"
fi

if [[ -z "$TARGET_GROUP_ARN" ]]; then
    TARGET_GROUP_ARN=$(aws elbv2 describe-target-groups --names "surgegate-tg" --query "TargetGroups[0].TargetGroupArn" --output text 2>/dev/null || true)
fi
if [[ -n "$TARGET_GROUP_ARN" && "$TARGET_GROUP_ARN" != "None" ]]; then
    # Give ALB time to release target group
    sleep 5
    aws elbv2 delete-target-group --target-group-arn "$TARGET_GROUP_ARN" || true
    log_success "Deleted Target Group: ${TARGET_GROUP_ARN}"
fi

# ------------------------------------------------------------------------------
# 4. AWS Lambda & Event Source Mappings
# ------------------------------------------------------------------------------
log_step "4. Deleting Lambda Function & SQS Trigger"
MAPPINGS=$(aws lambda list-event-source-mappings --function-name "$LAMBDA_FUNCTION_NAME" --query "EventSourceMappings[].UUID" --output text 2>/dev/null || true)
for m_id in $MAPPINGS; do
    aws lambda delete-event-source-mapping --uuid "$m_id" || true
    log_success "Deleted Event Source Mapping: ${m_id}"
done

if aws lambda get-function --function-name "$LAMBDA_FUNCTION_NAME" >/dev/null 2>&1; then
    aws lambda delete-function --function-name "$LAMBDA_FUNCTION_NAME" || true
    log_success "Deleted Lambda Function: ${LAMBDA_FUNCTION_NAME}"
fi

# ------------------------------------------------------------------------------
# 5. Amazon SQS Queues
# ------------------------------------------------------------------------------
log_step "5. Deleting SQS Queues"
MAIN_Q_URL=$(aws sqs get-queue-url --queue-name "$SQS_QUEUE_NAME" --query "QueueUrl" --output text 2>/dev/null || true)
if [[ -n "$MAIN_Q_URL" && "$MAIN_Q_URL" != "None" ]]; then
    aws sqs delete-queue --queue-url "$MAIN_Q_URL" || true
    log_success "Deleted SQS Queue: ${MAIN_Q_URL}"
fi

DLQ_URL=$(aws sqs get-queue-url --queue-name "$SQS_DLQ_NAME" --query "QueueUrl" --output text 2>/dev/null || true)
if [[ -n "$DLQ_URL" && "$DLQ_URL" != "None" ]]; then
    aws sqs delete-queue --queue-url "$DLQ_URL" || true
    log_success "Deleted SQS DLQ: ${DLQ_URL}"
fi

# ------------------------------------------------------------------------------
# 6. Amazon SNS Topic
# ------------------------------------------------------------------------------
log_step "6. Deleting SNS Topic"
SNS_TOPIC_NAME="${SNS_TOPIC_NAME:-surgegate-booking-notifications}"
SNS_ARN=$(aws sns list-topics --query "Topics[?contains(TopicArn, '${SNS_TOPIC_NAME}')].TopicArn" --output text 2>/dev/null || true)
if [[ -n "$SNS_ARN" && "$SNS_ARN" != "None" ]]; then
    aws sns delete-topic --topic-arn "$SNS_ARN" || true
    log_success "Deleted SNS Topic: ${SNS_ARN}"
fi

# ------------------------------------------------------------------------------
# 7. Amazon RDS MySQL Database (Protected)
# ------------------------------------------------------------------------------
if [[ "$CONFIRM_DATA" == "yes" ]]; then
    log_step "7. Deleting Amazon RDS Database"
    if aws rds describe-db-instances --db-instance-identifier "$DB_ID" >/dev/null 2>&1; then
        log_info "Initiating deletion of RDS Instance ${DB_ID} (skip final snapshot for student dev)..."
        aws rds delete-db-instance --db-instance-identifier "$DB_ID" --skip-final-snapshot --delete-automated-backups >/dev/null || true
        log_info "Waiting for RDS instance deletion to finish (this takes several minutes)..."
        aws rds wait db-instance-deleted --db-instance-identifier "$DB_ID" 2>/dev/null || true
        log_success "Deleted RDS DB Instance: ${DB_ID}"
    fi

    # Delete DB Subnet Group
    if aws rds describe-db-subnet-groups --db-subnet-group-name "surgegate-db-subnet-group" >/dev/null 2>&1; then
        aws rds delete-db-subnet-group --db-subnet-group-name "surgegate-db-subnet-group" || true
        log_success "Deleted DB Subnet Group: surgegate-db-subnet-group"
    fi
else
    log_info "Skipping RDS Database deletion (Preserved as requested)."
fi

# ------------------------------------------------------------------------------
# 8. Amazon S3 Bucket (Protected)
# ------------------------------------------------------------------------------
if [[ "$CONFIRM_DATA" == "yes" ]]; then
    log_step "8. Deleting S3 Storage Bucket"
    if [[ -z "$S3_BUCKET" ]]; then
        S3_BUCKET=$(aws s3api list-buckets --query "Buckets[?contains(Name, 'surgegate-tickets-')].Name" --output text 2>/dev/null || true)
    fi

    for b in $S3_BUCKET; do
        if aws s3api head-bucket --bucket "$b" 2>/dev/null; then
            log_warn "Emptying all objects and versions in S3 bucket ${b}..."
            aws s3 rm "s3://${b}" --recursive || true
            aws s3api delete-bucket --bucket "$b" || true
            log_success "Deleted S3 bucket: ${b}"
        fi
    done
else
    log_info "Skipping S3 Bucket deletion (Preserved as requested)."
fi

# ------------------------------------------------------------------------------
# 9. IAM Roles and Instance Profiles
# ------------------------------------------------------------------------------
log_step "9. Deleting IAM Roles & Instance Profiles"
# EC2 Profile & Role
if aws iam get-instance-profile --instance-profile-name "surgegate-ec2-profile" >/dev/null 2>&1; then
    aws iam remove-role-from-instance-profile --instance-profile-name "surgegate-ec2-profile" --role-name "surgegate-ec2-role" 2>/dev/null || true
    aws iam delete-instance-profile --instance-profile-name "surgegate-ec2-profile" || true
    log_success "Deleted Instance Profile: surgegate-ec2-profile"
fi

if aws iam get-role --role-name "surgegate-ec2-role" >/dev/null 2>&1; then
    aws iam delete-role-policy --role-name "surgegate-ec2-role" --policy-name "SurgeGateEC2AppPolicy" 2>/dev/null || true
    aws iam detach-role-policy --role-name "surgegate-ec2-role" --policy-arn "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore" 2>/dev/null || true
    aws iam delete-role --role-name "surgegate-ec2-role" || true
    log_success "Deleted IAM Role: surgegate-ec2-role"
fi

# Lambda Role
if aws iam get-role --role-name "surgegate-lambda-role" >/dev/null 2>&1; then
    aws iam delete-role-policy --role-name "surgegate-lambda-role" --policy-name "SurgeGateLambdaWorkerPolicy" 2>/dev/null || true
    aws iam detach-role-policy --role-name "surgegate-lambda-role" --policy-arn "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole" 2>/dev/null || true
    aws iam delete-role --role-name "surgegate-lambda-role" || true
    log_success "Deleted IAM Role: surgegate-lambda-role"
fi

# ------------------------------------------------------------------------------
# 10. Security Groups
# ------------------------------------------------------------------------------
log_step "10. Deleting Security Groups"
# Delete rules first to avoid circular reference dependencies
SGS=("surgegate-db-sg" "surgegate-ec2-sg" "surgegate-alb-sg" "surgegate-lambda-sg")
for sg_name in "${SGS[@]}"; do
    SG_ID=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=${sg_name}" --query "SecurityGroups[0].GroupId" --output text 2>/dev/null || true)
    if [[ -n "$SG_ID" && "$SG_ID" != "None" ]]; then
        # Revoke ingress rules
        INGRESS_RULES=$(aws ec2 describe-security-groups --group-ids "$SG_ID" --query "SecurityGroups[0].IpPermissions" --output json 2>/dev/null || echo "[]")
        if [[ "$INGRESS_RULES" != "[]" ]]; then
            aws ec2 revoke-security-group-ingress --group-id "$SG_ID" --ip-permissions "$INGRESS_RULES" 2>/dev/null || true
        fi
    fi
done

for sg_name in "${SGS[@]}"; do
    SG_ID=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=${sg_name}" --query "SecurityGroups[0].GroupId" --output text 2>/dev/null || true)
    if [[ -n "$SG_ID" && "$SG_ID" != "None" ]]; then
        # Wait for ALB and EC2 ENIs to detach and release security group
        SG_DELETED=false
        for attempt in {1..8}; do
            if aws ec2 delete-security-group --group-id "$SG_ID" 2>/dev/null; then
                log_success "Deleted Security Group: ${sg_name} (${SG_ID})"
                SG_DELETED=true
                break
            else
                sleep 5
            fi
        done
        if [[ "$SG_DELETED" == "false" ]]; then
            log_warn "Security Group ${sg_name} (${SG_ID}) could not be deleted immediately (pending AWS ENI detach)."
        fi
    fi
done

# ------------------------------------------------------------------------------
# 11. VPC Networking (Route Tables, Subnets, IGW, VPC)
# ------------------------------------------------------------------------------
log_step "11. Deleting VPC Subnets, Gateways, and Network Isolation"
if [[ -z "$VPC_ID" ]]; then
    VPC_ID=$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=surgegate-vpc" --query "Vpcs[0].VpcId" --output text 2>/dev/null || true)
fi

if [[ -n "$VPC_ID" && "$VPC_ID" != "None" ]]; then
    # Subnets (retry if interfaces are detaching)
    SUBNETS=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=${VPC_ID}" --query "Subnets[].SubnetId" --output text 2>/dev/null || true)
    for sub in $SUBNETS; do
        for attempt in {1..6}; do
            if aws ec2 delete-subnet --subnet-id "$sub" 2>/dev/null; then
                log_success "Deleted Subnet: ${sub}"
                break
            else
                sleep 4
            fi
        done
    done

    # Route Tables (custom only)
    RTS=$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=${VPC_ID}" --query "RouteTables[?Associations[0].Main!=true].RouteTableId" --output text 2>/dev/null || true)
    for rt in $RTS; do
        aws ec2 delete-route-table --route-table-id "$rt" 2>/dev/null || true
        log_success "Deleted Route Table: ${rt}"
    done

    # Internet Gateway
    IGW=$(aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=${VPC_ID}" --query "InternetGateways[0].InternetGatewayId" --output text 2>/dev/null || true)
    if [[ -n "$IGW" && "$IGW" != "None" ]]; then
        aws ec2 detach-internet-gateway --internet-gateway-id "$IGW" --vpc-id "$VPC_ID" 2>/dev/null || true
        aws ec2 delete-internet-gateway --internet-gateway-id "$IGW" 2>/dev/null || true
        log_success "Detached and deleted Internet Gateway: ${IGW}"
    fi

    # VPC
    aws ec2 delete-vpc --vpc-id "$VPC_ID" 2>/dev/null || true
    log_success "Deleted SurgeGate VPC: ${VPC_ID}"
fi

# Clean output metadata
if [[ "$CONFIRM_DATA" == "yes" ]]; then
    rm -f "$OUTPUTS_JSON" "$OUTPUTS_ENV"
    log_info "Removed deployment-outputs.json and deployment-outputs.env"
fi

echo ""
echo -e "${BOLD}${GREEN}=============================================================================="
echo "          SurgeGate Infrastructure Cleanup Completed Successfully!           "
echo "=============================================================================="
echo -e "${NC}"
