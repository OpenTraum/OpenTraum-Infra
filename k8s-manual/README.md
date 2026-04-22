# OpenTraum Infra — 수동 배포 매니페스트

ArgoCD(GitOps) 없이 `kubectl apply` 로 직접 적용하는 K8s 매니페스트 모음.
자동 배포(서비스별 이미지 태그 CI/CD)는 각 서비스 레포(`OpenTraum-*-service/k8s/`)
안에서 이뤄지므로, 여기는 **수동 배포 + 공용 인프라** 전용이다.

## 레이아웃

```
k8s-manual/
├── namespace.yml            opentraum / mariadb / kafka / redis ns
├── priorityclass.yml        opentraum-{high,medium,low}
├── configmap.yml            공용 ConfigMap (Gateway route + DB/Kafka/Redis 주소)
├── ingress.yml              nginx Ingress
├── pdb.yml                  Gateway / service DB PDB (Strimzi Kafka는 Operator 관리)
│
├── gateway/                 ← app 계층 (수동 배포 완전판)
├── auth-service/            (deployment.yml + service.yml + secret.yml)
├── event-service/
├── payment-service/
├── reservation-service/
├── user-service/            (deployment.yml + service.yml + secret.yml)
├── web/                     (프론트엔드, Nginx proxy → gateway:8080)
│
├── mariadb/                 Helm custom-values (opentraum-mariadb, mariadb ns)
├── mariadb-cdc/             reservation-db / payment-db / event-db (kafka ns, CDC 전용)
│
├── kafka-connect/           Strimzi KafkaConnect + Connectors + Topics
├── redis/                   opentraum-redis (priorityClass: high)
│
├── tempo/                   Grafana Tempo (monitoring ns)
├── alloy/                   Grafana Alloy config/service patch
└── grafana/                 Grafana Tempo datasource
```

## Kafka — Strimzi `my-kafka-cluster` 사용

- 과거 raw StatefulSet(`opentraum-kafka`, apache/kafka:3.7.0) 은 폐기
- 현재 기준: Strimzi Operator 가 관리하는 **`my-kafka-cluster`** (Kafka 4.1.0, KafkaNodePool)
- Bootstrap 주소: `my-kafka-cluster-kafka-bootstrap.kafka:9092`
- KafkaConnect / KafkaConnector / KafkaTopic CR 은 `strimzi.io/cluster: my-kafka-cluster` 로 연결

## PostgreSQL 제거, MariaDB 로 통일

- 과거 `opentraum-postgres` (opentraum ns) StatefulSet 은 삭제 — 이미 실존하지 않음
- 과거 `postgres-1-postgresql.kafka` (auth/user 용) 도 더 이상 사용하지 않음
- 현재 DB 배치:
  | DB | ns | 용도 | 쓰는 서비스 |
  |---|---|---|---|
  | `opentraum-mariadb` (Bitnami Helm) | `mariadb` | 공용. auth / user DB | auth-service, user-service |
  | `reservation-db` | `kafka` | CDC 전용 | reservation-service + Debezium |
  | `payment-db` | `kafka` | CDC 전용 | payment-service + Debezium |
  | `event-db` | `kafka` | CDC 전용 | event-service + Debezium |

## 자동 배포와의 차이

서비스 레포의 `k8s/deployment.yml` 은 CI 가 이미지 SHA 를 주입해 배포한다.
여기 `k8s-manual/*/deployment.yml` 은:

| 항목 | 수동 배포 (이 레포) |
|---|---|
| 이미지 태그 | `:latest` (수동 롤아웃 시 Harbor 최신) |
| revisionHistoryLimit | 2 |
| terminationGracePeriodSeconds | 40s (event-service 는 30s) — Spring `lifecycle.timeout-per-shutdown-phase` + 버퍼 |
| JAVA_OPTS | `-XX:MaxRAMPercentage=75` 포함 |
| Lazy Init | `SPRING_MAIN_LAZY_INITIALIZATION=true` |
| startupProbe | failureThreshold: 20 |
| priorityClassName | high(gateway/payment/reservation/redis) / medium(auth/user/event) / low(web) |
| wait-for-payment initContainer | reservation-service 만 |
| Affinity | 3대장(reservation/payment/event) podAffinity + 같은 app podAntiAffinity |
| imagePullPolicy | Always (Harbor 상시 가용 가정) |
| Secret | auth/user DB 자격증명을 `auth-db-secret`, `user-db-secret` 으로 분리 |

## 배포 순서 (처음 Bootstrap)

```bash
# 1. namespace / 보안
kubectl apply -f namespace.yml
kubectl apply -f priorityclass.yml

# 2. 공용
kubectl apply -f configmap.yml

# 3. DB / Middleware
bash mariadb/install.sh              # opentraum-mariadb (mariadb ns, Helm)
kubectl apply -f mariadb-cdc/        # reservation/payment/event-db (kafka ns)
kubectl apply -f redis/

# Kafka: Strimzi Operator + Kafka/KafkaNodePool CR 이 이미 설치되어 있어야 함
# (kafka-operator 설치는 본 레포 범위 밖)

# 4. CDC (Strimzi KafkaConnect + Connector + Topic)
bash kafka-connect/deploy.sh

# 5. 관측
bash tempo/deploy.sh
kubectl apply -f alloy/
kubectl apply -f grafana/

# 6. 앱 (Secret 먼저, 그 다음 Deployment)
kubectl apply -f auth-service/        # secret.yml 포함
kubectl apply -f user-service/        # secret.yml 포함
kubectl apply -f event-service/
kubectl apply -f payment-service/
kubectl apply -f reservation-service/
kubectl apply -f gateway/
kubectl apply -f web/

# 7. 진입 / 가용성
kubectl apply -f ingress.yml
kubectl apply -f pdb.yml
```

## 이미지 재배포 (수동 롤아웃)

```bash
for d in gateway auth-service user-service event-service payment-service reservation-service web; do
  kubectl -n opentraum rollout restart deployment/$d
done
```

모든 앱이 `imagePullPolicy: Always` 이므로 rollout restart 만으로 Harbor latest 재획득.

## 주의

- ArgoCD Application CR 은 제거. 자동 배포는 서비스 레포 CI/CD (`.github/workflows/cicd.yml`) 담당.
- 서비스 레포의 `k8s/deployment.yml` 과 여기 `k8s-manual/*/deployment.yml` 은 **의도적으로 다르다** (태그/옵션/Affinity 등). 동기화 대상이 아님.
- Secret (`auth-db-secret`, `user-db-secret`, `*-db-secret`(CDC), `opentraum-secrets`, `harbor-secret`, `harbor-registry-secret`) — 현재는 편의상 평문 stringData 로 Git 에 있다. 운영 이관 시 SealedSecret/SOPS/ExternalSecrets 로 변환 권장.
