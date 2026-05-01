# monitoring/ — Helm values 정식 배포

monitoring ns 의 Helm release 3개에 대한 values.yaml 모음.

## Release 목록

| Release | Chart | Version | 주요 역할 |
|---|---|---|---|
| `kube-prometheus-stack` | `prometheus-community/kube-prometheus-stack` | 84.4.0 | Prometheus + Alertmanager + Grafana + Operator + kube-state-metrics |
| `loki` | `grafana/loki` | 7.0.0 | 로그 저장 (SingleBinary) + gateway |
| `alloy` | `grafana/alloy` | 1.8.0 | 로그 수집 (DaemonSet), 일반 워커 노드 배치 |

## 파일

| 파일 | 대상 |
|---|---|
| `values-kube-prometheus-stack.yaml` | kube-prometheus-stack 전체 |
| `values-loki.yaml` | loki singleBinary + gateway |
| `values-alloy.yaml` | alloy 로그 수집 + 일반 워커 노드 배치 |

## 적용

```bash
# Helm repo 추가 (1회)
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update

# Upgrade
helm upgrade kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --version 84.4.0 \
  -n monitoring -f values-kube-prometheus-stack.yaml

helm upgrade loki grafana/loki \
  --version 7.0.0 \
  -n monitoring -f values-loki.yaml

helm upgrade alloy grafana/alloy \
  --version 1.8.0 \
  -n monitoring -f values-alloy.yaml
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

### DaemonSet 스케줄링 기준

- `alloy` 는 일반 워커 노드그룹(`skala3-cloud1-team8-ng`)에만 배치
- `loki-canary` 는 실습용 검증 컴포넌트라 운영 배포에서는 비활성화
- GPU 노드의 GPU 메트릭은 `gpu-monitoring/dcgm-exporter.yml` 이 별도 수집
- `nvidia-device-plugin` 은 GPU 노드에서만 `nvidia.com/gpu` 리소스를 광고
- 기존 `alloy/configmap-patch.yaml` 은 수동 ConfigMap 패치용 참고 파일이며, 정식 배포는 `values-alloy.yaml` 로 관리

### GPU monitoring 관리 기준

- `dcgm-exporter`, ServiceMonitor, GPU Grafana dashboard 는 `k8s/gpu-monitoring/` raw manifest 로 관리
- Helm release(`kube-prometheus-stack`, `loki`, `alloy`) 는 core monitoring 구성만 관리
- GPU dashboard 는 Grafana sidecar 가 `grafana_dashboard: "1"` 라벨 ConfigMap 을 watch 해서 자동 등록

## 히스토리

- **2026-04-07**: alloy 최초 배포
- **2026-04-03**: kube-prometheus-stack + loki 최초 배포 (helm install)
- **2026-04-22**: values.yaml 정식 작성 + topologySpread 추가 (이전 세션에서 `kubectl delete pod` 로 임시 분산한 것을 values 로 영구화)

## 튜닝 후보 (미적용)

- Loki 를 StorageClass "ebs-sc" → "gp3" 로 변경해 비용 절감 (gp2 → gp3 는 IOPS 기본 3000 보장)
- Prometheus federation 구성 (멀티 클러스터 확장 시)
- Grafana dashboard 자동 프로비저닝 (ConfigMap 기반)
