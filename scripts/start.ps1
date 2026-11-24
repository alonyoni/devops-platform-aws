# =============================================================================
# start.ps1 — Full platform initiation script
# Runs everything from zero to live cluster
#
# Usage:
#   .\scripts\start.ps1
#
# Prerequisites:
#   - AWS CLI configured (aws configure)
#   - Terraform installed
#   - kubectl installed
#   - Helm installed
#   - Docker Desktop running
# =============================================================================

$ErrorActionPreference = "Stop"
$REPO_ROOT = Split-Path -Parent $PSScriptRoot

# --------------------------------------------------------------------------
# Colours
# --------------------------------------------------------------------------
function Log    { param($msg) Write-Host "[INFO]  $msg" -ForegroundColor Cyan }
function Ok     { param($msg) Write-Host "[OK]    $msg" -ForegroundColor Green }
function Warn   { param($msg) Write-Host "[WARN]  $msg" -ForegroundColor Yellow }
function Fail   { param($msg) Write-Host "[ERROR] $msg" -ForegroundColor Red; exit 1 }
function Header { param($msg) Write-Host "`n========== $msg ==========" -ForegroundColor Magenta }

# --------------------------------------------------------------------------
# Timer
# --------------------------------------------------------------------------
$StartTime = Get-Date
function Elapsed {
    $elapsed = (Get-Date) - $StartTime
    return "{0:mm}m {0:ss}s" -f $elapsed
}

# =============================================================================
# PHASE 0 — Check prerequisites
# =============================================================================
Header "PHASE 0 — Checking prerequisites"

foreach ($tool in @("aws", "terraform", "kubectl", "helm", "docker")) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        Fail "$tool is not installed or not in PATH. Install it before running this script."
    }
    Ok "$tool found"
}

# Verify AWS credentials work
Log "Verifying AWS credentials..."
try {
    $CALLER = aws sts get-caller-identity | ConvertFrom-Json
} catch {
    Fail "AWS credentials not configured. Run: aws configure"
}

$AWS_ACCOUNT_ID = $CALLER.Account
$AWS_REGION     = "us-east-1"
$CLUSTER_NAME   = "devops-platform-dev"
$ECR_REGISTRY   = "$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com"
$ECR_REPO       = "$ECR_REGISTRY/devops-platform/app"

Ok "AWS Account: $AWS_ACCOUNT_ID | Region: $AWS_REGION"

# Verify Docker is running
try {
    docker info | Out-Null
} catch {
    Fail "Docker Desktop is not running. Start it and try again."
}
Ok "Docker is running"

# =============================================================================
# PHASE 1 — Terraform tfvars
# =============================================================================
Header "PHASE 1 — Preparing Terraform variables"

$TFVARS = "$REPO_ROOT\terraform\environments\dev\terraform.tfvars"
$TFVARS_EXAMPLE = "$REPO_ROOT\terraform\environments\dev\terraform.tfvars.example"

if (-not (Test-Path $TFVARS)) {
    Log "terraform.tfvars not found — creating from example..."
    Copy-Item $TFVARS_EXAMPLE $TFVARS

    # Replace the placeholder account ID automatically
    (Get-Content $TFVARS) `
        -replace '123456789012', $AWS_ACCOUNT_ID `
        | Set-Content $TFVARS

    Ok "terraform.tfvars created with account ID: $AWS_ACCOUNT_ID"
} else {
    Log "terraform.tfvars already exists — skipping"
    
    # Make sure account ID is correct even if file already existed
    (Get-Content $TFVARS) `
        -replace '123456789012', $AWS_ACCOUNT_ID `
        | Set-Content $TFVARS
    Ok "Account ID updated in terraform.tfvars"
}

# =============================================================================
# PHASE 2 — Terraform bootstrap (S3 + DynamoDB)
# =============================================================================
Header "PHASE 2 — Terraform bootstrap (S3 + DynamoDB remote state)"

$BOOTSTRAP_DIR = "$REPO_ROOT\terraform\bootstrap"

# Check if S3 bucket already exists
$S3_EXISTS = aws s3api head-bucket `
    --bucket "devops-platform-terraform-state" `
    --region $AWS_REGION 2>&1

if ($LASTEXITCODE -eq 0) {
    Warn "Bootstrap S3 bucket already exists — skipping bootstrap"
} else {
    Log "Running terraform init + apply in bootstrap..."
    Push-Location $BOOTSTRAP_DIR

    terraform init -no-color
    if ($LASTEXITCODE -ne 0) { Fail "terraform init failed in bootstrap" }

    terraform apply -auto-approve -no-color
    if ($LASTEXITCODE -ne 0) { Fail "terraform apply failed in bootstrap" }

    Pop-Location
    Ok "Bootstrap complete — S3 bucket and DynamoDB table created"
}

# =============================================================================
# PHASE 3 — Terraform apply (EKS cluster)
# =============================================================================
Header "PHASE 3 — Provisioning AWS infrastructure (~15 minutes)"

$DEV_DIR = "$REPO_ROOT\terraform\environments\dev"
Push-Location $DEV_DIR

Log "Running terraform init..."
terraform init -no-color
if ($LASTEXITCODE -ne 0) { Fail "terraform init failed" }

Log "Running terraform apply (this takes ~15 minutes — grab a coffee)..."
terraform apply -auto-approve -no-color
if ($LASTEXITCODE -ne 0) { Fail "terraform apply failed" }

# Capture outputs
$TF_OUTPUT     = terraform output -json | ConvertFrom-Json
$CLUSTER_NAME  = $TF_OUTPUT.eks_cluster_name.value
$ECR_REPO_URL  = $TF_OUTPUT.ecr_repository_urls.value.app

Pop-Location
Ok "Infrastructure provisioned — Cluster: $CLUSTER_NAME ($(Elapsed))"

# =============================================================================
# PHASE 4 — Configure kubectl
# =============================================================================
Header "PHASE 4 — Configuring kubectl"

Log "Updating kubeconfig..."
aws eks update-kubeconfig `
    --region $AWS_REGION `
    --name $CLUSTER_NAME

# Wait for nodes to be ready
Log "Waiting for nodes to reach Ready state..."
$retries = 0
do {
    Start-Sleep -Seconds 15
    $NODES = kubectl get nodes --no-headers 2>$null
    $READY = ($NODES -split "`n" | Where-Object { $_ -match "\sReady\s" }).Count
    $retries++
    Log "Nodes ready: $READY (attempt $retries/20)"
} while ($READY -lt 2 -and $retries -lt 20)

if ($READY -lt 2) { Fail "Nodes did not reach Ready state in time" }
Ok "Nodes ready: $READY ($(Elapsed))"

# =============================================================================
# PHASE 5 — Apply base Kubernetes manifests
# =============================================================================
Header "PHASE 5 — Applying base Kubernetes manifests"

$K8S = "$REPO_ROOT\kubernetes"

$manifests = @(
    "$K8S\namespaces\namespaces.yaml",
    "$K8S\namespaces\resource-quotas.yaml",
    "$K8S\rbac\cluster-roles.yaml",
    "$K8S\rbac\cluster-role-bindings.yaml",
    "$K8S\rbac\service-accounts.yaml",
    "$K8S\rbac\roles.yaml",
    "$K8S\storage\storage-classes.yaml",
    "$K8S\network-policies\default-deny.yaml",
    "$K8S\network-policies\app-network-policies.yaml",
    "$K8S\cluster-addons\metrics-server.yaml"
)

foreach ($manifest in $manifests) {
    Log "Applying: $(Split-Path -Leaf $manifest)"
    kubectl apply -f $manifest
    if ($LASTEXITCODE -ne 0) { Fail "Failed to apply $manifest" }
}

Ok "Base manifests applied ($(Elapsed))"

# =============================================================================
# PHASE 6 — Create secrets
# =============================================================================
Header "PHASE 6 — Creating Kubernetes secrets"

# Generate random passwords
$GRAFANA_PASSWORD  = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes((New-Guid).ToString().Replace("-","").Substring(0,16)))
$JENKINS_PASSWORD  = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes((New-Guid).ToString().Replace("-","").Substring(0,16)))

# Grafana admin secret
Log "Creating Grafana admin secret..."
kubectl create secret generic grafana-admin-secret `
    --from-literal=admin-password=$GRAFANA_PASSWORD `
    -n monitoring `
    --dry-run=client -o yaml | kubectl apply -f -

# Prometheus basic auth (admin/admin for dev)
Log "Creating Prometheus basic auth secret..."
kubectl create secret generic prometheus-basic-auth `
    --from-literal=auth="admin:admin" `
    -n monitoring `
    --dry-run=client -o yaml | kubectl apply -f -

# Jenkins admin secret
Log "Creating Jenkins admin secret..."
kubectl create secret generic jenkins-admin-secret `
    --from-literal=jenkins-admin-user=admin `
    --from-literal=jenkins-admin-password=$JENKINS_PASSWORD `
    -n jenkins `
    --dry-run=client -o yaml | kubectl apply -f -

# Jenkins AWS account ID secret
kubectl create secret generic jenkins-aws-secret `
    --from-literal=aws-account-id=$AWS_ACCOUNT_ID `
    -n jenkins `
    --dry-run=client -o yaml | kubectl apply -f -

Ok "Secrets created ($(Elapsed))"

# =============================================================================
# PHASE 7 — Install Helm repos
# =============================================================================
Header "PHASE 7 — Adding Helm repositories"

$repos = @{
    "argo"                   = "https://argoproj.github.io/argo-helm"
    "jenkins"                = "https://charts.jenkins.io"
    "prometheus-community"   = "https://prometheus-community.github.io/helm-charts"
    "ingress-nginx"          = "https://kubernetes.github.io/ingress-nginx"
    "jetstack"               = "https://charts.jetstack.io"
}

foreach ($repo in $repos.GetEnumerator()) {
    Log "Adding repo: $($repo.Key)"
    helm repo add $repo.Key $repo.Value 2>$null
}

helm repo update
Ok "Helm repos updated ($(Elapsed))"

# =============================================================================
# PHASE 8 — Install ArgoCD
# =============================================================================
Header "PHASE 8 — Installing ArgoCD (~5 minutes)"

Log "Installing ArgoCD via Helm..."
helm upgrade --install argocd argo/argo-cd `
    --namespace argocd `
    --values "$REPO_ROOT\argocd\install\helm-values.yaml" `
    --version "6.7.2" `
    --timeout 10m `
    --wait `
    --atomic

if ($LASTEXITCODE -ne 0) { Fail "ArgoCD installation failed" }

# Get ArgoCD admin password
$ARGOCD_SECRET = kubectl get secret argocd-initial-admin-secret `
    -n argocd `
    -o jsonpath="{.data.password}"
$ARGOCD_PASSWORD = [System.Text.Encoding]::UTF8.GetString(
    [System.Convert]::FromBase64String($ARGOCD_SECRET)
)

Ok "ArgoCD installed — admin password: $ARGOCD_PASSWORD ($(Elapsed))"

# =============================================================================
# PHASE 9 — Install Monitoring Stack
# =============================================================================
Header "PHASE 9 — Installing Prometheus + Grafana (~5 minutes)"

Log "Installing kube-prometheus-stack via Helm..."
helm upgrade --install kube-prometheus-stack `
    prometheus-community/kube-prometheus-stack `
    --namespace monitoring `
    --values "$REPO_ROOT\monitoring\prometheus\helm-values.yaml" `
    --version "57.0.3" `
    --timeout 15m `
    --wait `
    --atomic

if ($LASTEXITCODE -ne 0) { Fail "Monitoring stack installation failed" }

# Upload Grafana dashboards
Log "Uploading Grafana dashboards..."
kubectl create configmap grafana-dashboard-platform-overview `
    --from-file=platform-overview.json="$REPO_ROOT\monitoring\grafana\dashboards\platform-overview-dashboard.json" `
    -n monitoring `
    --dry-run=client -o yaml | kubectl apply -f -

kubectl create configmap grafana-dashboard-app-slo `
    --from-file=app-slo.json="$REPO_ROOT\monitoring\grafana\dashboards\application-slo-dashboard.json" `
    -n monitoring `
    --dry-run=client -o yaml | kubectl apply -f -

kubectl label configmap grafana-dashboard-platform-overview grafana_dashboard=1 -n monitoring --overwrite
kubectl label configmap grafana-dashboard-app-slo           grafana_dashboard=1 -n monitoring --overwrite

Ok "Monitoring stack installed ($(Elapsed))"

# =============================================================================
# PHASE 10 — Install Jenkins
# =============================================================================
Header "PHASE 10 — Installing Jenkins (~8 minutes)"

Log "Installing Jenkins via Helm..."
helm upgrade --install jenkins jenkins/jenkins `
    --namespace jenkins `
    --values "$REPO_ROOT\jenkins\helm-values.yaml" `
    --version "5.0.17" `
    --timeout 10m `
    --wait `
    --atomic

if ($LASTEXITCODE -ne 0) { Fail "Jenkins installation failed" }

Ok "Jenkins installed ($(Elapsed))"

# =============================================================================
# PHASE 11 — Build and Push Sample App to ECR
# =============================================================================
Header "PHASE 11 — Building and pushing sample app to ECR"

Log "Authenticating Docker to ECR..."
aws ecr get-login-password --region $AWS_REGION | `
    docker login --username AWS --password-stdin $ECR_REGISTRY

if ($LASTEXITCODE -ne 0) { Fail "ECR authentication failed" }

Log "Building Docker image..."
Push-Location "$REPO_ROOT\app"

docker build `
    --build-arg BUILD_DATE=(Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ") `
    --build-arg VERSION="v1.0.0" `
    --tag "$ECR_REPO_URL`:v1.0.0" `
    --tag "$ECR_REPO_URL`:latest" `
    .

if ($LASTEXITCODE -ne 0) { Fail "Docker build failed" }

Log "Pushing image to ECR..."
docker push "$ECR_REPO_URL`:v1.0.0"
docker push "$ECR_REPO_URL`:latest"

if ($LASTEXITCODE -ne 0) { Fail "Docker push failed" }

Pop-Location
Ok "Image pushed: $ECR_REPO_URL`:v1.0.0 ($(Elapsed))"

# =============================================================================
# PHASE 12 — Deploy Sample App with Helm
# =============================================================================
Header "PHASE 12 — Deploying sample app to app-dev"

Log "Deploying app via Helm..."
helm upgrade --install app `
    "$REPO_ROOT\app\helm" `
    --namespace app-dev `
    --set image.repository=$ECR_REPO_URL `
    --set image.tag=v1.0.0 `
    --set global.environment=dev `
    --wait `
    --timeout 5m `
    --atomic

if ($LASTEXITCODE -ne 0) { Fail "App deployment failed" }

Ok "App deployed to app-dev ($(Elapsed))"

# =============================================================================
# PHASE 13 — Final verification
# =============================================================================
Header "PHASE 13 — Verifying everything is running"

Log "All pods across all namespaces:"
kubectl get pods --all-namespaces

Log "All nodes:"
kubectl get nodes

Log "Helm releases:"
helm list --all-namespaces

# =============================================================================
# DONE — Print access information
# =============================================================================
$TotalTime = Elapsed

Write-Host ""
Write-Host "╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║          PLATFORM IS LIVE — ACCESS INFORMATION              ║" -ForegroundColor Green
Write-Host "╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""
Write-Host "Total time: $TotalTime" -ForegroundColor Cyan
Write-Host ""
Write-Host "CREDENTIALS:" -ForegroundColor Yellow
Write-Host "  ArgoCD   user: admin    password: $ARGOCD_PASSWORD"
Write-Host "  Jenkins  user: admin    password: $JENKINS_PASSWORD"
Write-Host "  Grafana  user: admin    password: $GRAFANA_PASSWORD"
Write-Host ""
Write-Host "PORT-FORWARD COMMANDS (run each in a separate terminal):" -ForegroundColor Yellow
Write-Host "  ArgoCD:     kubectl port-forward svc/argocd-server 8080:80 -n argocd"
Write-Host "  Grafana:    kubectl port-forward svc/kube-prometheus-stack-grafana 3000:80 -n monitoring"
Write-Host "  Prometheus: kubectl port-forward svc/kube-prometheus-stack-prometheus 9090:9090 -n monitoring"
Write-Host "  Jenkins:    kubectl port-forward svc/jenkins 8081:8080 -n jenkins"
Write-Host "  App:        kubectl port-forward svc/app 8082:80 -n app-dev"
Write-Host ""
Write-Host "URLS (after port-forwarding):" -ForegroundColor Yellow
Write-Host "  ArgoCD:     http://localhost:8080"
Write-Host "  Grafana:    http://localhost:3000"
Write-Host "  Prometheus: http://localhost:9090"
Write-Host "  Jenkins:    http://localhost:8081"
Write-Host "  App:        http://localhost:8082"
Write-Host "  App health: http://localhost:8082/health"
Write-Host "  App API:    http://localhost:8082/api/v1/items"
Write-Host "  App metrics:http://localhost:8082/metrics"
Write-Host ""
Write-Host "WHEN DONE — destroy everything:" -ForegroundColor Red
Write-Host "  .\scripts\destroy.ps1"
Write-Host ""
Write-Host "  OR manually:"
Write-Host "  cd $REPO_ROOT\terraform\environments\dev"
Write-Host "  terraform destroy"
Write-Host ""
