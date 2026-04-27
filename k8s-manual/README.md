# OpenTraum Infra — 공용 인프라 매니페스트

ArgoCD(GitOps) 가 직접 관리하지 않는 클러스터 공용 인프라 매니페스트 모음.
앱 매니페스트는 각 서비스 레포(`OpenTraum-*-service/k8s/`) 가 SoT 이며 ArgoCD 자동 배포 대상이다.

## 레이아웃

```
k8s-manual/
├── namespace.yml            opentraum / mariadb / kafka / redis ns
├── priorityclass.yml        opentraum-{high,medium,low}
├── configmap.yml            공용 ConfigMap (Gateway route + DB/Kafka/Redis 주소)
├── ingress.yml              nginx Ingress
├── pdb.yml                  Gateway / service DB PDB (Strimzi Kafka는 Operator 관리)
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

# 6. 앱: 각 서비스 레포 `k8s/` 가 SoT. ArgoCD Application 이 자동 sync.
#    DB Secret (auth-db-secret, user-db-secret, event-db-secret, reservation-db-secret, payment-db-secret) 은
#    별도 클러스터 배포 (SealedSecret / SOPS / ExternalSecrets 권장).

# 7. 진입 / 가용성
kubectl apply -f ingress.yml
kubectl apply -f pdb.yml
```

## 주의

- 앱 매니페스트(`deployment.yml`, `service.yml`, `secret.yml`) 는 각 서비스 레포 `k8s/` 가 SoT.
- DB Secret 은 평문 stringData 를 Git 에 두지 않는다. 운영은 SealedSecret/SOPS/ExternalSecrets 로 관리.
