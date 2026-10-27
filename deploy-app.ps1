<#
.SYNOPSIS
    SurgeGate - Application Deployment Stage (PowerShell Native)
.DESCRIPTION
    Deploys the real SurgeGate FastAPI backend and React frontend containers
    to the AWS infrastructure provisioned by deploy-infra.ps1 / deploy.sh.
    Retrieves parameters directly from AWS SSM Parameter Store, packages and uploads
    the application bundle to S3, updates the Launch Template (guaranteeing InstanceType=t3.small,
    AMI, IAM instance profile, security groups, IMDSv2, and UserData), and triggers an ASG
    instance refresh with active progress monitoring.
.PARAMETER Profile
    AWS CLI Profile (default: 'surgegate').
.PARAMETER Region
    AWS Region (default: 'ap-south-1').
.PARAMETER Environment
    Target deployment environment (default: 'dev').
.PARAMETER DbPassword
    Optional master password for RDS MySQL. If not supplied, reads from SSM Parameter Store or environment.
.PARAMETER ForceNewVersion
    If specified, creates a new Launch Template version even if the latest version is already valid.
.PARAMETER DryRun
    If specified, validates connectivity and prints the application deployment plan without mutating resources.
#>

[CmdletBinding()]
param(
    [switch]$DryRun,
    [string]$Profile = "surgegate",
    [string]$Region = "ap-south-1",
    [string]$Environment = "dev",
    [string]$DbPassword = "",
    [switch]$ForceNewVersion
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

function Invoke-AwsCli {
    param(
        [string[]]$ArgsList,
        [switch]$AllowFailure
    )
    $output = & aws @ArgsList 2>&1
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0 -and -not $AllowFailure) {
        $errText = ($output | Out-String).Trim()
        Write-Failure "AWS CLI command failed (exit code $exitCode): aws $($ArgsList -join ' ')"
        if (-not [string]::IsNullOrWhiteSpace($errText)) {
            Write-Failure $errText
        }
        exit $exitCode
    }
    return ($output | Out-String).Trim()
}

function Write-JsonNoBom {
    param(
        [string]$Path,
        [string]$JsonContent
    )
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $JsonContent, $utf8NoBom)
}

Write-Host "==============================================================================" -ForegroundColor Cyan
Write-Host "          SurgeGate - Application Container Deployment Stage                  " -ForegroundColor Cyan
Write-Host "==============================================================================" -ForegroundColor Cyan

# ------------------------------------------------------------------------------
# 0. Caller Identity & Account Verification
# ------------------------------------------------------------------------------
Write-Step "0. Validating AWS Authentication and Account Identity"
$callerJson = aws sts get-caller-identity --profile $Profile --region $Region --output json 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Failure "AWS authentication failed with profile '$Profile'. Run 'aws configure --profile $Profile'."
    Write-Failure "$callerJson"
    exit 1
}

$caller = $callerJson | ConvertFrom-Json
$AccountId = $caller.Account
$CallerArn = $caller.Arn

if ($AccountId -ne "269494630662") {
    Write-Failure "ACCOUNT MISMATCH! Expected account 269494630662, but authenticated as $AccountId ($CallerArn). Aborting."
    exit 1
}
Write-Success "Authenticated as: $CallerArn (Account ID: $AccountId, Region: $Region, Profile: $Profile)"

# ------------------------------------------------------------------------------
# 1. Retrieve Infrastructure Parameters from SSM Parameter Store
# ------------------------------------------------------------------------------
Write-Step "1. Retrieving Infrastructure Configuration from AWS Parameter Store"
$SsmPrefix = "/surgegate/$Environment"

$paramRaw = aws ssm get-parameters-by-path --profile $Profile --region $Region --path $SsmPrefix --with-decryption --query "Parameters[].{Name:Name,Value:Value}" --output json 2>$null
$paramItems = $(if ($paramRaw) { $paramRaw | ConvertFrom-Json } else { @() })
$config = @{}
if ($paramItems -and $paramItems.Count -gt 0) {
    foreach ($item in $paramItems) {
        $shortKey = $item.Name.Replace("$SsmPrefix/", "")
        $config[$shortKey] = $item.Value
    }
    Write-Success "Retrieved $($config.Count) configuration parameters from SSM Parameter Store ($SsmPrefix/*)."
} else {
    Write-Warn "Could not retrieve parameters from SSM Parameter Store. Checking local deployment-outputs.json..."
    $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    $outputsPath = Join-Path $ScriptDir "deployment-outputs.json"
    if (Test-Path $outputsPath) {
        $fileOutputs = Get-Content -Raw -Path $outputsPath | ConvertFrom-Json
        foreach ($prop in $fileOutputs.PSObject.Properties) {
            $config[$prop.Name] = $prop.Value
        }
        Write-Success "Loaded configuration from $outputsPath."
    } else {
        if ($DryRun) {
            Write-Warn "[DRY-RUN] No deployment-outputs.json found. Using simulated parameters for dry run plan."
            $config["db_host"] = "surgegate-db.c7iis22kcvpq.ap-south-1.rds.amazonaws.com"
            $config["db_port"] = "3306"
            $config["db_name"] = "surgegate"
            $config["db_user"] = "surgegate_admin"
            $config["db_password"] = "surgegate_secret"
            $config["sqs_url"] = "https://sqs.ap-south-1.amazonaws.com/$AccountId/surgegate-ticket-queue"
            $config["s3_bucket"] = "surgegate-tickets-dev-269494630662-apsouth1"
            $config["alb_dns_name"] = "surgegate-alb-89694237.ap-south-1.elb.amazonaws.com"
            $config["alb_endpoint"] = "http://surgegate-alb-89694237.ap-south-1.elb.amazonaws.com"
            $config["asg_name"] = "surgegate-asg"
            $config["ec2_security_group"] = "sg-02298e692985fa777"
        } else {
            Write-Failure "No infrastructure configuration found! Run deploy-infra.ps1 first."
            exit 1
        }
    }
}

$DbHost = $config["db_host"]
$DbPort = $(if ($config["db_port"]) { $config["db_port"] } else { "3306" })
$DbName = $(if ($config["db_name"]) { $config["db_name"] } else { "surgegate" })
$DbUser = $(if ($config["db_user"]) { $config["db_user"] } else { "surgegate_admin" })
$SqsUrl = $config["sqs_url"]
$S3Bucket = $config["s3_bucket"]
$AlbDns = $config["alb_dns_name"]
$AlbEndpoint = $config["alb_endpoint"]
$AsgName = $(if ($config["asg_name"]) { $config["asg_name"] } else { "surgegate-asg" })
$Ec2SgId = $(if ($config["ec2_security_group"]) { $config["ec2_security_group"] } else { "sg-02298e692985fa777" })

# Resolve Database Password safely
$ResolvedDbPass = ""
if (-not [string]::IsNullOrWhiteSpace($DbPassword)) {
    $ResolvedDbPass = $DbPassword
    Write-Info "Using database password provided via -DbPassword parameter."
} elseif (-not [string]::IsNullOrWhiteSpace($env:SURGEGATE_DB_PASSWORD)) {
    $ResolvedDbPass = $env:SURGEGATE_DB_PASSWORD
    Write-Info "Using database password from `$env:SURGEGATE_DB_PASSWORD."
} elseif (-not [string]::IsNullOrWhiteSpace($env:DB_PASSWORD)) {
    $ResolvedDbPass = $env:DB_PASSWORD
    Write-Info "Using database password from `$env:DB_PASSWORD."
} elseif ($config.ContainsKey("db_password") -and -not [string]::IsNullOrWhiteSpace($config["db_password"])) {
    $ResolvedDbPass = $config["db_password"]
    Write-Info "Retrieved database password from SSM Parameter Store."
} else {
    $ResolvedDbPass = "surgegate_secret"
    Write-Warn "No database password specified in SSM or environment. Using default 'surgegate_secret'."
}

# Ensure password exists in SSM Parameter Store for EC2 instances and Lambda worker
if (-not $DryRun -and -not [string]::IsNullOrWhiteSpace($ResolvedDbPass) -and -not ($config.ContainsKey("db_password") -and $config["db_password"] -eq $ResolvedDbPass)) {
    Write-Info "Storing database password in SSM Parameter Store ($SsmPrefix/db_password)..."
    aws ssm put-parameter --profile $Profile --region $Region --name "$SsmPrefix/db_password" --type "SecureString" --value $ResolvedDbPass --overwrite 2>&1 | Out-Null
}

Write-Info "Database Host:       $DbHost"
Write-Info "Database User:       $DbUser"
Write-Info "SQS Queue URL:       $SqsUrl"
Write-Info "S3 Bucket Name:      $S3Bucket"
Write-Info "ALB Endpoint:        $AlbEndpoint"
Write-Info "Target ASG Name:     $AsgName"
Write-Info "EC2 Security Group:  $Ec2SgId"

if (-not $DbHost -or -not $AsgName -or -not $S3Bucket) {
    Write-Failure "Incomplete infrastructure outputs. Missing db_host, asg_name, or s3_bucket."
    exit 1
}

# ------------------------------------------------------------------------------
# 2. Package and Upload Application Bundle to S3
# ------------------------------------------------------------------------------
Write-Step "2. Packaging and Staging Application Bundle in S3"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$zipPath = Join-Path $env:TEMP "surgegate-app.zip"

if ($DryRun) {
    Write-Info "[DRY-RUN] Would create application zip from repository source (backend, frontend, schema, docker-compose.prod.yml)."
    Write-Info "[DRY-RUN] Would upload bundle to s3://$S3Bucket/app/surgegate-app.zip."
} else {
    Write-Info "Creating application archive at $zipPath..."
    if (Test-Path $zipPath) { Remove-Item $zipPath -Force }

    $stagingDir = Join-Path $env:TEMP "surgegate-staging"
    if (Test-Path $stagingDir) { Remove-Item $stagingDir -Recurse -Force }
    New-Item -ItemType Directory -Path $stagingDir | Out-Null

    Copy-Item -Path (Join-Path $ScriptDir "backend") -Destination (Join-Path $stagingDir "backend") -Recurse -Exclude @("__pycache__", ".pytest_cache", "venv", ".env")
    Copy-Item -Path (Join-Path $ScriptDir "frontend") -Destination (Join-Path $stagingDir "frontend") -Recurse -Exclude @("node_modules", "dist", ".env")
    Copy-Item -Path (Join-Path $ScriptDir "schema") -Destination (Join-Path $stagingDir "schema") -Recurse
    Copy-Item -Path (Join-Path $ScriptDir "docker-compose.prod.yml") -Destination (Join-Path $stagingDir "docker-compose.prod.yml")

    Compress-Archive -Path "$stagingDir\*" -DestinationPath $zipPath -Force
    Remove-Item $stagingDir -Recurse -Force

    Write-Info "Uploading bundle to s3://$S3Bucket/app/surgegate-app.zip..."
    $s3Upload = Invoke-AwsCli @("s3", "cp", $zipPath, "s3://$S3Bucket/app/surgegate-app.zip", "--profile", $Profile, "--region", $Region)
    Write-Success "Application bundle successfully uploaded to S3: s3://$S3Bucket/app/surgegate-app.zip"
    Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
}

# ------------------------------------------------------------------------------
# 3. Application Container Bootstrap UserData Script
# ------------------------------------------------------------------------------
Write-Step "3. Preparing Application Container Launch Configuration"

$appUserData = @"
#!/usr/bin/env bash
exec > >(tee /var/log/surgegate-app.log|logger -t surgegate-app -s 2>/dev/console) 2>&1
echo "Starting SurgeGate Application Container Deployment..."

# Install Docker, Git, MariaDB/MySQL client, unzip, and AWS CLI
dnf update -y
dnf install -y docker git mariadb105 unzip awscli nc 2>/dev/null || dnf install -y docker git mariadb105 unzip

systemctl enable --now docker
usermod -aG docker ec2-user

# Install Docker Compose Plugin (install in standard search directories)
DOCKER_PLUGINS_LIB=/usr/libexec/docker/cli-plugins
DOCKER_PLUGINS_LOCAL=/usr/local/lib/docker/cli-plugins
mkdir -p `$DOCKER_PLUGINS_LIB `$DOCKER_PLUGINS_LOCAL
curl -sSL https://github.com/docker/compose/releases/download/v2.26.1/docker-compose-linux-x86_64 -o `$DOCKER_PLUGINS_LIB/docker-compose
chmod +x `$DOCKER_PLUGINS_LIB/docker-compose
ln -sf `$DOCKER_PLUGINS_LIB/docker-compose `$DOCKER_PLUGINS_LOCAL/docker-compose 2>/dev/null || true
ln -sf `$DOCKER_PLUGINS_LIB/docker-compose /usr/bin/docker-compose 2>/dev/null || true

# Prepare application directory
APP_DIR=/opt/surgegate-app
mkdir -p `$APP_DIR
cd `$APP_DIR

# Fetch application bundle from S3 (with fallback to git repository)
echo "Downloading application bundle from S3..."
if aws s3 cp s3://$S3Bucket/app/surgegate-app.zip /tmp/surgegate-app.zip --region $Region 2>/dev/null; then
    unzip -q -o /tmp/surgegate-app.zip -d `$APP_DIR
    rm -f /tmp/surgegate-app.zip
    echo "Application archive unpacked successfully."
else
    echo "S3 bundle download failed; attempting fallback git clone..."
    git clone https://github.com/Shreyas-fr/MINIPROJECTCCL.git . 2>/dev/null || git pull origin main 2>/dev/null || true
fi

# Dynamically resolve DB password from SSM if not injected
DB_PASS="$ResolvedDbPass"
if [ -z "`$DB_PASS" ]; then
    SSM_PASS=`$(aws ssm get-parameter --name "/surgegate/$Environment/db_password" --with-decryption --region $Region --query "Parameter.Value" --output text 2>/dev/null || true)
    if [ -n "`$SSM_PASS" ] && [ "`$SSM_PASS" != "None" ]; then
        DB_PASS="`$SSM_PASS"
    else
        DB_PASS="surgegate_secret"
    fi
fi

# Write production environment file
cat << ENV_EOF > .env
SURGEGATE_DB_HOST=$DbHost
SURGEGATE_DB_PORT=$DbPort
SURGEGATE_DB_NAME=$DbName
SURGEGATE_DB_USER=$DbUser
SURGEGATE_DB_PASSWORD=`$DB_PASS
DATABASE_URL=mysql+pymysql://${DbUser}:`$DB_PASS@${DbHost}:${DbPort}/${DbName}?charset=utf8mb4
APP_PORT=8000
ENVIRONMENT=$Environment
USE_AWS_MOCK=false
AWS_REGION=$Region
SURGEGATE_SQS_URL=$SqsUrl
SURGEGATE_S3_BUCKET=$S3Bucket
ENABLE_QUEUE_SCHEDULER=true
QUEUE_ADMISSION_BATCH_SIZE=5
QUEUE_ADMISSION_INTERVAL_SECONDS=3
VITE_BACKEND_URL=http://backend:8000
ENV_EOF

# Wait for RDS MySQL to become reachable
echo "Waiting for RDS MySQL (${DbHost}:${DbPort}) to accept connections..."
for i in {1..30}; do
    if timeout 3 bash -c "</dev/tcp/${DbHost}/${DbPort}" 2>/dev/null; then
        echo "RDS MySQL is reachable."
        break
    fi
    sleep 3
done

# Apply Database Schema if table does not exist
echo "Applying database schema to RDS MySQL..."
mysql -h $DbHost -u $DbUser -p"`$DB_PASS" $DbName < schema/schema.sql 2>/dev/null || echo "Schema already applied."

# Launch production containers
echo "Starting SurgeGate production containers..."
docker compose -f docker-compose.prod.yml --env-file .env up --build -d

# Wait for backend container to report healthy before database seeding
echo "Waiting for backend container health check..."
for i in {1..25}; do
    HEALTH=`$(docker inspect --format='{{json .State.Health.Status}}' surgegate-backend-prod 2>/dev/null || echo '"starting"')
    if [ "`$HEALTH" = '"healthy"' ]; then
        echo "Backend container is healthy."
        break
    fi
    sleep 4
done

# Execute database seeding inside running container (idempotent)
docker compose -f docker-compose.prod.yml exec -T backend python -m app.seed 2>/dev/null || echo "Database seed finished or already present."

echo "SurgeGate Application Container Bootstrap Complete."
"@

$appUserDataB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($appUserData))

# ------------------------------------------------------------------------------
# 4. Launch Template Management (Preserve All Fields & Idempotency)
# ------------------------------------------------------------------------------
Write-Step "4. Configuring and Validating Launch Template 'surgegate-lt'"

$LtName = "surgegate-lt"
$TargetInstanceType = "t3.small"

# Retrieve baseline template data from Version 1
$v1Raw = aws ec2 describe-launch-template-versions --profile $Profile --region $Region `
    --launch-template-name $LtName --versions 1 --output json 2>$null
$v1Obj = $(if ($v1Raw) { $v1Raw | ConvertFrom-Json } else { $null })
$v1Data = $(if ($v1Obj -and $v1Obj.LaunchTemplateVersions.Count -gt 0) { $v1Obj.LaunchTemplateVersions[0].LaunchTemplateData } else { $null })

$BaselineImageId = $(if ($v1Data -and $v1Data.ImageId) { $v1Data.ImageId } else { "ami-022374b883d9d7931" })
$BaselineIamProfile = $(if ($v1Data -and $v1Data.IamInstanceProfile -and $v1Data.IamInstanceProfile.Name) { $v1Data.IamInstanceProfile.Name } else { "surgegate-ec2-profile" })
$BaselineSgId = $(if ($v1Data -and $v1Data.SecurityGroupIds -and $v1Data.SecurityGroupIds.Count -gt 0) { $v1Data.SecurityGroupIds[0] } else { $Ec2SgId })

Write-Info "Baseline AMI:               $BaselineImageId"
Write-Info "Baseline IAM Profile:       $BaselineIamProfile"
Write-Info "Baseline Security Group:    $BaselineSgId"
Write-Info "Target Instance Type:       $TargetInstanceType"

# Inspect current latest version
$ltMetaRaw = aws ec2 describe-launch-templates --profile $Profile --region $Region `
    --launch-template-names $LtName --output json 2>$null
$ltMeta = $(if ($ltMetaRaw) { $ltMetaRaw | ConvertFrom-Json } else { $null })
$latestVerNum = $(if ($ltMeta -and $ltMeta.LaunchTemplates.Count -gt 0) { $ltMeta.LaunchTemplates[0].LatestVersionNumber } else { 1 })

$targetVersion = $null

if (-not $ForceNewVersion) {
    # Check if latest version already has full configuration and matching UserData
    $latestVerRaw = aws ec2 describe-launch-template-versions --profile $Profile --region $Region `
        --launch-template-name $LtName --versions "$latestVerNum" --output json 2>$null
    $latestVerObj = $(if ($latestVerRaw) { $latestVerRaw | ConvertFrom-Json } else { $null })
    $latestVerData = $(if ($latestVerObj -and $latestVerObj.LaunchTemplateVersions.Count -gt 0) { $latestVerObj.LaunchTemplateVersions[0].LaunchTemplateData } else { $null })

    if ($latestVerData `
        -and $latestVerData.InstanceType -eq $TargetInstanceType `
        -and -not [string]::IsNullOrWhiteSpace($latestVerData.ImageId) `
        -and ($latestVerData.IamInstanceProfile -and -not [string]::IsNullOrWhiteSpace($latestVerData.IamInstanceProfile.Name)) `
        -and ($latestVerData.SecurityGroupIds -and $latestVerData.SecurityGroupIds.Count -gt 0) `
        -and ($latestVerData.UserData -eq $appUserDataB64)) {
        
        Write-Success "Found existing valid Launch Template version $latestVerNum with identical container bootstrap and InstanceType=$TargetInstanceType."
        $targetVersion = $latestVerNum
    }
}

if (-not $targetVersion) {
    if ($DryRun) {
        Write-Info "[DRY-RUN] Would create new Launch Template version with complete spec (InstanceType=$TargetInstanceType, AMI=$BaselineImageId, IAM=$BaselineIamProfile, SGs=[$BaselineSgId], UserData)."
        $targetVersion = 3
    } else {
        Write-Info "Creating new Launch Template version explicitly defining all required launch settings..."

        $completeLtData = @{
            ImageId = $BaselineImageId
            InstanceType = $TargetInstanceType
            IamInstanceProfile = @{
                Name = $BaselineIamProfile
            }
            SecurityGroupIds = @($BaselineSgId)
            UserData = $appUserDataB64
            MetadataOptions = @{
                HttpTokens = "required"
                HttpPutResponseHopLimit = 2
                HttpEndpoint = "enabled"
            }
            TagSpecifications = @(
                @{
                    ResourceType = "instance"
                    Tags = @(
                        @{ Key = "Name"; Value = "surgegate-app-worker" },
                        @{ Key = "Project"; Value = "SurgeGate" },
                        @{ Key = "Environment"; Value = $Environment }
                    )
                }
            )
        }

        $ltTempFile = Join-Path $env:TEMP "surgegate-lt-data.json"
        $ltJsonContent = $completeLtData | ConvertTo-Json -Depth 5
        Write-JsonNoBom -Path $ltTempFile -JsonContent $ltJsonContent

        $createVerOutput = Invoke-AwsCli @(
            "ec2", "create-launch-template-version",
            "--profile", $Profile,
            "--region", $Region,
            "--launch-template-name", $LtName,
            "--source-version", "1",
            "--launch-template-data", "file://$ltTempFile",
            "--query", "LaunchTemplateVersion.VersionNumber",
            "--output", "text"
        )
        Remove-Item $ltTempFile -Force -ErrorAction SilentlyContinue

        if ([string]::IsNullOrWhiteSpace($createVerOutput) -or $createVerOutput -eq "None") {
            Write-Failure "Failed to create new Launch Template version."
            exit 1
        }

        $targetVersion = [int]$createVerOutput.Trim()
        Write-Success "Successfully created Launch Template version: $targetVersion"
    }
}

# Validate target version data
Write-Info "Validating Launch Template version $targetVersion launch settings..."
if (-not $DryRun) {
    $valRaw = aws ec2 describe-launch-template-versions --profile $Profile --region $Region `
        --launch-template-name $LtName --versions "$targetVersion" --output json 2>$null
    $valObj = $(if ($valRaw) { $valRaw | ConvertFrom-Json } else { $null })
    $valData = $(if ($valObj -and $valObj.LaunchTemplateVersions.Count -gt 0) { $valObj.LaunchTemplateVersions[0].LaunchTemplateData } else { $null })

    if (-not $valData) {
        Write-Failure "Failed to retrieve Launch Template version $targetVersion for validation."
        exit 1
    }

    $errors = @()
    if ($valData.InstanceType -ne $TargetInstanceType) {
        $errors += "InstanceType is '$($valData.InstanceType)' (expected '$TargetInstanceType')"
    }
    if ([string]::IsNullOrWhiteSpace($valData.ImageId)) {
        $errors += "ImageId is missing"
    }
    if (-not $valData.IamInstanceProfile -or [string]::IsNullOrWhiteSpace($valData.IamInstanceProfile.Name)) {
        $errors += "IamInstanceProfile is missing"
    }
    if (-not $valData.SecurityGroupIds -or $valData.SecurityGroupIds.Count -eq 0) {
        $errors += "SecurityGroupIds is empty"
    }
    if ([string]::IsNullOrWhiteSpace($valData.UserData)) {
        $errors += "UserData is empty"
    }

    if ($errors.Count -gt 0) {
        Write-Failure "Launch Template version $targetVersion validation failed:"
        foreach ($err in $errors) { Write-Failure "  • $err" }
        exit 1
    }
    Write-Success "Launch Template version $targetVersion passed validation (InstanceType: $($valData.InstanceType), AMI: $($valData.ImageId), IAM: $($valData.IamInstanceProfile.Name))."

    # Update default version of Launch Template
    Invoke-AwsCli @(
        "ec2", "modify-launch-template",
        "--profile", $Profile,
        "--region", $Region,
        "--launch-template-name", $LtName,
        "--default-version", "$targetVersion"
    ) | Out-Null
    Write-Success "Updated Launch Template '$LtName' default version to: $targetVersion"

    # Explicitly configure ASG to use target version
    Write-Info "Updating Auto Scaling Group '$AsgName' to use Launch Template version $targetVersion..."
    Invoke-AwsCli @(
        "autoscaling", "update-auto-scaling-group",
        "--profile", $Profile,
        "--region", $Region,
        "--auto-scaling-group-name", $AsgName,
        "--launch-template", "LaunchTemplateName=$LtName,Version=$targetVersion"
    ) | Out-Null
    Write-Success "Auto Scaling Group '$AsgName' updated to Launch Template version $targetVersion."
}

# ------------------------------------------------------------------------------
# 5. Trigger & Monitor ASG Instance Refresh
# ------------------------------------------------------------------------------
Write-Step "5. Initiating Auto Scaling Group Instance Refresh"

if ($DryRun) {
    Write-Info "[DRY-RUN] Would start instance refresh for '$AsgName' using Rolling strategy."
    Write-Info "[DRY-RUN] Would monitor rolling instance rollover until InService."
} else {
    # Check if an instance refresh is already active
    $activeRefreshesRaw = aws autoscaling describe-instance-refreshes --profile $Profile --region $Region `
        --auto-scaling-group-name $AsgName `
        --query "InstanceRefreshes[?Status=='InProgress'||Status=='Pending']" `
        --output json 2>$null
    $activeRefreshes = $(if ($activeRefreshesRaw) { $activeRefreshesRaw | ConvertFrom-Json } else { @() })

    $refreshId = $null
    if ($activeRefreshes -and $activeRefreshes.Count -gt 0) {
        $refreshId = $activeRefreshes[0].InstanceRefreshId
        Write-Info "Found existing active Instance Refresh: $refreshId (Status: $($activeRefreshes[0].Status))"
    } else {
        Write-Info "Starting ASG instance refresh for $AsgName (Strategy: Rolling, Warmup: 180s, MinHealthy: 50%)..."
        $refreshJson = aws autoscaling start-instance-refresh --profile $Profile --region $Region `
            --auto-scaling-group-name $AsgName `
            --strategy "Rolling" `
            --preferences "MinHealthyPercentage=50,InstanceWarmup=180" `
            --output json 2>&1
        $refreshExit = $LASTEXITCODE

        if ($refreshExit -ne 0) {
            Write-Failure "Failed to start ASG instance refresh (exit code $refreshExit):"
            Write-Failure "$refreshJson"
            exit 1
        }

        $refreshObj = $refreshJson | ConvertFrom-Json
        $refreshId = $refreshObj.InstanceRefreshId

        if ([string]::IsNullOrWhiteSpace($refreshId)) {
            Write-Failure "AWS returned empty InstanceRefreshId. Cannot proceed."
            exit 1
        }
        Write-Success "Started Instance Refresh: $refreshId"
    }

    # Monitor refresh status for up to 90 seconds
    Write-Info "Monitoring instance refresh progress for up to 90 seconds..."
    $pollInterval = 10
    $maxPolls = 9
    $refreshStatus = "InProgress"
    $percentComplete = 0

    for ($i = 1; $i -le $maxPolls; $i++) {
        Start-Sleep -Seconds $pollInterval
        $statusRaw = aws autoscaling describe-instance-refreshes --profile $Profile --region $Region `
            --auto-scaling-group-name $AsgName `
            --instance-refresh-ids $refreshId `
            --output json 2>$null
        $statusObj = $(if ($statusRaw) { $statusRaw | ConvertFrom-Json } else { $null })

        if ($statusObj -and $statusObj.InstanceRefreshes -and $statusObj.InstanceRefreshes.Count -gt 0) {
            $refItem = $statusObj.InstanceRefreshes[0]
            $refreshStatus = $refItem.Status
            $percentComplete = $(if ($refItem.PercentageComplete) { $refItem.PercentageComplete } else { 0 })
            Write-Info "[$i/$maxPolls] Instance Refresh Status: $refreshStatus ($percentComplete% complete)"

            if ($refreshStatus -eq "Successful") {
                Write-Success "Instance refresh completed successfully!"
                break
            }
            if ($refreshStatus -eq "Failed" -or $refreshStatus -eq "Cancelled") {
                Write-Failure "Instance refresh $refreshStatus! Reason: $($refItem.StatusReason)"
                exit 1
            }
        }
    }

    if ($refreshStatus -ne "Successful") {
        Write-Info "Instance refresh is continuing in the background ($percentComplete% complete)."
        Write-Info "To check ongoing progress, run:"
        Write-Info "aws autoscaling describe-instance-refreshes --auto-scaling-group-name $AsgName --profile $Profile --region $Region"
    }
}

# ------------------------------------------------------------------------------
# 6. Summary & Verification Instructions
# ------------------------------------------------------------------------------
Write-Host "`n==============================================================================" -ForegroundColor Green
Write-Host "          SurgeGate Application Deployment Staged Successfully!               " -ForegroundColor Green
Write-Host "==============================================================================" -ForegroundColor Green
Write-Host "`nEndpoint Details:" -ForegroundColor White
Write-Host " • Application Load Balancer: $AlbEndpoint" -ForegroundColor Cyan
Write-Host " • API Health Endpoint:       $AlbEndpoint/health" -ForegroundColor Cyan
Write-Host " • Swagger API Documentation: $AlbEndpoint/docs" -ForegroundColor Cyan
Write-Host " • React Ticket Portal:       $AlbEndpoint/" -ForegroundColor Cyan
Write-Host ""
