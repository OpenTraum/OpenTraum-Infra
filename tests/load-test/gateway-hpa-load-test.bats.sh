#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT="${SCRIPT:-scripts/load-test/gateway-hpa-load-test.sh}"
K8S_SCRIPT="scripts/load-test/gateway-hpa-k8s-wrk2-runner.sh"
TMP_ROOT="${TMPDIR:-/tmp}/gateway-hpa-load-test-tests.$$"
BIN_DIR="${TMP_ROOT}/bin"
OUT_DIR="${TMP_ROOT}/out"
mkdir -p "${BIN_DIR}" "${OUT_DIR}"
trap 'rm -rf "${TMP_ROOT}"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

cat > "${BIN_DIR}/kubectl" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" = "get" && "${2:-}" = "pods" ]]; then
  exit 0
fi
echo "stub kubectl $*"
STUB
chmod +x "${BIN_DIR}/kubectl"
PATH="${BIN_DIR}:${PATH}"

bash -n "${SCRIPT}"
bash -n "${K8S_SCRIPT}"

set +e
MODE=wrk-all \
OUT_DIR="${OUT_DIR}/legacy-mode" \
"${SCRIPT}" > "${OUT_DIR}/legacy-mode.stdout" 2> "${OUT_DIR}/legacy-mode.stderr"
status=$?
set -e
[[ "${status}" -eq 2 ]] || fail "legacy MODE should exit 2, got ${status}"
grep -q 'removed local-generator option' "${OUT_DIR}/legacy-mode.stderr" || fail "legacy MODE error was not specific"

set +e
WRK2_BIN=/no/such/wrk2 \
OUT_DIR="${OUT_DIR}/local-bin" \
"${SCRIPT}" > "${OUT_DIR}/local-bin.stdout" 2> "${OUT_DIR}/local-bin.stderr"
status=$?
set -e
[[ "${status}" -eq 2 ]] || fail "WRK2_BIN should exit 2, got ${status}"
grep -q 'load generation must run inside EKS wrk2 Job pods' "${OUT_DIR}/local-bin.stderr" || fail "WRK2_BIN guardrail error was not specific"

DRY_RUN=1 \
OUT_DIR="${OUT_DIR}/dry-run" \
TOTAL_RATE=10000 \
PODS=17 \
DURATION_SECONDS=60 \
AVOID_GATEWAY_NODES=0 \
"${SCRIPT}" > "${OUT_DIR}/dry-run.stdout" 2> "${OUT_DIR}/dry-run.stderr"

manifest_count=$(find "${OUT_DIR}/dry-run" -name 'gateway-wrk2-*.yaml' | wc -l | tr -d ' ')
[[ "${manifest_count}" -eq 1 ]] || fail "expected one Kubernetes Job manifest, got ${manifest_count}"
grep -R -q '^kind: Job$' "${OUT_DIR}/dry-run" || fail "dry-run did not write a Kubernetes Job manifest"
grep -R -q 'parallelism: 17' "${OUT_DIR}/dry-run" || fail "manifest missing requested pod parallelism"
grep -q '^total_rate=10000$' "${OUT_DIR}/dry-run/run-config.env" || fail "run-config missing total rate"
grep -q '^pods=17$' "${OUT_DIR}/dry-run/run-config.env" || fail "run-config missing pod count"

if grep -R -q '"${WRK_BIN}"\|"${WRK2_BIN}"' "${SCRIPT}"; then
  fail "compatibility wrapper still invokes local generator binaries"
fi

echo "PASS: Gateway HPA load test entrypoint only permits EKS wrk2 Job dry-runs and rejects local generators"
