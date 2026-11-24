#!/usr/bin/env bash
# =============================================================================
# port-forward.sh — Start port-forwards for all platform services
#
# Usage:
#   ./scripts/port-forward.sh [--env dev] [--service all|argocd|jenkins|grafana|prometheus]
# =============================================================================
set -euo pipefail

ENV="dev"
SERVICE="all"
AWS_REGION="us-east-1"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)     ENV="$2";     shift 2 ;;
    --service) SERVICE="$2"; shift 2 ;;
    --region)  AWS_REGION="$2"; shift 2 ;;
    *) echo "Unknown: $1"; exit 1 ;;
  esac
done

CLUSTER_NAME="devops-platform-${ENV}"
aws eks update-kubeconfig --region "${AWS_REGION}" --name "${CLUSTER_NAME}" 2>/dev/null || true

pf() {
  local svc=$1 ns=$2 local_port=$3 remote_port=$4
  echo "Starting port-forward: $svc ($ns) → localhost:$local_port"
  kubectl port-forward "svc/$svc" "${local_port}:${remote_port}" -n "$ns" &
}

case "$SERVICE" in
  argocd)
    pf argocd-server argocd 8443 443
    ;;
  jenkins)
    pf jenkins jenkins 8080 8080
    ;;
  grafana)
    pf kube-prometheus-stack-grafana monitoring 3000 80
    ;;
  prometheus)
    pf kube-prometheus-stack-prometheus monitoring 9090 9090
    ;;
  alertmanager)
    pf kube-prometheus-stack-alertmanager monitoring 9093 9093
    ;;
  all)
    pf argocd-server                        argocd    8443 443
    pf jenkins                              jenkins   8080 8080
    pf kube-prometheus-stack-grafana        monitoring 3000 80
    pf kube-prometheus-stack-prometheus     monitoring 9090 9090
    pf kube-prometheus-stack-alertmanager   monitoring 9093 9093
    ;;
  *)
    echo "Unknown service: $SERVICE"
    exit 1
    ;;
esac

echo ""
echo "Port-forwards running. Press Ctrl+C to stop all."
echo ""
echo "  ArgoCD:      https://localhost:8443"
echo "  Jenkins:     http://localhost:8080"
echo "  Grafana:     http://localhost:3000"
echo "  Prometheus:  http://localhost:9090"
echo "  Alertmanager: http://localhost:9093"
echo ""

wait
