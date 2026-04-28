#!/usr/bin/env bash
#
# Grafana Tempo 배포 스크립트
#
# 순서:
#   1) ConfigMap (tempo.yaml)
#   2) Service (3200 / 9095 / 4317 / 4318)
#   3) StatefulSet (monolithic, PVC 10Gi)
#
# idempotent: apply만 수행. 파괴적 명령 없음.
#
# 전제:
#   - monitoring 네임스페이스 존재
#   - ebs-sc StorageClass 존재
#   - grafana/tempo:2.6.0 pull 가능 (Docker Hub)

set -euo pipefail

NS="monitoring"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() { printf '\n\033[1;36m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }

log "네임스페이스 '${NS}' 확인"
kubectl get ns "${NS}" >/dev/null

log "Tempo ConfigMap apply"
kubectl apply -f "${SCRIPT_DIR}/configmap.yaml"

log "Tempo Service apply"
kubectl apply -f "${SCRIPT_DIR}/service.yaml"

log "Tempo StatefulSet apply"
kubectl apply -f "${SCRIPT_DIR}/statefulset.yaml"

log "Tempo StatefulSet Ready 대기"
kubectl -n "${NS}" rollout status statefulset/tempo --timeout=300s

log "완료. 상태 확인:"
echo "  kubectl -n ${NS} get sts,svc,cm -l app.kubernetes.io/name=tempo"
echo "  kubectl -n ${NS} logs sts/tempo -f"
