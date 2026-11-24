#!/usr/bin/env bash
# =============================================================================
# bootstrap.sh — Full platform bootstrap after EKS cluster is live
#
# Runs in order:
#   1. Verify prerequisites
#   2. Configure kubectl
#   3. Apply Kubernetes base manifests (namespaces, RBAC, storage)
#   4. Upload Grafana dashboards as ConfigMaps
#   5. Install ArgoCD via Helm
#   6. Bootstrap ArgoCD secrets
#   7. Apply ArgoCD root-app (triggers app-of-apps)
#   8. Install Jenkins via Helm
#   9. Print access info
#
# Usage:
#   ./scripts/bootstrap.sh [--env dev|prod] [--region us-east-1]
# =============================================================================
set -euo pipefail

# --------------------------------------------------------------------------
# Defaults / argument parsing
# --------------------------------------------------------------------------
ENV="dev"
AWS_REGION="us-east-1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

usage() {
  echo "Usage: $0 [--env dev|prod] [--region us-east-1]"
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)     ENV="$2";        shift 2 ;;
    --region)  AWS_REGION="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

# --------------------------------------------------------------------------
# Colours
# --------------------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; NC='\033[0m'

log()     { echo -e "${BLUE}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

CLUSTER_NAME="devops-platform-${ENV}"

# --------------------------------------------------------------------------
# Step 0: Prerequisites
# --------------------------------------------------------------------------
log "Checking prerequisites..."

for cmd in aws kubectl helm jq; do
  if ! command -v "$cmd" &>/dev/null; then
    error "Required tool not found: $cmd"
  fi
done

AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
success "AWS account: ${AWS_ACCOUNT_ID}, region: ${AWS_REGION}"

# --------------------------------------------------------------------------
# Step 1: Configure kubectl
# --------------------------------------------------------------------------
log "Configuring kubectl for cluster: ${CLUSTER_NAME}"
aws eks update-kubeconfig \
  --region "${AWS_REGION}" \
  --name "${CLUSTER_NAME}" \
  --alias "${CLUSTER_NAME}"

kubectl cluster-info --context "${CLUSTER_NAME}" || error "Cannot reach cluster"
success "kubectl configured"

# --------------------------------------------------------------------------
# Step 2: Apply base Kubernetes manifests
# --------------------------------------------------------------------------
log "Applying namespaces..."
kubectl apply -f "${REPO_ROOT}/kubernetes/namespaces/namespaces.yaml"

log "Applying resource quotas..."
kubectl apply -f "${REPO_ROOT}/kubernetes/namespaces/resource-quotas.yaml"

log "Applying RBAC..."
kubectl apply -f "${REPO_ROOT}/kubernetes/rbac/cluster-roles.yaml"
kubectl apply -f "${REPO_ROOT}/kubernetes/rbac/cluster-role-bindings.yaml"
kubectl apply -f "${REPO_ROOT}/kubernetes/rbac/service-accounts.yaml"
kubectl apply -f "${REPO_ROOT}/kubernetes/rbac/roles.yaml"

log "Applying storage classes..."
kubectl apply -f "${REPO_ROOT}/kubernetes/storage/storage-classes.yaml"

log "Applying network policies..."
kubectl apply -f "${REPO_ROOT}/kubernetes/network-policies/default-deny.yaml"
kubectl apply -f "${REPO_ROOT}/kubernetes/network-policies/app-network-policies.yaml"

log "Applying cluster add-ons..."
kubectl apply -f "${REPO_ROOT}/kubernetes/cluster-addons/metrics-server.yaml"
kubectl apply -f "${REPO_ROOT}/kubernetes/cluster-addons/cluster-autoscaler.yaml"
kubectl apply -f "${REPO_ROOT}/kubernetes/cluster-addons/pod-disruption-budgets.yaml"

success "Base manifests applied"

# --------------------------------------------------------------------------
# Step 3: Upload Grafana dashboards as ConfigMaps
# --------------------------------------------------------------------------
log "Uploading Grafana dashboard ConfigMaps..."
kubectl create configmap grafana-dashboard-platform-overview \
  --from-file=platform-overview.json="${REPO_ROOT}/monitoring/grafana/dashboards/platform-overview-dashboard.json" \
  -n monitoring \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create configmap grafana-dashboard-app-slo \
  --from-file=app-slo.json="${REPO_ROOT}/monitoring/grafana/dashboards/application-slo-dashboard.json" \
  -n monitoring \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl label configmap grafana-dashboard-platform-overview grafana_dashboard=1 -n monitoring --overwrite
kubectl label configmap grafana-dashboard-app-slo           grafana_dashboard=1 -n monitoring --overwrite
success "Grafana dashboards uploaded"

# --------------------------------------------------------------------------
# Step 4: Install ArgoCD
# --------------------------------------------------------------------------
log "Adding Helm repos..."
helm repo add argo   https://argoproj.github.io/argo-helm      2>/dev/null || true
helm repo add jenkins https://charts.jenkins.io                 2>/dev/null || true
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx 2>/dev/null || true
helm repo update
success "Helm repos updated"

log "Installing ArgoCD..."
helm upgrade --install argocd argo/argo-cd \
  --namespace argocd \
  --create-namespace \
  --values "${REPO_ROOT}/argocd/install/helm-values.yaml" \
  --version "6.7.2" \
  --timeout 10m \
  --wait

success "ArgoCD installed"

# --------------------------------------------------------------------------
# Step 5: Create ArgoCD secrets (from env vars or prompts)
# --------------------------------------------------------------------------
log "Creating ArgoCD secrets..."

GITHUB_TOKEN="${GITHUB_TOKEN:-}"
SLACK_TOKEN="${SLACK_TOKEN:-}"

if [[ -z "$GITHUB_TOKEN" ]]; then
  read -rsp "Enter GitHub PAT token for ArgoCD repo access: " GITHUB_TOKEN
  echo
fi

kubectl create secret generic argocd-github-secret \
  --from-literal=username=git \
  --from-literal=password="${GITHUB_TOKEN}" \
  -n argocd \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic devops-platform-gitops-repo \
  --from-literal=type=git \
  --from-literal=url="https://github.com/your-org/devops-platform-gitops" \
  --from-literal=username=git \
  --from-literal=password="${GITHUB_TOKEN}" \
  -n argocd \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl label secret devops-platform-gitops-repo \
  argocd.argoproj.io/secret-type=repository \
  -n argocd --overwrite

if [[ -n "$SLACK_TOKEN" ]]; then
  kubectl create secret generic argocd-notifications-secret \
    --from-literal=slack-token="${SLACK_TOKEN}" \
    -n argocd \
    --dry-run=client -o yaml | kubectl apply -f -
fi

success "ArgoCD secrets created"

# --------------------------------------------------------------------------
# Step 6: Bootstrap ArgoCD root app (app-of-apps)
# --------------------------------------------------------------------------
log "Waiting for ArgoCD to be ready..."
kubectl rollout status deployment/argocd-server -n argocd --timeout=300s

log "Applying ArgoCD AppProjects..."
kubectl apply -f "${REPO_ROOT}/argocd/apps/projects.yaml"

log "Applying ArgoCD root application (app-of-apps)..."
kubectl apply -f "${REPO_ROOT}/argocd/apps/root-app.yaml"

success "ArgoCD root app applied — platform tools will sync automatically"

# --------------------------------------------------------------------------
# Step 7: Create monitoring secrets
# --------------------------------------------------------------------------
log "Creating monitoring secrets..."

GRAFANA_PASS="${GRAFANA_ADMIN_PASSWORD:-$(openssl rand -base64 16)}"
kubectl create secret generic grafana-admin-secret \
  --from-literal=admin-password="${GRAFANA_PASS}" \
  -n monitoring \
  --dry-run=client -o yaml | kubectl apply -f -

# Store generated password for display at end
GRAFANA_PASSWORD_GENERATED="$GRAFANA_PASS"

# Prometheus basic auth (default: admin/admin — CHANGE IN PRODUCTION)
HTPASSWD_HASH=$(openssl passwd -apr1 admin)
kubectl create secret generic prometheus-basic-auth \
  --from-literal=auth="admin:${HTPASSWD_HASH}" \
  -n monitoring \
  --dry-run=client -o yaml | kubectl apply -f -

success "Monitoring secrets created"

# --------------------------------------------------------------------------
# Step 8: Create Jenkins secrets
# --------------------------------------------------------------------------
log "Creating Jenkins secrets..."

JENKINS_PASS="${JENKINS_ADMIN_PASSWORD:-$(openssl rand -base64 16)}"
JENKINS_PASSWORD_GENERATED="$JENKINS_PASS"

kubectl create secret generic jenkins-admin-secret \
  --from-literal=jenkins-admin-user=admin \
  --from-literal=jenkins-admin-password="${JENKINS_PASS}" \
  -n jenkins \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic jenkins-github-secret \
  --from-literal=username=git \
  --from-literal=token="${GITHUB_TOKEN}" \
  -n jenkins \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic jenkins-aws-secret \
  --from-literal=aws-account-id="${AWS_ACCOUNT_ID}" \
  -n jenkins \
  --dry-run=client -o yaml | kubectl apply -f -

success "Jenkins secrets created"

# --------------------------------------------------------------------------
# Step 9: Print access info
# --------------------------------------------------------------------------
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║            BOOTSTRAP COMPLETE — ACCESS INFORMATION          ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo "Cluster:    ${CLUSTER_NAME}"
echo "Region:     ${AWS_REGION}"
echo ""
echo -e "${BLUE}Port-forward commands:${NC}"
echo "  ArgoCD:     kubectl port-forward svc/argocd-server 8443:443 -n argocd"
echo "  Jenkins:    kubectl port-forward svc/jenkins 8080:8080 -n jenkins"
echo "  Grafana:    kubectl port-forward svc/kube-prometheus-stack-grafana 3000:80 -n monitoring"
echo "  Prometheus: kubectl port-forward svc/kube-prometheus-stack-prometheus 9090:9090 -n monitoring"
echo ""
echo -e "${BLUE}Credentials:${NC}"
echo "  ArgoCD admin password:"
echo "    kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}' | base64 -d"
echo ""
echo "  Jenkins admin password: ${JENKINS_PASSWORD_GENERATED}"
echo "  Grafana admin password: ${GRAFANA_PASSWORD_GENERATED}"
echo ""
echo -e "${YELLOW}IMPORTANT: Save these passwords securely. They will not be shown again.${NC}"
echo ""
