#!/usr/bin/env bash
# =============================================================================
# teardown.sh — Safely destroy all AWS resources
#
# Sequence:
#   1. Confirm environment
#   2. Delete all K8s LoadBalancer services (prevents orphaned ELBs blocking TF destroy)
#   3. terraform destroy dev
#   4. terraform destroy prod (optional)
#   5. Clean up local kubeconfig entries
#
# Usage:
#   ./scripts/teardown.sh --env dev [--yes]
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

ENV=""
AUTO_APPROVE=false
AWS_REGION="us-east-1"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()   { echo -e "\033[0;34m[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)    ENV="$2";        shift 2 ;;
    --region) AWS_REGION="$2"; shift 2 ;;
    --yes)    AUTO_APPROVE=true; shift ;;
    *) echo "Unknown: $1"; exit 1 ;;
  esac
done

[[ -z "$ENV" ]] && error "--env is required (dev|prod)"

# Hard stop for prod without explicit confirmation
if [[ "$ENV" == "prod" && "$AUTO_APPROVE" != "true" ]]; then
  echo -e "${RED}╔══════════════════════════════════════╗${NC}"
  echo -e "${RED}║  DESTROYING PRODUCTION ENVIRONMENT  ║${NC}"
  echo -e "${RED}╚══════════════════════════════════════╝${NC}"
  read -rp "Type the environment name to confirm: " CONFIRM
  [[ "$CONFIRM" != "prod" ]] && { echo "Aborted."; exit 0; }
fi

CLUSTER_NAME="devops-platform-${ENV}"

# --------------------------------------------------------------------------
# Step 1: Delete LoadBalancer services to avoid orphaned ELBs
# --------------------------------------------------------------------------
log "Checking for LoadBalancer services..."
aws eks update-kubeconfig --region "${AWS_REGION}" --name "${CLUSTER_NAME}" 2>/dev/null || warn "Could not configure kubectl — cluster may already be down"

if kubectl cluster-info &>/dev/null 2>&1; then
  LB_SERVICES=$(kubectl get svc --all-namespaces -o json 2>/dev/null \
    | jq -r '.items[] | select(.spec.type=="LoadBalancer") | "\(.metadata.namespace) \(.metadata.name)"')

  if [[ -n "$LB_SERVICES" ]]; then
    warn "Found LoadBalancer services — deleting to avoid orphaned ELBs:"
    echo "$LB_SERVICES"
    echo "$LB_SERVICES" | while read -r ns svc; do
      kubectl delete svc "$svc" -n "$ns" --ignore-not-found
      log "Deleted svc/$svc in $ns"
    done
    log "Waiting 30s for ELBs to fully deregister..."
    sleep 30
  fi
fi

# --------------------------------------------------------------------------
# Step 2: Terraform destroy
# --------------------------------------------------------------------------
TF_DIR="${REPO_ROOT}/terraform/environments/${ENV}"

if [[ ! -d "$TF_DIR" ]]; then
  error "Terraform environment directory not found: ${TF_DIR}"
fi

warn "About to run: terraform destroy in ${TF_DIR}"

APPROVE_FLAG=""
[[ "$AUTO_APPROVE" == "true" ]] && APPROVE_FLAG="-auto-approve"

cd "$TF_DIR"
terraform init -reconfigure
terraform destroy ${APPROVE_FLAG}

success "Terraform destroy complete for ${ENV}"

# --------------------------------------------------------------------------
# Step 3: Clean local kubeconfig
# --------------------------------------------------------------------------
kubectl config delete-context "${CLUSTER_NAME}" 2>/dev/null || true
kubectl config delete-cluster "${CLUSTER_NAME}" 2>/dev/null || true
success "Removed ${CLUSTER_NAME} from local kubeconfig"

echo ""
success "Teardown complete for environment: ${ENV}"
warn "S3 state bucket and DynamoDB lock table are NOT deleted — remove manually if needed:"
echo "  aws s3 rb s3://devops-platform-terraform-state --force"
echo "  aws dynamodb delete-table --table-name devops-platform-terraform-locks --region ${AWS_REGION}"
