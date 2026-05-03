# OpenTraum 인프라 매뉴얼 - Gateway 트래픽 테스트

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

Gateway는 외부 트래픽이 처음 닿는 진입점입니다. 이 테스트의 목표는 서비스 노드 수를 고정한 상태에서 Gateway replicas(현재 수동 변경, KEDA 미설치)와 부하 발생기 배치가 어느 지점에서 병목을 만드는지 재현 가능하게 남기는 것입니다.

중요한 전제는 "부하를 받는 서비스 용량"과 "부하를 만드는 generator 용량"을 분리하는 것입니다. 현재 후속 실험의 capacity budget은 t3.medium × 7 서비스 노드 + wrk 전용 노드 1개를 기본으로 고정하며, 서비스 nodegroup 증설은 10,000 RPS 달성을 위한 해결책으로 사용하지 않습니다. 한 실험 안에서 여러 값을 동시에 바꾸면 어떤 변경이 효과를 냈는지 알 수 없으므로, 매 phase마다 고정값과 변경점을 명시합니다.

부하 발생기는 별도 namespace와 wrk 전용 노드에서 실행합니다. 이 분리는 workstation 병목을 제거하고, 부하 발생 Pod가 Gateway Pod와 같은 node 자원을 경쟁하지 않게 하기 위한 조건입니다. 이후 Gateway replicas/resource 튜닝은 서비스 노드 7개 고정 조건을 유지한 별도 phase로 기록합니다.

도구 정책은 단순하게 유지합니다. 신규·재현 실험은 EKS 내부 Kubernetes Job으로 실행하는 `wrk2`만 사용합니다. 과거 비-EKS generator 결과는 최종 capacity 판정이나 신규 절차에 사용하지 않습니다.

모든 신규 실험은 Gateway 전용 경로만 대상으로 합니다. business API는 event-service, DB, Redis 등 downstream 병목이 섞일 수 있으므로 Gateway 단독 실험에서 제외합니다. 또한 본 시점에서 트래픽 테스트는 아직 실행 전이며, 이하 시나리오·기준 구성·예상 판정은 모두 플랜 단계입니다.

---

## 2. 테스트 범위

### 2.1 제외한 business endpoint

`GET /api/v1/concerts` 등 business endpoint는 Gateway뿐 아니라 event-service와 DB 상태가 함께 반영되므로 Gateway 단독 capacity 판단 근거로 사용하지 않습니다.

### 2.2 Gateway-only endpoint

Gateway 자극용 경로는 다음 조건을 만족해야 합니다.

- Ingress 또는 Gateway Service를 통해 Gateway를 통과
- downstream 서비스 호출을 최소화
- route miss로 404가 나면 성공 처리량이 아니라 Gateway CPU/replica 반응 baseline으로만 해석

이에 따라 `GET /api/__loadtest__` 경로를 사용합니다. 현재 배포에서 이 경로가 404를 반환하면 해당 결과는 성공 처리량이 아니라 route-miss baseline으로만 기록합니다. 2xx synthetic endpoint 또는 별도 microservice 분리는 현재 Infra PR 범위 밖의 후속 TODO 후보로 둡니다.

### 2.3 baseline과 tuning 실험 구분

| 범주 | 서비스 노드/Gateway replicas | 부하 발생기 | 목적 |
|---|---|---|---|
| baseline | 서비스 노드 7개 고정, Gateway replicas 1 (현재값) 유지 | EKS `load-test` namespace의 wrk2 Job | 현재 출발점 확인 |
| loadgen 분리 | 서비스 노드 7개 고정, Gateway replicas 1 유지 | 별도 namespace/node pool의 wrk2 Pod 확장 | client 병목 제거 |
| target tuning | 서비스 노드 7개 고정 조건에서 Gateway replicas(수동 변경), resource, probe를 단계적으로 변경 | 별도 namespace/wrk 전용 노드의 wrk2 Pod | 10,000 RPS 병목 분리 |

따라서 과거의 broad tuning 결과는 참고 이력으로만 두고, 현재 판정은 "서비스 노드 고정 기준 구성"과 "고정 조건 내 튜닝"을 분리해 기록합니다.

---

## 3. 실행 스크립트

### 3.1 EKS wrk2 Job runner만 사용

실행 스크립트는 [../chaos/load-test/scripts/gateway-hpa-k8s-wrk2-runner.sh](../chaos/load-test/scripts/gateway-hpa-k8s-wrk2-runner.sh)입니다. 호환용 entrypoint [../chaos/load-test/scripts/gateway-hpa-load-test.sh](../chaos/load-test/scripts/gateway-hpa-load-test.sh)도 같은 Kubernetes Job runner로 위임하며, legacy `MODE=wrk*`, `WRK_BIN`, `WRK2_BIN` 같은 workstation generator 옵션은 실패 처리합니다.

```bash
DRY_RUN=1 \
TOTAL_RATE=10000 \
PODS=17 \
chaos/load-test/scripts/gateway-hpa-load-test.sh
```

위 dry-run은 `/tmp/opentraum-gateway-hpa-k8s-wrk2-<timestamp>` 아래에 Job manifest와 `run-config.env`를 남깁니다. manifest와 node 분리 조건을 확인한 뒤에만 `DRY_RUN=0`으로 실행합니다.

### 3.2 Kubernetes wrk2 Job runner

클러스터 내부에서 `wrk2` Pod를 여러 개 띄우는 스크립트는 [../chaos/load-test/scripts/gateway-hpa-k8s-wrk2-runner.sh](../chaos/load-test/scripts/gateway-hpa-k8s-wrk2-runner.sh)에 둡니다. 기본 target은 Gateway 내부 Service입니다.

```bash
TOTAL_RATE=10000 \
PODS=17 \
DRY_RUN=1 \
chaos/load-test/scripts/gateway-hpa-k8s-wrk2-runner.sh
```

기본값은 17 Pod / 10,000 RPS / 300초이며, Pod별 target rate는 `ceil(TOTAL_RATE / PODS)`로 계산합니다.

```bash
DRY_RUN=0 \
TOTAL_RATE=10000 \
PODS=17 \
THREADS=2 \
CONNECTIONS=256 \
DURATION_SECONDS=60 \
LOADGEN_NODE_SELECTOR="nodegroup-type=gpu" \
LOADGEN_TOLERATION_KEY=nodegroup-type \
LOADGEN_TOLERATION_VALUE=gpu \
chaos/load-test/scripts/gateway-hpa-k8s-wrk2-runner.sh
```

300초 지속 검증은 별도 phase로 실행할 예정입니다.

```bash
DRY_RUN=0 \
TOTAL_RATE=10000 \
PODS=17 \
THREADS=2 \
CONNECTIONS=256 \
DURATION_SECONDS=300 \
LOADGEN_NODE_SELECTOR="nodegroup-type=gpu" \
LOADGEN_TOLERATION_KEY=nodegroup-type \
LOADGEN_TOLERATION_VALUE=gpu \
chaos/load-test/scripts/gateway-hpa-k8s-wrk2-runner.sh
```

이 runner의 목적은 developer workstation의 CPU/네트워크 한계를 실험 변수에서 제거하는 것입니다. Gateway가 뜨는 서비스 노드는 7개로 고정하고, replicas(수동 변경)/resource/probe 조정은 별도 target tuning phase로 분리해 기록합니다.

runner guardrail은 다음과 같습니다.

- 기본 target은 `http://gateway.opentraum.svc.cluster.local:8080/api/__loadtest__`
- `load-test` namespace에서 Job 실행
- `GATEWAY_LABEL_SELECTOR` 기본값은 `app=gateway`이며, `key=value` 또는 쉼표로 구분한 equality selector를 지원
- 기본적으로 현재 Gateway Pod가 떠 있는 node를 `NotIn` affinity로 제외하고, 확인 실패 시 live run은 중단
- loadgen Pod끼리는 `topologySpreadConstraints`로 node 분산을 시도
- `DRY_RUN=1`이 기본값이며, live run은 dry-run manifest와 node 배치 조건을 먼저 검토한 뒤 실행

---

## 4. 기준 구성

baseline 출발점은 다음입니다.

| 항목 | 기준값 |
|---|---|
| Gateway replicas | 1 (현재값, 수동 변경. KEDA/HPA 미설치) |
| Gateway CPU request / limit | 300m / 300m |
| Gateway memory request / limit | 512Mi / 512Mi |
| 부하 대상 | Gateway 전용 `/api/__loadtest__` |
| 신규 부하 도구 | `wrk2` |

오토스케일러는 현재 미설치 상태이므로, replicas 변경은 매니페스트(GitOps) 기준으로 수동 적용한 뒤 측정합니다.

10,000 RPS 달성을 위한 tuning phase에서는 위 기준값을 고정값으로 보지 않습니다. 단, 한 phase 안에서 변경한 값은 명시하고, 그 변경이 RPS/latency/ready 상태/replicas 변경 시점에 준 영향을 따로 판정합니다.

---

## 5. 결과 요약

본 시점에서 트래픽 테스트는 아직 실행 전이므로, 아래 표는 측정 결과가 아니라 측정해야 할 구간과 사전 가설을 정리한 플랜입니다. 실제 RPS·p99·replica 거동 수치는 실행 후에 별도 PR에서 채워 넣습니다.

| 구간 | 측정 항목 | 사전 가설 |
|---|---|---|
| 500 RPS | 1 replica 처리 가능 여부, p99, CPU 사용률 | baseline 범위 내 통과 가능성 높음 |
| 900~1000 RPS | 1 replica CPU 한계, replicas 수동 증설 시점 | 1 replica로는 CPU 포화 가능, 2 replicas 비교 필요 |
| 1500 RPS | replicas 단계별 처리량과 p99 | 4 replicas 내외에서 RPS 통과 가능성 |
| 2000 RPS | RPS 통과 여부와 p99 SLO | RPS는 가능하나 p99가 1초대로 튈 수 있음 |
| 5000 RPS | startup/readiness probe 안정성, timeout | baseline 범위에서는 cold-start/probe 재시작 발생 가능 |
| 10000 RPS | wrk 전용 노드 1개 + wrk2 17 Pod 조건에서 60s/300s 안정성 | 60초 smoke 근접·300초 지속 실패 시나리오 검증 필요 |

결론적으로 기존 baseline만으로 10,000 RPS를 지원한다고 사전 단정할 근거는 없습니다. 리뷰 피드백에 따라 부하 발생기는 EKS 내부 wrk 전용 노드에 올리고, wrk2 Pod 17개를 한 wrk 노드에 모아 Gateway와 분리할 예정입니다. 다음 단계는 서비스 노드를 늘리는 것이 아니라, 서비스 7개 노드 조건을 유지한 채 Gateway probe/resource 튜닝을 GitOps manifest 기준으로 반영해 병목을 분리하는 것입니다.

---

## 6. 상세 결과

본 시점에서 모든 phase는 아직 실행 전입니다. 아래 표는 실행 후 결과를 채워 넣을 슬롯 형태로 두고, "Actual RPS / Latency / Gateway 관측" 칼럼은 실험을 마친 PR에서 갱신합니다.

### 6.1 제외된 workstation generator 이력

과거 비-EKS generator 결과는 developer workstation CPU/네트워크와 외부 경로 변수가 섞여 있습니다. 따라서 이 문서의 신규 capacity 판정, 운영 권장안, 후속 실험 절차에는 사용하지 않습니다. 필요한 경우 과거 raw 기록에서 별도 감사할 수 있지만, 재현 실험은 반드시 EKS 내부 `wrk2` Job으로 다시 실행합니다.

### 6.2 EKS wrk2 Job (예정 phase)

`wrk2` Pod를 `load-test` namespace에 띄우고, Gateway와 다른 node pool로 분리해 developer workstation 병목을 제거할 예정입니다. 이 방식은 부하 발생기를 애플리케이션 서비스 노드와 분리해 client 병목을 줄이는 목적입니다.

| Phase | Target RPS | Pods | Duration | 측정 항목 |
|---|---:|---:|---:|---|
| smoke | 100 | 1 | 30s | runner 정상 동작 확인, p99 baseline |
| bounded 2000 | 2,000 | 17 | 300s | RPS 통과 여부, pod별 p99, replicas 거동(수동) |
| bounded 5000 | 5,000 | 17 | 300s | startup/readiness probe 안정성, timeout 발생 여부 |

### 6.3 wrk 전용 노드 1개 + wrk2 17 Pod (예정 phase)

다음 실험은 "wrk용 노드만 1개 추가하고, wrk2 Pod 17개를 그 노드에 배치"한 조건입니다. 일반 서비스 노드는 별도 증설 변수로 보지 않고, 부하 발생기와 Gateway가 같은 node 자원을 경쟁하지 않도록 분리하는 데 집중합니다.

| Phase | Target RPS | Pods | Connections | Duration | Gateway pre-warm(수동 replicas) | 측정 항목 |
|---|---:|---:|---:|---:|---|---|
| one wrk node baseline | 10,000 | 17 | 128 | 300s | 1 replicas (현재값)부터 시작 | cold-start와 Gateway 안정성 영향 |
| prewarm7 c128 | 10,000 | 17 | 128 | 60s | 7 replicas | pre-warm 효과, connection 부족 여부 |
| prewarm10 c128 | 10,000 | 17 | 128 | 60s | 10 replicas | c128 안정성 |
| prewarm10 c256 | 10,000 | 17 | 256 | 60s | 10 replicas | 60초 smoke에서 10k 근접 가능 여부 |
| prewarm10 c256 | 10,500 | 17 | 256 | 60s | 10 replicas | target 상향 시 timeout 임계 |
| prewarm10 c256 | 10,150 | 17 | 256 | 60s | 10 replicas | 10k 초과 안정성 |
| prewarm10 c256 | 10,000 | 17 | 256 | 300s | 10 replicas | 300초 지속 가능 여부, wrk 노드 CPU 포화 |

본 phase의 가설은 "60초 c256 smoke가 10,000 RPS에 근접하더라도 300초 지속 시 부하 발생기 측 CPU 포화로 timeout이 늘어날 가능성"입니다. 결과는 실행 후 별도 PR에서 채워 넣습니다.

### 6.4 후속 재현 phase (예정)

후속 재현에서는 Gateway repo code를 수정하지 않고, ConfigMap에 임시 Gateway-only 204 route를 추가해 downstream API를 제외할 예정입니다. 실험 후 route는 제거하고 Gateway는 1 replica 기준으로 되돌립니다.

| Phase | Target RPS | Pods | Connections | Duration | Gateway 수동 replicas | 측정 항목 |
|---|---:|---:|---:|---:|---|---|
| auth204 r4 c128 | 10,000 | 17 | 128 | 60s | 4 replicas | RPS, timeout, restart |
| auth204 r6 c128 | 10,000 | 17 | 128 | 60s | 6 replicas | RPS, timeout, restart |
| auth204 r8 c128 | 10,000 | 17 | 128 | 60s | 8 replicas | RPS, timeout, restart |
| auth204 r8 c256 | 10,000 | 17 | 256 | 60s | 8 replicas | liveness restart 발생 여부 |
| auth204 r10 c256 | 10,000 | 17 | 256 | 60s | 10 replicas | liveness restart 발생 여부 |

이 재현의 가설은 "단순히 Gateway replicas를 8~10으로 수동 상향하거나 wrk2 connection을 256으로 늘리는 방식만으로는 안정적인 개선이 어렵고, c256 구간에서는 health probe timeout 이후 liveness restart가 발생할 수 있다"입니다. live Deployment patch로 probe를 완화하더라도 ArgoCD가 Gateway Deployment를 GitOps 기준으로 되돌리므로, 검증은 임시 `kubectl patch`가 아니라 Gateway manifest 변경 PR 단위로 진행합니다.

---

## 7. 해석

본 절은 실행 전 시점의 사전 해석 가설입니다. 실제 RPS·p99·replicas 거동은 측정 후 수정합니다.

### 7.1 replica 기준 (사전 가설)

500 RPS는 1 replica로 처리 가능할 것으로 보입니다. 900~1000 RPS부터는 단일 Gateway Pod의 CPU target을 넘길 가능성이 있어, 수동으로 `replicas: 2` 이상 운영을 검토할 근거가 됩니다. KEDA/HPA가 미설치 상태이므로 자동 scale-out이 아닌 사전 수동 증설로 sudden traffic을 흡수해야 합니다.

1500 RPS는 4 replicas 수준에서 처리 가능할 것으로 가정하며, 2000 RPS는 RPS 자체는 가능하지만 p99 SLO 별도 판정이 필요할 것으로 가정합니다. 실제 수치는 EKS wrk2 Job 측정으로 확인합니다.

### 7.2 10,000 RPS 해석 (사전 가설)

10,000 RPS는 현재 baseline Gateway 구성(replicas 1, CPU req=lim 300m, mem 512Mi)으로는 capacity로 선언할 수 없을 것으로 가정합니다. 제외된 workstation generator 실험은 client 병목과 외부 경로 영향이 섞이므로 capacity 판정에서 배제합니다.

부하 발생기를 EKS 내부로 옮긴 뒤에도, 단일 wrk 전용 노드 1개 + wrk2 Pod 17개 조건에서 300초 지속 시 부하 발생기 CPU 포화가 1차 병목이 될 가능성이 있습니다. 실험은 이 가설을 검증하는 방향으로 진행합니다.

따라서 다음 목표는 "서비스 노드를 계속 늘려서 숫자만 맞추기"가 아닙니다. 서비스 노드 7개 범위를 고정하고 wrk 전용 노드 1개를 분리한 상태에서, 단일 wrk 노드가 300초 동안 10,000 RPS를 안정 주입할 수 있는지 먼저 확인합니다. 이 조건에서 부하 주입이 안정화되면 Gateway 쪽 병목을 다시 분리합니다.

### 7.3 병목 후보

우선 확인해야 할 병목 후보는 다음입니다.

- 수동 replicas 1에서 출발하는 cold-start 영향 (KEDA/HPA 미설치 환경)
- Gateway Pod CPU 포화 (현재 req=lim 300m / mem 512Mi)
- Gateway startup/readiness probe 안정성 (실측 startup 48.4s)
- 고정된 서비스 노드 7개(t3.medium) 안에서의 CPU/스케줄링 여유
- wrk 전용 노드 1개가 300초 동안 10,000 RPS를 만들 수 있는지 여부
- Ingress/NLB 경로와 connection backlog
- load-generator Pod가 Gateway Pod와 같은 node 자원을 경쟁하는지 여부

---

## 8. 운영 권장안

본 절의 권장안은 실행 전 사전 가설입니다. 측정 후 수치가 확보되면 근거 칼럼을 갱신합니다.

| 운영 기준 | 권장안 | 사전 근거 |
|---|---|---|
| 평시 500 RPS 이하 | 현재값 replicas 1 유지 가능 | 1 replica로 처리 가능할 것으로 가정 |
| 900~1000 RPS 유입 가능 | 사전에 수동 `replicas: 2`로 증설 검토 | KEDA/HPA 미설치이므로 자동 scale-out 불가, 사전 증설 필요 |
| 1500 RPS 목표 | EKS wrk2 Job으로 측정 전까지 보수적으로 판단 | workstation generator 결과는 판정에서 제외 |
| 2000 RPS 목표 | 수동 replicas 상향 후 pre-warm 비교 및 SLO 기준 측정 | RPS는 통과 가능하나 p99 1초대 가능성 |
| 5000 RPS 이상 | Gateway pre-warm, node 여유, probe 안정화 튜닝 필요 | baseline 범위에서 안정 통과 어려울 것으로 가정 |
| 10000 RPS 목표 | Gateway probe/resource 튜닝을 GitOps manifest로 반영한 뒤 wrk 전용 노드 1개 + wrk2 17 Pod 조건으로 측정 | 측정 전 단계, 60초 단기 가능성 vs 300초 지속 실패 가설 |

즉시 manifest 변경 또는 후속 PR을 제안한다면 다음처럼 단계화합니다.

1. 비용 우선이면 현재 replicas 1 유지 (KEDA/HPA 미설치)
2. 1000 RPS대 sudden traffic 대응이 목표면 Gateway 매니페스트 수동 `replicas: 2` 변경 제안
3. 2000 RPS 이상을 운영 목표로 잡을 경우 성공 endpoint와 SLO를 먼저 정하고 pre-warm 비교 실험 진행
4. 10,000 RPS 달성이 목표이므로 서비스 노드는 고정 범위로 두고, Gateway liveness/readiness probe와 CPU request/limit을 먼저 tuning matrix로 관리
5. 60초 smoke에서 socket error와 Gateway restart가 없는 것이 확인된 뒤에만 300초 지속 실험으로 승격

wrk 전용 노드를 1개만 추가한다는 제약을 유지한다면 다음 해결책을 우선 검토합니다.

| 우선순위 | 제안 | 이유 |
|---:|---|---|
| 1 | wrk 전용 노드의 instance type 또는 CPU capacity 상향 | 300초 10,000 RPS에서 wrk 노드 CPU 포화·timeout 발생 가능성 |
| 2 | wrk2 Pod의 CPU request/limit 상향 및 node allocatable 대비 병렬도 재계산 | 17 Pod가 한 노드에서 CPU를 나눠 쓰므로 장시간 주입 안정성이 낮을 수 있음 |
| 3 | wrk2 image를 Harbor/ECR로 옮기고 사전 pull | Job 시작 지연과 외부 registry 변수를 제거 |
| 4 | Gateway pre-warm은 낮은 replicas에서 시작해 probe/resource 튜닝 후 단계적으로 상향 | replicas만 무리하게 올리면 c256 조건에서 liveness restart 발생 가능성 |
| 5 | Gateway CPU request/limit과 liveness/readiness probe timeout 비교 실험 | 10k 주입 시 health probe timeout으로 liveness restart 가능성 |

---

## 9. 다음 실험 원칙

다음 실험은 다음 원칙을 지킵니다.

- 이후 실험은 EKS 내부 Kubernetes Job으로 실행하는 `wrk2`만 사용
- business API가 아니라 Gateway 전용 경로만 사용
- Gateway가 올라가는 일반 서비스 노드는 7개로 고정하고, 증설이 필요해 보이면 현재 실험을 중단한 뒤 별도 의사결정으로 분리
- load-generator는 `load-test` namespace와 wrk 전용 node에서 실행
- 현재 기준 실험은 wrk 전용 노드 1개 + wrk2 Pod 17개를 기본값으로 둠
- load-generator Pod와 Gateway Pod가 같은 node에 뜨지 않는지 매 phase마다 확인
- 500 / 1000 / 2000 / 5000 / 10000 RPS를 같은 표에 섞지 말고, baseline test와 tuning phase를 분리
- 최종 판정은 RPS, p99 latency, Gateway ready 상태, replicas 변경 시점, scheduling event를 함께 보고 결정

10,000 RPS 달성을 위해 아래 값을 tuning matrix로 관리합니다.

| 결정 항목 | 필요한 이유 |
|---|---|
| Gateway 수동 replicas 단계 | KEDA/HPA 미설치 환경에서 cold-start와 steady-state capacity 분리 |
| 일반 서비스 node count/type | 서비스 노드 7개 고정 조건 유지 (t3.medium × 7) |
| wrk 전용 node count/type | client 병목 제거. 현재는 1개 추가 조건으로 고정 |
| wrk2 Pod CPU request/limit | 단일 wrk 노드에서 300초 지속 주입 가능 여부 확인 |
| 성공 endpoint 또는 load-test endpoint | 404 route miss가 아닌 SLO 기준 측정 |
| latency SLO | RPS만 맞고 p99가 초 단위로 튀는 결과를 통과로 보지 않기 위해 필요 |

다음 실험의 1순위는 c256 17 Pod 60초 조건에서 10,000 RPS 근접이 가능한지 측정한 뒤, 같은 조건을 300초 동안 유지하도록 만드는 것입니다.

| 순서 | 튜닝 항목 | 기대 효과 |
|---:|---|---|
| 1 | EKS wrk2 Job c256 17 Pod 60초 10,000 RPS 측정 | baseline 확보 |
| 2 | 같은 조건을 300초로 늘리되 wrk2 Job Pod CPU request/limit 조정 | timeout 원인이 wrk 노드 CPU인지 확인 |
| 3 | 필요 시 loadgen 전용 노드 instance type 상향 | "노드 수"가 아니라 "부하 발생기 1대의 성능" 문제로 분리 |
| 4 | Gateway 수동 replicas 10 유지 후 10,000 RPS 재시도 | cold-start 영향 제거 |
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
