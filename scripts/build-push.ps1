# =============================================================================
# build-push.ps1 — Build Docker image, scan with Trivy, push to ECR
# Windows PowerShell equivalent of build-push.sh
#
# Usage:
#   .\scripts\build-push.ps1
#   .\scripts\build-push.ps1 -Env prod -Tag v1.2.3
#   .\scripts\build-push.ps1 -SkipScan
# =============================================================================

param(
    [string]$Env       = "dev",
    [string]$Tag       = "",
    [string]$Region    = "us-east-1",
    [switch]$SkipScan  = $false
)

$ErrorActionPreference = "Stop"
$REPO_ROOT = Split-Path -Parent $PSScriptRoot
$APP_DIR   = "$REPO_ROOT\app"

# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------
function Log     { param($msg) Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $msg" -ForegroundColor Cyan }
function Ok      { param($msg) Write-Host "[OK]    $msg" -ForegroundColor Green }
function Warn    { param($msg) Write-Host "[WARN]  $msg" -ForegroundColor Yellow }
function Fail    { param($msg) Write-Host "[ERROR] $msg" -ForegroundColor Red; exit 1 }

# --------------------------------------------------------------------------
# Derive values
# --------------------------------------------------------------------------
Log "Getting AWS account ID..."
$AWS_ACCOUNT_ID = aws sts get-caller-identity --query Account --output text
if ($LASTEXITCODE -ne 0) { Fail "AWS credentials not configured. Run: aws configure" }

$ECR_REGISTRY = "$AWS_ACCOUNT_ID.dkr.ecr.$Region.amazonaws.com"
$ECR_REPO     = "devops-platform/app"

# Auto-generate tag if not provided
if ($Tag -eq "") {
    $GIT_SHA  = git -C $REPO_ROOT rev-parse --short HEAD
    $VERSION  = if (Test-Path "$APP_DIR\VERSION") { Get-Content "$APP_DIR\VERSION" -Raw } else { "0.0.0" }
    $VERSION  = $VERSION.Trim()
    $Tag      = "$Env-$VERSION-$GIT_SHA"
}

$IMAGE_FULL   = "$ECR_REGISTRY/$ECR_REPO`:$Tag"
$IMAGE_LATEST = "$ECR_REGISTRY/$ECR_REPO`:latest"
$BUILD_DATE   = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
$VCS_REF      = git -C $REPO_ROOT rev-parse HEAD

# --------------------------------------------------------------------------
# Summary
# --------------------------------------------------------------------------
Write-Host ""
Write-Host "========== BUILD + PUSH ==========" -ForegroundColor Magenta
Write-Host "  Environment : $Env"
Write-Host "  Image tag   : $Tag"
Write-Host "  Full image  : $IMAGE_FULL"
Write-Host "  Skip scan   : $SkipScan"
Write-Host "==================================" -ForegroundColor Magenta
Write-Host ""

# --------------------------------------------------------------------------
# Step 1 — Build Docker image
# --------------------------------------------------------------------------
Log "Building Docker image: $IMAGE_FULL"

docker build `
    --build-arg BUILD_DATE=$BUILD_DATE `
    --build-arg VCS_REF=$VCS_REF `
    --build-arg VERSION=$Tag `
    --tag $IMAGE_FULL `
    --tag $IMAGE_LATEST `
    --file "$APP_DIR\Dockerfile" `
    $APP_DIR

if ($LASTEXITCODE -ne 0) { Fail "Docker build failed" }
Ok "Image built: $IMAGE_FULL"

# --------------------------------------------------------------------------
# Step 2 — Trivy security scan
# --------------------------------------------------------------------------
if (-not $SkipScan) {
    Log "Running Trivy security scan..."

    # Check if Trivy is installed locally
    $TrivyInstalled = Get-Command trivy -ErrorAction SilentlyContinue

    if ($TrivyInstalled) {
        # Use local Trivy
        Log "Using local Trivy installation..."

        # Informational scan — show all severities, do not fail
        trivy image `
            --exit-code 0 `
            --severity LOW,MEDIUM,HIGH,CRITICAL `
            $IMAGE_FULL

        # Strict scan — fail on HIGH/CRITICAL
        trivy image `
            --exit-code 1 `
            --severity HIGH,CRITICAL `
            --ignore-unfixed `
            --format json `
            --output trivy-report.json `
            $IMAGE_FULL

        if ($LASTEXITCODE -ne 0) {
            Fail "Trivy found HIGH/CRITICAL vulnerabilities. Image will NOT be pushed. Fix the vulnerabilities or run with -SkipScan to bypass."
        }

    } else {
        # Trivy not installed — run via Docker
        Log "Trivy not found locally — running via Docker..."

        docker run --rm `
            -v //var/run/docker.sock:/var/run/docker.sock `
            aquasec/trivy:0.49.1 image `
                --exit-code 1 `
                --severity HIGH,CRITICAL `
                --ignore-unfixed `
                $IMAGE_FULL

        if ($LASTEXITCODE -ne 0) {
            Fail "Trivy found HIGH/CRITICAL vulnerabilities. Image will NOT be pushed."
        }
    }

    Ok "Trivy scan passed — no HIGH/CRITICAL vulnerabilities found"

} else {
    Warn "Trivy scan SKIPPED (-SkipScan flag set)"
}

# --------------------------------------------------------------------------
# Step 3 — Authenticate to ECR
# --------------------------------------------------------------------------
Log "Authenticating Docker to ECR: $ECR_REGISTRY"

aws ecr get-login-password --region $Region | `
    docker login --username AWS --password-stdin $ECR_REGISTRY

if ($LASTEXITCODE -ne 0) { Fail "ECR authentication failed" }
Ok "Authenticated to ECR"

# --------------------------------------------------------------------------
# Step 4 — Push image
# --------------------------------------------------------------------------
Log "Pushing image: $IMAGE_FULL"
docker push $IMAGE_FULL
if ($LASTEXITCODE -ne 0) { Fail "docker push failed" }

# Push :latest tag on prod or dev
Log "Pushing latest tag: $IMAGE_LATEST"
docker push $IMAGE_LATEST
if ($LASTEXITCODE -ne 0) { Fail "docker push latest failed" }

# --------------------------------------------------------------------------
# Step 5 — Get image digest
# --------------------------------------------------------------------------
$IMAGE_DIGEST = docker inspect `
    --format="{{index .RepoDigests 0}}" `
    $IMAGE_FULL 2>$null

if (-not $IMAGE_DIGEST) { $IMAGE_DIGEST = "N/A" }

# --------------------------------------------------------------------------
# Done
# --------------------------------------------------------------------------
Write-Host ""
Ok "Push complete"
Write-Host "  Image  : $IMAGE_FULL" -ForegroundColor Green
Write-Host "  Digest : $IMAGE_DIGEST" -ForegroundColor Green
Write-Host "  Tag    : $Tag" -ForegroundColor Green
Write-Host ""
Write-Host "Next step — deploy it:" -ForegroundColor Yellow
Write-Host "  .\scripts\deploy.ps1 -Env $Env -Tag $Tag"
Write-Host ""
