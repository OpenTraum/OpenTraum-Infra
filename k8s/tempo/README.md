# Grafana Tempo + Alloy OTLP 배포

monitoring 네임스페이스에 Tempo(monolithic, local PVC)를 배포하고, Alloy를 OTLP
receiver로 확장해 애플리케이션 trace를 Tempo로 전달합니다. Grafana에 Tempo
datasource도 자동 등록됩니다.

## 전제
- `monitoring` 네임스페이스 존재
- kube-prometheus-stack / Loki / Alloy 가 이미 설치되어 있음 (replicas=0 상태 가능)
- `ebs-sc` StorageClass 존재
- Tempo 이미지는 Docker Hub `grafana/tempo:2.6.0` (Harbor mirror 불필요 — 용량 작고 public)

## 배포 순서

### 1) Tempo
```bash
chmod +x k8s-manual/tempo/deploy.sh
k8s-manual/tempo/deploy.sh
# 또는 개별:
kubectl apply -f k8s-manual/tempo/configmap.yaml
kubectl apply -f k8s-manual/tempo/service.yaml
kubectl apply -f k8s-manual/tempo/statefulset.yaml
kubectl -n monitoring rollout status statefulset/tempo
```

### 2) Alloy ConfigMap 덮어쓰기 + OTLP Service 추가 + rollout
```bash
kubectl apply -f k8s-manual/alloy/configmap-patch.yaml
kubectl apply -f k8s-manual/alloy/service-patch.yaml

# Alloy 재기동해서 새 config 반영 + replicas 복구
kubectl -n monitoring scale deploy/alloy --replicas=1   # 또는 ds일 경우 생략
kubectl -n monitoring rollout restart deploy/alloy       # DaemonSet이면 daemonset/alloy
```
> Alloy가 Deployment인지 DaemonSet인지는 Helm chart values에 따라 다릅니다.
> `kubectl -n monitoring get deploy,ds -l app.kubernetes.io/name=alloy` 로 확인.

### 3) Grafana Tempo datasource + rollout
```bash
kubectl apply -f k8s-manual/grafana/datasource-tempo.yaml

# Grafana replicas 복구
kubectl -n monitoring scale deploy/kube-prometheus-stack-grafana --replicas=1
# sidecar 캐시 반영 안 되면:
kubectl -n monitoring rollout restart deploy/kube-prometheus-stack-grafana
```

## 확인

```bash
# Tempo Ready
kubectl -n monitoring get sts,svc,pvc -l app.kubernetes.io/name=tempo

# Alloy config 반영 + OTLP 포트
kubectl -n monitoring get cm alloy -o yaml | head -50
kubectl -n monitoring get svc alloy-otlp

# Grafana datasource 자동 등록 확인 (sidecar log)
kubectl -n monitoring logs deploy/kube-prometheus-stack-grafana -c grafana-sc-datasources | tail -30
```

Grafana UI → Explore → Tempo datasource 선택 → trace 조회.

## 파일 목록

- `k8s-manual/tempo/configmap.yaml` — Tempo monolithic config
- `k8s-manual/tempo/service.yaml` — Tempo Service (3200/9095/4317/4318)
- `k8s-manual/tempo/statefulset.yaml` — Tempo StatefulSet (PVC 10Gi ebs-sc)
- `k8s-manual/tempo/deploy.sh` — Tempo apply 스크립트
- `k8s-manual/alloy/configmap-patch.yaml` — 기존 Loki 수집 + OTLP receiver + Tempo exporter
- `k8s-manual/alloy/service-patch.yaml` — `alloy-otlp` Service (4317/4318)
- `k8s-manual/grafana/datasource-tempo.yaml` — Grafana Tempo datasource sidecar ConfigMap
