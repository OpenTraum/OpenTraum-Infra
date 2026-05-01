#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT="${SCRIPT:-scripts/load-test/gateway-hpa-load-test.sh}"
TMP_ROOT="${TMPDIR:-/tmp}/gateway-hpa-load-test-tests.$$"
BIN_DIR="${TMP_ROOT}/bin"
OUT_DIR="${TMP_ROOT}/out"
mkdir -p "${BIN_DIR}" "${OUT_DIR}"
trap 'rm -rf "${TMP_ROOT}"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

write_stub() {
  local name="$1"
  cat > "${BIN_DIR}/${name}" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" = "-v" ]]; then
  echo "stub version"
fi
exit 0
STUB
  chmod +x "${BIN_DIR}/${name}"
}

write_stub kubectl
write_stub wrk
write_stub wrk2

PATH="${BIN_DIR}:${PATH}"

bash -n "${SCRIPT}"
bash -n scripts/load-test/gateway-hpa-k8s-wrk2-runner.sh

set +e
TARGET_URL="https://<TEAM_DOMAIN>/api/__loadtest__" \
MODE=wrk2-rate \
DRY_RUN=1 \
OUT_DIR="${OUT_DIR}/dry-run" \
WRK2_BIN=/no/such/wrk2 \
WRK2_RATES="2000 5000" \
WRK2_DURATION_SECONDS=1 \
COOLDOWN_SECONDS=1 \
"${SCRIPT}" > "${OUT_DIR}/dry-run.stdout" 2> "${OUT_DIR}/dry-run.stderr"
status=$?
set -e
[[ "${status}" -eq 0 ]] || fail "wrk2 dry run exited ${status}"
[[ -f "${OUT_DIR}/dry-run/wrk2-rate-2000rps/plan.txt" ]] || fail "missing 2000rps dry-run plan"
[[ -f "${OUT_DIR}/dry-run/wrk2-rate-5000rps/plan.txt" ]] || fail "missing 5000rps dry-run plan"
grep -q '^rate=2000$' "${OUT_DIR}/dry-run/wrk2-rate-2000rps/plan.txt" || fail "2000rps plan missing rate"
grep -q '^tool=wrk2-rate$' "${OUT_DIR}/dry-run/wrk2-rate-5000rps/plan.txt" || fail "5000rps plan missing tool"

set +e
TARGET_URL="https://<TEAM_DOMAIN>/api/__loadtest__" \
MODE=wrk2-rate \
DRY_RUN=1 \
OUT_DIR="${OUT_DIR}/bad-rate" \
WRK2_BIN=/no/such/wrk2 \
WRK2_RATES="2000 not-a-number" \
"${SCRIPT}" > "${OUT_DIR}/bad-rate.stdout" 2> "${OUT_DIR}/bad-rate.stderr"
status=$?
set -e
[[ "${status}" -eq 2 ]] || fail "invalid WRK2_RATES should exit 2, got ${status}"
grep -q 'WRK2_RATES item' "${OUT_DIR}/bad-rate.stderr" || fail "invalid WRK2_RATES error was not specific"

set +e
TARGET_URL="https://<TEAM_DOMAIN>/api/__loadtest__" \
MODE=invalid \
DRY_RUN=1 \
OUT_DIR="${OUT_DIR}/bad-mode" \
"${SCRIPT}" > "${OUT_DIR}/bad-mode.stdout" 2> "${OUT_DIR}/bad-mode.stderr"
status=$?
set -e
[[ "${status}" -eq 2 ]] || fail "invalid MODE should exit 2, got ${status}"
grep -q 'wrk2-rate' "${OUT_DIR}/bad-mode.stderr" || fail "MODE error does not mention wrk2-rate"

echo "PASS: gateway-hpa-load-test script syntax, wrk2 dry-run, and validation checks"
