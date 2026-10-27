<#
.SYNOPSIS
    SurgeGate - AWS Infrastructure Verification Script (PowerShell Native)
.DESCRIPTION
    Audits actual AWS resource states, least-privilege security postures,
    database isolation, S3 encryption, SQS redrive, IAM role policies,
    Lambda SQS triggers, ASG scaling policies, ALB health, CloudWatch alarms,
    and SSM Parameter Store outputs.
.PARAMETER Profile
    AWS CLI Profile to use (default: 'surgegate').
.PARAMETER OutputsFile
    Relative or absolute path to deployment-outputs.json (default: 'deployment-outputs.json').
.PARAMETER Region
    AWS Region (default: 'ap-south-1').
.PARAMETER Environment
    Target deployment environment (default: 'dev').
#>

[CmdletBinding()]
param(
    [string]$Profile = "surgegate",
    [string]$OutputsFile = "deployment-outputs.json",
    [string]$Region = "ap-south-1",
    [string]$Environment = "dev"
)

$env:AWS_PROFILE = $Profile
$env:AWS_DEFAULT_REGION = $Region
$env:AWS_REGION = $Region

$ErrorActionPreference = "Continue"

$passCount = 0
$failCount = 0
$skipCount = 0

function Write-Pass { param([string]$msg) Write-Host "  [ PASS ] $msg" -ForegroundColor Green; $script:passCount++ }
function Write-Fail { param([string]$msg) Write-Host "  [ FAIL ] $msg" -ForegroundColor Red; $script:failCount++ }
function Write-Skip { param([string]$msg) Write-Host "  [ SKIP ] $msg" -ForegroundColor Yellow; $script:skipCount++ }
function Write-Sec  { param([string]$msg) Write-Host "`n==> $msg" -ForegroundColor Cyan }

function Convert-FromAwsJson {
    param($rawJson)
    if (-not $rawJson) { return $null }
    $str = $(if ($rawJson -is [array]) { $rawJson -join "`n" } else { [string]$rawJson })
    if ([string]::IsNullOrWhiteSpace($str) -or $str.StartsWith("aws:") -or $str.StartsWith("An error")) { return $null }
    try {
        return ($str | ConvertFrom-Json)
    } catch {
        return $null
    }
}

function Get-AwsTextList {
    param($text)
    if (-not $text) { return @() }
    $val = $(if ($text -is [array]) { $text -join " " } else { [string]$text })
    $str = $val.Trim()
    if ([string]::IsNullOrWhiteSpace($str) -or $str -eq "None" -or $str.StartsWith("aws:")) { return @() }
    return ($str.Split([char[]]@("`t", ' ', "`r", "`n"), [System.StringSplitOptions]::RemoveEmptyEntries))
}

Write-Host "==============================================================================" -ForegroundColor Cyan
Write-Host "          SurgeGate - AWS Infrastructure Verification & Audit                 " -ForegroundColor Cyan
Write-Host "==============================================================================" -ForegroundColor Cyan

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$OutputsPath = Join-Path $ScriptDir $OutputsFile

$outputs = $null
if (Test-Path $OutputsPath) {
    try {
        $outputs = Get-Content -Raw -Path $OutputsPath | ConvertFrom-Json
        if ($outputs.region) { $Region = $outputs.region }
        if ($outputs.environment) { $Environment = $outputs.environment }
    } catch {
        Write-Host "Note: Could not parse $OutputsFile as JSON." -ForegroundColor Yellow
    }
}

# 1. AWS Identity Check
Write-Sec "1. AWS CLI & Caller Identity"
$callerRaw = aws --profile $Profile --region $Region sts get-caller-identity --output json 2>&1
$caller = Convert-FromAwsJson $callerRaw
if ($caller -and $caller.Account) {
    if ($caller.Account -eq "269494630662") {
        Write-Pass "Authenticated AWS Caller: Account $($caller.Account) in $Region ($($caller.Arn), Profile: $Profile)"
    } else {
        Write-Fail "ACCOUNT MISMATCH! Expected 269494630662, found $($caller.Account). Aborting."
        exit 1
    }
} else {
    Write-Fail "AWS STS authentication failed with profile '$Profile'. Check credentials."
    exit 1
}

# 2. VPC & Networking
Write-Sec "2. Amazon VPC & Network Architecture"
$vpcId = $(if ($outputs -and ($outputs.vpc_id -is [string])) { $outputs.vpc_id } else { aws --profile $Profile --region $Region ec2 describe-vpcs --filters "Name=tag:Name,Values=surgegate-vpc" --query "Vpcs[0].VpcId" --output text 2>$null })
if ($vpcId -and $vpcId -ne "None" -and -not $vpcId.StartsWith("aws:")) {
    $vpcState = (aws --profile $Profile --region $Region ec2 describe-vpcs --vpc-ids $vpcId --query "Vpcs[0].State" --output text 2>$null)
    if ($vpcState -and $vpcState.Trim() -eq "available") {
        Write-Pass "VPC $vpcId is available."
    } else {
        Write-Fail "VPC $vpcId state is '$vpcState' (expected 'available')."
    }

    # Subnets
    $subnetsRaw = aws --profile $Profile --region $Region ec2 describe-subnets --filters "Name=vpc-id,Values=$vpcId" --query "Subnets[].{Id:SubnetId,Az:AvailabilityZone,State:State,Cidr:CidrBlock}" --output json 2>$null
    $subnets = Convert-FromAwsJson $subnetsRaw
    if ($subnets -and $subnets.Count -ge 4) {
        Write-Pass "Found $($subnets.Count) subnets associated with SurgeGate VPC across Availability Zones."
        foreach ($s in $subnets) {
            if ($s.State -eq "available") {
                Write-Pass "Subnet $($s.Id) ($($s.Cidr), $($s.Az)) is available."
            } else {
                Write-Fail "Subnet $($s.Id) state is '$($s.State)'."
            }
        }
    } else {
        $cnt = $(if ($subnets) { $subnets.Count } else { 0 })
        Write-Fail "Expected at least 4 subnets in VPC $vpcId, found $cnt."
    }
} else {
    Write-Fail "SurgeGate VPC not found in AWS or $OutputsFile."
}

# 3. Security Groups
Write-Sec "3. Security Groups & Ingress Rule Posture"
$rdsSgId = $(if ($outputs -and ($outputs.rds_security_group -is [string])) { $outputs.rds_security_group } else { aws --profile $Profile --region $Region ec2 describe-security-groups --filters "Name=group-name,Values=surgegate-db-sg" --query "SecurityGroups[0].GroupId" --output text 2>$null })
$ec2SgId = $(if ($outputs -and ($outputs.ec2_security_group -is [string])) { $outputs.ec2_security_group } else { aws --profile $Profile --region $Region ec2 describe-security-groups --filters "Name=group-name,Values=surgegate-ec2-sg" --query "SecurityGroups[0].GroupId" --output text 2>$null })

if ($rdsSgId -and $rdsSgId -ne "None" -and -not $rdsSgId.StartsWith("aws:")) {
    $openRds = aws --profile $Profile --region $Region ec2 describe-security-groups --group-ids $rdsSgId --filters "Name=ip-permission.from-port,Values=3306" "Name=ip-permission.cidr,Values=0.0.0.0/0" --query "SecurityGroups[0].GroupId" --output text 2>$null
    if (-not $openRds -or $openRds -eq "None") {
        Write-Pass "RDS Security Group ($rdsSgId) strictly isolates port 3306 (NOT exposed to 0.0.0.0/0)."
    } else {
        Write-Fail "CRITICAL SECURITY RISK: Port 3306 is open to 0.0.0.0/0 in SG $rdsSgId!"
    }
} else {
    Write-Skip "RDS Security Group not found."
}

if ($ec2SgId -and $ec2SgId -ne "None" -and -not $ec2SgId.StartsWith("aws:")) {
    $openSsh = aws --profile $Profile --region $Region ec2 describe-security-groups --group-ids $ec2SgId --filters "Name=ip-permission.from-port,Values=22" "Name=ip-permission.cidr,Values=0.0.0.0/0" --query "SecurityGroups[0].GroupId" --output text 2>$null
    if (-not $openSsh -or $openSsh -eq "None") {
        Write-Pass "EC2 Security Group ($ec2SgId) does NOT expose SSH port 22 (Secured via SSM Session Manager)."
    } else {
        Write-Fail "SECURITY WARNING: SSH port 22 is exposed to 0.0.0.0/0 in SG $ec2SgId!"
    }
} else {
    Write-Skip "EC2 Security Group not found."
}

# 4. S3 Storage
Write-Sec "4. Amazon S3 Ticket Storage"
$s3Bucket = $(if ($outputs -and ($outputs.s3_bucket -is [string])) { $outputs.s3_bucket } else { aws --profile $Profile --region $Region s3api list-buckets --query "Buckets[?contains(Name, 'surgegate-tickets-')].Name | [0]" --output text 2>$null })
if ($s3Bucket -and $s3Bucket -ne "None" -and -not $s3Bucket.StartsWith("aws:")) {
    aws --profile $Profile --region $Region s3api head-bucket --bucket $s3Bucket 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Pass "S3 Bucket '$s3Bucket' is reachable and active."
        
        $pab = aws --profile $Profile --region $Region s3api get-public-access-block --bucket $s3Bucket --query "PublicAccessBlockConfiguration.BlockPublicAcls" --output text 2>$null
        if ($pab -and ($pab.Trim() -eq "True" -or $pab.Trim() -eq "true")) {
            Write-Pass "S3 Public Access Block is enabled."
        } else {
            Write-Fail "S3 Public Access Block is disabled on $s3Bucket!"
        }

        $enc = aws --profile $Profile --region $Region s3api get-bucket-encryption --bucket $s3Bucket --query "ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.SSEAlgorithm" --output text 2>$null
        if ($enc -and ($enc.Trim() -eq "AES256" -or $enc.Trim() -eq "aws:kms")) {
            Write-Pass "S3 Server-Side Encryption is active ($($enc.Trim()))."
        } else {
            Write-Fail "S3 Server-Side Encryption not properly configured on $s3Bucket ($enc)."
        }
    } else {
        Write-Fail "S3 Bucket '$s3Bucket' exists but is not accessible."
    }
} else {
    Write-Skip "S3 Bucket check skipped (not found)."
}

# 5. SQS Queues & DLQ
Write-Sec "5. Amazon SQS Queues & Dead Letter Protection"
$sqsUrl = $(if ($outputs -and ($outputs.sqs_queue_url -is [string]) -and $outputs.sqs_queue_url.StartsWith("https://")) { $outputs.sqs_queue_url } else { aws --profile $Profile --region $Region sqs get-queue-url --queue-name "surgegate-ticket-queue" --query "QueueUrl" --output text 2>$null })
$dlqUrl = $(if ($outputs -and ($outputs.sqs_dlq_url -is [string]) -and $outputs.sqs_dlq_url.StartsWith("https://")) { $outputs.sqs_dlq_url } else { aws --profile $Profile --region $Region sqs get-queue-url --queue-name "surgegate-ticket-dlq" --query "QueueUrl" --output text 2>$null })

if ($sqsUrl -and $sqsUrl -ne "None" -and $sqsUrl.StartsWith("https://")) {
    $sqsAttrsRaw = aws --profile $Profile --region $Region sqs get-queue-attributes --queue-url $sqsUrl --attribute-names ApproximateNumberOfMessages RedrivePolicy QueueArn --output json 2>$null
    $sqsAttrsObj = Convert-FromAwsJson $sqsAttrsRaw
    if ($sqsAttrsObj -and $sqsAttrsObj.Attributes) {
        $attrs = $sqsAttrsObj.Attributes
        $msgCount = $attrs.ApproximateNumberOfMessages
        $redrive = $attrs.RedrivePolicy
        $mainQueueArn = $attrs.QueueArn
        Write-Pass "SQS Ticket Queue is operational ($sqsUrl, ARN: $mainQueueArn, Active msgs: $msgCount)."
        if ($redrive) {
            $redriveParsed = Convert-FromAwsJson $redrive
            Write-Pass "SQS Dead Letter Redrive Policy is active (Target: $($redriveParsed.deadLetterTargetArn), MaxReceive: $($redriveParsed.maxReceiveCount))."
        } else {
            Write-Fail "SQS Dead Letter Redrive Policy is MISSING on main queue!"
        }
    } else {
        Write-Fail "Failed to get queue attributes for SQS main queue: $sqsUrl"
    }
} else {
    Write-Fail "SQS Ticket Queue ('surgegate-ticket-queue') not found or URL is invalid."
}

if ($dlqUrl -and $dlqUrl -ne "None" -and $dlqUrl.StartsWith("https://")) {
    $dlqAttrsRaw = aws --profile $Profile --region $Region sqs get-queue-attributes --queue-url $dlqUrl --attribute-names ApproximateNumberOfMessages QueueArn --output json 2>$null
    $dlqAttrsObj = Convert-FromAwsJson $dlqAttrsRaw
    if ($dlqAttrsObj -and $dlqAttrsObj.Attributes) {
        Write-Pass "SQS Dead Letter Queue is reachable ($dlqUrl, Dead letters: $($dlqAttrsObj.Attributes.ApproximateNumberOfMessages))."
    }
} else {
    Write-Fail "SQS Dead Letter Queue ('surgegate-ticket-dlq') not found."
}

# 6. IAM Least-Privilege Roles & Policies
Write-Sec "6. IAM Roles & Policy Enforcement"
$ec2RoleName = "surgegate-ec2-role"
$lambdaRoleName = "surgegate-lambda-role"

$ec2RoleCheck = aws --profile $Profile --region $Region iam get-role --role-name $ec2RoleName --query "Role.Arn" --output text 2>$null
if ($ec2RoleCheck -and $ec2RoleCheck -ne "None" -and -not $ec2RoleCheck.StartsWith("aws:")) {
    Write-Pass "IAM Role '$ec2RoleName' exists ($($ec2RoleCheck.Trim()))."
    $ec2PolsRaw = aws --profile $Profile --region $Region iam list-role-policies --role-name $ec2RoleName --query "PolicyNames[]" --output text 2>$null
    $ec2Pols = Get-AwsTextList $ec2PolsRaw
    if ($ec2Pols -contains "SurgeGateEC2AppPolicy") {
        Write-Pass "Inline policy 'SurgeGateEC2AppPolicy' attached to $ec2RoleName."
    } else {
        Write-Fail "Inline policy 'SurgeGateEC2AppPolicy' is MISSING on $ec2RoleName!"
    }
    $ec2ManagedRaw = aws --profile $Profile --region $Region iam list-attached-role-policies --role-name $ec2RoleName --query "AttachedPolicies[].PolicyName" --output text 2>$null
    $ec2Managed = Get-AwsTextList $ec2ManagedRaw
    if ($ec2Managed -contains "AmazonSSMManagedInstanceCore") {
        Write-Pass "Managed policy 'AmazonSSMManagedInstanceCore' attached to $ec2RoleName."
    } else {
        Write-Fail "Managed policy 'AmazonSSMManagedInstanceCore' is MISSING on $ec2RoleName!"
    }
} else {
    Write-Fail "IAM Role '$ec2RoleName' not found."
}

$lambdaRoleCheck = aws --profile $Profile --region $Region iam get-role --role-name $lambdaRoleName --query "Role.Arn" --output text 2>$null
if ($lambdaRoleCheck -and $lambdaRoleCheck -ne "None" -and -not $lambdaRoleCheck.StartsWith("aws:")) {
    Write-Pass "IAM Role '$lambdaRoleName' exists ($($lambdaRoleCheck.Trim()))."
    $lambdaPolsRaw = aws --profile $Profile --region $Region iam list-role-policies --role-name $lambdaRoleName --query "PolicyNames[]" --output text 2>$null
    $lambdaPols = Get-AwsTextList $lambdaPolsRaw
    if ($lambdaPols -contains "SurgeGateLambdaWorkerPolicy") {
        Write-Pass "Inline policy 'SurgeGateLambdaWorkerPolicy' attached to $lambdaRoleName."
    } else {
        Write-Fail "Inline policy 'SurgeGateLambdaWorkerPolicy' is MISSING on $lambdaRoleName!"
    }
    $lambdaManagedRaw = aws --profile $Profile --region $Region iam list-attached-role-policies --role-name $lambdaRoleName --query "AttachedPolicies[].PolicyName" --output text 2>$null
    $lambdaManaged = Get-AwsTextList $lambdaManagedRaw
    if ($lambdaManaged -contains "AWSLambdaBasicExecutionRole") {
        Write-Pass "Managed policy 'AWSLambdaBasicExecutionRole' attached to $lambdaRoleName."
    } else {
        Write-Fail "Managed policy 'AWSLambdaBasicExecutionRole' is MISSING on $lambdaRoleName!"
    }
} else {
    Write-Fail "IAM Role '$lambdaRoleName' not found."
}

# 7. Lambda Worker & Event Source Mapping
Write-Sec "7. AWS Lambda Ticket Worker & SQS Trigger"
$lambdaArn = $(if ($outputs -and ($outputs.lambda_function_arn -is [string])) { $outputs.lambda_function_arn } else { aws --profile $Profile --region $Region lambda get-function --function-name "surgegate-ticket-processor" --query "Configuration.FunctionArn" --output text 2>$null })
if ($lambdaArn -and $lambdaArn -ne "None" -and -not $lambdaArn.StartsWith("aws:")) {
    $lamCfgRaw = aws --profile $Profile --region $Region lambda get-function --function-name "surgegate-ticket-processor" --output json 2>$null
    $lambdaCfg = (Convert-FromAwsJson $lamCfgRaw).Configuration
    if ($lambdaCfg) {
        Write-Pass "Lambda function $($lambdaCfg.FunctionName) is in state '$($lambdaCfg.State)' (Runtime: $($lambdaCfg.Runtime))."
        
        $esmListRaw = aws --profile $Profile --region $Region lambda list-event-source-mappings --function-name "surgegate-ticket-processor" --output json 2>$null
        $esmList = (Convert-FromAwsJson $esmListRaw).EventSourceMappings
        if ($esmList -and $esmList.Count -gt 0) {
            $esm = $esmList[0]
            if ($esm.State -eq "Enabled" -or $esm.State -eq "Enabling" -or $esm.State -eq "Creating") {
                Write-Pass "Lambda Event Source Mapping trigger is active (State: $($esm.State), Source: $($esm.EventSourceArn), Batch: $($esm.BatchSize))."
            } else {
                Write-Fail "Lambda Event Source Mapping is in unexpected state: '$($esm.State)'."
            }
        } else {
            Write-Fail "No Event Source Mapping found connecting SQS to Lambda ticket processor!"
        }
    }
} else {
    Write-Fail "Lambda function 'surgegate-ticket-processor' not found."
}

# 8. RDS Database
Write-Sec "8. Amazon RDS MySQL Database"
$dbId = $(if ($outputs -and ($outputs.db_instance_identifier -is [string])) { $outputs.db_instance_identifier } else { "surgegate-db" })
$rdsRaw = aws --profile $Profile --region $Region rds describe-db-instances --db-instance-identifier $dbId --output json 2>$null
$rdsJson = Convert-FromAwsJson $rdsRaw
if ($rdsJson -and $rdsJson.DBInstances -and $rdsJson.DBInstances.Count -gt 0) {
    $db = $rdsJson.DBInstances[0]
    if ($db.DBInstanceStatus -eq "available") {
        Write-Pass "RDS Database is available ($($db.Engine) $($db.DBInstanceClass), Endpoint: $($db.Endpoint.Address))."
    } else {
        Write-Fail "RDS Database status is '$($db.DBInstanceStatus)' (expected 'available')."
    }

    if ($db.StorageEncrypted -eq $true) {
        Write-Pass "RDS Database storage is encrypted at rest."
    } else {
        Write-Fail "RDS Database storage encryption is disabled!"
    }

    if ($db.PubliclyAccessible -eq $false) {
        Write-Pass "RDS Database is private (PubliclyAccessible: false)."
    } else {
        Write-Fail "CRITICAL SECURITY WARNING: RDS Database is marked publicly accessible!"
    }
} else {
    Write-Fail "RDS DB instance '$dbId' not found."
}

# 9. ALB & ASG & Scaling Policies
Write-Sec "9. Application Load Balancer, Target Group & Auto Scaling"
$albArn = $(if ($outputs -and ($outputs.alb_arn -is [string])) { $outputs.alb_arn } else { aws --profile $Profile --region $Region elbv2 describe-load-balancers --names "surgegate-alb" --query "LoadBalancers[0].LoadBalancerArn" --output text 2>$null })
if ($albArn -and $albArn -ne "None" -and -not $albArn.StartsWith("aws:")) {
    $albDns = (aws --profile $Profile --region $Region elbv2 describe-load-balancers --load-balancer-arns $albArn --query "LoadBalancers[0].DNSName" --output text 2>$null).Trim()
    $albState = (aws --profile $Profile --region $Region elbv2 describe-load-balancers --load-balancer-arns $albArn --query "LoadBalancers[0].State.Code" --output text 2>$null).Trim()
    if ($albState -eq "active") {
        Write-Pass "Application Load Balancer is active at: http://$albDns"
    } else {
        Write-Fail "ALB state is '$albState' (expected 'active')."
    }
} else {
    Write-Fail "ALB 'surgegate-alb' not found."
}

$asgName = $(if ($outputs -and ($outputs.asg_name -is [string])) { $outputs.asg_name } else { "surgegate-asg" })
$asgCheck = (aws --profile $Profile --region $Region autoscaling describe-auto-scaling-groups --auto-scaling-group-names $asgName --query "AutoScalingGroups[0].AutoScalingGroupName" --output text 2>$null)
if ($asgCheck -and $asgCheck.Trim() -eq $asgName) {
    $asgInstCount = (aws --profile $Profile --region $Region autoscaling describe-auto-scaling-groups --auto-scaling-group-names $asgName --query "length(AutoScalingGroups[0].Instances)" --output text 2>$null).Trim()
    $asgDesired = (aws --profile $Profile --region $Region autoscaling describe-auto-scaling-groups --auto-scaling-group-names $asgName --query "AutoScalingGroups[0].DesiredCapacity" --output text 2>$null).Trim()
    Write-Pass "Auto Scaling Group $asgName is active (Instances: $asgInstCount, Desired: $asgDesired)."

    # Check Scaling Policy
    $ttPolArn = (aws --profile $Profile --region $Region autoscaling describe-policies --auto-scaling-group-name $asgName --policy-names "surgegate-cpu-target-tracking" --query "ScalingPolicies[0].PolicyARN" --output text 2>$null)
    if ($ttPolArn -and $ttPolArn -ne "None" -and -not $ttPolArn.StartsWith("aws:")) {
        Write-Pass "ASG CPU Target Tracking Policy is attached ($($ttPolArn.Trim()))."
    } else {
        Write-Fail "ASG CPU Target Tracking Policy 'surgegate-cpu-target-tracking' is MISSING!"
    }
} else {
    Write-Fail "Auto Scaling Group '$asgName' not found."
}

# 10. CloudWatch Alarms
Write-Sec "10. Amazon CloudWatch Alarms"
$alarms = @("surgegate-asg-high-cpu", "surgegate-sqs-queue-backlog", "surgegate-rds-high-cpu")
foreach ($a in $alarms) {
    $state = aws --profile $Profile --region $Region cloudwatch describe-alarms --alarm-names $a --query "MetricAlarms[0].StateValue" --output text 2>$null
    if ($state -and $state -ne "None" -and -not $state.StartsWith("aws:")) {
        Write-Pass "CloudWatch Alarm '$a' is configured (Current state: $($state.Trim()))."
    } else {
        Write-Fail "CloudWatch Alarm '$a' not found!"
    }
}

# 11. AWS Systems Manager Parameter Store
Write-Sec "11. AWS Systems Manager Parameter Store Audit"
$ssmPrefix = "/surgegate/$Environment"
$ssmRaw = aws --profile $Profile --region $Region ssm get-parameters-by-path --path $ssmPrefix --with-decryption --output json 2>$null
$ssmObj = Convert-FromAwsJson $ssmRaw
$ssmParams = $(if ($ssmObj -and $ssmObj.Parameters) { $ssmObj.Parameters } else { @() })
if ($ssmParams -and $ssmParams.Count -gt 0) {
    Write-Pass "Found $($ssmParams.Count) parameters under $ssmPrefix/* in Parameter Store."
    $paramMap = @{}
    foreach ($p in $ssmParams) {
        $shortKey = $p.Name.Replace("$ssmPrefix/", "")
        $paramMap[$shortKey] = $p.Value
    }
    $reqKeys = @("vpc_id", "alb_endpoint", "db_host", "s3_bucket", "sqs_url", "sqs_arn", "sqs_dlq_url", "asg_name")
    foreach ($k in $reqKeys) {
        if ($paramMap.ContainsKey($k) -and -not [string]::IsNullOrWhiteSpace($paramMap[$k])) {
            Write-Pass "Parameter '$k' = '$($paramMap[$k])'"
        } else {
            Write-Fail "Parameter '$k' is missing or empty in Parameter Store!"
        }
    }
} else {
    Write-Fail "No parameters found under $ssmPrefix/* in Parameter Store!"
}

# ------------------------------------------------------------------------------
# Final Verification Summary
# ------------------------------------------------------------------------------
Write-Host "`n==============================================================================" -ForegroundColor $(if ($failCount -eq 0) { "Green" } else { "Yellow" })
Write-Host "Verification Summary: $passCount Passed, $failCount Failed, $skipCount Skipped" -ForegroundColor $(if ($failCount -eq 0) { "Green" } else { "Yellow" })
Write-Host "==============================================================================" -ForegroundColor $(if ($failCount -eq 0) { "Green" } else { "Yellow" })

if ($failCount -gt 0) {
    Write-Host "Infrastructure audit completed with $failCount issues to resolve." -ForegroundColor Yellow
} else {
    Write-Host "All SurgeGate infrastructure components verified successfully!" -ForegroundColor Green
}
Write-Host ""
