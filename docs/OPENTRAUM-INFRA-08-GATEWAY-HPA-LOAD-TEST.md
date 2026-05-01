# OpenTraum 인프라 매뉴얼 - Gateway HPA 부하 테스트

> 작성일: 2026-05-01
> 시리즈 인덱스: [00 INDEX](OPENTRAUM-INFRA-00-INDEX.md)
> 관련: [03 WORKLOAD](OPENTRAUM-INFRA-03-WORKLOAD.md) · [06 OPERATIONS](OPENTRAUM-INFRA-06-OPERATIONS.md)

## 목차

- [1. 개요](#1-개요)
- [2. 테스트 범위](#2-테스트-범위)
- [3. 실행 스크립트](#3-실행-스크립트)
- [4. 기준 구성](#4-기준-구성)
- [5. 결과 요약](#5-결과-요약)
- [6. 상세 결과](#6-상세-결과)
- [7. 해석](#7-해석)
- [8. 운영 권장안](#8-운영-권장안)
- [9. 다음 실험 원칙](#9-다음-실험-원칙)
- [10. 보안 처리](#10-보안-처리)

---

## 1. 개요

Gateway는 외부 트래픽이 처음 닿는 진입점입니다. 이 테스트의 목표는 서비스 노드 수를 고정한 상태에서 Gateway HPA와 부하 발생기 배치가 어느 지점에서 병목을 만드는지 재현 가능하게 남기는 것입니다.

중요한 전제는 "부하를 받는 서비스 용량"과 "부하를 만드는 generator 용량"을 분리하는 것입니다. 현재 후속 실험의 capacity budget은 전체 11개 노드(서비스 7 + GPU 3 + wrk 1)로 고정하며, 서비스 nodegroup 증설은 10,000 RPS 달성을 위한 해결책으로 사용하지 않습니다. 한 실험 안에서 여러 값을 동시에 바꾸면 어떤 변경이 효과를 냈는지 알 수 없으므로, 매 phase마다 고정값과 변경점을 명시합니다.

부하 발생기는 별도 namespace와 wrk 전용 노드에서 실행합니다. 이 분리는 local PC 병목을 제거하고, 부하 발생 Pod가 Gateway Pod와 같은 node 자원을 경쟁하지 않게 하기 위한 조건입니다. 이후 Gateway/HPA 튜닝은 서비스 노드 7개 고정 조건을 유지한 별도 phase로 기록합니다.

도구별 역할은 다음처럼 분리합니다.

| 도구 | 현재 문서에서의 역할 |
|---|---|
| `hey` | 1차 과거 이력 보존용. 신규 실험에는 사용하지 않음 |
| `wrk` | connection/thread 조건별 처리량 확인용 |
| `wrk2` | 목표 RPS를 고정하는 rate-controlled 검증용 |
| Kubernetes `wrk2` Job | 클러스터 내부 load-generator Pod를 여러 개 띄워 client 병목을 제거하고 10,000 RPS를 재현하는 용도 |

모든 신규 실험은 Gateway 전용 경로만 대상으로 합니다. business API는 event-service, DB, Redis 등 downstream 병목이 섞일 수 있으므로 Gateway HPA 단독 실험에서 제외합니다.

---

## 2. 테스트 범위

### 2.1 제외한 business endpoint

초기 smoke에서 `GET /api/v1/concerts`를 확인했지만, 100 RPS 수준에서도 timeout이 섞였습니다. 이 경로는 Gateway뿐 아니라 event-service와 DB 상태가 함께 반영되므로 Gateway HPA 판단 근거로 사용하지 않습니다.

### 2.2 Gateway-only endpoint

Gateway HPA 자극용 경로는 다음 조건을 만족해야 합니다.

- Ingress 또는 Gateway Service를 통해 Gateway를 통과
- downstream 서비스 호출을 최소화
- route miss로 404가 나면 성공 처리량이 아니라 Gateway CPU/HPA 반응 baseline으로만 해석

이에 따라 `GET /api/__loadtest__` 경로를 사용합니다. 현재 배포에서 이 경로가 404를 반환하면 해당 결과는 성공 처리량이 아니라 route-miss/HPA 반응 baseline으로만 기록합니다. 2xx synthetic endpoint 또는 별도 microservice 분리는 현재 Infra PR 범위 밖의 후속 TODO 후보로 둡니다.

### 2.3 baseline과 tuning 실험 구분

| 범주 | 서비스 노드/HPA | 부하 발생기 | 목적 |
|---|---|---|---|
| baseline | 기존 Gateway HPA와 기존 서비스 노드 범위 유지 | local 또는 별도 loadgen node | 현재 출발점 확인 |
| loadgen 분리 | 기존 Gateway HPA와 기존 서비스 노드 범위 유지 | 별도 namespace/node pool의 wrk2 Pod 확장 | client 병목 제거 |
| target tuning | 서비스 노드 7개 고정 조건에서 Gateway HPA, replica, resource, probe를 단계적으로 변경 | 별도 namespace/wrk 전용 노드의 wrk2 Pod | 10,000 RPS 병목 분리 |

따라서 과거의 broad tuning 결과는 참고 이력으로만 두고, 현재 판정은 "서비스 노드 고정 기준 구성"과 "고정 조건 내 튜닝"을 분리해 기록합니다.

---

## 3. 실행 스크립트

### 3.1 local wrk/wrk2 runner

실행 스크립트는 [../scripts/load-test/gateway-hpa-load-test.sh](../scripts/load-test/gateway-hpa-load-test.sh)에 둡니다. 결과는 기본적으로 `/tmp/opentraum-gateway-hpa-loadtest-<timestamp>` 아래에 저장합니다.

초기 `hey` 결과는 이력으로만 보존하고, 스크립트의 신규 실행 모드에서는 사용하지 않습니다.

```bash
TARGET_URL="https://<TEAM_DOMAIN>/api/__loadtest__" \
MODE=wrk-all \
scripts/load-test/gateway-hpa-load-test.sh
```

주요 모드는 다음과 같습니다.

| MODE | 설명 |
|---|---|
| `wrk` | 단일 `wrk` phase 실행 |
| `wrk-parallel` | 같은 host에서 여러 `wrk` process를 병렬 실행 |
| `wrk2-rate` | `wrk2 -R`로 목표 RPS를 고정해 순차 실행 |
| `wrk2-parallel` | 같은 host에서 여러 `wrk2` process를 병렬 실행 |
| `wrk-all` | local `wrk` 기본 phase 실행 |

### 3.2 Kubernetes wrk2 Job runner

클러스터 내부에서 `wrk2` Pod를 여러 개 띄우는 스크립트는 [../scripts/load-test/gateway-hpa-k8s-wrk2-runner.sh](../scripts/load-test/gateway-hpa-k8s-wrk2-runner.sh)에 둡니다. 기본 target은 Gateway 내부 Service입니다.

```bash
TOTAL_RATE=10000 \
PODS=17 \
DRY_RUN=1 \
scripts/load-test/gateway-hpa-k8s-wrk2-runner.sh
```

기본 dry-run/실행 예시는 다음과 같습니다.

```bash
KUBECONFIG="<KUBECONFIG_PATH>" \
DRY_RUN=1 \
TOTAL_RATE=2000 \
PODS=17 \
THREADS=2 \
CONNECTIONS=128 \
GATEWAY_LABEL_SELECTOR="app=gateway" \
LOADGEN_NODE_SELECTOR="opentraum.io/node-role=loadgen" \
LOADGEN_TOLERATION_KEY=nodegroup-type \
LOADGEN_TOLERATION_VALUE=gpu \
scripts/load-test/gateway-hpa-k8s-wrk2-runner.sh
```

`3 GPU + 1 wrk`처럼 같은 비서비스 nodegroup 안에서 wrk 노드 1개만 분리할 때는 wrk 노드에 별도 역할 label을 붙이고, 기존 GPU taint는 그대로 toleration합니다.

```bash
KUBECONFIG="<KUBECONFIG_PATH>" \
DRY_RUN=1 \
TOTAL_RATE=10000 \
PODS=17 \
THREADS=2 \
CONNECTIONS=256 \
GATEWAY_LABEL_SELECTOR="app=gateway" \
LOADGEN_NODE_SELECTOR="opentraum.io/node-role=loadgen" \
LOADGEN_TOLERATION_KEY=nodegroup-type \
LOADGEN_TOLERATION_VALUE=gpu \
scripts/load-test/gateway-hpa-k8s-wrk2-runner.sh
```

이 runner의 목적은 local PC 한 대의 CPU/네트워크 한계를 제거하는 것입니다. Gateway가 뜨는 서비스 노드는 7개로 고정하고, HPA/resource/probe 조정은 별도 target tuning phase로 분리해 기록합니다.

runner guardrail은 다음과 같습니다.

- 기본 target은 `http://gateway.opentraum.svc.cluster.local:8080/api/__loadtest__`
- `opentraum-loadtest` namespace에서 Job 실행
- `GATEWAY_LABEL_SELECTOR` 기본값은 `app=gateway`이며, `key=value` 또는 쉼표로 구분한 equality selector를 지원
- `podAntiAffinity`는 `GATEWAY_LABEL_SELECTOR`를 `matchLabels`로 렌더링해 Gateway Pod와 같은 node 배치를 회피
- 실행 시점의 Gateway node도 같은 `GATEWAY_LABEL_SELECTOR`로 조회해 `nodeAffinity` `NotIn`으로 제외
- `LOADGEN_NODE_SELECTOR`와 `LOADGEN_TOLERATION_*`로 loadgen 전용 node 지정 가능. 현재 기준은 `LOADGEN_NODE_SELECTOR="opentraum.io/node-role=loadgen"`과 기존 GPU taint toleration 조합
- 기본 `DRY_RUN=1`로 manifest를 먼저 확인

---

## 4. 기준 구성

baseline 출발점은 다음입니다.

| 항목 | 기준값 |
|---|---|
| HPA min / max | 1 / 10 |
| HPA target | CPU averageUtilization 60% |
| Gateway CPU request / limit | 500m / 1 core |
| Gateway memory request / limit | 256Mi / 512Mi |
| 부하 대상 | Gateway 전용 `/api/__loadtest__` |
| 신규 부하 도구 | `wrk`, `wrk2` |

HPA behavior는 scale-up stabilization 30초, 30초당 최대 2 pods 증가, scale-down stabilization 300초, 60초당 최대 1 pod 감소 정책으로 관측했습니다.

10,000 RPS 달성을 위한 tuning phase에서는 위 기준값을 고정값으로 보지 않습니다. 단, 한 phase 안에서 변경한 값은 명시하고, 그 변경이 RPS/latency/ready 상태/HPA event에 준 영향을 따로 판정합니다.

---

## 5. 결과 요약

| 구간 | 핵심 결과 | 판정 |
|---|---|---|
| 500 RPS | `hey` 497 RPS, `wrk` 494 RPS. 1 replica 유지 | 1 replica로 충분 |
| 900~1000 RPS | `hey` 978 RPS, `wrk` 873 RPS. HPA scale-out 관측 | 최소 2 replicas 검토 근거 있음 |
| 1500 RPS | `wrk` 1499 RPS, HPA 4 replicas까지 확장 | 4 replicas 전제 처리 가능 |
| 2000 RPS | local `hey/wrk`는 1800 RPS대. EKS `wrk2` 17 Pod는 2005 RPS 달성 | RPS는 통과, p99 1초대라 SLO는 별도 판단 필요 |
| 5000 RPS | baseline 범위에서는 안정 통과하지 못함. cold-start/probe 재시작과 timeout 확인 | 튜닝 필요 |
| 10000 RPS | wrk 전용 노드 1개 + wrk2 17 Pod 조건에서 60초 9887 RPS까지 근접. 300초 지속은 2577 RPS와 timeout 대량 발생 | 10,000 RPS 안정 달성은 아직 실패. 단일 wrk 노드와 Gateway/node 튜닝 필요 |

결론적으로 기존 baseline만으로는 10,000 RPS를 지원한다고 말할 수 없습니다. 리뷰 피드백에 따라 부하 발생기를 local PC가 아니라 EKS 내부 wrk 전용 노드에 올리고, wrk2 Pod 17개를 한 wrk 노드에 모아 Gateway와 분리했습니다. 이 조건에서 60초 smoke는 10,000 RPS에 근접했지만, 300초 지속 실험은 wrk 노드 CPU와 timeout이 동시에 터지며 실패했습니다. 다음 단계는 서비스 노드를 늘리는 것이 아니라, 전체 11개/서비스 7개 노드 조건을 유지한 채 단일 wrk 노드의 부하 발생 한계와 Gateway/Gateway node 병목을 분리해 해결하는 것입니다.

---

## 6. 상세 결과

### 6.1 1차 hey 이력

`hey`는 신규 실험에서는 더 이상 사용하지 않고, 1차 이력으로만 보존합니다.

| 단계 | 목표 RPS | 달성 RPS | 목표 대비 | Duration | p95 | p99 | Replica/HPA 관측 | 판정 |
|---|---:|---:|---:|---:|---:|---:|---|---|
| Smoke | 100 | 99.95 | 99.9% | 60s | 107ms | 174ms | 1 replica 유지 | 통과 |
| Load | 500 | 497.15 | 99.4% | 300s | 111ms | 150ms | 1 replica 유지, HPA 약 50~52%/60% | 통과 |
| Load | 1000 | 978.17 | 97.8% | 300s | 137ms | 396ms | 2 -> 4 replicas scale-out | 통과 |
| Load | 2000 | 1833.51 | 91.7% | 300s | 295ms | 798ms | 6 replicas까지 scale-out | 기준 미달 |

### 6.2 local wrk 결과

| 단계 | Threads | Connections | Duration | 달성 RPS | Requests | Avg latency | p99 latency | Replica/HPA 관측 | 판정 |
|---|---:|---:|---:|---:|---:|---:|---:|---|---|
| c8 | 2 | 8 | 300s | 494.21 | 148,310 | 21.28ms | 97.86ms | 1 replica 유지 | 500 RPS 보조 통과 |
| c16 | 4 | 16 | 300s | 873.45 | 262,173 | 23.33ms | 104.87ms | 2 replicas scale-out | 900~1000 RPS scale-out 확인 |
| c32 | 4 | 32 | 300s | 1499.71 | 450,047 | 26.77ms | 119.09ms | 4 replicas scale-out | 1500 RPS 처리 확인 |
| c64 | 8 | 64 | 300s | 1828.01 | 548,516 | 46.05ms | 280.98ms | 7 replicas scale-out | 2000 RPS 기준 미달 |

### 6.3 같은 host 병렬 wrk 결과

이 결과는 같은 local host에서 여러 `wrk` process를 늘린 실험입니다. 독립 load-generator 서버 여러 대를 붙인 분산 테스트가 아닙니다.

| Phase | Clients | Client별 Threads/Connections | Duration | Aggregate RPS | Client별 RPS 분포 | Gateway Replica/HPA | p99 latency | 판정 |
|---|---:|---|---:|---:|---|---|---:|---|
| single c64 baseline | 1 | 8 / 64 | 300s | 1,861.19 | 1개 client | 최대 6 desired | 240.28ms | 기존 1800 RPS대 재현 |
| parallel wrk x2 | 2 | 8 / 64 | 300s | 2,274.13 | 1,140.33 / 1,133.80 RPS | 최대 9 replicas | 527~530ms | 처리량 증가, 선형 확장 아님 |
| parallel wrk x5 | 5 | 8 / 64 | 300s | 2,595.27 | 517.49~521.39 RPS/client | 최대 10/10 replicas | 1.17~1.20s | 10,000 RPS 미달 |

### 6.4 local wrk2 rate 결과

이 결과도 local generator 1대 기준입니다. 모든 요청은 Gateway 전용 경로로만 보냈습니다.

| Target RPS | Actual RPS | Target 대비 | Runtime | Requests | Latency p50 / p90 / p99 | Socket errors | Gateway/HPA | 판정 |
|---:|---:|---:|---:|---:|---|---|---|---|
| 2,000 | 1,898.07 | 94.9% | 5.00m | 569,416 | 94.91ms / 4.99s / 8.63s | timeout 1,937 | 최대 6 replicas | 95% 기준 바로 아래, latency 과다 |
| 5,000 | 2,134.19 | 42.7% | 5.00m | 640,333 | 1.69m / 2.51m / 2.75m | timeout 1,965 | 최대 7 replicas | 목표 미달 |
| 10,000 | 155.36 | 1.6% | 16.83m | 156,849 | 34.96s / 0.94m / 1.04m | timeout 763 | 지표 일부 수집 실패 | 실패, capacity 판정값으로 사용하지 않음 |

### 6.5 EKS wrk2 Job 결과

`wrk2` Pod를 `opentraum-loadtest` namespace에 띄우고, Gateway와 다른 node pool로 분리해 local PC 병목을 제거했습니다. 이 방식은 부하 발생기를 애플리케이션 서비스 노드와 분리해 client 병목을 줄이는 목적입니다.

| Phase | Target RPS | Pods | Duration | Actual RPS | Requests | Latency 요약 | Gateway/HPA | 판정 |
|---|---:|---:|---:|---:|---:|---|---|---|
| smoke | 100 | 1 | 30s | 101.31 | 3,072 | p99 100ms 미만 수준 | 1 replica | runner 정상 확인 |
| bounded 2000 | 2,000 | 17 | 300s | 2,005.05 | 602,171 | pod별 p99 약 1.23~1.49s | 최대 3 replicas 관측 | RPS 통과, latency SLO는 보류 |
| bounded 5000 | 5,000 | 17 | 300s | 유효 통과 없음 | - | cold-start/probe 재시작과 timeout 발생 | Gateway ready 불안정 | 현 기준 구성에서는 capacity 선언 불가 |

### 6.6 wrk 전용 노드 1개 + wrk2 17 Pod 결과

다음 실험은 "wrk용 노드만 1개 추가하고, wrk2 Pod 17개를 그 노드에 배치"한 조건입니다. 일반 서비스 노드는 별도 증설 변수로 보지 않고, 부하 발생기와 Gateway가 같은 node 자원을 경쟁하지 않도록 분리하는 데 집중했습니다.

| Phase | Target RPS | Pods | Connections | Duration | Gateway pre-warm | Actual RPS | Socket errors | Gateway/HPA 관측 | 판정 |
|---|---:|---:|---:|---:|---|---:|---|---|---|
| one wrk node baseline | 10,000 | 17 | 128 | 300s | HPA baseline에서 시작 | 3,432.76 | 소켓 오류 발생 | Gateway ready 하락 후 7 replicas 회복 | cold-start와 Gateway 안정성 영향 큼 |
| prewarm7 c128 | 10,000 | 17 | 128 | 60s | 7 replicas | 5,751.79 | 없음 | HPA 9~10 replicas로 상승 | pre-warm 효과 있음, connection 부족 |
| prewarm10 c128 | 10,000 | 17 | 128 | 60s | 10 replicas | 3,361.36 | 없음 | Gateway 10/10 유지 | c128 조건은 불안정, 처리량 하락 |
| prewarm10 c256 | 10,000 | 17 | 256 | 60s | 10 replicas | 9,887.41 | 없음 | Gateway 10/10 유지, HPA 118%/60% | 10k 근접. 단기 smoke 기준 최선 |
| prewarm10 c256 | 10,500 | 17 | 256 | 60s | 10 replicas | 3,248.41 | timeout 급증 | Gateway 10/10이나 timeout 급증 | target 상향 실패 |
| prewarm10 c256 | 10,150 | 17 | 256 | 60s | 10 replicas | 6,145.33 | 소켓 오류 일부 | 일부 Gateway restart 관측 | 10k 초과 안정화 실패 |
| prewarm10 c256 | 10,000 | 17 | 256 | 300s | 10 replicas | 2,576.56 | timeout 대량 발생 | Gateway 10/10 유지, wrk 노드 CPU 포화 | 300초 지속 실패 |

60초 c256 smoke는 10,000 RPS에 근접했고, Gateway ready도 10/10을 유지했습니다. 그러나 같은 조건을 300초로 늘리면 부하 발생기 쪽 wrk 노드 CPU가 포화되고 timeout이 대량 발생했습니다. 따라서 현재 결과는 "Gateway가 10,000 RPS를 처리했다"가 아니라 "단일 wrk 전용 노드 조건에서 60초 단기 주입은 거의 가능하지만, 300초 지속 주입은 부하 발생기와 Gateway/node 병목을 더 분리해야 한다"로 해석합니다.

참고로, 과거 broad tuning smoke는 현재 고정 노드 기준과 다르므로 최종 capacity 판정에는 사용하지 않습니다.

---

## 7. 해석

### 7.1 replica 기준

500 RPS는 1 replica로 충분합니다. 900~1000 RPS부터는 단일 Gateway Pod의 CPU target을 넘기므로 `minReplicas: 2` 검토 근거가 있습니다. 비용을 우선하면 min 1을 유지할 수 있지만, 갑작스러운 1000 RPS 진입과 scale-up 지연을 줄이려면 min 2가 더 안전합니다.

1500 RPS는 4 replicas까지 확장된 상태에서 처리됐습니다. 2000 RPS는 EKS 내부 wrk2 Job으로 RPS 자체는 달성했지만 p99가 1초대를 넘었으므로, 단순 RPS 통과와 사용자 체감 SLO 통과를 분리해야 합니다.

### 7.2 10,000 RPS 해석

10,000 RPS는 현재 baseline Gateway 구성의 capacity로는 선언할 수 없습니다. local generator 실험은 client 병목과 외부 경로 영향이 섞였고, EKS 내부 wrk2 실험은 2000 RPS까지는 유효했지만 5000 RPS부터 안정성이 무너졌습니다.

부하 발생기를 EKS 내부로 옮긴 뒤에는 해석이 더 명확해졌습니다. wrk 전용 노드 1개 + wrk2 Pod 17개 + Gateway 10 replica pre-warm + connection 256 조건에서 60초 9,887 RPS까지 접근했습니다. 그러나 target 상향 재시도는 timeout 또는 Gateway restart로 무너졌고, 10,000 RPS 300초 지속 실험도 timeout 대량 발생으로 실패했습니다.

따라서 다음 목표는 "서비스 노드를 계속 늘려서 숫자만 맞추기"가 아닙니다. 실서비스 재현성을 위해 서비스 노드 범위를 고정하고 wrk 전용 노드 1개를 분리한 상태에서, 단일 wrk 노드가 300초 동안 10,000 RPS를 안정 주입할 수 있는지 먼저 검증해야 합니다. 이 조건에서 부하 주입이 안정화되면 Gateway 쪽 병목을 다시 분리합니다.

### 7.3 병목 후보

현재 결과에서 우선 확인해야 할 병목 후보는 다음입니다.

- HPA scale-up 지연과 min 1 cold-start 영향
- Gateway Pod CPU 포화
- Gateway startup/readiness probe 안정성
- 고정된 서비스 노드 7개 안에서의 CPU/스케줄링 여유
- wrk 전용 노드 1개가 300초 동안 10,000 RPS를 만들 수 있는지 여부
- Ingress/NLB 경로와 connection backlog
- load-generator Pod가 Gateway Pod와 같은 node 자원을 경쟁하는지 여부

---

## 8. 운영 권장안

| 운영 기준 | 권장안 | 근거 |
|---|---|---|
| 평시 500 RPS 이하 | HPA min 1 유지 가능 | 500 RPS에서 1 replica 처리 확인 |
| 900~1000 RPS 유입 가능 | `minReplicas: 2` 검토 | 1000 RPS 근처부터 scale-out 관측 |
| 1500 RPS 목표 | 최소 4 replicas까지 scale-out 전제 | local `wrk c32` 결과 |
| 2000 RPS 목표 | `minReplicas: 2` 이상 또는 pre-warm 비교 후 SLO 기준 재검증 | EKS wrk2로 RPS는 통과했지만 p99 1초대 |
| 5000 RPS 이상 | Gateway pre-warm, HPA scale-up 속도, node 여유, probe 안정화 튜닝 필요 | baseline bounded 실험에서 안정 통과 없음 |
| 10000 RPS 목표 | wrk 전용 노드 1개 + wrk2 17 Pod + c256 조건을 기준으로 병목 제거 | 60초 9,887 RPS 근접, 300초 지속 실패 |

즉시 manifest 변경 또는 후속 PR을 제안한다면 다음처럼 단계화합니다.

1. 비용 우선이면 현재 HPA min 1 유지
2. 1000 RPS대 sudden traffic 대응이 목표면 Gateway `minReplicas: 2` 제안
3. 2000 RPS 이상을 운영 목표로 잡을 경우 성공 endpoint와 SLO를 먼저 정하고 pre-warm 비교 실험 진행
4. 10,000 RPS 달성이 목표이므로 서비스 노드는 고정 범위로 두고, wrk 전용 노드 1개 조건에서 부하 주입 안정성을 먼저 확보
5. wrk 300초 지속 주입이 안정화된 뒤 Gateway min/maxReplicas, resource request/limit, probe 정책, HPA scale-up을 tuning matrix로 관리

wrk 전용 노드를 1개만 추가한다는 제약을 유지한다면 다음 해결책을 우선 검토합니다.

| 우선순위 | 제안 | 이유 |
|---:|---|---|
| 1 | wrk 전용 노드의 instance type 또는 CPU capacity 상향 | 300초 10,000 RPS에서 wrk 노드 CPU가 포화되고 timeout 대량 발생 |
| 2 | wrk2 Pod의 CPU request/limit 상향 및 node allocatable 대비 병렬도 재계산 | 17 Pod가 한 노드에서 CPU를 나눠 쓰므로 장시간 주입 안정성이 낮을 수 있음 |
| 3 | wrk2 image를 Harbor/ECR로 옮기고 사전 pull | Job 시작 지연과 외부 registry 변수를 제거 |
| 4 | Gateway pre-warm 10을 테스트 phase에서만 적용하고 운영 manifest 변경은 별도 판단 | cold-start 영향을 제거하되 비용 정책과 분리 |
| 5 | Gateway CPU request/limit과 probe timeout 비교 실험 | 10k 초과 시 Gateway restart/ready 흔들림을 줄이기 위함 |

---

## 9. 다음 실험 원칙

다음 실험은 다음 원칙을 지킵니다.

- `hey`는 더 이상 사용하지 않고, 이후 실험은 `wrk`/`wrk2`만 사용
- business API가 아니라 Gateway 전용 경로만 사용
- Gateway가 올라가는 일반 서비스 노드는 7개로 고정하고, 증설이 필요해 보이면 현재 실험을 중단한 뒤 별도 의사결정으로 분리
- load-generator는 `opentraum-loadtest` namespace와 wrk 전용 node에서 실행
- 현재 기준 실험은 wrk 전용 노드 1개 + wrk2 Pod 17개를 기본값으로 둠
- load-generator Pod와 Gateway Pod가 같은 node에 뜨지 않는지 매 phase마다 확인
- 500 / 1000 / 2000 / 5000 / 10000 RPS를 같은 표에 섞지 말고, baseline test와 tuning phase를 분리
- 최종 판정은 RPS, p99 latency, Gateway ready 상태, HPA event, scheduling event를 함께 보고 결정

10,000 RPS 달성을 위해 아래 값을 tuning matrix로 관리합니다.

| 결정 항목 | 필요한 이유 |
|---|---|
| Gateway HPA min/max | autoscale cold-start와 steady-state capacity 분리 |
| 일반 서비스 node count/type | 서비스 노드 7개 고정 조건 유지 |
| wrk 전용 node count/type | client 병목 제거. 현재는 1개 추가 조건으로 고정 |
| wrk2 Pod CPU request/limit | 단일 wrk 노드에서 300초 지속 주입 가능 여부 확인 |
| 성공 endpoint 또는 load-test endpoint | 404 route miss가 아닌 SLO 기준 측정 |
| latency SLO | RPS만 맞고 p99가 초 단위로 튀는 결과를 통과로 보지 않기 위해 필요 |

다음 실험의 1순위는 9,887 RPS 근접 조건을 재현한 뒤, 같은 조건을 300초 동안 유지하도록 만드는 것입니다.

| 순서 | 튜닝 항목 | 기대 효과 |
|---:|---|---|
| 1 | wrk 전용 노드 1개에서 c256 17 Pod 60초 9,887 RPS 재현 | 실험 재현성 확보 |
| 2 | 같은 조건을 300초로 늘리되 wrk Pod CPU request/limit 조정 | timeout 원인이 wrk 노드 CPU인지 확인 |
| 3 | 필요 시 wrk 전용 노드 instance type 상향 | "노드 수"가 아니라 "부하 발생기 1대의 성능" 문제로 분리 |
| 4 | Gateway pre-warm 10 유지 후 10,000 RPS 재시도 | HPA cold-start 영향 제거 |
| 5 | Gateway readiness/startup probe 실패 원인 확인 | 10k 초과 시 ready 하락 방지 |
| 6 | Gateway CPU request/limit 상향 비교 | Pod당 처리량 증가 또는 throttling 완화 |

---

## 10. 보안 처리

본 문서는 공개 가능한 운영 문서로 유지하기 위해 다음 값을 남기지 않습니다.

| 마스킹 대상 | 처리 방식 |
|---|---|
| 실제 public Ingress host | `<TEAM_DOMAIN>` placeholder 사용 |
| AWS 계정 ID | 미기재 |
| cluster ARN 또는 정확한 cluster name | 미기재 또는 `<CLUSTER_NAME>` 사용 |
| 로컬 클러스터 접속 파일 경로 | `<KUBECONFIG_PATH>` placeholder 사용 |
| node/pod private IP | 미기재 |
| 인증 비밀값 | 미기재 |

테스트 스크립트도 실제 host를 하드코딩하지 않고 `TARGET_URL` 환경변수로 주입받습니다.
