#!/usr/bin/env bash
# =============================================================================
# OpenTraum Gateway HPA Kubernetes wrk2 Runner
# =============================================================================
# Runs wrk2 from multiple Kubernetes Job pods instead of the local workstation.
# The default target is the in-cluster Gateway service path so business services
# are not exercised.
# =============================================================================

set -Eeuo pipefail

KUBECTL_BIN="${KUBECTL_BIN:-kubectl}"
LOADTEST_NAMESPACE="${LOADTEST_NAMESPACE:-opentraum-loadtest}"
TARGET_NAMESPACE="${TARGET_NAMESPACE:-opentraum}"
GATEWAY_DEPLOYMENT="${GATEWAY_DEPLOYMENT:-gateway}"
GATEWAY_HPA="${GATEWAY_HPA:-gateway-hpa}"
GATEWAY_LABEL_SELECTOR="${GATEWAY_LABEL_SELECTOR:-app=gateway}"
TARGET_URL="${TARGET_URL:-http://gateway.opentraum.svc.cluster.local:8080/api/__loadtest__}"
IMAGE="${IMAGE:-cylab/wrk2:latest}"
RUN_ID="${RUN_ID:-$(date +%Y%m%d%H%M%S%z)}"
JOB_NAME_SUFFIX="$(printf '%s' "${RUN_ID}" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9-]+/-/g; s/^-+//; s/-+$//')"
JOB_NAME="${JOB_NAME:-gateway-wrk2-${JOB_NAME_SUFFIX}}"
OUT_DIR="${OUT_DIR:-/tmp/opentraum-gateway-hpa-k8s-wrk2-${RUN_ID}}"
TOTAL_RATE="${TOTAL_RATE:-10000}"
PODS="${PODS:-17}"
THREADS="${THREADS:-2}"
CONNECTIONS="${CONNECTIONS:-128}"
DURATION_SECONDS="${DURATION_SECONDS:-300}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-20}"
DRY_RUN="${DRY_RUN:-1}"
WAIT_TIMEOUT_SECONDS="${WAIT_TIMEOUT_SECONDS:-1200}"
AVOID_GATEWAY_NODES="${AVOID_GATEWAY_NODES:-1}"
STRICT_GATEWAY_NODE_AVOIDANCE="${STRICT_GATEWAY_NODE_AVOIDANCE:-1}"
LOADGEN_NODE_SELECTOR="${LOADGEN_NODE_SELECTOR:-}"
LOADGEN_TOLERATION_KEY="${LOADGEN_TOLERATION_KEY:-}"
LOADGEN_TOLERATION_VALUE="${LOADGEN_TOLERATION_VALUE:-}"
LOADGEN_TOLERATION_EFFECT="${LOADGEN_TOLERATION_EFFECT:-NoSchedule}"
CPU_REQUEST="${CPU_REQUEST:-100m}"
CPU_LIMIT="${CPU_LIMIT:-500m}"
MEMORY_REQUEST="${MEMORY_REQUEST:-64Mi}"
MEMORY_LIMIT="${MEMORY_LIMIT:-256Mi}"
GATEWAY_NODES=""
LOAD_TEST_LOCK_DIR="${LOAD_TEST_LOCK_DIR:-/tmp/opentraum-gateway-hpa-loadtest.lock}"
LOAD_TEST_LOCK_ACQUIRED=0

usage() {
  cat <<'USAGE'
OpenTraum Gateway HPA Kubernetes wrk2 Runner

Default behavior is DRY_RUN=1. It writes the Job manifest and command plan only.

Examples:
  # Plan a 17-pod, 10,000 RPS run against the in-cluster Gateway service.
  scripts/load-test/gateway-hpa-k8s-wrk2-runner.sh

  # Execute after checking the manifest and cluster/node separation.
  DRY_RUN=0 \
  TOTAL_RATE=10000 \
  PODS=17 \
  scripts/load-test/gateway-hpa-k8s-wrk2-runner.sh

  # Use an explicitly supplied target while keeping it out of git.
  DRY_RUN=0 \
  TARGET_URL="http://gateway.opentraum.svc.cluster.local:8080/api/__loadtest__" \
  TOTAL_RATE=5000 \
  PODS=10 \
  scripts/load-test/gateway-hpa-k8s-wrk2-runner.sh

Optional:
  LOADTEST_NAMESPACE=opentraum-loadtest
  TARGET_NAMESPACE=opentraum
  GATEWAY_LABEL_SELECTOR=app=gateway
  TARGET_URL=http://gateway.opentraum.svc.cluster.local:8080/api/__loadtest__
  IMAGE=cylab/wrk2:latest
  TOTAL_RATE=10000
  PODS=17
  THREADS=2
  CONNECTIONS=128
  DURATION_SECONDS=300
  TIMEOUT_SECONDS=20
  AVOID_GATEWAY_NODES=1
  STRICT_GATEWAY_NODE_AVOIDANCE=1
  LOADGEN_NODE_SELECTOR="nodegroup-type=gpu"
  LOADGEN_TOLERATION_KEY=nodegroup-type
  LOADGEN_TOLERATION_VALUE=gpu
  LOADGEN_TOLERATION_EFFECT=NoSchedule
  DRY_RUN=1
  LOAD_TEST_LOCK_DIR=/tmp/opentraum-gateway-hpa-loadtest.lock
USAGE
}

fail() {
  echo "ERROR: $*" >&2
  exit 2
}

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')" "$*" | tee -a "${OUT_DIR}/run.log"
}

k() {
  "${KUBECTL_BIN}" "$@"
}

release_load_test_lock() {
  if [[ "${LOAD_TEST_LOCK_ACQUIRED}" = "1" ]]; then
    rm -rf "${LOAD_TEST_LOCK_DIR}"
    LOAD_TEST_LOCK_ACQUIRED=0
  fi
}

acquire_load_test_lock() {
  if mkdir "${LOAD_TEST_LOCK_DIR}" 2>/dev/null; then
    LOAD_TEST_LOCK_ACQUIRED=1
    {
      echo "pid=$$"
      echo "started_at=$(date '+%Y-%m-%d %H:%M:%S %Z')"
      echo "job_name=${JOB_NAME}"
      echo "out_dir=${OUT_DIR}"
    } > "${LOAD_TEST_LOCK_DIR}/owner"
    trap release_load_test_lock EXIT INT TERM
    log "Acquired load-test lock: ${LOAD_TEST_LOCK_DIR}"
    return 0
  fi

  local owner="unknown"
  [[ -f "${LOAD_TEST_LOCK_DIR}/owner" ]] && owner="$(tr '\n' ' ' < "${LOAD_TEST_LOCK_DIR}/owner")"
  fail "another gateway load test appears to be running; lock=${LOAD_TEST_LOCK_DIR}; owner=${owner}. Remove the lock only after confirming no load test is active."
}

require_positive_integer() {
  local name="$1"
  local value="$2"
  [[ "${value}" =~ ^[1-9][0-9]*$ ]] || fail "${name} must be a positive integer. got=${value}"
}

validate_match_label_selector() {
  local name="$1"
  local selector="$2"
  [[ -n "${selector//[[:space:]]/}" ]] || fail "${name} must not be empty"

  local item key value
  local normalized="${selector//,/ }"
  for item in ${normalized}; do
    key="${item%%=*}"
    value="${item#*=}"
    [[ -n "${key}" && -n "${value}" && "${key}" != "${value}" ]] || fail "${name} must use equality-only key=value items. got=${item}"
    [[ "${key}" != *'!'* && "${key}" != *'('* && "${key}" != *')'* ]] || fail "${name} only supports key=value items that can be rendered into matchLabels. got=${item}"
  done
}

match_labels_yaml() {
  local selector="$1"
  local indent="$2"
  local normalized="${selector//,/ }"
  local item key value
  for item in ${normalized}; do
    key="${item%%=*}"
    value="${item#*=}"
    printf '%*s%s: "%s"\n' "${indent}" '' "${key}" "${value}"
  done
}

validate() {
  [[ "${DRY_RUN}" = "0" || "${DRY_RUN}" = "1" ]] || fail "DRY_RUN must be 0 or 1. got=${DRY_RUN}"
  [[ "${AVOID_GATEWAY_NODES}" = "0" || "${AVOID_GATEWAY_NODES}" = "1" ]] || fail "AVOID_GATEWAY_NODES must be 0 or 1. got=${AVOID_GATEWAY_NODES}"
  [[ "${STRICT_GATEWAY_NODE_AVOIDANCE}" = "0" || "${STRICT_GATEWAY_NODE_AVOIDANCE}" = "1" ]] || fail "STRICT_GATEWAY_NODE_AVOIDANCE must be 0 or 1. got=${STRICT_GATEWAY_NODE_AVOIDANCE}"
  validate_match_label_selector "GATEWAY_LABEL_SELECTOR" "${GATEWAY_LABEL_SELECTOR}"
  require_positive_integer "TOTAL_RATE" "${TOTAL_RATE}"
  require_positive_integer "PODS" "${PODS}"
  require_positive_integer "THREADS" "${THREADS}"
  require_positive_integer "CONNECTIONS" "${CONNECTIONS}"
  require_positive_integer "DURATION_SECONDS" "${DURATION_SECONDS}"
  require_positive_integer "TIMEOUT_SECONDS" "${TIMEOUT_SECONDS}"
  require_positive_integer "WAIT_TIMEOUT_SECONDS" "${WAIT_TIMEOUT_SECONDS}"
}

rate_per_pod() {
  awk -v total="${TOTAL_RATE}" -v pods="${PODS}" 'BEGIN { printf "%d", int((total + pods - 1) / pods) }'
}

collect_gateway_nodes() {
  [[ "${AVOID_GATEWAY_NODES}" = "1" ]] || return 0

  local nodes
  set +e
  nodes="$(k get pods -n "${TARGET_NAMESPACE}" -l "${GATEWAY_LABEL_SELECTOR}" -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' 2>"${OUT_DIR}/gateway-node-query.stderr" | sort -u)"
  local query_status=$?
  set -e

  GATEWAY_NODES="${nodes}"

  if [[ "${query_status}" -ne 0 || -z "${GATEWAY_NODES//[[:space:]]/}" ]]; then
    if [[ "${DRY_RUN}" = "0" && "${STRICT_GATEWAY_NODE_AVOIDANCE}" = "1" ]]; then
      fail "could not resolve current Gateway nodes; refusing live run because STRICT_GATEWAY_NODE_AVOIDANCE=1"
    fi
    log "Gateway node exclusion could not be resolved; dry-run manifest will keep podAntiAffinity only"
  fi
}

selector_yaml() {
  local selector="${LOADGEN_NODE_SELECTOR}"
  [[ -n "${selector//[[:space:]]/}" ]] || return 0

  echo "      nodeSelector:"
  local item key value
  for item in ${selector}; do
    key="${item%%=*}"
    value="${item#*=}"
    [[ -n "${key}" && -n "${value}" && "${key}" != "${value}" ]] || fail "LOADGEN_NODE_SELECTOR must use key=value items. got=${item}"
    printf '        %s: "%s"\n' "${key}" "${value}"
  done
}

tolerations_yaml() {
  [[ -n "${LOADGEN_TOLERATION_KEY//[[:space:]]/}" ]] || return 0

  echo "      tolerations:"
  echo "        - key: \"${LOADGEN_TOLERATION_KEY}\""
  if [[ -n "${LOADGEN_TOLERATION_VALUE//[[:space:]]/}" ]]; then
    echo "          operator: Equal"
    echo "          value: \"${LOADGEN_TOLERATION_VALUE}\""
  else
    echo "          operator: Exists"
  fi
  echo "          effect: \"${LOADGEN_TOLERATION_EFFECT}\""
}

gateway_node_values_yaml() {
  [[ "${AVOID_GATEWAY_NODES}" = "1" ]] || return 0
  [[ -n "${GATEWAY_NODES//[[:space:]]/}" ]] || return 0

  echo "                  - key: kubernetes.io/hostname"
  echo "                    operator: NotIn"
  echo "                    values:"
  local node
  while IFS= read -r node; do
    [[ -n "${node}" ]] || continue
    printf '                      - "%s"\n' "${node}"
  done <<< "${GATEWAY_NODES}"
}

write_manifest() {
  local manifest="$1"
  local per_pod_rate
  per_pod_rate="$(rate_per_pod)"

  {
    cat <<YAML
apiVersion: batch/v1
kind: Job
metadata:
  name: ${JOB_NAME}
  namespace: ${LOADTEST_NAMESPACE}
  labels:
    app.kubernetes.io/name: gateway-wrk2-loadgen
    app.kubernetes.io/part-of: opentraum
    opentraum.io/load-test: gateway-hpa
spec:
  completions: ${PODS}
  parallelism: ${PODS}
  completionMode: Indexed
  backoffLimit: 0
  ttlSecondsAfterFinished: 3600
  template:
    metadata:
      labels:
        app.kubernetes.io/name: gateway-wrk2-loadgen
        app.kubernetes.io/part-of: opentraum
        opentraum.io/load-test: gateway-hpa
    spec:
      restartPolicy: Never
YAML
    selector_yaml
    tolerations_yaml
    cat <<YAML
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
              - matchExpressions:
                  - key: kubernetes.io/os
                    operator: In
                    values:
                      - linux
YAML
    gateway_node_values_yaml
    cat <<YAML
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            - labelSelector:
                matchLabels:
YAML
    match_labels_yaml "${GATEWAY_LABEL_SELECTOR}" 18
    cat <<YAML
              namespaces:
                - ${TARGET_NAMESPACE}
              topologyKey: kubernetes.io/hostname
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: ScheduleAnyway
          labelSelector:
            matchLabels:
              app.kubernetes.io/name: gateway-wrk2-loadgen
      containers:
        - name: wrk2
          image: ${IMAGE}
          imagePullPolicy: IfNotPresent
          command:
            - wrk
          args:
            - "-t${THREADS}"
            - "-c${CONNECTIONS}"
            - "-d${DURATION_SECONDS}s"
            - "-R${per_pod_rate}"
            - "--timeout"
            - "${TIMEOUT_SECONDS}s"
            - "--latency"
            - "${TARGET_URL}"
          resources:
            requests:
              cpu: ${CPU_REQUEST}
              memory: ${MEMORY_REQUEST}
            limits:
              cpu: ${CPU_LIMIT}
              memory: ${MEMORY_LIMIT}
YAML
  } > "${manifest}"
}

snapshot() {
  local label="$1"
  local dir="${OUT_DIR}/${label}"
  mkdir -p "${dir}"
  {
    echo "### timestamp"
    date '+%Y-%m-%d %H:%M:%S %Z'
    echo
    echo "### hpa"
    k get hpa "${GATEWAY_HPA}" -n "${TARGET_NAMESPACE}" -o wide || true
    echo
    echo "### deployment"
    k get deploy "${GATEWAY_DEPLOYMENT}" -n "${TARGET_NAMESPACE}" -o wide || true
    echo
    echo "### gateway pods"
    k get pods -n "${TARGET_NAMESPACE}" -l "${GATEWAY_LABEL_SELECTOR}" -o wide || true
    echo
    echo "### loadgen pods"
    k get pods -n "${LOADTEST_NAMESPACE}" -l job-name="${JOB_NAME}" -o wide || true
    echo
    echo "### top nodes"
    k top nodes || true
  } > "${dir}/snapshot.txt" 2>&1
}

main() {
  validate
  mkdir -p "${OUT_DIR}"
  collect_gateway_nodes

  local per_pod_rate
  per_pod_rate="$(rate_per_pod)"
  local manifest="${OUT_DIR}/${JOB_NAME}.yaml"
  write_manifest "${manifest}"

  {
    echo "target_url=<masked>"
    echo "image=${IMAGE}"
    echo "total_rate=${TOTAL_RATE}"
    echo "pods=${PODS}"
    echo "rate_per_pod=${per_pod_rate}"
    echo "threads=${THREADS}"
    echo "connections=${CONNECTIONS}"
    echo "duration_seconds=${DURATION_SECONDS}"
    echo "timeout_seconds=${TIMEOUT_SECONDS}"
    echo "gateway_label_selector=${GATEWAY_LABEL_SELECTOR}"
    echo "avoid_gateway_nodes=${AVOID_GATEWAY_NODES}"
    echo "strict_gateway_node_avoidance=${STRICT_GATEWAY_NODE_AVOIDANCE}"
    echo "gateway_node_exclusion_count=$(printf '%s\n' "${GATEWAY_NODES}" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')"
    echo "loadgen_node_selector=${LOADGEN_NODE_SELECTOR:-<none>}"
    echo "loadgen_toleration_key=${LOADGEN_TOLERATION_KEY:-<none>}"
    echo "loadgen_toleration_value=${LOADGEN_TOLERATION_VALUE:-<none>}"
    echo "loadgen_toleration_effect=${LOADGEN_TOLERATION_EFFECT:-<none>}"
  } > "${OUT_DIR}/run-config.env"

  log "Output directory: ${OUT_DIR}"
  log "Job manifest: ${manifest}"
  log "Total target rate: ${TOTAL_RATE}; pods: ${PODS}; rate per pod: ${per_pod_rate}"
  log "Target URL is masked in persisted config"

  if [[ "${DRY_RUN}" = "1" ]]; then
    log "DRY_RUN=1; manifest written only"
    return 0
  fi

  acquire_load_test_lock
  k create namespace "${LOADTEST_NAMESPACE}" --dry-run=client -o yaml > "${OUT_DIR}/namespace.yaml"
  k apply -f "${OUT_DIR}/namespace.yaml"

  snapshot "before"
  k apply -f "${manifest}"
  set +e
  k wait -n "${LOADTEST_NAMESPACE}" --for=condition=complete "job/${JOB_NAME}" --timeout="${WAIT_TIMEOUT_SECONDS}s"
  local wait_status=$?
  set -e

  snapshot "after"
  k logs -n "${LOADTEST_NAMESPACE}" -l job-name="${JOB_NAME}" --prefix=true --tail=-1 > "${OUT_DIR}/wrk2-pod-logs.txt" 2>&1 || true
  k get events -A --sort-by=.lastTimestamp > "${OUT_DIR}/events.txt" 2>&1 || true
  k describe job "${JOB_NAME}" -n "${LOADTEST_NAMESPACE}" > "${OUT_DIR}/job-describe.txt" 2>&1 || true
  k get pods -n "${LOADTEST_NAMESPACE}" -l job-name="${JOB_NAME}" -o wide > "${OUT_DIR}/loadgen-pods.txt" 2>&1 || true

  log "Completed Kubernetes wrk2 run: wait_status=${wait_status}"
  return "${wait_status}"
}

main "$@"
