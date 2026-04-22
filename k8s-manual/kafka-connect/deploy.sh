#!/usr/bin/env bash
#
# OpenTraum Debezium CDC 배포 스크립트
#
# 순서:
#   1) 3개 MariaDB StatefulSet (reservation-db, payment-db, event-db)
#   2) Debezium KafkaConnect CR (Strimzi가 Connect 클러스터 기동 + JAR 빌드)
#   3) KafkaTopic CR (비즈니스 토픽 + DLQ + schema-history)
#   4) 3개 KafkaConnector CR (Connect Pod Ready 대기 후)
#
# idempotent: apply만 수행. 파괴적 명령(delete/force/--grace-period=0) 없음.
#
# 전제:
#   - kafka 네임스페이스 존재
#   - opentraum-kafka StatefulSet 이미 Ready
#   - kafka ns에 Strimzi Cluster Operator 이미 설치됨 (KafkaConnect/KafkaConnector/KafkaTopic CRD 처리)
#   - ebs-sc StorageClass 존재

set -euo pipefail

NS="kafka"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MDB_DIR="$(cd "${SCRIPT_DIR}/../mariadb-cdc" && pwd)"
CONNECT_DIR="${SCRIPT_DIR}"

log() { printf '\n\033[1;36m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }

# ---------------------------------------------------------------------------
# 0) 네임스페이스 확인 (apply 안함, 없으면 즉시 실패 — 기존 리소스 보호)
# ---------------------------------------------------------------------------
log "네임스페이스 '${NS}' 확인"
kubectl get ns "${NS}" >/dev/null

# ---------------------------------------------------------------------------
# 1) MariaDB 3개 배포
# ---------------------------------------------------------------------------
log "MariaDB 3개 배포 (reservation-db / payment-db / event-db)"
kubectl apply -f "${MDB_DIR}/reservation-db.yaml"
kubectl apply -f "${MDB_DIR}/payment-db.yaml"
kubectl apply -f "${MDB_DIR}/event-db.yaml"

log "MariaDB StatefulSet Ready 대기"
for sts in reservation-db payment-db event-db; do
  kubectl -n "${NS}" rollout status statefulset/"${sts}" --timeout=300s
done

# ---------------------------------------------------------------------------
# 2) Debezium KafkaConnect CR
# ---------------------------------------------------------------------------
log "KafkaConnect CR 적용 (Strimzi가 Connect + Debezium 이미지 빌드/배포)"
kubectl apply -f "${CONNECT_DIR}/kafka-connect.yaml"

# ---------------------------------------------------------------------------
# 3) KafkaTopic CR
# ---------------------------------------------------------------------------
log "KafkaTopic CR 적용 (비즈니스 3 + DLQ + schema-history 3)"
kubectl apply -f "${CONNECT_DIR}/topics.yaml"

# ---------------------------------------------------------------------------
# 4) Connect Pod Ready 대기 후 Connector CR apply
# ---------------------------------------------------------------------------
log "KafkaConnect 클러스터 Ready 대기 (Strimzi가 build/deploy 끝낼 때까지)"
# Strimzi KafkaConnect는 Ready condition을 status에 채움
kubectl -n "${NS}" wait kafkaconnect/opentraum-debezium-connect \
  --for=condition=Ready \
  --timeout=900s

log "Connect Pod Ready 대기"
kubectl -n "${NS}" rollout status deployment/opentraum-debezium-connect-connect \
  --timeout=600s || true

log "KafkaConnector CR 적용 (reservation / payment / event)"
kubectl apply -f "${CONNECT_DIR}/connector-reservation.yaml"
kubectl apply -f "${CONNECT_DIR}/connector-payment.yaml"
kubectl apply -f "${CONNECT_DIR}/connector-event.yaml"

log "완료. 상태 확인:"
echo "  kubectl -n ${NS} get kafkaconnect,kafkaconnector,kafkatopic"
echo "  kubectl -n ${NS} get sts,svc -l app.kubernetes.io/component=database"
