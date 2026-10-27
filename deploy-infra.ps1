<#
.SYNOPSIS
    SurgeGate - AWS Infrastructure Provisioning Script (PowerShell Native)
.DESCRIPTION
    Provisions and configures SurgeGate infrastructure in AWS region ap-south-1:
    VPC, Subnets, Security Groups, S3, SQS with DLQ, IAM runtime roles,
    AWS Lambda worker, RDS MySQL, ALB, Auto Scaling Group, CloudWatch Alarms,
    and SSM Parameter Store.

    Designed for strict idempotency, safe resumability, zero destructive actions,
    and student budget safety. Existing SurgeGate resources (VPC, RDS, S3, ALB,
    Launch Template, ASG, DLQ, Lambda) are discovered and preserved.
.PARAMETER DryRun
    If specified, validates prerequisites and checks existing AWS state without mutating resources.
.PARAMETER Profile
    AWS CLI Profile to use (default: 'surgegate').
.PARAMETER Environment
    Target deployment environment (default: 'dev').
.PARAMETER Region
    AWS Region (default: 'ap-south-1').
.PARAMETER DbPassword
    Optional master password for RDS. If RDS already exists, the master password
    is preserved and NOT modified. If supplied, it will be stored in SSM Parameter Store.
#>

[CmdletBinding()]
param(
    [switch]$DryRun,
    [string]$Profile = "surgegate",
    [string]$Environment = "dev",
    [string]$Region = "ap-south-1",
    [string]$ProjectName = "surgegate",
    [string]$VpcCidr = "10.0.0.0/16",
    [string]$PublicSubnet1Cidr = "10.0.1.0/24",
    [string]$PublicSubnet2Cidr = "10.0.2.0/24",
    [string]$PrivateSubnet1Cidr = "10.0.11.0/24",
    [string]$PrivateSubnet2Cidr = "10.0.12.0/24",
    [int]$AppPort = 3000,
    [string]$Ec2InstanceType = "t3.small",
    [string]$DbInstanceClass = "db.t3.micro",
    [string]$DbName = "surgegate",
    [string]$DbUser = "surgegate_admin",
    [string]$DbPassword = ""
)

$env:AWS_PROFILE = $Profile
$env:AWS_DEFAULT_REGION = $Region
$env:AWS_REGION = $Region

$ErrorActionPreference = "Continue"

function Write-Step { param([string]$msg) Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-Success { param([string]$msg) Write-Host "[SUCCESS] $msg" -ForegroundColor Green }
function Write-Info { param([string]$msg) Write-Host "[INFO] $msg" -ForegroundColor Gray }
function Write-Warn { param([string]$msg) Write-Host "[WARN] $msg" -ForegroundColor Yellow }
function Write-Failure { param([string]$msg) Write-Host "[ERROR] $msg" -ForegroundColor Red }

function Write-JsonNoBom {
    param(
        [string]$FilePath,
        [string]$Content
    )
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($FilePath, $Content, $utf8NoBom)
}

function Invoke-AwsCli {
    param(
        [string]$StepDescription,
        [scriptblock]$CommandBlock
    )
    $output = & $CommandBlock 2>&1
    $exitCode = $LASTEXITCODE
    $outLines = @()
    if ($output) {
        foreach ($line in $output) {
            $outLines += [string]$line
        }
    }
    $outStr = ($outLines -join "`n").Trim()

    if ($exitCode -ne 0 -or $outStr.StartsWith("aws: [ERROR]") -or $outStr.StartsWith("An error occurred")) {
        Write-Failure "AWS operation failed during: $StepDescription (Exit code: $exitCode)"
        if ($outStr) { Write-Failure "$outStr" }
        exit 1
    }
    return $outStr
}

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$OutputsJson = Join-Path $ScriptDir "deployment-outputs.json"
$OutputsEnv = Join-Path $ScriptDir "deployment-outputs.env"

Write-Host "==============================================================================" -ForegroundColor Cyan
Write-Host "          SurgeGate - AWS Infrastructure Provisioning (PowerShell)            " -ForegroundColor Cyan
Write-Host "==============================================================================" -ForegroundColor Cyan

# ------------------------------------------------------------------------------
# 1. Prerequisite & Caller Identity Validation
# ------------------------------------------------------------------------------
Write-Step "1. Validating Prerequisites and AWS CLI Environment"

if (-not (Get-Command "aws.exe" -ErrorAction SilentlyContinue)) {
    Write-Failure "AWS CLI ('aws.exe') not found in PATH. Please install AWS CLI v2."
    exit 1
}

$callerRaw = Invoke-AwsCli "STS Caller Identity" {
    aws --profile $Profile --region $Region sts get-caller-identity --output json
}
$caller = $callerRaw | ConvertFrom-Json
$AccountId = $caller.Account
$CallerArn = $caller.Arn

if ($AccountId -ne "269494630662") {
    Write-Failure "ACCOUNT MISMATCH! Target account must be 269494630662, but authenticated as $AccountId ($CallerArn). Aborting."
    exit 1
}

Write-Success "Authenticated as: $CallerArn (Account ID: $AccountId, Region: $Region, Profile: $Profile)"

# Query Availability Zones in target region
$azRaw = (aws --profile $Profile --region $Region ec2 describe-availability-zones --filters "Name=state,Values=available" "Name=zone-type,Values=availability-zone" --query "AvailabilityZones[].ZoneName" --output text)
$azs = $(if ($azRaw) { [string]$azRaw.Trim() } else { "" }).Split([char[]]@("`t", ' ', "`r", "`n"), [System.StringSplitOptions]::RemoveEmptyEntries)
if ($azs.Count -lt 2) {
    $azRaw = (aws --profile $Profile --region $Region ec2 describe-availability-zones --filters "Name=state,Values=available" --query "AvailabilityZones[].ZoneName" --output text)
    $azs = $(if ($azRaw) { [string]$azRaw.Trim() } else { "" }).Split([char[]]@("`t", ' ', "`r", "`n"), [System.StringSplitOptions]::RemoveEmptyEntries)
}

if ($azs.Count -lt 2) {
    Write-Failure "Region $Region requires at least 2 available AZs. Found: $($azs -join ', ')"
    exit 1
}
$AzA = $azs[0]
$AzB = $azs[1]
Write-Info "Selected Availability Zones: $AzA, $AzB"

# ------------------------------------------------------------------------------
# Database Password & Preservation Logic
# ------------------------------------------------------------------------------
$SsmPrefix = "/surgegate/$Environment"
$DbInstanceId = "surgegate-db"

# Check if RDS instance already exists in AWS
$existingRdsCheck = aws --profile $Profile --region $Region rds describe-db-instances --db-instance-identifier $DbInstanceId --query "DBInstances[0].DBInstanceStatus" --output text 2>$null
$rdsAlreadyExists = ($existingRdsCheck -and $existingRdsCheck -ne "None" -and -not $existingRdsCheck.StartsWith("aws:"))

# Check if password exists in SSM Parameter Store
$existingSsmPass = aws --profile $Profile --region $Region ssm get-parameter --name "$SsmPrefix/db_password" --with-decryption --query "Parameter.Value" --output text 2>$null
$hasSsmPass = ($existingSsmPass -and $existingSsmPass -ne "None" -and -not $existingSsmPass.StartsWith("aws:"))

if ($hasSsmPass) {
    $DbPassword = $existingSsmPass
    Write-Info "Retrieved existing database master password from SSM Parameter Store ($SsmPrefix/db_password)."
} elseif ($rdsAlreadyExists) {
    if ([string]::IsNullOrWhiteSpace($DbPassword)) {
        Write-Info "Existing RDS instance '$DbInstanceId' detected. Preserving existing database without modifying password."
    } else {
        Write-Info "Existing RDS instance '$DbInstanceId' detected. Supplied -DbPassword will be saved to SSM Parameter Store without altering RDS."
    }
} else {
    # Initial RDS creation: generate secure random password if not supplied
    if ([string]::IsNullOrWhiteSpace($DbPassword)) {
        if ($DryRun) {
            $DbPassword = "[DRY-RUN-MASKED-PASSWORD]"
        } else {
            $chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
            $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
            $bytes = New-Object byte[] 16
            $rng.GetBytes($bytes)
            $sb = New-Object System.Text.StringBuilder 16
            foreach ($b in $bytes) { [void]$sb.Append($chars[$b % $chars.Length]) }
            $DbPassword = $sb.ToString()
            Write-Info "Auto-generated secure master password for initial Amazon RDS MySQL provisioning."
        }
    }
}

# ------------------------------------------------------------------------------
# 2. Plan Summary
# ------------------------------------------------------------------------------
Write-Host "`n----------------------------------------------------------------------" -ForegroundColor Yellow
Write-Host "                   INFRASTRUCTURE PROVISIONING PLAN                   " -ForegroundColor Yellow
Write-Host "----------------------------------------------------------------------" -ForegroundColor Yellow
Write-Host " Project Name:         $ProjectName" -ForegroundColor Cyan
Write-Host " Environment:          $Environment" -ForegroundColor Cyan
Write-Host " AWS Region:           $Region" -ForegroundColor Cyan
Write-Host " Account ID:           $AccountId" -ForegroundColor Cyan
Write-Host " VPC CIDR:             $VpcCidr" -ForegroundColor Cyan
Write-Host " Availability Zones:   $AzA, $AzB" -ForegroundColor Cyan
Write-Host " RDS MySQL Instance:   $DbInstanceId ($DbInstanceClass, 20GB gp3) - $(if ($rdsAlreadyExists) { 'PRESERVE EXISTING' } else { 'CREATE NEW' })" -ForegroundColor Cyan
Write-Host " SQS & DLQ:            surgegate-ticket-queue / surgegate-ticket-dlq" -ForegroundColor Cyan
Write-Host " Lambda Worker:        surgegate-ticket-processor (python3.11)" -ForegroundColor Cyan
Write-Host " ALB & ASG:            surgegate-alb / surgegate-asg ($Ec2InstanceType)" -ForegroundColor Cyan
Write-Host " SSM Parameter Store:  $SsmPrefix/*" -ForegroundColor Cyan
Write-Host " CloudWatch Alarms:    Enabled" -ForegroundColor Cyan
Write-Host "----------------------------------------------------------------------" -ForegroundColor Yellow

if ($DryRun) {
    Write-Info "Running in DRY-RUN mode. Validating existing state without mutating resources."
}

$TagSpec = "ResourceType={0},Tags=[{{Key=Name,Value={1}}},{{Key=Project,Value=SurgeGate}},{{Key=Environment,Value={2}}},{{Key=ManagedBy,Value=deploy-infra.ps1}}]"

# ------------------------------------------------------------------------------
# 3. Custom VPC & Subnets
# ------------------------------------------------------------------------------
Write-Step "2. Amazon VPC and Subnets Configuration"

$VpcId = aws --profile $Profile --region $Region ec2 describe-vpcs --filters "Name=tag:Project,Values=SurgeGate" "Name=tag:Name,Values=surgegate-vpc" --query "Vpcs[0].VpcId" --output text 2>$null
if (-not $VpcId -or $VpcId -eq "None") {
    $VpcId = aws --profile $Profile --region $Region ec2 describe-vpcs --filters "Name=cidr,Values=$VpcCidr" --query "Vpcs[0].VpcId" --output text 2>$null
}

if ($VpcId -and $VpcId -ne "None") {
    Write-Success "Found existing SurgeGate VPC: $VpcId"
} else {
    if ($DryRun) {
        Write-Info "[DRY-RUN] Would create VPC ($VpcCidr) with DNS hostnames enabled."
        $VpcId = "vpc-dryrunplaceholder"
    } else {
        Write-Info "Creating VPC with CIDR $VpcCidr..."
        $vpcTag = ($TagSpec -f "vpc", "surgegate-vpc", $Environment)
        $VpcId = Invoke-AwsCli "Create VPC" {
            aws --profile $Profile --region $Region ec2 create-vpc --cidr-block $VpcCidr --tag-specifications $vpcTag --query "Vpc.VpcId" --output text
        }
        aws --profile $Profile --region $Region ec2 modify-vpc-attribute --vpc-id $VpcId --enable-dns-hostnames '{\"Value\":true}' | Out-Null
        aws --profile $Profile --region $Region ec2 modify-vpc-attribute --vpc-id $VpcId --enable-dns-support '{\"Value\":true}' | Out-Null
        Write-Success "Created VPC: $VpcId"
    }
}

# Internet Gateway
$IgwId = aws --profile $Profile --region $Region ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$VpcId" --query "InternetGateways[0].InternetGatewayId" --output text 2>$null
if (-not $IgwId -or $IgwId -eq "None") {
    $IgwId = aws --profile $Profile --region $Region ec2 describe-internet-gateways --filters "Name=tag:Name,Values=surgegate-igw" --query "InternetGateways[0].InternetGatewayId" --output text 2>$null
}

if ($IgwId -and $IgwId -ne "None") {
    Write-Success "Found existing Internet Gateway: $IgwId"
} else {
    if ($DryRun) {
        Write-Info "[DRY-RUN] Would create Internet Gateway and attach to VPC."
        $IgwId = "igw-dryrunplaceholder"
    } else {
        $igwTag = ($TagSpec -f "internet-gateway", "surgegate-igw", $Environment)
        $IgwId = Invoke-AwsCli "Create Internet Gateway" {
            aws --profile $Profile --region $Region ec2 create-internet-gateway --tag-specifications $igwTag --query "InternetGateway.InternetGatewayId" --output text
        }
        aws --profile $Profile --region $Region ec2 attach-internet-gateway --internet-gateway-id $IgwId --vpc-id $VpcId | Out-Null
        Write-Success "Attached Internet Gateway: $IgwId"
    }
}

function Find-OrCreate-Subnet {
    param($name, $cidr, $az, [bool]$isPublic)
    $subId = aws --profile $Profile --region $Region ec2 describe-subnets --filters "Name=vpc-id,Values=$VpcId" "Name=cidr-block,Values=$cidr" --query "Subnets[0].SubnetId" --output text 2>$null
    if ($subId -and $subId -ne "None" -and -not $subId.StartsWith("aws:")) {
        Write-Success "Found existing Subnet $name : $subId"
        return [string]$subId.Trim()
    }
    if ($DryRun) {
        Write-Info "[DRY-RUN] Would create Subnet $name ($cidr) in $az"
        return "subnet-$name-dryrun"
    }
    $subTag = ($TagSpec -f "subnet", $name, $Environment)
    $subId = Invoke-AwsCli "Create Subnet $name" {
        aws --profile $Profile --region $Region ec2 create-subnet --vpc-id $VpcId --cidr-block $cidr --availability-zone $az --tag-specifications $subTag --query "Subnet.SubnetId" --output text
    }
    if ($isPublic) {
        aws --profile $Profile --region $Region ec2 modify-subnet-attribute --subnet-id $subId --map-public-ip-on-launch | Out-Null
    }
    Write-Success "Created Subnet $name : $subId"
    return $subId
}

$PubSubA = Find-OrCreate-Subnet "surgegate-public-subnet-1" $PublicSubnet1Cidr $AzA $true
$PubSubB = Find-OrCreate-Subnet "surgegate-public-subnet-2" $PublicSubnet2Cidr $AzB $true
$PrivSubA = Find-OrCreate-Subnet "surgegate-private-subnet-1" $PrivateSubnet1Cidr $AzA $false
$PrivSubB = Find-OrCreate-Subnet "surgegate-private-subnet-2" $PrivateSubnet2Cidr $AzB $false

# Route Tables
$PubRtId = aws --profile $Profile --region $Region ec2 describe-route-tables --filters "Name=vpc-id,Values=$VpcId" "Name=tag:Name,Values=surgegate-public-rt" --query "RouteTables[0].RouteTableId" --output text 2>$null
if ($PubRtId -and $PubRtId -ne "None" -and -not $PubRtId.StartsWith("aws:")) {
    $PubRtId = [string]$PubRtId.Trim()
    Write-Success "Found existing Public Route Table: $PubRtId"
} else {
    if ($DryRun) {
        Write-Info "[DRY-RUN] Would create Public Route Table with route 0.0.0.0/0 -> IGW."
        $PubRtId = "rtb-pub-dryrun"
    } else {
        $rtTag = ($TagSpec -f "route-table", "surgegate-public-rt", $Environment)
        $PubRtId = Invoke-AwsCli "Create Public Route Table" {
            aws --profile $Profile --region $Region ec2 create-route-table --vpc-id $VpcId --tag-specifications $rtTag --query "RouteTable.RouteTableId" --output text
        }
        aws --profile $Profile --region $Region ec2 create-route --route-table-id $PubRtId --destination-cidr-block 0.0.0.0/0 --gateway-id $IgwId 2>$null | Out-Null
        aws --profile $Profile --region $Region ec2 associate-route-table --subnet-id $PubSubA --route-table-id $PubRtId 2>$null | Out-Null
        aws --profile $Profile --region $Region ec2 associate-route-table --subnet-id $PubSubB --route-table-id $PubRtId 2>$null | Out-Null
        Write-Success "Created Public Route Table: $PubRtId"
    }
}

$PrivRtId = aws --profile $Profile --region $Region ec2 describe-route-tables --filters "Name=vpc-id,Values=$VpcId" "Name=tag:Name,Values=surgegate-private-rt" --query "RouteTables[0].RouteTableId" --output text 2>$null
if ($PrivRtId -and $PrivRtId -ne "None" -and -not $PrivRtId.StartsWith("aws:")) {
    $PrivRtId = [string]$PrivRtId.Trim()
    Write-Success "Found existing Private Route Table: $PrivRtId"
} else {
    if ($DryRun) {
        Write-Info "[DRY-RUN] Would create Private Route Table (isolated, no IGW route)."
        $PrivRtId = "rtb-priv-dryrun"
    } else {
        $rtTag = ($TagSpec -f "route-table", "surgegate-private-rt", $Environment)
        $PrivRtId = Invoke-AwsCli "Create Private Route Table" {
            aws --profile $Profile --region $Region ec2 create-route-table --vpc-id $VpcId --tag-specifications $rtTag --query "RouteTable.RouteTableId" --output text
        }
        aws --profile $Profile --region $Region ec2 associate-route-table --subnet-id $PrivSubA --route-table-id $PrivRtId 2>$null | Out-Null
        aws --profile $Profile --region $Region ec2 associate-route-table --subnet-id $PrivSubB --route-table-id $PrivRtId 2>$null | Out-Null
        Write-Success "Created Private Route Table: $PrivRtId"
    }
}

# ------------------------------------------------------------------------------
# 4. Security Groups (Least Privilege)
# ------------------------------------------------------------------------------
Write-Step "3. Security Groups Configuration"

function Find-OrCreate-SG {
    param($name, $desc)
    $sgId = aws --profile $Profile --region $Region ec2 describe-security-groups --filters "Name=vpc-id,Values=$VpcId" "Name=group-name,Values=$name" --query "SecurityGroups[0].GroupId" --output text 2>$null
    if ($sgId -and $sgId -ne "None" -and -not $sgId.StartsWith("aws:")) {
        Write-Success "Found existing Security Group $name : $sgId"
        return [string]$sgId.Trim()
    }
    if ($DryRun) {
        Write-Info "[DRY-RUN] Would create Security Group $name"
        return "sg-$name-dryrun"
    }
    $sgTag = ($TagSpec -f "security-group", $name, $Environment)
    $sgId = Invoke-AwsCli "Create Security Group $name" {
        aws --profile $Profile --region $Region ec2 create-security-group --group-name $name --description $desc --vpc-id $VpcId --tag-specifications $sgTag --query "GroupId" --output text
    }
    Write-Success "Created Security Group $name : $sgId"
    return $sgId
}

$AlbSgId = Find-OrCreate-SG "surgegate-alb-sg" "SurgeGate ALB Public Ingress"
$Ec2SgId = Find-OrCreate-SG "surgegate-ec2-sg" "SurgeGate EC2 Application Ingress from ALB"
$RdsSgId = Find-OrCreate-SG "surgegate-db-sg" "SurgeGate Private RDS MySQL Ingress from App"
$LambdaSgId = Find-OrCreate-SG "surgegate-lambda-sg" "SurgeGate Lambda Worker Ingress/Egress"

if (-not $DryRun) {
    # ALB: HTTP 80 from public
    aws --profile $Profile --region $Region ec2 authorize-security-group-ingress --group-id $AlbSgId --protocol tcp --port 80 --cidr 0.0.0.0/0 2>$null | Out-Null
    # EC2: AppPort from ALB SG only
    aws --profile $Profile --region $Region ec2 authorize-security-group-ingress --group-id $Ec2SgId --protocol tcp --port $AppPort --source-group $AlbSgId 2>$null | Out-Null
    aws --profile $Profile --region $Region ec2 authorize-security-group-ingress --group-id $Ec2SgId --protocol tcp --port 80 --source-group $AlbSgId 2>$null | Out-Null
    # RDS: MySQL 3306 ONLY from EC2 SG and Lambda SG (NEVER 0.0.0.0/0)
    aws --profile $Profile --region $Region ec2 authorize-security-group-ingress --group-id $RdsSgId --protocol tcp --port 3306 --source-group $Ec2SgId 2>$null | Out-Null
    aws --profile $Profile --region $Region ec2 authorize-security-group-ingress --group-id $RdsSgId --protocol tcp --port 3306 --source-group $LambdaSgId 2>$null | Out-Null
    Write-Success "Configured least-privilege Security Group ingress rules."
}

# ------------------------------------------------------------------------------
# 5. Amazon S3 Storage Bucket
# ------------------------------------------------------------------------------
Write-Step "4. Amazon S3 Bucket Configuration"

$s3CleanRegion = $Region.Replace("-", "")
$S3Bucket = "surgegate-tickets-${Environment}-${AccountId}-${s3CleanRegion}"

$existingBucket = aws --profile $Profile --region $Region s3api list-buckets --query "Buckets[?contains(Name, 'surgegate-tickets-')].Name | [0]" --output text 2>$null
if ($existingBucket -and $existingBucket -ne "None" -and -not $existingBucket.StartsWith("aws:")) {
    $S3Bucket = [string]$existingBucket.Trim()
    Write-Success "Found existing S3 Bucket: $S3Bucket"
} else {
    if ($DryRun) {
        Write-Info "[DRY-RUN] Would create S3 Bucket: $S3Bucket with SSE-S3 AES256 and Public Access Blocked."
    } else {
        Write-Info "Creating S3 bucket: $S3Bucket..."
        Invoke-AwsCli "Create S3 Bucket $S3Bucket" {
            if ($Region -eq "us-east-1") {
                aws --profile $Profile --region $Region s3api create-bucket --bucket $S3Bucket
            } else {
                aws --profile $Profile --region $Region s3api create-bucket --bucket $S3Bucket --create-bucket-configuration "LocationConstraint=$Region"
            }
        } | Out-Null

        aws --profile $Profile --region $Region s3api put-public-access-block --bucket $S3Bucket --public-access-block-configuration "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true" | Out-Null
        
        $sseConfig = @{
            Rules = @(
                @{
                    ApplyServerSideEncryptionByDefault = @{
                        SSEAlgorithm = "AES256"
                    }
                }
            )
        } | ConvertTo-Json -Compress
        $tempSseFile = Join-Path $env:TEMP "s3-sse-$([guid]::NewGuid().ToString('N')).json"
        Write-JsonNoBom $tempSseFile $sseConfig
        $normSseFile = $tempSseFile.Replace('\', '/')
        aws --profile $Profile --region $Region s3api put-bucket-encryption --bucket $S3Bucket --server-side-encryption-configuration "file://$normSseFile" 2>$null | Out-Null
        Remove-Item -Path $tempSseFile -Force -ErrorAction SilentlyContinue

        aws --profile $Profile --region $Region s3api put-bucket-tagging --bucket $S3Bucket --tagging "TagSet=[{Key=Project,Value=SurgeGate},{Key=Environment,Value=$Environment}]" 2>$null | Out-Null
        Write-Success "Created secured S3 bucket: $S3Bucket"
    }
}

# ------------------------------------------------------------------------------
# 6. Amazon SQS Queues (Main Buffer + Dead Letter Queue)
# ------------------------------------------------------------------------------
Write-Step "5. Amazon SQS Queues Configuration"

$SqsDlqName = "surgegate-ticket-dlq"
$SqsQueueName = "surgegate-ticket-queue"

# DLQ Discovery / Creation
$SqsDlqUrl = aws --profile $Profile --region $Region sqs get-queue-url --queue-name $SqsDlqName --query "QueueUrl" --output text 2>$null
if ($SqsDlqUrl -and $SqsDlqUrl -ne "None" -and -not $SqsDlqUrl.StartsWith("aws:")) {
    $SqsDlqUrl = [string]$SqsDlqUrl.Trim()
    $SqsDlqArn = Invoke-AwsCli "Get SQS DLQ ARN" {
        aws --profile $Profile --region $Region sqs get-queue-attributes --queue-url $SqsDlqUrl --attribute-names QueueArn --query "Attributes.QueueArn" --output text
    }
    Write-Success "Found existing SQS DLQ: $SqsDlqUrl ($SqsDlqArn)"
} else {
    if ($DryRun) {
        Write-Info "[DRY-RUN] Would create SQS DLQ: $SqsDlqName"
        $SqsDlqUrl = "https://sqs.$Region.amazonaws.com/$AccountId/$SqsDlqName"
        $SqsDlqArn = "arn:aws:sqs:${Region}:${AccountId}:${SqsDlqName}"
    } else {
        $SqsDlqUrl = Invoke-AwsCli "Create SQS DLQ" {
            aws --profile $Profile --region $Region sqs create-queue --queue-name $SqsDlqName --tags "Project=SurgeGate,Environment=$Environment" --query "QueueUrl" --output text
        }
        $SqsDlqArn = Invoke-AwsCli "Get SQS DLQ ARN" {
            aws --profile $Profile --region $Region sqs get-queue-attributes --queue-url $SqsDlqUrl --attribute-names QueueArn --query "Attributes.QueueArn" --output text
        }
        Write-Success "Created SQS DLQ: $SqsDlqUrl ($SqsDlqArn)"
    }
}

# Main Queue Discovery / Creation with UTF-8 No-BOM JSON file
$SqsQueueUrl = aws --profile $Profile --region $Region sqs get-queue-url --queue-name $SqsQueueName --query "QueueUrl" --output text 2>$null
if ($SqsQueueUrl -and $SqsQueueUrl -ne "None" -and -not $SqsQueueUrl.StartsWith("aws:")) {
    $SqsQueueUrl = [string]$SqsQueueUrl.Trim()
    $SqsQueueArn = Invoke-AwsCli "Get Main SQS Queue ARN" {
        aws --profile $Profile --region $Region sqs get-queue-attributes --queue-url $SqsQueueUrl --attribute-names QueueArn --query "Attributes.QueueArn" --output text
    }
    Write-Success "Found existing SQS Ticket Queue: $SqsQueueUrl ($SqsQueueArn)"

    # Verify / update RedrivePolicy on existing main queue
    if (-not $DryRun) {
        $currentRedrive = aws --profile $Profile --region $Region sqs get-queue-attributes --queue-url $SqsQueueUrl --attribute-names RedrivePolicy --query "Attributes.RedrivePolicy" --output text 2>$null
        if (-not $currentRedrive -or $currentRedrive -eq "None") {
            Write-Info "Configuring RedrivePolicy on existing SQS Ticket Queue..."
            $redriveJson = @{
                deadLetterTargetArn = $SqsDlqArn
                maxReceiveCount = 3
            } | ConvertTo-Json -Compress

            $attrHash = @{
                VisibilityTimeout = "60"
                RedrivePolicy = $redriveJson
            }
            $tempAttrFile = Join-Path $env:TEMP "sqs-attrs-$([guid]::NewGuid().ToString('N')).json"
            Write-JsonNoBom $tempAttrFile ($attrHash | ConvertTo-Json)
            $normAttrFile = $tempAttrFile.Replace('\', '/')

            Invoke-AwsCli "Set SQS Queue Attributes" {
                aws --profile $Profile --region $Region sqs set-queue-attributes --queue-url $SqsQueueUrl --attributes "file://$normAttrFile"
            } | Out-Null
            Remove-Item -Path $tempAttrFile -Force -ErrorAction SilentlyContinue
            Write-Success "Updated RedrivePolicy on existing SQS Ticket Queue."
        }
    }
} else {
    if ($DryRun) {
        Write-Info "[DRY-RUN] Would create SQS Queue: $SqsQueueName with RedrivePolicy (maxReceiveCount: 3)"
        $SqsQueueUrl = "https://sqs.$Region.amazonaws.com/$AccountId/$SqsQueueName"
        $SqsQueueArn = "arn:aws:sqs:${Region}:${AccountId}:${SqsQueueName}"
    } else {
        $redriveJson = @{
            deadLetterTargetArn = $SqsDlqArn
            maxReceiveCount = 3
        } | ConvertTo-Json -Compress

        $attrHash = @{
            VisibilityTimeout = "60"
            RedrivePolicy = $redriveJson
        }
        $tempAttrFile = Join-Path $env:TEMP "sqs-attrs-$([guid]::NewGuid().ToString('N')).json"
        Write-JsonNoBom $tempAttrFile ($attrHash | ConvertTo-Json)
        $normAttrFile = $tempAttrFile.Replace('\', '/')

        Write-Info "Creating Main SQS Queue '$SqsQueueName' with RedrivePolicy..."
        $SqsQueueUrl = Invoke-AwsCli "Create Main SQS Queue" {
            aws --profile $Profile --region $Region sqs create-queue `
                --queue-name $SqsQueueName `
                --attributes "file://$normAttrFile" `
                --tags "Project=SurgeGate,Environment=$Environment" `
                --query "QueueUrl" --output text
        }
        Remove-Item -Path $tempAttrFile -Force -ErrorAction SilentlyContinue

        if (-not $SqsQueueUrl.StartsWith("https://sqs.")) {
            Write-Failure "Invalid SQS Queue URL returned: $SqsQueueUrl"
            exit 1
        }

        $SqsQueueArn = Invoke-AwsCli "Get Main SQS Queue ARN" {
            aws --profile $Profile --region $Region sqs get-queue-attributes `
                --queue-url $SqsQueueUrl `
                --attribute-names QueueArn `
                --query "Attributes.QueueArn" --output text
        }
        if (-not $SqsQueueArn.StartsWith("arn:aws:sqs:")) {
            Write-Failure "Invalid SQS Queue ARN returned: $SqsQueueArn"
            exit 1
        }

        Write-Success "Created Main SQS Queue: $SqsQueueUrl ($SqsQueueArn)"
    }
}

# Strict validation: ensure Queue ARN is ready before IAM policy attachment
if (-not $DryRun -and ([string]::IsNullOrWhiteSpace($SqsQueueArn) -or -not $SqsQueueArn.StartsWith("arn:aws:sqs:"))) {
    Write-Failure "CRITICAL: Main SQS Queue ARN is empty or invalid ('$SqsQueueArn'). Cannot configure IAM policies. Aborting."
    exit 1
}

# ------------------------------------------------------------------------------
# 7. IAM Runtime Roles & Instance Profile
# ------------------------------------------------------------------------------
Write-Step "6. IAM Least-Privilege Roles Configuration"

$Ec2RoleName = "surgegate-ec2-role"
$Ec2ProfileName = "surgegate-ec2-profile"
$LambdaRoleName = "surgegate-lambda-role"

# EC2 Role Discovery / Creation
$Ec2RoleArn = aws --profile $Profile --region $Region iam get-role --role-name $Ec2RoleName --query "Role.Arn" --output text 2>$null
if ($Ec2RoleArn -and $Ec2RoleArn -ne "None" -and -not $Ec2RoleArn.StartsWith("aws:")) {
    $Ec2RoleArn = [string]$Ec2RoleArn.Trim()
    Write-Success "Found existing IAM Role: $Ec2RoleName ($Ec2RoleArn)"
} else {
    if ($DryRun) {
        Write-Info "[DRY-RUN] Would create IAM Role: $Ec2RoleName with SSM and App policies."
        $Ec2RoleArn = "arn:aws:iam::$AccountId:role/$Ec2RoleName"
    } else {
        $ec2Trust = '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
        $tempTrustFile = Join-Path $env:TEMP "ec2-trust-$([guid]::NewGuid().ToString('N')).json"
        Write-JsonNoBom $tempTrustFile $ec2Trust
        $normTrustFile = $tempTrustFile.Replace('\', '/')

        $Ec2RoleArn = Invoke-AwsCli "Create EC2 IAM Role" {
            aws --profile $Profile --region $Region iam create-role `
                --role-name $Ec2RoleName `
                --assume-role-policy-document "file://$normTrustFile" `
                --tags "Key=Project,Value=SurgeGate" "Key=Environment,Value=$Environment" `
                --query "Role.Arn" --output text
        }
        Remove-Item -Path $tempTrustFile -Force -ErrorAction SilentlyContinue
        Write-Success "Created IAM Role: $Ec2RoleName ($Ec2RoleArn)"
    }
}

# ALWAYS ensure EC2 policies are attached / updated (idempotent)
if (-not $DryRun) {
    aws --profile $Profile --region $Region iam attach-role-policy --role-name $Ec2RoleName --policy-arn "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore" | Out-Null
    
    $appPolicy = @"
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": ["sqs:SendMessage", "sqs:GetQueueUrl", "sqs:GetQueueAttributes"],
            "Resource": "$SqsQueueArn"
        },
        {
            "Effect": "Allow",
            "Action": ["s3:PutObject", "s3:GetObject"],
            "Resource": "arn:aws:s3:::$S3Bucket/*"
        },
        {
            "Effect": "Allow",
            "Action": ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"],
            "Resource": "arn:aws:ssm:${Region}:${AccountId}:parameter/surgegate/*"
        },
        {
            "Effect": "Allow",
            "Action": ["kms:Decrypt"],
            "Resource": "*"
        }
    ]
}
"@
    $tempAppPolFile = Join-Path $env:TEMP "ec2-app-policy-$([guid]::NewGuid().ToString('N')).json"
    Write-JsonNoBom $tempAppPolFile $appPolicy
    $normAppPolFile = $tempAppPolFile.Replace('\', '/')

    Invoke-AwsCli "Put SurgeGateEC2AppPolicy" {
        aws --profile $Profile --region $Region iam put-role-policy `
            --role-name $Ec2RoleName `
            --policy-name "SurgeGateEC2AppPolicy" `
            --policy-document "file://$normAppPolFile"
    } | Out-Null
    Remove-Item -Path $tempAppPolFile -Force -ErrorAction SilentlyContinue
    Write-Success "Attached/Updated SurgeGateEC2AppPolicy on $Ec2RoleName."
}

# Instance Profile
$instProfile = aws --profile $Profile --region $Region iam get-instance-profile --instance-profile-name $Ec2ProfileName --query "InstanceProfile.InstanceProfileName" --output text 2>$null
if (-not $instProfile -or $instProfile -eq "None" -or $instProfile.StartsWith("aws:")) {
    if (-not $DryRun) {
        aws --profile $Profile --region $Region iam create-instance-profile --instance-profile-name $Ec2ProfileName 2>$null | Out-Null
        aws --profile $Profile --region $Region iam add-role-to-instance-profile --instance-profile-name $Ec2ProfileName --role-name $Ec2RoleName 2>$null | Out-Null
        Write-Success "Created and associated Instance Profile: $Ec2ProfileName"
        Start-Sleep -Seconds 3
    }
} else {
    Write-Success "Found existing Instance Profile: $Ec2ProfileName"
}

# Lambda Role Discovery / Creation
$LambdaRoleArn = aws --profile $Profile --region $Region iam get-role --role-name $LambdaRoleName --query "Role.Arn" --output text 2>$null
if ($LambdaRoleArn -and $LambdaRoleArn -ne "None" -and -not $LambdaRoleArn.StartsWith("aws:")) {
    $LambdaRoleArn = [string]$LambdaRoleArn.Trim()
    Write-Success "Found existing IAM Role: $LambdaRoleName ($LambdaRoleArn)"
} else {
    if ($DryRun) {
        Write-Info "[DRY-RUN] Would create IAM Role: $LambdaRoleName for Lambda execution."
        $LambdaRoleArn = "arn:aws:iam::$AccountId:role/$LambdaRoleName"
    } else {
        $lambdaTrust = '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
        $tempLamTrustFile = Join-Path $env:TEMP "lambda-trust-$([guid]::NewGuid().ToString('N')).json"
        Write-JsonNoBom $tempLamTrustFile $lambdaTrust
        $normLamTrustFile = $tempLamTrustFile.Replace('\', '/')

        $LambdaRoleArn = Invoke-AwsCli "Create Lambda IAM Role" {
            aws --profile $Profile --region $Region iam create-role `
                --role-name $LambdaRoleName `
                --assume-role-policy-document "file://$normLamTrustFile" `
                --tags "Key=Project,Value=SurgeGate" "Key=Environment,Value=$Environment" `
                --query "Role.Arn" --output text
        }
        Remove-Item -Path $tempLamTrustFile -Force -ErrorAction SilentlyContinue
        Write-Success "Created IAM Role: $LambdaRoleName ($LambdaRoleArn)"
    }
}

# ALWAYS ensure Lambda policies are attached / updated (idempotent)
if (-not $DryRun) {
    aws --profile $Profile --region $Region iam attach-role-policy --role-name $LambdaRoleName --policy-arn "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole" | Out-Null
    
    $lambdaPolicy = @"
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"],
            "Resource": "$SqsQueueArn"
        },
        {
            "Effect": "Allow",
            "Action": ["s3:PutObject", "s3:GetObject"],
            "Resource": "arn:aws:s3:::$S3Bucket/*"
        }
    ]
}
"@
    $tempLamPolFile = Join-Path $env:TEMP "lambda-policy-$([guid]::NewGuid().ToString('N')).json"
    Write-JsonNoBom $tempLamPolFile $lambdaPolicy
    $normLamPolFile = $tempLamPolFile.Replace('\', '/')

    Invoke-AwsCli "Put SurgeGateLambdaWorkerPolicy" {
        aws --profile $Profile --region $Region iam put-role-policy `
            --role-name $LambdaRoleName `
            --policy-name "SurgeGateLambdaWorkerPolicy" `
            --policy-document "file://$normLamPolFile"
    } | Out-Null
    Remove-Item -Path $tempLamPolFile -Force -ErrorAction SilentlyContinue
    Write-Success "Attached/Updated SurgeGateLambdaWorkerPolicy on $LambdaRoleName."
}

# ------------------------------------------------------------------------------
# 8. AWS Lambda Serverless Ticket Worker
# ------------------------------------------------------------------------------
Write-Step "7. AWS Lambda Ticket Worker Deployment"

$LambdaFunctionName = "surgegate-ticket-processor"
$LambdaZip = Join-Path $ScriptDir "lambda_payload.zip"
$LambdaHandlerFile = Join-Path $ScriptDir "lambda\ticket_processor.py"

if (-not (Test-Path $LambdaHandlerFile)) {
    Write-Failure "Handler file not found: $LambdaHandlerFile"
    exit 1
}

# Package Lambda zip
if (Test-Path $LambdaZip) { Remove-Item $LambdaZip -Force }
Compress-Archive -Path $LambdaHandlerFile -DestinationPath $LambdaZip -Force

$LambdaArn = aws --profile $Profile --region $Region lambda get-function --function-name $LambdaFunctionName --query "Configuration.FunctionArn" --output text 2>$null
if ($LambdaArn -and $LambdaArn -ne "None" -and -not $LambdaArn.StartsWith("aws:")) {
    $LambdaArn = [string]$LambdaArn.Trim()
    Write-Success "Found existing Lambda function: $LambdaArn"
    if (-not $DryRun) {
        aws --profile $Profile --region $Region lambda update-function-code --function-name $LambdaFunctionName --zip-file "fileb://$LambdaZip" 2>$null | Out-Null
        aws --profile $Profile --region $Region lambda update-function-configuration --function-name $LambdaFunctionName --environment "Variables={S3_BUCKET_NAME=$S3Bucket,ENVIRONMENT=$Environment}" 2>$null | Out-Null
        Write-Success "Updated Lambda function code and configuration."
    }
} else {
    if ($DryRun) {
        Write-Info "[DRY-RUN] Would create Lambda Function: $LambdaFunctionName"
        $LambdaArn = "arn:aws:lambda:${Region}:${AccountId}:function:${LambdaFunctionName}"
    } else {
        Write-Info "Creating Lambda function: $LambdaFunctionName..."
        Start-Sleep -Seconds 5
        $LambdaArn = Invoke-AwsCli "Create Lambda Function" {
            aws --profile $Profile --region $Region lambda create-function `
                --function-name $LambdaFunctionName `
                --runtime "python3.11" `
                --role $LambdaRoleArn `
                --handler "ticket_processor.lambda_handler" `
                --timeout 30 `
                --memory-size 128 `
                --zip-file "fileb://$LambdaZip" `
                --environment "Variables={S3_BUCKET_NAME=$S3Bucket,ENVIRONMENT=$Environment}" `
                --tags "Project=SurgeGate,Environment=$Environment" `
                --query "FunctionArn" --output text
        }
        Write-Success "Created Lambda function: $LambdaArn"
    }
}

# SQS Trigger Mapping with Bounded IAM Propagation Backoff
if (-not $DryRun) {
    $mapping = aws --profile $Profile --region $Region lambda list-event-source-mappings `
        --function-name $LambdaFunctionName `
        --query "EventSourceMappings[?EventSourceArn=='$SqsQueueArn'].UUID" --output text 2>$null
    
    if (-not $mapping -or $mapping -eq "None" -or $mapping.StartsWith("aws:")) {
        Write-Info "Configuring Lambda SQS Event Source Mapping..."
        $esmCreated = $false
        for ($attempt = 1; $attempt -le 5; $attempt++) {
            $esmRes = aws --profile $Profile --region $Region lambda create-event-source-mapping `
                --function-name $LambdaFunctionName `
                --event-source-arn $SqsQueueArn `
                --batch-size 5 `
                --enabled 2>&1
            if ($LASTEXITCODE -eq 0) {
                $esmCreated = $true
                Write-Success "Connected SQS queue to Lambda ticket processor."
                break
            }
            Write-Warn "Lambda ESM creation attempt $attempt/5: $esmRes. Retrying in 5s (waiting for IAM propagation)..."
            Start-Sleep -Seconds 5
        }
        if (-not $esmCreated) {
            Write-Failure "Failed to connect Lambda to SQS Queue after 5 attempts."
            exit 1
        }
    } else {
        Write-Success "Found existing Lambda Event Source Mapping ($mapping) for SQS queue."
    }
}
if (Test-Path $LambdaZip) { Remove-Item $LambdaZip -Force }

# ------------------------------------------------------------------------------
# 9. Amazon RDS for MySQL Database (Strict Preservation)
# ------------------------------------------------------------------------------
Write-Step "8. Amazon RDS MySQL Database Configuration"

$DbSubnetGroupName = "surgegate-db-subnet-group"
$existingSubGroup = aws --profile $Profile --region $Region rds describe-db-subnet-groups --db-subnet-group-name $DbSubnetGroupName --query "DBSubnetGroups[0].DBSubnetGroupName" --output text 2>$null
if ($existingSubGroup -and $existingSubGroup -ne "None" -and -not $existingSubGroup.StartsWith("aws:")) {
    Write-Success "Found existing DB Subnet Group: $DbSubnetGroupName"
} else {
    if ($DryRun) {
        Write-Info "[DRY-RUN] Would create DB Subnet Group across $PrivSubA and $PrivSubB"
    } else {
        $subList = "$PrivSubA $PrivSubB"
        Invoke-AwsCli "Create DB Subnet Group" {
            aws --profile $Profile --region $Region rds create-db-subnet-group `
                --db-subnet-group-name $DbSubnetGroupName `
                --db-subnet-group-description "SurgeGate private database subnets" `
                --subnet-ids $PrivSubA $PrivSubB `
                --tags "Key=Project,Value=SurgeGate" "Key=Environment,Value=$Environment"
        } | Out-Null
        Write-Success "Created DB Subnet Group: $DbSubnetGroupName"
    }
}

$existingDb = aws --profile $Profile --region $Region rds describe-db-instances --db-instance-identifier $DbInstanceId --query "DBInstances[0].DBInstanceStatus" --output text 2>$null
$DbEndpoint = ""
if ($existingDb -and $existingDb -ne "None" -and -not $existingDb.StartsWith("aws:")) {
    $DbEndpoint = (aws --profile $Profile --region $Region rds describe-db-instances --db-instance-identifier $DbInstanceId --query "DBInstances[0].Endpoint.Address" --output text 2>$null).Trim()
    Write-Success "Found existing RDS DB instance: $DbInstanceId ($DbEndpoint) [PRESERVED - UNCHANGED]"
} else {
    if ($DryRun) {
        Write-Info "[DRY-RUN] Would create RDS MySQL instance $DbInstanceId (Single-AZ, 20GB gp3, private, auto-minor-upgrade)"
        $DbEndpoint = "surgegate-db-dryrun.c123456789.ap-south-1.rds.amazonaws.com"
    } else {
        Write-Info "Creating RDS MySQL instance: $DbInstanceId (this typically takes 5-10 minutes)..."
        Invoke-AwsCli "Create RDS Instance" {
            aws --profile $Profile --region $Region rds create-db-instance `
                --db-instance-identifier $DbInstanceId `
                --db-instance-class $DbInstanceClass `
                --engine mysql `
                --engine-version "8.0" `
                --master-username $DbUser `
                --master-user-password $DbPassword `
                --allocated-storage 20 `
                --max-allocated-storage 50 `
                --storage-type gp3 `
                --storage-encrypted `
                --db-subnet-group-name $DbSubnetGroupName `
                --vpc-security-group-ids $RdsSgId `
                --db-name $DbName `
                --no-publicly-accessible `
                --backup-retention-period 1 `
                --no-multi-az `
                --tags "Key=Project,Value=SurgeGate" "Key=Environment,Value=$Environment"
        } | Out-Null

        Write-Info "Waiting for RDS instance $DbInstanceId to become available..."
        aws --profile $Profile --region $Region rds wait db-instance-available --db-instance-identifier $DbInstanceId
        $DbEndpoint = (aws --profile $Profile --region $Region rds describe-db-instances --db-instance-identifier $DbInstanceId --query "DBInstances[0].Endpoint.Address" --output text).Trim()
        Write-Success "RDS MySQL Instance is available at: ${DbEndpoint}:3306"
    }
}

# ------------------------------------------------------------------------------
# 10. Application Load Balancer & Target Group
# ------------------------------------------------------------------------------
Write-Step "9. Application Load Balancer and Target Group Configuration"

$TgName = "surgegate-tg"
$AlbName = "surgegate-alb"

$TargetGroupArn = aws --profile $Profile --region $Region elbv2 describe-target-groups --names $TgName --query "TargetGroups[0].TargetGroupArn" --output text 2>$null
if ($TargetGroupArn -and $TargetGroupArn -ne "None" -and -not $TargetGroupArn.StartsWith("aws:")) {
    $TargetGroupArn = [string]$TargetGroupArn.Trim()
    Write-Success "Found existing Target Group: $TargetGroupArn"
} else {
    if ($DryRun) {
        Write-Info "[DRY-RUN] Would create Target Group: $TgName (Port $AppPort, health check /health)"
        $TargetGroupArn = "arn:aws:elasticloadbalancing:${Region}:${AccountId}:targetgroup/${TgName}/dryrun"
    } else {
        $TargetGroupArn = Invoke-AwsCli "Create Target Group" {
            aws --profile $Profile --region $Region elbv2 create-target-group `
                --name $TgName `
                --protocol HTTP `
                --port $AppPort `
                --vpc-id $VpcId `
                --target-type instance `
                --health-check-protocol HTTP `
                --health-check-port $AppPort `
                --health-check-path "/health" `
                --health-check-interval-seconds 30 `
                --healthy-threshold-count 2 `
                --unhealthy-threshold-count 3 `
                --tags "Key=Project,Value=SurgeGate" "Key=Environment,Value=$Environment" `
                --query "TargetGroups[0].TargetGroupArn" --output text
        }
        Write-Success "Created Target Group: $TargetGroupArn"
    }
}

# ALB
$AlbArn = aws --profile $Profile --region $Region elbv2 describe-load-balancers --names $AlbName --query "LoadBalancers[0].LoadBalancerArn" --output text 2>$null
$AlbDnsName = ""
if ($AlbArn -and $AlbArn -ne "None" -and -not $AlbArn.StartsWith("aws:")) {
    $AlbArn = [string]$AlbArn.Trim()
    $AlbDnsName = (aws --profile $Profile --region $Region elbv2 describe-load-balancers --load-balancer-arns $AlbArn --query "LoadBalancers[0].DNSName" --output text 2>$null).Trim()
    Write-Success "Found existing ALB: http://$AlbDnsName"
} else {
    if ($DryRun) {
        Write-Info "[DRY-RUN] Would create Application Load Balancer across $PubSubA and $PubSubB"
        $AlbArn = "arn:aws:elasticloadbalancing:${Region}:${AccountId}:loadbalancer/app/${AlbName}/dryrun"
        $AlbDnsName = "surgegate-alb-dryrun.elb.amazonaws.com"
    } else {
        Write-Info "Creating Application Load Balancer: $AlbName..."
        $AlbArn = Invoke-AwsCli "Create ALB" {
            aws --profile $Profile --region $Region elbv2 create-load-balancer `
                --name $AlbName `
                --subnets $PubSubA $PubSubB `
                --security-groups $AlbSgId `
                --scheme internet-facing `
                --type application `
                --ip-address-type ipv4 `
                --tags "Key=Project,Value=SurgeGate" "Key=Environment,Value=$Environment" `
                --query "LoadBalancers[0].LoadBalancerArn" --output text
        }
        $AlbDnsName = (aws --profile $Profile --region $Region elbv2 describe-load-balancers --load-balancer-arns $AlbArn --query "LoadBalancers[0].DNSName" --output text).Trim()
        Write-Success "Created Application Load Balancer: http://$AlbDnsName"
    }
}

# Listener (HTTP:80 -> Target Group)
if (-not $DryRun) {
    $listener = aws --profile $Profile --region $Region elbv2 describe-listeners --load-balancer-arn $AlbArn --query "Listeners[?Port==``80``].ListenerArn" --output text 2>$null
    if (-not $listener -or $listener -eq "None" -or $listener.StartsWith("aws:")) {
        Invoke-AwsCli "Create ALB Listener" {
            aws --profile $Profile --region $Region elbv2 create-listener `
                --load-balancer-arn $AlbArn `
                --protocol HTTP `
                --port 80 `
                --default-actions "Type=forward,TargetGroupArn=$TargetGroupArn" `
                --tags "Key=Project,Value=SurgeGate" "Key=Environment,Value=$Environment"
        } | Out-Null
        Write-Success "Created ALB HTTP:80 Listener forwarding to $TgName"
    } else {
        Write-Success "Found existing ALB HTTP:80 Listener."
    }
}

# ------------------------------------------------------------------------------
# 11. EC2 Launch Template & Auto Scaling Group
# ------------------------------------------------------------------------------
Write-Step "10. EC2 Launch Template and Auto Scaling Group Configuration"

$LtName = "surgegate-lt"
$AsgName = "surgegate-asg"

$baselineUserData = @"
#!/usr/bin/env bash
exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1
echo "SurgeGate Baseline Infrastructure Node starting..."

yum update -y
yum install -y python3-pip jq

mkdir -p /opt/surgegate
cat << 'APP_EOF' > /opt/surgegate/server.py
import http.server
import socketserver
import json

PORT = $AppPort

class SurgeGateHandler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/health' or self.path == '/':
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            response = {
                "status": "HEALTHY",
                "service": "SurgeGate Edge Node",
                "environment": "$Environment",
                "sqs_queue": "$SqsQueueName",
                "db_configured": bool("$DbEndpoint"),
                "message": "SurgeGate traffic management node is operational."
            }
            self.wfile.write(json.dumps(response).encode('utf-8'))
        else:
            self.send_response(404)
            self.end_headers()

with socketserver.TCPServer(("", PORT), SurgeGateHandler) as httpd:
    httpd.serve_forever()
APP_EOF

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
echo "SurgeGate Edge Node operational."
"@

$userDataB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($baselineUserData))

$amiId = aws --profile $Profile --region $Region ec2 describe-images `
    --owners amazon `
    --filters "Name=name,Values=al2023-ami-2023.*-x86_64" "Name=state,Values=available" `
    --query "Images | sort_by(@, &CreationDate) | [-1].ImageId" --output text 2>$null

if (-not $amiId -or $amiId -eq "None" -or $amiId.StartsWith("aws:")) {
    $amiId = "ami-053b12d3152c0cc71" # Standard AL2023 fallback for ap-south-1
}
Write-Info "Target AMI: $amiId"

$LaunchTemplateId = aws --profile $Profile --region $Region ec2 describe-launch-templates `
    --filters "Name=launch-template-name,Values=$LtName" `
    --query "LaunchTemplates[0].LaunchTemplateId" --output text 2>$null

if ($LaunchTemplateId -and $LaunchTemplateId -ne "None" -and -not $LaunchTemplateId.StartsWith("aws:")) {
    $LaunchTemplateId = [string]$LaunchTemplateId.Trim()
    Write-Success "Found existing Launch Template: $LaunchTemplateId ($LtName)"
} else {
    if ($DryRun) {
        Write-Info "[DRY-RUN] Would create Launch Template $LtName ($Ec2InstanceType, IMDSv2 HopLimit 2, 20GB gp3)"
        $LaunchTemplateId = "lt-dryrunplaceholder"
    } else {
        $ltConfig = @{
            ImageId = $amiId
            InstanceType = $Ec2InstanceType
            IamInstanceProfile = @{ Name = $Ec2ProfileName }
            SecurityGroupIds = @($Ec2SgId)
            UserData = $userDataB64
            MetadataOptions = @{
                HttpEndpoint = "enabled"
                HttpTokens = "required"
                HttpPutResponseHopLimit = 2
            }
            BlockDeviceMappings = @(
                @{
                    DeviceName = "/dev/xvda"
                    Ebs = @{
                        VolumeSize = 20
                        VolumeType = "gp3"
                        Encrypted = $true
                        DeleteOnTermination = $true
                    }
                }
            )
        }
        $tempLtFile = Join-Path $env:TEMP "lt-data-$([guid]::NewGuid().ToString('N')).json"
        Write-JsonNoBom $tempLtFile ($ltConfig | ConvertTo-Json -Depth 5)
        $normLtFile = $tempLtFile.Replace('\', '/')

        $ltTag = ($TagSpec -f "launch-template", $LtName, $Environment)
        $LaunchTemplateId = Invoke-AwsCli "Create Launch Template" {
            aws --profile $Profile --region $Region ec2 create-launch-template `
                --launch-template-name $LtName `
                --launch-template-data "file://$normLtFile" `
                --tag-specifications $ltTag `
                --query "LaunchTemplate.LaunchTemplateId" --output text
        }
        Remove-Item -Path $tempLtFile -Force -ErrorAction SilentlyContinue
        Write-Success "Created Launch Template: $LaunchTemplateId"
    }
}

# Auto Scaling Group Discovery / Creation
$existingAsg = aws --profile $Profile --region $Region autoscaling describe-auto-scaling-groups `
    --auto-scaling-group-names $AsgName `
    --query "AutoScalingGroups[0].AutoScalingGroupName" --output text 2>$null

if ($existingAsg -and $existingAsg -ne "None" -and -not $existingAsg.StartsWith("aws:")) {
    Write-Success "Found existing Auto Scaling Group: $AsgName"
} else {
    if ($DryRun) {
        Write-Info "[DRY-RUN] Would create Auto Scaling Group $AsgName (Min: 1, Desired: 1, Max: 2)"
    } else {
        $subnetList = "$PubSubA,$PubSubB"
        Invoke-AwsCli "Create Auto Scaling Group" {
            aws --profile $Profile --region $Region autoscaling create-auto-scaling-group `
                --auto-scaling-group-name $AsgName `
                --launch-template "LaunchTemplateId=$LaunchTemplateId,Version=`$Latest" `
                --min-size 1 `
                --max-size 2 `
                --desired-capacity 1 `
                --vpc-zone-identifier $subnetList `
                --target-group-arns $TargetGroupArn `
                --health-check-type "ELB" `
                --health-check-grace-period 180 `
                --tags "Key=Project,Value=SurgeGate,PropagateAtLaunch=true" "Key=Environment,Value=$Environment,PropagateAtLaunch=true" "Key=Name,Value=surgegate-app-instance,PropagateAtLaunch=true"
        } | Out-Null
        Write-Success "Created Auto Scaling Group: $AsgName"
    }
}

# ALWAYS ensure ASG CPU Target Tracking Policy is attached with bounded backoff for Service-Linked Role
if (-not $DryRun) {
    $existingPol = aws --profile $Profile --region $Region autoscaling describe-policies `
        --auto-scaling-group-name $AsgName `
        --policy-names "surgegate-cpu-target-tracking" `
        --query "ScalingPolicies[0].PolicyARN" --output text 2>$null

    if (-not $existingPol -or $existingPol -eq "None" -or $existingPol.StartsWith("aws:")) {
        Write-Info "Configuring ASG CPU Target Tracking Policy (70% CPU)..."
        $ttConfig = @{
            TargetValue = 70.0
            PredefinedMetricSpecification = @{
                PredefinedMetricType = "ASGAverageCPUUtilization"
            }
        }
        $tempTtFile = Join-Path $env:TEMP "tt-policy-$([guid]::NewGuid().ToString('N')).json"
        Write-JsonNoBom $tempTtFile ($ttConfig | ConvertTo-Json -Depth 4)
        $normTtFile = $tempTtFile.Replace('\', '/')

        $policyApplied = $false
        for ($attempt = 1; $attempt -le 6; $attempt++) {
            $polRes = aws --profile $Profile --region $Region autoscaling put-scaling-policy `
                --auto-scaling-group-name $AsgName `
                --policy-name "surgegate-cpu-target-tracking" `
                --policy-type "TargetTrackingScaling" `
                --target-tracking-configuration "file://$normTtFile" 2>&1
            if ($LASTEXITCODE -eq 0) {
                $policyApplied = $true
                Write-Success "Configured ASG CPU Target Tracking Policy (70% CPU target)."
                break
            }
            if ($polRes -match "ServiceLinkedRole" -or $polRes -match "not yet ready") {
                Write-Warn "ASG Service-Linked Role is propagating (attempt $attempt/6). Waiting 10 seconds..."
                Start-Sleep -Seconds 10
            } else {
                Write-Warn "put-scaling-policy attempt $attempt/6 returned: $polRes. Retrying in 5 seconds..."
                Start-Sleep -Seconds 5
            }
        }
        Remove-Item -Path $tempTtFile -Force -ErrorAction SilentlyContinue

        if (-not $policyApplied) {
            Write-Failure "Failed to attach CPU Target Tracking Policy to ASG '$AsgName' after 6 attempts."
            exit 1
        }
    } else {
        Write-Success "Found existing ASG CPU Target Tracking Policy: surgegate-cpu-target-tracking."
    }
}

# ------------------------------------------------------------------------------
# 12. Amazon CloudWatch Alarms
# ------------------------------------------------------------------------------
if (-not $DryRun) {
    Write-Step "11. Amazon CloudWatch Alarms Configuration"
    aws --profile $Profile --region $Region cloudwatch put-metric-alarm `
        --alarm-name "surgegate-asg-high-cpu" `
        --alarm-description "SurgeGate ASG CPU Utilization exceeds 75%" `
        --metric-name CPUUtilization `
        --namespace AWS/EC2 `
        --statistic Average `
        --period 120 `
        --threshold 75 `
        --comparison-operator GreaterThanThreshold `
        --dimensions "Name=AutoScalingGroupName,Value=$AsgName" `
        --evaluation-periods 2 `
        --unit Percent `
        --tags "Key=Project,Value=SurgeGate" "Key=Environment,Value=$Environment" | Out-Null

    aws --profile $Profile --region $Region cloudwatch put-metric-alarm `
        --alarm-name "surgegate-sqs-queue-backlog" `
        --alarm-description "SurgeGate SQS buffer exceeds 50 visible messages" `
        --metric-name ApproximateNumberOfMessagesVisible `
        --namespace AWS/SQS `
        --statistic Average `
        --period 60 `
        --threshold 50 `
        --comparison-operator GreaterThanThreshold `
        --dimensions "Name=QueueName,Value=$SqsQueueName" `
        --evaluation-periods 1 `
        --unit Count `
        --tags "Key=Project,Value=SurgeGate" "Key=Environment,Value=$Environment" | Out-Null

    aws --profile $Profile --region $Region cloudwatch put-metric-alarm `
        --alarm-name "surgegate-rds-high-cpu" `
        --alarm-description "SurgeGate RDS MySQL CPU exceeds 80%" `
        --metric-name CPUUtilization `
        --namespace AWS/RDS `
        --statistic Average `
        --period 300 `
        --threshold 80 `
        --comparison-operator GreaterThanThreshold `
        --dimensions "Name=DBInstanceIdentifier,Value=$DbInstanceId" `
        --evaluation-periods 2 `
        --unit Percent `
        --tags "Key=Project,Value=SurgeGate" "Key=Environment,Value=$Environment" | Out-Null
    Write-Success "Configured CloudWatch Alarms: ASG CPU, SQS backlog, and RDS CPU."
}

# ------------------------------------------------------------------------------
# 13. AWS Systems Manager Parameter Store Configuration
# ------------------------------------------------------------------------------
Write-Step "12. AWS Systems Manager Parameter Store Configuration"

if ($DryRun) {
    Write-Info "[DRY-RUN] Would store parameters under $SsmPrefix/* in SSM Parameter Store."
} else {
    function Put-SsmParam {
        param($key, $val, $type = "String")
        if ([string]::IsNullOrWhiteSpace($val) -or $val -eq "None") {
            return
        }
        $paramName = "$SsmPrefix/$key"
        Invoke-AwsCli "Put SSM Parameter $paramName" {
            aws --profile $Profile --region $Region ssm put-parameter `
                --name "$paramName" `
                --value "$val" `
                --type "$type" `
                --overwrite
        } | Out-Null
        
        # Tag parameter via separate idempotent call
        aws --profile $Profile --region $Region ssm add-tags-to-resource `
            --resource-type "Parameter" `
            --resource-id "$paramName" `
            --tags "Key=Project,Value=SurgeGate" "Key=Environment,Value=$Environment" 2>$null | Out-Null
    }

    Put-SsmParam "vpc_id" $VpcId
    Put-SsmParam "public_subnet_1" $PubSubA
    Put-SsmParam "public_subnet_2" $PubSubB
    Put-SsmParam "private_subnet_1" $PrivSubA
    Put-SsmParam "private_subnet_2" $PrivSubB
    Put-SsmParam "alb_arn" $AlbArn
    Put-SsmParam "alb_dns_name" $AlbDnsName
    Put-SsmParam "alb_endpoint" "http://$AlbDnsName"
    Put-SsmParam "target_group_arn" $TargetGroupArn
    Put-SsmParam "ec2_security_group" $Ec2SgId
    Put-SsmParam "rds_security_group" $RdsSgId
    Put-SsmParam "db_host" $DbEndpoint
    Put-SsmParam "db_port" "3306"
    Put-SsmParam "db_name" $DbName
    Put-SsmParam "db_user" $DbUser
    if (-not [string]::IsNullOrWhiteSpace($DbPassword) -and $DbPassword -ne "[DRY-RUN-MASKED-PASSWORD]") {
        Put-SsmParam "db_password" $DbPassword "SecureString"
    }
    Put-SsmParam "s3_bucket" $S3Bucket
    Put-SsmParam "sqs_url" $SqsQueueUrl
    Put-SsmParam "sqs_arn" $SqsQueueArn
    Put-SsmParam "sqs_dlq_url" $SqsDlqUrl
    Put-SsmParam "sqs_dlq_arn" $SqsDlqArn
    Put-SsmParam "lambda_arn" $LambdaArn
    Put-SsmParam "asg_name" $AsgName
    Write-Success "Stored infrastructure outputs and secrets under $SsmPrefix/* in SSM Parameter Store."
}

# ------------------------------------------------------------------------------
# 14. Export Deployment Outputs (JSON & ENV)
# ------------------------------------------------------------------------------
Write-Step "13. Exporting Verified Infrastructure Deployment Artifacts"

$outputs = [ordered]@{
    timestamp              = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    account_id             = $AccountId
    region                 = $Region
    profile                = $Profile
    project_name           = $ProjectName
    environment            = $Environment
    vpc_id                 = $VpcId
    internet_gateway_id    = $IgwId
    public_subnet_1        = $PubSubA
    public_subnet_2        = $PubSubB
    private_subnet_1       = $PrivSubA
    private_subnet_2       = $PrivSubB
    alb_security_group     = $AlbSgId
    ec2_security_group     = $Ec2SgId
    rds_security_group     = $RdsSgId
    lambda_security_group  = $LambdaSgId
    s3_bucket              = $S3Bucket
    sqs_queue_url          = "$SqsQueueUrl"
    sqs_queue_arn          = "$SqsQueueArn"
    sqs_dlq_url            = "$SqsDlqUrl"
    sqs_dlq_arn            = "$SqsDlqArn"
    ec2_role_arn           = "$Ec2RoleArn"
    ec2_instance_profile   = "$Ec2ProfileName"
    lambda_role_arn        = "$LambdaRoleArn"
    lambda_function_arn    = "$LambdaArn"
    db_instance_identifier = "$DbInstanceId"
    db_endpoint            = "$DbEndpoint"
    db_port                = 3306
    db_name                = "$DbName"
    db_user                = "$DbUser"
    target_group_arn       = "$TargetGroupArn"
    alb_arn                = "$AlbArn"
    alb_dns_name           = "$AlbDnsName"
    launch_template_id     = "$LaunchTemplateId"
    asg_name               = "$AsgName"
}

$outputs | ConvertTo-Json -Depth 5 | Set-Content -Path $OutputsJson -Encoding UTF8
Write-Success "Saved JSON outputs to: $OutputsJson"

$envContent = @"
# SurgeGate Deployed Infrastructure Endpoints
SURGEGATE_VPC_ID=$VpcId
SURGEGATE_ALB_ENDPOINT=http://$AlbDnsName
SURGEGATE_DB_HOST=$DbEndpoint
SURGEGATE_DB_PORT=3306
SURGEGATE_DB_NAME=$DbName
SURGEGATE_DB_USER=$DbUser
SURGEGATE_SQS_URL=$SqsQueueUrl
SURGEGATE_SQS_ARN=$SqsQueueArn
SURGEGATE_SQS_DLQ_URL=$SqsDlqUrl
SURGEGATE_SQS_DLQ_ARN=$SqsDlqArn
SURGEGATE_S3_BUCKET=$S3Bucket
SURGEGATE_LAMBDA_ARN=$LambdaArn
"@
Set-Content -Path $OutputsEnv -Value $envContent -Encoding UTF8
Write-Success "Saved environment variables to: $OutputsEnv"

# ------------------------------------------------------------------------------
# 15. Deployment Verification Summary
# ------------------------------------------------------------------------------
Write-Host "`n==============================================================================" -ForegroundColor Green
Write-Host "          SurgeGate AWS Infrastructure Provisioned Successfully!              " -ForegroundColor Green
Write-Host "==============================================================================" -ForegroundColor Green
Write-Host "`nLive Infrastructure Endpoints & Identifiers:" -ForegroundColor White
Write-Host " • VPC ID:                 $VpcId" -ForegroundColor Cyan
Write-Host " • ALB Endpoint:           http://$AlbDnsName" -ForegroundColor Cyan
Write-Host " • Health Check Endpoint:   http://$AlbDnsName/health" -ForegroundColor Cyan
Write-Host " • RDS MySQL Host:         ${DbEndpoint}:3306" -ForegroundColor Cyan
Write-Host " • S3 Ticket Storage:      s3://$S3Bucket" -ForegroundColor Cyan
Write-Host " • SQS Main Queue URL:     $SqsQueueUrl" -ForegroundColor Cyan
Write-Host " • SQS Dead Letter Queue:  $SqsDlqUrl" -ForegroundColor Cyan
Write-Host " • Lambda Worker ARN:      $LambdaArn" -ForegroundColor Cyan
Write-Host " • Auto Scaling Group:     $AsgName" -ForegroundColor Cyan
Write-Host " • Parameter Store:        $SsmPrefix/*" -ForegroundColor Cyan
Write-Host ""
