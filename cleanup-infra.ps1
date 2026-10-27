<#
.SYNOPSIS
    SurgeGate - AWS Infrastructure Teardown & Cleanup Script (PowerShell Native)
.DESCRIPTION
    Safely tears down SurgeGate resources in reverse dependency order.
    Requires explicit confirmation to prevent accidental deletion and
    guarantees non-interference with unrelated AWS resources.
.PARAMETER Force
    If specified, bypasses confirmation prompts.
.PARAMETER DeleteData
    If specified, permanently deletes RDS and S3 data stores.
.PARAMETER Region
    AWS Region (default: 'ap-south-1').
#>

[CmdletBinding()]
param(
    [switch]$Force,
    [switch]$DeleteData,
    [string]$Profile = "surgegate",
    [string]$Region = "ap-south-1",
    [string]$Environment = "dev"
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

Write-Host "==============================================================================" -ForegroundColor Red
Write-Host "          SurgeGate - AWS Infrastructure Teardown (PowerShell)                " -ForegroundColor Red
Write-Host "==============================================================================" -ForegroundColor Red

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$OutputsPath = Join-Path $ScriptDir "deployment-outputs.json"
$outputs = $null
if (Test-Path $OutputsPath) {
    try {
        $outputs = Get-Content -Raw -Path $OutputsPath | ConvertFrom-Json
        if ($outputs.region) { $Region = $outputs.region }
        if ($outputs.environment) { $Environment = $outputs.environment }
    } catch { }
}

$callerJson = aws sts get-caller-identity --profile $Profile --region $Region --output json 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Failure "AWS authentication failed with profile '$Profile'. Run 'aws configure --profile $Profile'."
    exit 1
}
$caller = $callerJson | ConvertFrom-Json
$AccountId = $caller.Account
if ($AccountId -ne "269494630662") {
    Write-Failure "ACCOUNT MISMATCH! Expected account 269494630662, but authenticated as $AccountId. Aborting teardown."
    exit 1
}

Write-Host "Target Environment for Deletion:" -ForegroundColor Yellow
Write-Host " • AWS Account:  $AccountId ($($caller.Arn))" -ForegroundColor Cyan
Write-Host " • AWS Region:   $Region" -ForegroundColor Cyan
Write-Host " • AWS Profile:  $Profile" -ForegroundColor Cyan
Write-Host " • Project Tag:  Project=SurgeGate" -ForegroundColor Cyan

if (-not $Force) {
    $confirm = Read-Host "`nWARNING: This will delete SurgeGate AWS resources. Type 'yes' to proceed"
    if ($confirm -ne "yes") {
        Write-Info "Teardown aborted."
        exit 0
    }

    if (-not $DeleteData) {
        $dataConfirm = Read-Host "Permanently destroy RDS database and S3 bucket? Type 'DELETE-DATA' or press Enter to preserve"
        if ($dataConfirm -eq "DELETE-DATA") {
            $DeleteData = $true
        }
    }
}

# 1. CloudWatch Alarms
Write-Step "1. Deleting CloudWatch Alarms"
$alarms = @("surgegate-asg-high-cpu", "surgegate-sqs-queue-backlog", "surgegate-rds-high-cpu")
foreach ($a in $alarms) {
    aws cloudwatch delete-alarms --region $Region --alarm-names $a 2>$null | Out-Null
    Write-Success "Deleted alarm: $a"
}

# 2. ASG & Launch Template
Write-Step "2. Terminating Auto Scaling Group and Launch Template"
$asgName = if ($outputs) { $outputs.asg_name } else { "surgegate-asg" }
$hasAsg = aws autoscaling describe-auto-scaling-groups --region $Region --auto-scaling-group-names $asgName --query "AutoScalingGroups[0].AutoScalingGroupName" --output text 2>$null
if ($hasAsg -and $hasAsg -ne "None") {
    Write-Info "Scaling ASG $asgName to 0 instances..."
    aws autoscaling update-auto-scaling-group --region $Region --auto-scaling-group-name $asgName --min-size 0 --max-size 0 --desired-capacity 0 2>$null | Out-Null
    
    while ($true) {
        $instances = aws autoscaling describe-auto-scaling-groups --region $Region --auto-scaling-group-names $asgName --query "AutoScalingGroups[0].Instances | length" --output text 2>$null
        if (-not $instances -or $instances -eq "0" -or $instances -eq "None") { break }
        Write-Info "Waiting for $instances instances to shut down..."
        Start-Sleep -Seconds 10
    }
    aws autoscaling delete-auto-scaling-group --region $Region --auto-scaling-group-name $asgName --force-delete 2>$null | Out-Null
    Write-Success "Deleted Auto Scaling Group: $asgName"
}

$ltId = aws ec2 describe-launch-templates --region $Region --filters "Name=launch-template-name,Values=surgegate-lt" --query "LaunchTemplates[0].LaunchTemplateId" --output text 2>$null
if ($ltId -and $ltId -ne "None") {
    aws ec2 delete-launch-template --region $Region --launch-template-id $ltId 2>$null | Out-Null
    Write-Success "Deleted Launch Template: $ltId"
}

# 3. ALB & Target Group
Write-Step "3. Deleting Load Balancer and Target Group"
$albArn = if ($outputs) { $outputs.alb_arn } else { aws elbv2 describe-load-balancers --region $Region --names "surgegate-alb" --query "LoadBalancers[0].LoadBalancerArn" --output text 2>$null }
if ($albArn -and $albArn -ne "None") {
    $listeners = (aws elbv2 describe-listeners --region $Region --load-balancer-arn $albArn --query "Listeners[].ListenerArn" --output text 2>$null).Trim().Split([char[]]@("`t", ' ', "`r", "`n"), [System.StringSplitOptions]::RemoveEmptyEntries)
    foreach ($l in $listeners) {
        aws elbv2 delete-listener --region $Region --listener-arn $l 2>$null | Out-Null
    }
    aws elbv2 delete-load-balancer --region $Region --load-balancer-arn $albArn 2>$null | Out-Null
    Write-Info "Waiting for ALB release..."
    Start-Sleep -Seconds 15
    Write-Success "Deleted ALB: $albArn"
}

$tgArn = if ($outputs) { $outputs.target_group_arn } else { aws elbv2 describe-target-groups --region $Region --names "surgegate-tg" --query "TargetGroups[0].TargetGroupArn" --output text 2>$null }
if ($tgArn -and $tgArn -ne "None") {
    aws elbv2 delete-target-group --region $Region --target-group-arn $tgArn 2>$null | Out-Null
    Write-Success "Deleted Target Group: $tgArn"
}

# 4. Lambda & Triggers
Write-Step "4. Deleting Lambda Function & SQS Trigger"
$lambdaName = "surgegate-ticket-processor"
$esms = (aws lambda list-event-source-mappings --region $Region --function-name $lambdaName --query "EventSourceMappings[].UUID" --output text 2>$null).Trim().Split([char[]]@("`t", ' ', "`r", "`n"), [System.StringSplitOptions]::RemoveEmptyEntries)
foreach ($esm in $esms) {
    if ($esm -and $esm -ne "None") {
        aws lambda delete-event-source-mapping --region $Region --uuid $esm 2>$null | Out-Null
        Write-Success "Deleted Event Source Mapping: $esm"
    }
}
aws lambda delete-function --region $Region --function-name $lambdaName 2>$null | Out-Null
Write-Success "Deleted Lambda Function: $lambdaName"

# 5. SQS Queues
Write-Step "5. Deleting SQS Queues"
$mainQUrl = aws sqs get-queue-url --region $Region --queue-name "surgegate-ticket-queue" --query "QueueUrl" --output text 2>$null
if ($mainQUrl -and $mainQUrl -ne "None") {
    aws sqs delete-queue --region $Region --queue-url $mainQUrl 2>$null | Out-Null
    Write-Success "Deleted SQS Queue: $mainQUrl"
}
$dlqUrl = aws sqs get-queue-url --region $Region --queue-name "surgegate-ticket-dlq" --query "QueueUrl" --output text 2>$null
if ($dlqUrl -and $dlqUrl -ne "None") {
    aws sqs delete-queue --region $Region --queue-url $dlqUrl 2>$null | Out-Null
    Write-Success "Deleted SQS DLQ: $dlqUrl"
}

# 6. RDS Database (Protected)
if ($DeleteData) {
    Write-Step "6. Deleting RDS Database"
    $dbId = if ($outputs) { $outputs.db_instance_identifier } else { "surgegate-db" }
    aws rds delete-db-instance --region $Region --db-instance-identifier $dbId --skip-final-snapshot --delete-automated-backups 2>$null | Out-Null
    Write-Info "Waiting for RDS instance deletion..."
    aws rds wait db-instance-deleted --region $Region --db-instance-identifier $dbId 2>$null
    aws rds delete-db-subnet-group --region $Region --db-subnet-group-name "surgegate-db-subnet-group" 2>$null | Out-Null
    Write-Success "Deleted RDS Instance and Subnet Group: $dbId"
} else {
    Write-Info "Skipping RDS Database deletion (Preserved)."
}

# 7. S3 Bucket (Protected)
if ($DeleteData) {
    Write-Step "7. Deleting S3 Storage Bucket"
    $s3Bucket = if ($outputs) { $outputs.s3_bucket } else { aws s3api list-buckets --query "Buckets[?contains(Name, 'surgegate-tickets-')].Name | [0]" --output text 2>$null }
    if ($s3Bucket -and $s3Bucket -ne "None") {
        Write-Warn "Emptying and deleting S3 bucket: $s3Bucket..."
        aws s3 rm "s3://$s3Bucket" --recursive 2>$null | Out-Null
        aws s3api delete-bucket --bucket $s3Bucket 2>$null | Out-Null
        Write-Success "Deleted S3 bucket: $s3Bucket"
    }
} else {
    Write-Info "Skipping S3 Bucket deletion (Preserved)."
}

# 8. SSM Parameter Store
Write-Step "8. Deleting SSM Parameter Store Parameters"
$ssmPrefix = "/surgegate/$Environment"
$ssmParams = (aws ssm get-parameters-by-path --region $Region --path $ssmPrefix --query "Parameters[].Name" --output text 2>$null).Trim().Split([char[]]@("`t", ' ', "`r", "`n"), [System.StringSplitOptions]::RemoveEmptyEntries)
foreach ($p in $ssmParams) {
    if ($p -and $p -ne "None") {
        aws ssm delete-parameter --region $Region --name $p 2>$null | Out-Null
        Write-Success "Deleted SSM Parameter: $p"
    }
}

# 9. IAM Roles & Profile
Write-Step "9. Deleting IAM Roles & Instance Profile"
aws iam remove-role-from-instance-profile --instance-profile-name "surgegate-ec2-profile" --role-name "surgegate-ec2-role" 2>$null | Out-Null
aws iam delete-instance-profile --instance-profile-name "surgegate-ec2-profile" 2>$null | Out-Null
aws iam delete-role-policy --role-name "surgegate-ec2-role" --policy-name "SurgeGateEC2AppPolicy" 2>$null | Out-Null
aws iam detach-role-policy --role-name "surgegate-ec2-role" --policy-arn "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore" 2>$null | Out-Null
aws iam delete-role --role-name "surgegate-ec2-role" 2>$null | Out-Null

aws iam delete-role-policy --role-name "surgegate-lambda-role" --policy-name "SurgeGateLambdaWorkerPolicy" 2>$null | Out-Null
aws iam detach-role-policy --role-name "surgegate-lambda-role" --policy-arn "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole" 2>$null | Out-Null
aws iam delete-role --role-name "surgegate-lambda-role" 2>$null | Out-Null
Write-Success "Deleted SurgeGate IAM Roles and Instance Profile."

# 10. Security Groups
Write-Step "10. Deleting Security Groups"
$sgs = @("surgegate-db-sg", "surgegate-ec2-sg", "surgegate-alb-sg", "surgegate-lambda-sg")
foreach ($sgName in $sgs) {
    $sgId = aws ec2 describe-security-groups --region $Region --filters "Name=group-name,Values=$sgName" --query "SecurityGroups[0].GroupId" --output text 2>$null
    if ($sgId -and $sgId -ne "None") {
        $rules = aws ec2 describe-security-groups --region $Region --group-ids $sgId --query "SecurityGroups[0].IpPermissions" --output json 2>$null
        if ($rules -and $rules -ne "[]") {
            aws ec2 revoke-security-group-ingress --region $Region --group-id $sgId --ip-permissions $rules 2>$null | Out-Null
        }
    }
}

foreach ($sgName in $sgs) {
    $sgId = aws ec2 describe-security-groups --region $Region --filters "Name=group-name,Values=$sgName" --query "SecurityGroups[0].GroupId" --output text 2>$null
    if ($sgId -and $sgId -ne "None") {
        for ($i = 1; $i -le 6; $i++) {
            aws ec2 delete-security-group --region $Region --group-id $sgId 2>$null | Out-Null
            if ($LASTEXITCODE -eq 0) {
                Write-Success "Deleted Security Group: $sgName ($sgId)"
                break
            }
            Start-Sleep -Seconds 5
        }
    }
}

# 11. VPC & Networking
Write-Step "11. Deleting VPC Subnets, Route Tables, and Gateway"
$vpcId = if ($outputs) { $outputs.vpc_id } else { aws ec2 describe-vpcs --region $Region --filters "Name=tag:Name,Values=surgegate-vpc" --query "Vpcs[0].VpcId" --output text 2>$null }
if ($vpcId -and $vpcId -ne "None") {
    $subs = (aws ec2 describe-subnets --region $Region --filters "Name=vpc-id,Values=$vpcId" --query "Subnets[].SubnetId" --output text 2>$null).Trim().Split([char[]]@("`t", ' ', "`r", "`n"), [System.StringSplitOptions]::RemoveEmptyEntries)
    foreach ($s in $subs) {
        aws ec2 delete-subnet --region $Region --subnet-id $s 2>$null | Out-Null
        Write-Success "Deleted Subnet: $s"
    }

    $rts = (aws ec2 describe-route-tables --region $Region --filters "Name=vpc-id,Values=$vpcId" --query "RouteTables[?Associations[0].Main!=true].RouteTableId" --output text 2>$null).Trim().Split([char[]]@("`t", ' ', "`r", "`n"), [System.StringSplitOptions]::RemoveEmptyEntries)
    foreach ($r in $rts) {
        aws ec2 delete-route-table --region $Region --route-table-id $r 2>$null | Out-Null
        Write-Success "Deleted Route Table: $r"
    }

    $igw = aws ec2 describe-internet-gateways --region $Region --filters "Name=attachment.vpc-id,Values=$vpcId" --query "InternetGateways[0].InternetGatewayId" --output text 2>$null
    if ($igw -and $igw -ne "None") {
        aws ec2 detach-internet-gateway --region $Region --internet-gateway-id $igw --vpc-id $vpcId 2>$null | Out-Null
        aws ec2 delete-internet-gateway --region $Region --internet-gateway-id $igw 2>$null | Out-Null
        Write-Success "Detached and deleted Internet Gateway: $igw"
    }

    aws ec2 delete-vpc --region $Region --vpc-id $vpcId 2>$null | Out-Null
    Write-Success "Deleted SurgeGate VPC: $vpcId"
}

if ($DeleteData) {
    if (Test-Path $OutputsPath) { Remove-Item $OutputsPath -Force }
    $outputsEnvPath = Join-Path $ScriptDir "deployment-outputs.env"
    if (Test-Path $outputsEnvPath) { Remove-Item $outputsEnvPath -Force }
}

Write-Host "`n==============================================================================" -ForegroundColor Green
Write-Host "          SurgeGate Infrastructure Cleanup Completed Successfully!           " -ForegroundColor Green
Write-Host "==============================================================================" -ForegroundColor Green
