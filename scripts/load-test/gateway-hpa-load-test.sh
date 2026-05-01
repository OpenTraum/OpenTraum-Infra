#!/usr/bin/env bash
# =============================================================================
# OpenTraum Gateway HPA Load Test
# =============================================================================
# Runs gateway-focused load-test phases and records Kubernetes HPA/deployment
# snapshots. TARGET_URL must point to a gateway-only route such as
# https://<TEAM_DOMAIN>/api/__loadtest__.
#
# This runner is for new wrk/wrk2 follow-up experiments only.
# =============================================================================

set -Eeuo pipefail

TARGET_URL="${TARGET_URL:-}"
MODE="${MODE:-wrk-all}"
NAMESPACE="${NAMESPACE:-opentraum}"
GATEWAY_HPA="${GATEWAY_HPA:-gateway-hpa}"
GATEWAY_DEPLOYMENT="${GATEWAY_DEPLOYMENT:-gateway}"
GATEWAY_LABEL_SELECTOR="${GATEWAY_LABEL_SELECTOR:-app=gateway}"
RUN_ID="${RUN_ID:-$(date +%Y%m%dT%H%M%S%z)}"
OUT_DIR="${OUT_DIR:-/tmp/opentraum-gateway-hpa-loadtest-${RUN_ID}}"
KUBECTL_BIN="${KUBECTL_BIN:-kubectl}"
WRK_BIN="${WRK_BIN:-wrk}"
WRK2_BIN="${WRK2_BIN:-wrk2}"
DRY_RUN="${DRY_RUN:-0}"
COOLDOWN_SECONDS="${COOLDOWN_SECONDS:-300}"
BASELINE_TIMEOUT_SECONDS="${BASELINE_TIMEOUT_SECONDS:-900}"
SKIP_BASELINE_WAIT="${SKIP_BASELINE_WAIT:-0}"
LOADGEN_MONITOR_INTERVAL_SECONDS="${LOADGEN_MONITOR_INTERVAL_SECONDS:-5}"
MONITOR_TAIL_SECONDS="${MONITOR_TAIL_SECONDS:-90}"

WRK_PARALLEL_CLIENTS="${WRK_PARALLEL_CLIENTS:-2 5}"
WRK_PARALLEL_THREADS="${WRK_PARALLEL_THREADS:-8}"
WRK_PARALLEL_CONNECTIONS="${WRK_PARALLEL_CONNECTIONS:-64}"
WRK_PARALLEL_DURATION_SECONDS="${WRK_PARALLEL_DURATION_SECONDS:-300}"

WRK2_RATES="${WRK2_RATES:-1000 2000 5000 10000}"
WRK2_THREADS="${WRK2_THREADS:-8}"
WRK2_CONNECTIONS="${WRK2_CONNECTIONS:-256}"
WRK2_DURATION_SECONDS="${WRK2_DURATION_SECONDS:-300}"
WRK2_TIMEOUT_SECONDS="${WRK2_TIMEOUT_SECONDS:-20}"
WRK2_PARALLEL_CLIENTS="${WRK2_PARALLEL_CLIENTS:-2 5}"

usage() {
  cat <<'USAGE'
OpenTraum Gateway HPA Load Test

Required:
  TARGET_URL="https://<TEAM_DOMAIN>/api/__loadtest__"

Examples:
  TARGET_URL="https://<TEAM_DOMAIN>/api/__loadtest__" \
    MODE=wrk-all \
    scripts/load-test/gateway-hpa-load-test.sh

  TARGET_URL="https://<TEAM_DOMAIN>/api/__loadtest__" \
    MODE=wrk2-rate \
    WRK2_RATES="2000 5000 10000" \
    scripts/load-test/gateway-hpa-load-test.sh

Optional:
  MODE=wrk-all|wrk|wrk-parallel|wrk2|wrk2-rate|wrk2-parallel
  OUT_DIR=/tmp/opentraum-gateway-hpa-loadtest
  DRY_RUN=1
  NAMESPACE=opentraum
  GATEWAY_HPA=gateway-hpa
  GATEWAY_DEPLOYMENT=gateway
  WRK_PARALLEL_CLIENTS="2 5"
  WRK_PARALLEL_THREADS=8
  WRK_PARALLEL_CONNECTIONS=64
  WRK_PARALLEL_DURATION_SECONDS=300
  WRK2_BIN=wrk2
  WRK2_RATES="1000 2000 5000 10000"
  WRK2_THREADS=8
  WRK2_CONNECTIONS=256
  WRK2_DURATION_SECONDS=300
  WRK2_TIMEOUT_SECONDS=20
  WRK2_PARALLEL_CLIENTS="2 5"
  COOLDOWN_SECONDS=300
  BASELINE_TIMEOUT_SECONDS=900
  SKIP_BASELINE_WAIT=0
  LOADGEN_MONITOR_INTERVAL_SECONDS=5
  MONITOR_TAIL_SECONDS=90
USAGE
}

fail() {
  echo "ERROR: $*" >&2
  exit 2
}

if [[ -z "${TARGET_URL}" ]]; then
  usage
  echo
  fail "TARGET_URL is required."
fi

case "${MODE}" in
  wrk|wrk-parallel|wrk2|wrk2-rate|wrk2-parallel|wrk-all) ;;
  *)
    fail "MODE must be one of wrk, wrk-parallel, wrk2, wrk2-rate, wrk2-parallel, wrk-all. got=${MODE}"
    ;;
esac

mkdir -p "${OUT_DIR}"

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')" "$*" | tee -a "${OUT_DIR}/run.log"
}

k() {
  "${KUBECTL_BIN}" "$@"
}

require_command() {
  local name="$1"
  local bin="$2"
  if ! command -v "${bin}" >/dev/null 2>&1; then
    echo "ERROR: ${name} command not found: ${bin}" >&2
    exit 127
  fi
}

is_dry_run() {
  [[ "${DRY_RUN}" = "1" ]]
}

require_positive_integer() {
  local name="$1"
  local value="$2"
  if ! [[ "${value}" =~ ^[1-9][0-9]*$ ]]; then
    fail "${name} must be a positive integer. got=${value}"
  fi
}

validate_integer_list() {
  local name="$1"
  local value="$2"
  if [[ -z "${value//[[:space:]]/}" ]]; then
    fail "${name} must include at least one positive integer."
  fi

  local item
  for item in ${value}; do
    require_positive_integer "${name} item" "${item}"
  done
}

validate_common_config() {
  [[ "${DRY_RUN}" = "0" || "${DRY_RUN}" = "1" ]] || fail "DRY_RUN must be 0 or 1. got=${DRY_RUN}"
  require_positive_integer "COOLDOWN_SECONDS" "${COOLDOWN_SECONDS}"
  require_positive_integer "BASELINE_TIMEOUT_SECONDS" "${BASELINE_TIMEOUT_SECONDS}"
  require_positive_integer "LOADGEN_MONITOR_INTERVAL_SECONDS" "${LOADGEN_MONITOR_INTERVAL_SECONDS}"
  require_positive_integer "MONITOR_TAIL_SECONDS" "${MONITOR_TAIL_SECONDS}"
}

validate_wrk_parallel_config() {
  validate_integer_list "WRK_PARALLEL_CLIENTS" "${WRK_PARALLEL_CLIENTS}"
  require_positive_integer "WRK_PARALLEL_THREADS" "${WRK_PARALLEL_THREADS}"
  require_positive_integer "WRK_PARALLEL_CONNECTIONS" "${WRK_PARALLEL_CONNECTIONS}"
  require_positive_integer "WRK_PARALLEL_DURATION_SECONDS" "${WRK_PARALLEL_DURATION_SECONDS}"
}

validate_wrk2_config() {
  validate_integer_list "WRK2_RATES" "${WRK2_RATES}"
  validate_integer_list "WRK2_PARALLEL_CLIENTS" "${WRK2_PARALLEL_CLIENTS}"
  require_positive_integer "WRK2_THREADS" "${WRK2_THREADS}"
  require_positive_integer "WRK2_CONNECTIONS" "${WRK2_CONNECTIONS}"
  require_positive_integer "WRK2_DURATION_SECONDS" "${WRK2_DURATION_SECONDS}"
  require_positive_integer "WRK2_TIMEOUT_SECONDS" "${WRK2_TIMEOUT_SECONDS}"
}

snapshot() {
  local label="$1"
  local dir="${OUT_DIR}/${label}"
  mkdir -p "${dir}"
  {
    echo "### timestamp"
    date '+%Y-%m-%d %H:%M:%S %Z'
    echo
    echo "### pods"
    k get pods -n "${NAMESPACE}" -o wide || true
    echo
    echo "### hpa"
    k get hpa "${GATEWAY_HPA}" -n "${NAMESPACE}" -o wide || true
    echo
    echo "### deploy"
    k get deploy "${GATEWAY_DEPLOYMENT}" -n "${NAMESPACE}" -o wide || true
    echo
    echo "### top pods"
    k top pod -n "${NAMESPACE}" || true
    echo
    echo "### top nodes"
    k top nodes || true
  } > "${dir}/snapshot.txt" 2>&1
}

monitor_phase() {
  local label="$1"
  local duration="$2"
  local dir="${OUT_DIR}/${label}"
  local end=$((SECONDS + duration))
  mkdir -p "${dir}"
  while [[ "${SECONDS}" -lt "${end}" ]]; do
    {
      echo "===== $(date '+%Y-%m-%d %H:%M:%S %Z') ====="
      echo "--- hpa"
      k get hpa "${GATEWAY_HPA}" -n "${NAMESPACE}" -o wide || true
      echo "--- deploy"
      k get deploy "${GATEWAY_DEPLOYMENT}" -n "${NAMESPACE}" -o wide || true
      echo "--- gateway pods"
      k get pods -n "${NAMESPACE}" -l "${GATEWAY_LABEL_SELECTOR}" -o wide || true
      echo "--- top pods"
      k top pod -n "${NAMESPACE}" || true
      echo "--- top nodes"
      k top nodes || true
      echo
    } >> "${dir}/metrics.log" 2>&1
    sleep "${LOADGEN_MONITOR_INTERVAL_SECONDS}"
  done
}

append_loadgen_sample() {
  local output_file="$1"
  {
    echo "===== $(date '+%Y-%m-%d %H:%M:%S %Z') ====="
    echo "--- os"
    uname -a || true
    echo "--- uptime"
    uptime || true
    echo "--- cpu"
    if [[ "$(uname -s)" = "Darwin" ]]; then
      top -l 1 -n 0 | head -20 || true
    else
      top -bn1 | head -20 || true
    fi
    echo "--- memory"
    if command -v free >/dev/null 2>&1; then
      free -m || true
    elif [[ "$(uname -s)" = "Darwin" ]]; then
      vm_stat || true
    else
      vmstat 1 2 || true
    fi
    echo "--- load generator processes"
    ps -Ao pid,ppid,pcpu,pmem,rss,etime,command | awk 'NR == 1 || /[w]rk/' || true
    echo
  } >> "${output_file}" 2>&1
}

monitor_load_generator() {
  local label="$1"
  local duration="$2"
  local dir="${OUT_DIR}/${label}"
  local output_file="${dir}/load-generator-monitor.log"
  local end=$((SECONDS + duration))
  mkdir -p "${dir}"
  while [[ "${SECONDS}" -lt "${end}" ]]; do
    append_loadgen_sample "${output_file}"
    sleep "${LOADGEN_MONITOR_INTERVAL_SECONDS}"
  done
}

start_monitors() {
  local label="$1"
  local duration="$2"
  monitor_phase "${label}" "${duration}" &
  MONITOR_PHASE_PID=$!
  monitor_load_generator "${label}" "${duration}" &
  LOADGEN_MONITOR_PID=$!
}

wait_monitors() {
  wait "${MONITOR_PHASE_PID}" || true
  wait "${LOADGEN_MONITOR_PID}" || true
}

write_phase_artifacts() {
  local label="$1"
  local dir="${OUT_DIR}/${label}"
  k describe hpa "${GATEWAY_HPA}" -n "${NAMESPACE}" > "${dir}/hpa-describe.txt" 2>&1 || true
  k get events -n "${NAMESPACE}" --sort-by=.lastTimestamp > "${dir}/events.txt" 2>&1 || true
  k logs -n "${NAMESPACE}" "deploy/${GATEWAY_DEPLOYMENT}" --tail=300 > "${dir}/gateway-tail.log" 2>&1 || true
}

wait_for_baseline() {
  local label="$1"
  local max_wait="${2:-${BASELINE_TIMEOUT_SECONDS}}"
  local end=$((SECONDS + max_wait))

  if [[ "${SKIP_BASELINE_WAIT}" = "1" ]]; then
    log "Skipping baseline wait before ${label}"
    return 0
  fi

  log "Waiting baseline before ${label}: ${GATEWAY_HPA} replicas=1 and deployment 1/1"
  while [[ "${SECONDS}" -lt "${end}" ]]; do
    local hpa_replicas
    local hpa_cpu
    local deploy_ready
    hpa_replicas="$(k get hpa "${GATEWAY_HPA}" -n "${NAMESPACE}" -o jsonpath='{.status.currentReplicas}' 2>/dev/null || true)"
    hpa_cpu="$(k get hpa "${GATEWAY_HPA}" -n "${NAMESPACE}" -o jsonpath='{.status.currentMetrics[0].resource.current.averageUtilization}' 2>/dev/null || true)"
    deploy_ready="$(k get deploy "${GATEWAY_DEPLOYMENT}" -n "${NAMESPACE}" -o jsonpath='{.status.readyReplicas}/{.status.replicas}' 2>/dev/null || true)"
    log "Baseline check ${label}: hpa_cpu=${hpa_cpu:-unknown}, hpa_replicas=${hpa_replicas:-unknown}, deploy_ready=${deploy_ready:-unknown}"
    if [[ "${hpa_replicas}" = "1" && "${deploy_ready}" = "1/1" ]]; then
      return 0
    fi
    sleep 20
  done

  log "Baseline wait timeout before ${label}; continuing with latest observed state"
}

run_wrk_phase() {
  local label="$1"
  local threads="$2"
  local connections="$3"
  local duration="$4"
  local dir="${OUT_DIR}/${label}"
  mkdir -p "${dir}"

  if is_dry_run; then
    log "DRY_RUN ${label}: tool=wrk threads=${threads}, connections=${connections}, duration=${duration}s"
    return 0
  fi

  wait_for_baseline "${label}"
  log "Starting ${label}: tool=wrk threads=${threads}, connections=${connections}, duration=${duration}s"
  snapshot "${label}/before"
  start_monitors "${label}" "$((duration + MONITOR_TAIL_SECONDS))"

  set +e
  "${WRK_BIN}" -t"${threads}" -c"${connections}" -d"${duration}s" --timeout 20s --latency "${TARGET_URL}" > "${dir}/wrk.txt" 2>&1
  local wrk_status=$?
  set -e

  wait_monitors
  snapshot "${label}/after"
  write_phase_artifacts "${label}"
  log "Finished ${label}: wrk_exit=${wrk_status}"
  return "${wrk_status}"
}

aggregate_wrk_outputs() {
  local label="$1"
  local client_count="$2"
  local tool="$3"
  local output_prefix="$4"
  local dir="${OUT_DIR}/${label}"
  local aggregate_file="${dir}/aggregate.txt"
  local total_rps="0"
  local client_id
  {
    echo "# ${tool} parallel aggregate"
    echo "label=${label}"
    echo "client_count=${client_count}"
    echo "duration_seconds=${WRK_PARALLEL_DURATION_SECONDS}"
    [[ "${tool}" = "wrk2" ]] && echo "target_rate_total=${CURRENT_WRK2_TARGET_RATE:-}"
    echo
    echo "client,status,requests_per_sec,output_file"
  } > "${aggregate_file}"

  for ((client_id = 1; client_id <= client_count; client_id++)); do
    local output_file="${dir}/${output_prefix}-${client_id}.txt"
    local status_file="${dir}/${output_prefix}-${client_id}.status"
    local status="unknown"
    local rps="0"
    [[ -f "${status_file}" ]] && status="$(cat "${status_file}")"
    if [[ -f "${output_file}" ]]; then
      rps="$(awk '/Requests\/sec:/ {print $2}' "${output_file}" | tail -1)"
    fi
    [[ -n "${rps}" ]] || rps="0"
    printf 'client-%s,%s,%s,%s\n' "${client_id}" "${status}" "${rps}" "${output_file}" >> "${aggregate_file}"
    total_rps="$(awk -v a="${total_rps}" -v b="${rps}" 'BEGIN { printf "%.2f", a + b }')"
  done

  {
    echo
    echo "aggregate_requests_per_sec=${total_rps}"
  } >> "${aggregate_file}"
  log "Aggregate ${label}: requests_per_sec=${total_rps}"
}

run_wrk_parallel_phase() {
  local label="$1"
  local client_count="$2"
  local dir="${OUT_DIR}/${label}"
  local client_id
  local overall_status=0
  local pids=()
  mkdir -p "${dir}"

  if is_dry_run; then
    log "DRY_RUN ${label}: tool=wrk-parallel clients=${client_count}, threads_per_client=${WRK_PARALLEL_THREADS}, connections_per_client=${WRK_PARALLEL_CONNECTIONS}, duration=${WRK_PARALLEL_DURATION_SECONDS}s"
    return 0
  fi

  wait_for_baseline "${label}"
  log "Starting ${label}: tool=wrk-parallel clients=${client_count}, threads_per_client=${WRK_PARALLEL_THREADS}, connections_per_client=${WRK_PARALLEL_CONNECTIONS}, duration=${WRK_PARALLEL_DURATION_SECONDS}s"
  snapshot "${label}/before"
  start_monitors "${label}" "$((WRK_PARALLEL_DURATION_SECONDS + MONITOR_TAIL_SECONDS))"

  set +e
  for ((client_id = 1; client_id <= client_count; client_id++)); do
    (
      "${WRK_BIN}" -t"${WRK_PARALLEL_THREADS}" -c"${WRK_PARALLEL_CONNECTIONS}" -d"${WRK_PARALLEL_DURATION_SECONDS}s" --timeout 20s --latency "${TARGET_URL}" > "${dir}/wrk-client-${client_id}.txt" 2>&1
      client_status="$?"
      echo "${client_status}" > "${dir}/wrk-client-${client_id}.status"
      exit "${client_status}"
    ) &
    pids+=("$!")
  done

  local pid
  for pid in "${pids[@]}"; do
    wait "${pid}"
    local wait_status=$?
    if [[ "${wait_status}" -ne 0 ]]; then
      overall_status="${wait_status}"
    fi
  done
  set -e

  wait_monitors
  aggregate_wrk_outputs "${label}" "${client_count}" "wrk" "wrk-client"
  snapshot "${label}/after"
  write_phase_artifacts "${label}"
  log "Finished ${label}: wrk_parallel_exit=${overall_status}"
  return "${overall_status}"
}

run_wrk2_phase() {
  local label="$1"
  local rate="$2"
  local dir="${OUT_DIR}/${label}"
  mkdir -p "${dir}"

  if is_dry_run; then
    log "DRY_RUN ${label}: tool=wrk2-rate rate=${rate}, threads=${WRK2_THREADS}, connections=${WRK2_CONNECTIONS}, duration=${WRK2_DURATION_SECONDS}s, timeout=${WRK2_TIMEOUT_SECONDS}s"
    cat > "${dir}/plan.txt" <<PLAN
label=${label}
tool=wrk2-rate
rate=${rate}
threads=${WRK2_THREADS}
connections=${WRK2_CONNECTIONS}
duration_seconds=${WRK2_DURATION_SECONDS}
timeout_seconds=${WRK2_TIMEOUT_SECONDS}
target_url=${TARGET_URL}
PLAN
    return 0
  fi

  wait_for_baseline "${label}"
  log "Starting ${label}: tool=wrk2 rate=${rate}, threads=${WRK2_THREADS}, connections=${WRK2_CONNECTIONS}, duration=${WRK2_DURATION_SECONDS}s, timeout=${WRK2_TIMEOUT_SECONDS}s"
  {
    echo "tool=wrk2"
    echo "target_rate=${rate}"
    echo "threads=${WRK2_THREADS}"
    echo "connections=${WRK2_CONNECTIONS}"
    echo "duration_seconds=${WRK2_DURATION_SECONDS}"
    echo "timeout_seconds=${WRK2_TIMEOUT_SECONDS}"
  } > "${dir}/phase-config.env"
  snapshot "${label}/before"
  start_monitors "${label}" "$((WRK2_DURATION_SECONDS + MONITOR_TAIL_SECONDS))"

  set +e
  "${WRK2_BIN}" -t"${WRK2_THREADS}" -c"${WRK2_CONNECTIONS}" -d"${WRK2_DURATION_SECONDS}s" -R"${rate}" --timeout "${WRK2_TIMEOUT_SECONDS}s" --latency "${TARGET_URL}" > "${dir}/wrk2.txt" 2>&1
  local wrk2_status=$?
  set -e

  wait_monitors
  snapshot "${label}/after"
  write_phase_artifacts "${label}"
  log "Finished ${label}: wrk2_exit=${wrk2_status}"
  return "${wrk2_status}"
}

run_wrk2_parallel_phase() {
  local label="$1"
  local client_count="$2"
  local target_rate="$3"
  local rate_per_client=$((target_rate / client_count))
  local dir="${OUT_DIR}/${label}"
  local client_id
  local overall_status=0
  local pids=()
  mkdir -p "${dir}"

  if [[ "${rate_per_client}" -lt 1 ]]; then
    fail "target_rate=${target_rate} is too low for client_count=${client_count}"
  fi

  if is_dry_run; then
    log "DRY_RUN ${label}: tool=wrk2-parallel clients=${client_count}, target_rps=${target_rate}, rate_per_client=${rate_per_client}, threads_per_client=${WRK2_THREADS}, connections_per_client=${WRK2_CONNECTIONS}, duration=${WRK2_DURATION_SECONDS}s"
    return 0
  fi

  wait_for_baseline "${label}"
  log "Starting ${label}: tool=wrk2-parallel clients=${client_count}, target_rps=${target_rate}, rate_per_client=${rate_per_client}, threads_per_client=${WRK2_THREADS}, connections_per_client=${WRK2_CONNECTIONS}, duration=${WRK2_DURATION_SECONDS}s"
  snapshot "${label}/before"
  start_monitors "${label}" "$((WRK2_DURATION_SECONDS + MONITOR_TAIL_SECONDS))"

  set +e
  for ((client_id = 1; client_id <= client_count; client_id++)); do
    (
      "${WRK2_BIN}" -t"${WRK2_THREADS}" -c"${WRK2_CONNECTIONS}" -d"${WRK2_DURATION_SECONDS}s" -R"${rate_per_client}" --timeout "${WRK2_TIMEOUT_SECONDS}s" --latency "${TARGET_URL}" > "${dir}/wrk2-client-${client_id}.txt" 2>&1
      client_status="$?"
      echo "${client_status}" > "${dir}/wrk2-client-${client_id}.status"
      exit "${client_status}"
    ) &
    pids+=("$!")
  done

  local pid
  for pid in "${pids[@]}"; do
    wait "${pid}"
    local wait_status=$?
    if [[ "${wait_status}" -ne 0 ]]; then
      overall_status="${wait_status}"
    fi
  done
  set -e

  wait_monitors
  CURRENT_WRK2_TARGET_RATE="${target_rate}" aggregate_wrk_outputs "${label}" "${client_count}" "wrk2" "wrk2-client"
  snapshot "${label}/after"
  write_phase_artifacts "${label}"
  log "Finished ${label}: wrk2_parallel_exit=${overall_status}"
  return "${overall_status}"
}

cooldown() {
  local label="$1"
  if is_dry_run; then
    log "DRY_RUN cooldown ${label}: ${COOLDOWN_SECONDS}s"
    return 0
  fi

  log "Cooldown ${label}: ${COOLDOWN_SECONDS}s"
  monitor_phase "cooldown-${label}" "${COOLDOWN_SECONDS}"
  snapshot "cooldown-${label}/after"
}

run_wrk_suite() {
  if ! is_dry_run; then
    require_command "wrk" "${WRK_BIN}"
    "${WRK_BIN}" -v > "${OUT_DIR}/wrk-version.txt" 2>&1 || true
  fi

  run_wrk_phase "wrk-load-c8-approx-500" 2 8 300
  cooldown "after-wrk-c8"
  run_wrk_phase "wrk-load-c16-approx-1000" 4 16 300
  cooldown "after-wrk-c16"
  run_wrk_phase "wrk-load-c32-approx-1500" 4 32 300
  cooldown "after-wrk-c32"
  run_wrk_phase "wrk-load-c64-max-throughput" 8 64 300
  cooldown "after-wrk-c64"
}

run_wrk_parallel_suite() {
  validate_wrk_parallel_config
  if ! is_dry_run; then
    require_command "wrk" "${WRK_BIN}"
    "${WRK_BIN}" -v > "${OUT_DIR}/wrk-version.txt" 2>&1 || true
  fi

  run_wrk_phase "wrk-single-c64-baseline" 8 64 "${WRK_PARALLEL_DURATION_SECONDS}"
  cooldown "after-wrk-single-c64-baseline"

  local client_count
  for client_count in ${WRK_PARALLEL_CLIENTS}; do
    run_wrk_parallel_phase "wrk-parallel-${client_count}clients" "${client_count}"
    cooldown "after-wrk-parallel-${client_count}clients"
  done
}

run_wrk2_suite() {
  validate_wrk2_config
  if ! is_dry_run; then
    require_command "wrk2" "${WRK2_BIN}"
    "${WRK2_BIN}" -v > "${OUT_DIR}/wrk2-version.txt" 2>&1 || true
  fi

  local rate
  for rate in ${WRK2_RATES}; do
    run_wrk2_phase "wrk2-rate-${rate}rps" "${rate}"
    cooldown "after-wrk2-${rate}rps"
  done
}

run_wrk2_parallel_suite() {
  validate_wrk2_config
  if ! is_dry_run; then
    require_command "wrk2" "${WRK2_BIN}"
    "${WRK2_BIN}" -v > "${OUT_DIR}/wrk2-version.txt" 2>&1 || true
  fi

  local rate
  local client_count
  for rate in ${WRK2_RATES}; do
    for client_count in ${WRK2_PARALLEL_CLIENTS}; do
      run_wrk2_parallel_phase "wrk2-parallel-${client_count}clients-${rate}rps" "${client_count}" "${rate}"
      cooldown "after-wrk2-parallel-${client_count}clients-${rate}rps"
    done
  done
}

main() {
  validate_common_config

  if ! is_dry_run; then
    require_command "kubectl" "${KUBECTL_BIN}"
  fi

  log "Output directory: ${OUT_DIR}"
  log "Target URL: ${TARGET_URL}"
  log "Namespace: ${NAMESPACE}"
  log "HPA: ${GATEWAY_HPA}"
  log "Deployment: ${GATEWAY_DEPLOYMENT}"
  log "Mode: ${MODE}"

  if is_dry_run; then
    log "DRY_RUN enabled: skipping Kubernetes snapshots and live load generation"
  else
    snapshot "baseline"
  fi

  case "${MODE}" in
    wrk)
      run_wrk_suite
      ;;
    wrk-parallel)
      run_wrk_parallel_suite
      ;;
    wrk2|wrk2-rate)
      run_wrk2_suite
      ;;
    wrk2-parallel)
      run_wrk2_parallel_suite
      ;;
    wrk-all)
      run_wrk_suite
      run_wrk_parallel_suite
      ;;
  esac

  if ! is_dry_run; then
    snapshot "final"
  fi
  log "Completed all phases"
}

main "$@"
