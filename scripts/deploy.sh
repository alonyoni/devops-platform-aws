#!/usr/bin/env bash
# =============================================================================
# deploy.sh — Update image tag in GitOps repo; ArgoCD syncs automatically
#
# Usage:
#   ./scripts/deploy.sh --env dev --tag v1.2.3 [--wait]
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

ENV=""
IMAGE_TAG=""
WAIT_FOR_ROLLOUT=false
AWS_REGION="us-east-1"
GITOPS_REPO="${GITOPS_REPO:-https://github.com/your-org/devops-platform-gitops.git}"
APP_NAME="app"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; NC='\033[0m'
log()     { echo -e "${BLUE}[$(date +%H:%M:%S)]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)    ENV="$2";        shift 2 ;;
    --tag)    IMAGE_TAG="$2";  shift 2 ;;
    --region) AWS_REGION="$2"; shift 2 ;;
    --wait)   WAIT_FOR_ROLLOUT=true; shift ;;
    *) echo "Unknown: $1"; exit 1 ;;
  esac
done

[[ -z "$ENV" ]]       && error "--env is required (dev|prod)"
[[ -z "$IMAGE_TAG" ]] && error "--tag is required"

# Require explicit confirmation for prod
if [[ "$ENV" == "prod" ]]; then
  echo -e "${YELLOW}WARNING: Deploying to PRODUCTION (${IMAGE_TAG})${NC}"
  read -rp "Type 'yes' to confirm: " CONFIRM
  [[ "$CONFIRM" != "yes" ]] && { echo "Aborted."; exit 0; }
fi

AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
IMAGE_REPO="${ECR_REGISTRY}/devops-platform/${APP_NAME}"

GITOPS_DIR=$(mktemp -d)
VALUES_PATH="environments/${ENV}/${APP_NAME}/values.yaml"

trap 'rm -rf "${GITOPS_DIR}"' EXIT

# --------------------------------------------------------------------------
# Clone GitOps repo and update image tag
# --------------------------------------------------------------------------
GITHUB_TOKEN="${GITHUB_TOKEN:-}"
if [[ -z "$GITHUB_TOKEN" ]]; then
  read -rsp "GitHub token for GitOps repo push: " GITHUB_TOKEN
  echo
fi

GITOPS_REPO_AUTH="${GITOPS_REPO/https:\/\//https:\/\/git:${GITHUB_TOKEN}@}"

log "Cloning GitOps repo..."
git clone --depth 1 "${GITOPS_REPO_AUTH}" "${GITOPS_DIR}"

cd "${GITOPS_DIR}"
git config user.email "deploy-script@devops-platform.internal"
git config user.name "Deploy Script"

log "Updating ${VALUES_PATH} → image.tag=${IMAGE_TAG}"

if ! command -v yq &>/dev/null; then
  error "yq is required. Install: https://github.com/mikefarah/yq"
fi

yq e ".image.tag = \"${IMAGE_TAG}\"" -i "${VALUES_PATH}"
yq e ".image.repository = \"${IMAGE_REPO}\"" -i "${VALUES_PATH}"

echo ""
log "Changes:"
git diff

git add "${VALUES_PATH}"
git commit -m "deploy(${APP_NAME}): ${IMAGE_TAG} → ${ENV}

Deployed by: $(git config user.name)
Timestamp: $(date -u +'%Y-%m-%dT%H:%M:%SZ')"

git push origin main
success "GitOps repo updated"

# --------------------------------------------------------------------------
# Optional: wait for rollout
# --------------------------------------------------------------------------
if [[ "$WAIT_FOR_ROLLOUT" == "true" ]]; then
  log "Waiting for ArgoCD to sync (up to 5 minutes)..."
  sleep 30

  CLUSTER_NAME="devops-platform-${ENV}"
  aws eks update-kubeconfig --region "${AWS_REGION}" --name "${CLUSTER_NAME}" --alias "${CLUSTER_NAME}" 2>/dev/null || true

  kubectl rollout status deployment/${APP_NAME} \
    --namespace "app-${ENV}" \
    --timeout=300s && success "Rollout complete" || {
    echo -e "${YELLOW}Rollout timed out. Check ArgoCD UI for status.${NC}"
  }
fi

echo ""
success "Deployment triggered"
echo "  Environment: ${ENV}"
echo "  Image tag:   ${IMAGE_TAG}"
echo "  ArgoCD will sync the change automatically (dev) or on manual approval (prod)"
