# monitoring/ — Helm values 정식 배포

monitoring ns 의 Helm release 3개에 대한 values.yaml 모음.

## Release 목록

| Release | Chart | Version | 주요 역할 |
|---|---|---|---|
| `kube-prometheus-stack` | `prometheus-community/kube-prometheus-stack` | 82.16.2 | Prometheus + Alertmanager + Grafana + Operator + kube-state-metrics |
| `loki` | `grafana/loki` | 6.55.0 | 로그 저장 (SingleBinary) + gateway |
| `alloy` | `grafana/alloy` | 1.7.0 | 로그/메트릭/OTLP 수집 (DaemonSet) — values 파일 불필요 |

## 파일

| 파일 | 대상 |
|---|---|
| `values-kube-prometheus-stack.yaml` | kube-prometheus-stack 전체 |
| `values-loki.yaml` | loki singleBinary + gateway |
| (alloy) | DaemonSet 이라 자동 분산, 별도 values 없음. 필요 시 `alloy/configmap-patch.yaml` 참고 |

## 적용

```bash
# Helm repo 추가 (1회)
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update

# Upgrade
helm upgrade kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  -n monitoring -f values-kube-prometheus-stack.yaml

helm upgrade loki grafana/loki \
  -n monitoring -f values-loki.yaml
```

## 주요 설계 결정

### topologySpreadConstraints

- 모든 스텁 Pod (prometheus, alertmanager, grafana, operator, loki-single, loki-gateway, kube-state-metrics) 에 `maxSkew: 1` `whenUnsatisfiable: ScheduleAnyway` 추가
- 6노드 분산 힌트. `ScheduleAnyway` 라 강제는 아니지만 스케줄러가 우선순위로 고려
- **이유**: 이전 세션에서 `ip-10-0-156-206` 노드에 monitoring Pod 8개 집중 → memory 90% 도달 관찰됨. 특정 노드 OOM 방지

### cross podAntiAffinity (2026-04-28 추가)

- prometheus / loki / mariadb 에 공통 라벨 `opentraum.io/heavy: "true"` + `preferredDuringScheduling` podAntiAffinity 추가
- **이유**: bitnami/loki/kube-prometheus-stack chart 기본 affinity 는 같은 release 내부 끼리만 회피. 단일 replica StatefulSet 에서는 사실상 무효 → 서로 다른 무거운 pod 간 cross anti-affinity 가 필요
- **효과**: 클러스터 셧다운 → 재기동 시 prometheus / loki / mariadb 가 자동으로 다른 노드에 분산 (이전엔 한 노드에 묶여 메모리 95% 까지 도달)
- **`preferred`** 라 노드 부족 시 강제 분산 안 함 (Pending 위험 회피)

### 리소스 제한

- 이전에는 Helm chart 기본값 (높은 limit) → 6노드 중 2~3노드에서 limit overcommit 100%+ 발생
- 각 컴포넌트별 실사용 기반 request/limit 로 하향 조정
- Prometheus retention 7d 로 단축 (기본 15d → 디스크 부담 완화)

### Loki AZ 제약

- EBS CSI 는 AZ-bound. Loki singleBinary PVC 가 2a/2b 중 하나에 바인딩되면 해당 AZ 3노드 중에서만 스케줄 가능
- `replicas=1` 이므로 분산 효과 제한적. 주 목적은 "특정 노드에 집중되지 않게" 힌트 제공

### alloy 제외 이유

- DaemonSet 이라 각 노드당 1개씩 자동 분산
- `alloy/configmap-patch.yaml` 로 OTLP receiver + Tempo exporter 만 별도 관리

## 히스토리

- **2026-04-07**: alloy 최초 배포
- **2026-04-03**: kube-prometheus-stack + loki 최초 배포 (helm install)
- **2026-04-22**: values.yaml 정식 작성 + topologySpread 추가 (이전 세션에서 `kubectl delete pod` 로 임시 분산한 것을 values 로 영구화)

## 튜닝 후보 (미적용)

- Loki/Tempo 를 StorageClass "ebs-sc" → "gp3" 로 변경해 비용 절감 (gp2 → gp3 는 IOPS 기본 3000 보장)
- Prometheus federation 구성 (멀티 클러스터 확장 시)
- Grafana dashboard 자동 프로비저닝 (ConfigMap 기반)
