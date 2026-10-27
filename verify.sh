#!/usr/bin/env bash
# ==============================================================================
# SurgeGate - Infrastructure Verification and Health Check Script
# Validates actual AWS resource states, security postures, and health metrics.
# ==============================================================================

set -Eeuo pipefail

BOLD="\033[1m"
GREEN="\033[0;32m"
RED="\033[0;31m"
YELLOW="\033[1;33m"
CYAN="\033[0;36m"
NC="\033[0m"

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

print_pass()    { echo -e "  [ ${GREEN}PASS${NC} ] $*"; ((PASS_COUNT++)); }
print_fail()    { echo -e "  [ ${RED}FAIL${NC} ] $*"; ((FAIL_COUNT++)); }
print_skipped() { echo -e "  [ ${YELLOW}SKIP${NC} ] $*"; ((SKIP_COUNT++)); }
section()       { echo -e "\n${BOLD}${CYAN}==> $*${NC}"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUTS_JSON="${SCRIPT_DIR}/deployment-outputs.json"
CONFIG_FILE="${SCRIPT_DIR}/config.env"

echo -e "${BOLD}${CYAN}"
echo "=============================================================================="
echo "          SurgeGate - AWS Infrastructure Verification & Audit                 "
echo "=============================================================================="
echo -e "${NC}"

if [[ ! -f "$OUTPUTS_JSON" ]]; then
    echo -e "${RED}[ERROR]${NC} deployment-outputs.json not found!"
    echo "Please run './deploy.sh' first to generate resource identifiers."
    exit 1
fi

if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
fi

# Check for jq or python fallback
if ! command -v jq >/dev/null 2>&1; then
    PYTHON_BIN=""
    if command -v python3 >/dev/null 2>&1; then
        PYTHON_BIN="python3"
    elif command -v python >/dev/null 2>&1; then
        PYTHON_BIN="python"
    fi
    if [[ -n "$PYTHON_BIN" ]]; then
        jq() {
            "$PYTHON_BIN" -c "
import sys, json
args = sys.argv[1:]
query = ''
inp_file = None
for a in args:
    if a.startswith('.'):
        query = a
    elif not a.startswith('-'):
        inp_file = a

try:
    data = json.load(open(inp_file)) if inp_file else json.load(sys.stdin)
except:
    data = {}

clean_key = query.strip('.').split('//')[0].strip()
val = data.get(clean_key, '') if isinstance(data, dict) else ''
print(val if val is not None else '')
" "$@"
        }
    fi
fi

AWS_REGION=$(jq -r '.region // "ap-south-1"' "$OUTPUTS_JSON" 2>/dev/null || echo "ap-south-1")
export AWS_DEFAULT_REGION="$AWS_REGION"

# Verify AWS CLI connectivity
section "1. AWS CLI & Caller Identity"
CALLER_IDENTITY=$(aws sts get-caller-identity --output json 2>&1 || true)
if echo "$CALLER_IDENTITY" | grep -q "Arn"; then
    ACCOUNT_ID=$(echo "$CALLER_IDENTITY" | jq -r '.Account')
    print_pass "Authenticated AWS Caller: Account ${ACCOUNT_ID} in ${AWS_REGION}"
else
    print_fail "Failed to verify AWS identity with STS. Credentials may be invalid or expired."
    exit 1
fi

# ------------------------------------------------------------------------------
# 2. VPC & Networking Audit
# ------------------------------------------------------------------------------
section "2. Amazon VPC & Network Architecture"
VPC_ID=$(jq -r '.vpc_id // empty' "$OUTPUTS_JSON")
if [[ -n "$VPC_ID" ]]; then
    VPC_STATE=$(aws ec2 describe-vpcs --vpc-ids "$VPC_ID" --query "Vpcs[0].State" --output text 2>/dev/null || true)
    if [[ "$VPC_STATE" == "available" ]]; then
        print_pass "VPC ${VPC_ID} is in available state."
    else
        print_fail "VPC ${VPC_ID} state is '${VPC_STATE}' (expected 'available')."
    fi

    # Subnets verification
    PUB_SUB_1=$(jq -r '.public_subnet_1 // empty' "$OUTPUTS_JSON")
    PUB_SUB_2=$(jq -r '.public_subnet_2 // empty' "$OUTPUTS_JSON")
    PRIV_SUB_1=$(jq -r '.private_subnet_1 // empty' "$OUTPUTS_JSON")
    PRIV_SUB_2=$(jq -r '.private_subnet_2 // empty' "$OUTPUTS_JSON")

    for sub in "$PUB_SUB_1" "$PUB_SUB_2" "$PRIV_SUB_1" "$PRIV_SUB_2"; do
        if [[ -n "$sub" ]]; then
            SUB_STATE=$(aws ec2 describe-subnets --subnet-ids "$sub" --query "Subnets[0].State" --output text 2>/dev/null || true)
            AZ=$(aws ec2 describe-subnets --subnet-ids "$sub" --query "Subnets[0].AvailabilityZone" --output text 2>/dev/null || true)
            if [[ "$SUB_STATE" == "available" ]]; then
                print_pass "Subnet ${sub} (${AZ}) is available."
            else
                print_fail "Subnet ${sub} is in state '${SUB_STATE}'."
            fi
        fi
    done
else
    print_fail "VPC ID missing in deployment-outputs.json."
fi

# ------------------------------------------------------------------------------
# 3. Security Groups & Port Exposure Audit
# ------------------------------------------------------------------------------
section "3. Security Groups & Ingress Rule Posture"
RDS_SG=$(jq -r '.rds_security_group // empty' "$OUTPUTS_JSON")
EC2_SG=$(jq -r '.ec2_security_group // empty' "$OUTPUTS_JSON")

if [[ -n "$RDS_SG" ]]; then
    # Verify RDS does NOT allow 0.0.0.0/0 on port 3306
    OPEN_RDS=$(aws ec2 describe-security-groups --group-ids "$RDS_SG" \
        --filters "Name=ip-permission.from-port,Values=3306" "Name=ip-permission.cidr,Values=0.0.0.0/0" \
        --query "SecurityGroups[0].GroupId" --output text 2>/dev/null || true)
    if [[ -z "$OPEN_RDS" || "$OPEN_RDS" == "None" ]]; then
        print_pass "RDS Security Group (${RDS_SG}) strictly isolates port 3306 (NOT exposed to 0.0.0.0/0)."
    else
        print_fail "SECURITY VULNERABILITY: RDS Security Group (${RDS_SG}) exposes port 3306 to 0.0.0.0/0!"
    fi
fi

if [[ -n "$EC2_SG" ]]; then
    # Verify SSH port 22 is NOT exposed to 0.0.0.0/0
    OPEN_SSH=$(aws ec2 describe-security-groups --group-ids "$EC2_SG" \
        --filters "Name=ip-permission.from-port,Values=22" "Name=ip-permission.cidr,Values=0.0.0.0/0" \
        --query "SecurityGroups[0].GroupId" --output text 2>/dev/null || true)
    if [[ -z "$OPEN_SSH" || "$OPEN_SSH" == "None" ]]; then
        print_pass "EC2 Security Group (${EC2_SG}) does NOT expose SSH port 22 to 0.0.0.0/0 (Uses SSM Session Manager)."
    else
        print_fail "SECURITY VULNERABILITY: EC2 Security Group (${EC2_SG}) exposes SSH port 22 to 0.0.0.0/0!"
    fi
fi

# ------------------------------------------------------------------------------
# 4. Amazon S3 Storage & Security
# ------------------------------------------------------------------------------
section "4. Amazon S3 Ticket Storage"
S3_BUCKET=$(jq -r '.s3_bucket // empty' "$OUTPUTS_JSON")
if [[ -n "$S3_BUCKET" ]]; then
    # Bucket accessibility
    if aws s3api head-bucket --bucket "$S3_BUCKET" 2>/dev/null; then
        print_pass "S3 Bucket ${S3_BUCKET} is reachable and accessible."
    else
        print_fail "Cannot access S3 Bucket ${S3_BUCKET}."
    fi

    # Public Access Block Check
    PAB=$(aws s3api get-public-access-block --bucket "$S3_BUCKET" --query "PublicAccessBlockConfiguration.BlockPublicAcls" --output text 2>/dev/null || true)
    if [[ "$PAB" == "True" || "$PAB" == "true" ]]; then
        print_pass "S3 Public Access Block is enabled."
    else
        print_fail "S3 Public Access Block is disabled on ${S3_BUCKET}!"
    fi

    # Encryption Check
    ENC=$(aws s3api get-bucket-encryption --bucket "$S3_BUCKET" --query "ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.SSEAlgorithm" --output text 2>/dev/null || true)
    if [[ "$ENC" == "AES256" || "$ENC" == "aws:kms" ]]; then
        print_pass "S3 Server-Side Encryption is active (${ENC})."
    else
        print_fail "S3 Server-Side Encryption not configured properly (${ENC})."
    fi
else
    print_skipped "S3 Bucket check skipped (not present in outputs)."
fi

# ------------------------------------------------------------------------------
# 5. Amazon SQS Queues & Dead Letter Redrive
# ------------------------------------------------------------------------------
section "5. Amazon SQS Queues & Dead Letter Protection"
SQS_URL=$(jq -r '.sqs_queue_url // empty' "$OUTPUTS_JSON")
SQS_DLQ_URL=$(jq -r '.sqs_dlq_url // empty' "$OUTPUTS_JSON")

if [[ -n "$SQS_URL" ]]; then
    SQS_ATTRS=$(aws sqs get-queue-attributes --queue-url "$SQS_URL" --attribute-names ApproximateNumberOfMessages RedrivePolicy --output json 2>/dev/null || true)
    if [[ -n "$SQS_ATTRS" ]]; then
        MSG_COUNT=$(echo "$SQS_ATTRS" | jq -r '.Attributes.ApproximateNumberOfMessages // "0"')
        REDRIVE=$(echo "$SQS_ATTRS" | jq -r '.Attributes.RedrivePolicy // empty')
        print_pass "SQS Ticket Queue is reachable (Active messages: ${MSG_COUNT})."
        if [[ -n "$REDRIVE" && "$REDRIVE" != "null" ]]; then
            print_pass "SQS Dead Letter Redrive Policy is active."
        else
            print_fail "SQS Redrive Policy is missing on main queue!"
        fi
    else
        print_fail "Cannot retrieve attributes for SQS Queue: ${SQS_URL}"
    fi
else
    print_skipped "SQS Queue check skipped."
fi

if [[ -n "$SQS_DLQ_URL" ]]; then
    DLQ_MSGS=$(aws sqs get-queue-attributes --queue-url "$SQS_DLQ_URL" --attribute-names ApproximateNumberOfMessages --query "Attributes.ApproximateNumberOfMessages" --output text 2>/dev/null || true)
    if [[ -n "$DLQ_MSGS" ]]; then
        print_pass "SQS Dead Letter Queue is reachable (Dead letter count: ${DLQ_MSGS})."
    fi
fi

# ------------------------------------------------------------------------------
# 6. AWS Lambda Serverless Worker
# ------------------------------------------------------------------------------
section "6. AWS Lambda Ticket Generation Function"
LAMBDA_ARN=$(jq -r '.lambda_function_arn // empty' "$OUTPUTS_JSON")
if [[ -n "$LAMBDA_ARN" ]]; then
    LAMBDA_INFO=$(aws lambda get-function --function-name "$LAMBDA_ARN" --output json 2>/dev/null || true)
    if [[ -n "$LAMBDA_INFO" ]]; then
        LAMBDA_STATE=$(echo "$LAMBDA_INFO" | jq -r '.Configuration.State // "Active"')
        RUNTIME=$(echo "$LAMBDA_INFO" | jq -r '.Configuration.Runtime')
        print_pass "Lambda function is in state '${LAMBDA_STATE}' (Runtime: ${RUNTIME})."

        # Check SQS event source mapping
        MAPPINGS=$(aws lambda list-event-source-mappings --function-name "$LAMBDA_ARN" --query "EventSourceMappings[0].State" --output text 2>/dev/null || true)
        if [[ "$MAPPINGS" == "Enabled" || "$MAPPINGS" == "Enabling" ]]; then
            print_pass "Lambda SQS Event Source Mapping is active (State: ${MAPPINGS})."
        else
            print_fail "Lambda SQS Event Source Mapping is '${MAPPINGS}'."
        fi
    else
        print_fail "Lambda function ${LAMBDA_ARN} not found or inaccessible."
    fi
else
    print_skipped "Lambda check skipped."
fi

# ------------------------------------------------------------------------------
# 7. Amazon RDS MySQL Database
# ------------------------------------------------------------------------------
section "7. Amazon RDS MySQL Database"
DB_ID=$(jq -r '.db_instance_identifier // empty' "$OUTPUTS_JSON")
if [[ -n "$DB_ID" ]]; then
    RDS_DETAILS=$(aws rds describe-db-instances --db-instance-identifier "$DB_ID" --output json 2>/dev/null || true)
    if [[ -n "$RDS_DETAILS" ]]; then
        DB_STATUS=$(echo "$RDS_DETAILS" | jq -r '.DBInstances[0].DBInstanceStatus')
        DB_ENGINE=$(echo "$RDS_DETAILS" | jq -r '.DBInstances[0].Engine')
        DB_CLASS=$(echo "$RDS_DETAILS" | jq -r '.DBInstances[0].DBInstanceClass')
        DB_ENC=$(echo "$RDS_DETAILS" | jq -r '.DBInstances[0].StorageEncrypted')
        DB_PUBLIC=$(echo "$RDS_DETAILS" | jq -r '.DBInstances[0].PubliclyAccessible')

        if [[ "$DB_STATUS" == "available" ]]; then
            print_pass "RDS Database is available (${DB_ENGINE} ${DB_CLASS})."
        else
            print_fail "RDS Database status is '${DB_STATUS}' (expected 'available')."
        fi

        if [[ "$DB_ENC" == "true" ]]; then
            print_pass "RDS Database storage is encrypted at rest."
        else
            print_fail "RDS Database storage encryption is disabled!"
        fi

        if [[ "$DB_PUBLIC" == "false" ]]; then
            print_pass "RDS Database is private (PubliclyAccessible: false)."
        else
            print_fail "SECURITY WARNING: RDS Database is marked publicly accessible!"
        fi
    else
        print_fail "RDS DB Instance ${DB_ID} not found in AWS."
    fi
else
    print_skipped "RDS check skipped."
fi

# ------------------------------------------------------------------------------
# 8. Application Load Balancer & Auto Scaling Group
# ------------------------------------------------------------------------------
section "8. Application Load Balancer & EC2 Auto Scaling"
ALB_ARN=$(jq -r '.alb_arn // empty' "$OUTPUTS_JSON")
if [[ -n "$ALB_ARN" ]]; then
    ALB_STATE=$(aws elbv2 describe-load-balancers --load-balancer-arns "$ALB_ARN" --query "LoadBalancers[0].State.Code" --output text 2>/dev/null || true)
    ALB_DNS=$(aws elbv2 describe-load-balancers --load-balancer-arns "$ALB_ARN" --query "LoadBalancers[0].DNSName" --output text 2>/dev/null || true)
    if [[ "$ALB_STATE" == "active" ]]; then
        print_pass "Application Load Balancer is active at: http://${ALB_DNS}"
    else
        print_fail "ALB State is '${ALB_STATE}' (expected 'active')."
    fi
else
    print_skipped "ALB check skipped."
fi

ASG_NAME=$(jq -r '.asg_name // empty' "$OUTPUTS_JSON")
if [[ -n "$ASG_NAME" ]]; then
    ASG_INFO=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG_NAME" --output json 2>/dev/null || true)
    if [[ -n "$ASG_INFO" ]]; then
        INST_COUNT=$(echo "$ASG_INFO" | jq -r '.AutoScalingGroups[0].Instances | length')
        DESIRED=$(echo "$ASG_INFO" | jq -r '.AutoScalingGroups[0].DesiredCapacity')
        print_pass "Auto Scaling Group ${ASG_NAME} is active (Instances: ${INST_COUNT}, Desired: ${DESIRED})."
    else
        print_fail "Auto Scaling Group ${ASG_NAME} not found."
    fi
else
    print_skipped "Auto Scaling Group check skipped."
fi

# ------------------------------------------------------------------------------
# 9. CloudWatch Alarms
# ------------------------------------------------------------------------------
section "9. Amazon CloudWatch Alarms"
ALARMS=("surgegate-asg-high-cpu" "surgegate-sqs-queue-backlog" "surgegate-rds-high-cpu")
for alarm in "${ALARMS[@]}"; do
    ALARM_STATE=$(aws cloudwatch describe-alarms --alarm-names "$alarm" --query "MetricAlarms[0].StateValue" --output text 2>/dev/null || true)
    if [[ -n "$ALARM_STATE" && "$ALARM_STATE" != "None" ]]; then
        print_pass "CloudWatch Alarm '${alarm}' exists (State: ${ALARM_STATE})."
    else
        print_skipped "CloudWatch Alarm '${alarm}' not deployed or not found."
    fi
done

# ------------------------------------------------------------------------------
# 10. AWS Systems Manager Parameter Store Audit
# ------------------------------------------------------------------------------
section "10. AWS Systems Manager Parameter Store Audit"
ENV_NAME="${ENVIRONMENT:-dev}"
SSM_PARAMS=$(aws ssm get-parameters-by-path --path "/surgegate/${ENV_NAME}" --query "Parameters[].Name" --output text 2>/dev/null || true)
if [[ -n "$SSM_PARAMS" && "$SSM_PARAMS" != "None" ]]; then
    PARAM_COUNT=$(echo "$SSM_PARAMS" | wc -w)
    print_pass "Found ${PARAM_COUNT} parameters stored under /surgegate/${ENV_NAME}/ in SSM Parameter Store."
    # Verify secure string for db_password
    DB_PASS_TYPE=$(aws ssm describe-parameters --filters "Key=Name,Values=/surgegate/${ENV_NAME}/db_password" --query "Parameters[0].Type" --output text 2>/dev/null || true)
    if [[ "$DB_PASS_TYPE" == "SecureString" ]]; then
        print_pass "Database password parameter (/surgegate/${ENV_NAME}/db_password) is encrypted (Type: SecureString)."
    elif [[ -n "$DB_PASS_TYPE" && "$DB_PASS_TYPE" != "None" ]]; then
        print_fail "SECURITY WARNING: /surgegate/${ENV_NAME}/db_password is not encrypted as SecureString (Found: ${DB_PASS_TYPE})!"
    fi
else
    print_skipped "SSM Parameter Store check skipped (no parameters under /surgegate/${ENV_NAME}/)."
fi

# ------------------------------------------------------------------------------
# 11. Audit Summary
# ------------------------------------------------------------------------------
echo ""
echo -e "${BOLD}${CYAN}==============================================================================${NC}"
echo -e "${BOLD}Verification Summary: ${GREEN}${PASS_COUNT} Passed${NC}, ${RED}${FAIL_COUNT} Failed${NC}, ${YELLOW}${SKIP_COUNT} Skipped${NC}"
echo -e "${BOLD}${CYAN}==============================================================================${NC}"

if [[ $FAIL_COUNT -eq 0 ]]; then
    echo -e "${GREEN}${BOLD}All infrastructure checks PASSED! SurgeGate environment is healthy and operational.${NC}"
    exit 0
else
    echo -e "${RED}${BOLD}One or more infrastructure checks FAILED. Review the errors above.${NC}"
    exit 1
fi
