# =============================================================================
# destroy.ps1 — Tear down everything
# Run this when you are done to avoid AWS charges
# =============================================================================

$ErrorActionPreference = "Stop"
$REPO_ROOT = Split-Path -Parent $PSScriptRoot
$AWS_REGION = "us-east-1"

function Log  { param($msg) Write-Host "[INFO]  $msg" -ForegroundColor Cyan }
function Ok   { param($msg) Write-Host "[OK]    $msg" -ForegroundColor Green }
function Warn { param($msg) Write-Host "[WARN]  $msg" -ForegroundColor Yellow }
function Fail { param($msg) Write-Host "[ERROR] $msg" -ForegroundColor Red; exit 1 }

Write-Host ""
Write-Host "╔══════════════════════════════════════════════╗" -ForegroundColor Red
Write-Host "║   DESTROYING ALL AWS RESOURCES               ║" -ForegroundColor Red
Write-Host "║   This will delete the entire platform       ║" -ForegroundColor Red
Write-Host "╚══════════════════════════════════════════════╝" -ForegroundColor Red
Write-Host ""

$confirm = Read-Host "Type 'yes' to confirm destruction"
if ($confirm -ne "yes") {
    Write-Host "Aborted." -ForegroundColor Yellow
    exit 0
}

# --------------------------------------------------------------------------
# Step 1: Delete LoadBalancer services first
# Prevents orphaned ELBs from blocking terraform destroy
# --------------------------------------------------------------------------
Log "Checking for LoadBalancer services..."
try {
    $LB_SERVICES = kubectl get svc --all-namespaces `
        -o jsonpath="{range .items[?(@.spec.type=='LoadBalancer')]}{.metadata.namespace}{' '}{.metadata.name}{'\n'}{end}" `
        2>$null

    if ($LB_SERVICES) {
        Warn "Found LoadBalancer services — deleting to prevent orphaned ELBs:"
        foreach ($line in ($LB_SERVICES -split "`n" | Where-Object { $_ -ne "" })) {
            $parts = $line -split " "
            $ns = $parts[0]
            $svc = $parts[1]
            Log "Deleting svc/$svc in namespace $ns"
            kubectl delete svc $svc -n $ns --ignore-not-found
        }
        Log "Waiting 30 seconds for ELBs to deregister..."
        Start-Sleep -Seconds 30
    } else {
        Log "No LoadBalancer services found"
    }
} catch {
    Warn "Could not check LoadBalancer services — cluster may already be gone"
}

# --------------------------------------------------------------------------
# Step 2: Terraform destroy
# --------------------------------------------------------------------------
Log "Running terraform destroy..."
Push-Location "$REPO_ROOT\terraform\environments\dev"

terraform destroy -auto-approve -no-color
if ($LASTEXITCODE -ne 0) { Fail "terraform destroy failed" }

Pop-Location

# --------------------------------------------------------------------------
# Step 3: Clean local kubeconfig
# --------------------------------------------------------------------------
Log "Cleaning local kubeconfig..."
kubectl config delete-context "devops-platform-dev" 2>$null
kubectl config delete-cluster "devops-platform-dev" 2>$null

# --------------------------------------------------------------------------
# Step 4: Verify
# --------------------------------------------------------------------------
Log "Verifying cluster is gone..."
$CLUSTERS = aws eks list-clusters --region $AWS_REGION | ConvertFrom-Json
if ($CLUSTERS.clusters -contains "devops-platform-dev") {
    Warn "Cluster still showing in AWS — may take a few more minutes to fully delete"
} else {
    Ok "Cluster is gone"
}

Write-Host ""
Ok "Destruction complete. No more AWS charges accumulating."
Write-Host ""
Warn "NOTE: The S3 state bucket and DynamoDB table still exist (intentional)."
Write-Host "      To delete them too run:"
Write-Host "      aws s3 rb s3://devops-platform-terraform-state --force"
Write-Host "      aws dynamodb delete-table --table-name devops-platform-terraform-locks --region us-east-1"
Write-Host ""
