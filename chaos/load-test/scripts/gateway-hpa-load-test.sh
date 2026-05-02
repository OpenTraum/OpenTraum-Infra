#!/usr/bin/env bash
# =============================================================================
# OpenTraum Gateway HPA Load Test (EKS wrk2 Job only)
# =============================================================================
# Historical workstation wrk/wrk2 modes were intentionally removed. All supported
# Gateway HPA load generation now runs as Kubernetes wrk2 Jobs via the EKS runner
# so results do not depend on a developer workstation or external client path.
# =============================================================================

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S_WRK2_RUNNER="${SCRIPT_DIR}/gateway-hpa-k8s-wrk2-runner.sh"

usage() {
  cat <<'USAGE'
OpenTraum Gateway HPA Load Test

Supported runner:
  chaos/load-test/scripts/gateway-hpa-k8s-wrk2-runner.sh

This compatibility entrypoint delegates to the Kubernetes wrk2 Job runner.
Workstation generators and legacy MODE values (wrk, wrk-parallel, wrk2,
wrk2-rate, wrk2-parallel, wrk-all) are not supported.

Examples:
  # Plan a 17-pod, 10,000 RPS EKS wrk2 Job run.
  DRY_RUN=1 \
  TOTAL_RATE=10000 \
  PODS=17 \
  chaos/load-test/scripts/gateway-hpa-load-test.sh

  # Execute after reviewing the manifest and node separation.
  DRY_RUN=0 \
  TOTAL_RATE=10000 \
  PODS=17 \
  chaos/load-test/scripts/gateway-hpa-load-test.sh

Optional variables are the same as gateway-hpa-k8s-wrk2-runner.sh, including:
  LOADTEST_NAMESPACE=load-test
  TARGET_NAMESPACE=opentraum
  TARGET_URL=http://gateway.opentraum.svc.cluster.local:8080/api/__loadtest__
  IMAGE=cylab/wrk2:latest
  TOTAL_RATE=10000
  PODS=17
  THREADS=2
  CONNECTIONS=128
  DURATION_SECONDS=300
  TIMEOUT_SECONDS=20
  DRY_RUN=1
USAGE
}

fail() {
  echo "ERROR: $*" >&2
  exit 2
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
esac

if [[ -n "${MODE:-}" ]]; then
  fail "MODE=${MODE} is a removed local-generator option. Use EKS wrk2 Job variables such as TOTAL_RATE, PODS, DURATION_SECONDS, and DRY_RUN instead."
fi

if [[ -n "${WRK_BIN:-}" || -n "${WRK2_BIN:-}" ]]; then
  fail "WRK_BIN/WRK2_BIN are not supported because load generation must run inside EKS wrk2 Job pods."
fi

exec "${K8S_WRK2_RUNNER}" "$@"
