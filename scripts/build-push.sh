#!/usr/bin/env bash
# =============================================================================
# build-push.sh — Build Docker image, scan with Trivy, push to ECR
#
# Usage:
#   ./scripts/build-push.sh [--env dev|prod] [--tag v1.2.3] [--skip-scan]
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Defaults
ENV="dev"
AWS_REGION="us-east-1"
IMAGE_TAG=""
SKIP_SCAN=false
APP_DIR="${REPO_ROOT}/app"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; NC='\033[0m'
log()     { echo -e "${BLUE}[$(date +%H:%M:%S)]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)        ENV="$2";       shift 2 ;;
    --region)     AWS_REGION="$2"; shift 2 ;;
    --tag)        IMAGE_TAG="$2"; shift 2 ;;
    --skip-scan)  SKIP_SCAN=true; shift ;;
    *) echo "Unknown: $1"; exit 1 ;;
  esac
done

# Derive values
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
ECR_REPO="devops-platform/app"

if [[ -z "$IMAGE_TAG" ]]; then
  GIT_SHA=$(git -C "${REPO_ROOT}" rev-parse --short HEAD)
  VERSION=$(cat "${APP_DIR}/VERSION" 2>/dev/null || echo "0.0.0")
  IMAGE_TAG="${ENV}-${VERSION}-${GIT_SHA}"
fi

IMAGE_FULL="${ECR_REGISTRY}/${ECR_REPO}:${IMAGE_TAG}"
BUILD_DATE=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
VCS_REF=$(git -C "${REPO_ROOT}" rev-parse HEAD)

log "Building image: ${IMAGE_FULL}"

# --------------------------------------------------------------------------
# Build
# --------------------------------------------------------------------------
docker build \
  --build-arg BUILD_DATE="${BUILD_DATE}" \
  --build-arg VCS_REF="${VCS_REF}" \
  --build-arg VERSION="${IMAGE_TAG}" \
  --tag "${IMAGE_FULL}" \
  --tag "${ECR_REGISTRY}/${ECR_REPO}:latest" \
  --file "${APP_DIR}/Dockerfile" \
  "${APP_DIR}"

success "Image built: ${IMAGE_FULL}"

# --------------------------------------------------------------------------
# Trivy scan
# --------------------------------------------------------------------------
if [[ "$SKIP_SCAN" == "false" ]]; then
  log "Running Trivy security scan..."

  if ! command -v trivy &>/dev/null; then
    log "Trivy not found locally, pulling via Docker..."
    docker run --rm \
      -v /var/run/docker.sock:/var/run/docker.sock \
      aquasec/trivy:0.49.1 image \
        --exit-code 1 \
        --severity HIGH,CRITICAL \
        --ignore-unfixed \
        "${IMAGE_FULL}"
  else
    trivy image \
      --exit-code 1 \
      --severity HIGH,CRITICAL \
      --ignore-unfixed \
      "${IMAGE_FULL}"
  fi

  success "Trivy scan passed"
fi

# --------------------------------------------------------------------------
# Push to ECR
# --------------------------------------------------------------------------
log "Authenticating to ECR..."
aws ecr get-login-password --region "${AWS_REGION}" \
  | docker login --username AWS --password-stdin "${ECR_REGISTRY}"

log "Pushing image..."
docker push "${IMAGE_FULL}"

if [[ "${ENV}" == "prod" ]]; then
  docker push "${ECR_REGISTRY}/${ECR_REPO}:latest"
  success "Also pushed :latest tag"
fi

IMAGE_DIGEST=$(docker inspect --format='{{index .RepoDigests 0}}' "${IMAGE_FULL}" 2>/dev/null || echo "N/A")

echo ""
success "Push complete"
echo "  Image:  ${IMAGE_FULL}"
echo "  Digest: ${IMAGE_DIGEST}"
echo "  Tag:    ${IMAGE_TAG}"
echo ""
echo "To deploy: ./scripts/deploy.sh --env ${ENV} --tag ${IMAGE_TAG}"
