# VDT Phase 2 – Security Platform: manifests

Khớp với **Guide 1/2 (Admin cluster)** và **Guide 2/2 (Workload cluster, tự cài khi cấp phát)**.
Admin cluster (kind + CAPI + CAPD + CAAPH) khai báo một lần; workload cluster nào có nhãn `security-baseline=enabled`
sẽ tự có Falco/Sidekick/Talon, Kyverno, namespace, NetworkPolicy, policy. Không còn `helm install` tay vào workload.

```
01-admin-cluster/kind-config.yaml            Admin: kind
02-workload-cluster/                         Admin (kubectl): ClusterClass, Cluster (có nhãn), calico.yaml (cluster cài Calico tay)
04-pg-target/compose.yaml                    Docker (network kind): PostgreSQL target
05-admin-apps/defectdojo|loki|grafana        Admin (helm): values
05-admin-apps/orchestrator/orchestrator.yaml Admin: CronJob scan-orchestrator (đa cluster, mặc định suspend)
workload/addons/                             Admin: HelmChartProxy (Falco, Talon, Kyverno) + ClusterResourceSet
workload/manifests/                          CRS apply xuống workload: namespace, Kyverno policy, quarantine NetworkPolicy, lab target
workload/scan/                               run-scans.sh + template Job (nạp vào ConfigMap scan-scripts)
workload/tests/                              verify, RT-1..3, PE-1..5, e2e, fixtures
scripts/                                     lib.sh, render.sh, provision-cluster.sh, scan-now.sh
Makefile, env.sh, env.example                Điểm vào: make addons | provision | verify | scan | test | e2e
.github/workflows/baseline.yml               CI (lint trên GitHub, apply/test/e2e trên self-hosted runner vdt-vm)
```

Nhãn trên đối tượng `Cluster`: `security-baseline=enabled` (tool bảo mật), `lab-target=enabled` (vulnerable-workload),
`cni=calico` (Calico qua CRS, chỉ cho cluster chưa có CNI).

## Điều kiện

Đã làm Bước 0 của Guide 1 (SSD, Docker data-root, inotify) và có `docker kubectl kind helm clusterctl jq make`.
Mọi lệnh chạy trên VM, tại thư mục gốc repo, kubectl trỏ admin (`kind-kind`). Sau khi clone: `chmod +x scripts/*.sh workload/scan/*.sh workload/tests/*.sh`.

## Thứ tự deploy

```bash
# Guide 1 – Admin
kind create cluster --config 01-admin-cluster/kind-config.yaml
export CLUSTER_TOPOLOGY=true EXP_CLUSTER_RESOURCE_SET=true
clusterctl init --infrastructure docker --addon helm           # CAPI + CAPD + CAAPH
kubectl wait --for=condition=Available deploy --all -A --timeout=10m

helm repo add defectdojo https://raw.githubusercontent.com/DefectDojo/django-DefectDojo/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update
helm upgrade --install defectdojo defectdojo/defectdojo -n defectdojo --create-namespace \
  -f 05-admin-apps/defectdojo/values.yaml --wait --timeout 15m
helm upgrade --install loki grafana/loki -n logging --create-namespace -f 05-admin-apps/loki/values.yaml
export GRAFANA_PASS='<đặt-mật-khẩu>'
export DOJO_DB_PASS=$(kubectl -n defectdojo get secret defectdojo-postgresql-specific -o jsonpath='{.data.postgresql-password}' | base64 -d)
envsubst '${GRAFANA_PASS} ${DOJO_DB_PASS}' < 05-admin-apps/grafana/values.yaml.tpl \
  | helm upgrade --install grafana grafana/grafana -n monitoring --create-namespace -f -

docker compose -f 04-pg-target/compose.yaml up -d
source env.sh
DOJO_PASS=$(kubectl -n defectdojo get secret defectdojo -o jsonpath='{.data.DD_ADMIN_PASSWORD}' | base64 -d)
export DOJO_API_KEY=$(curl -sS -X POST "$DOJO_URL/api/v2/api-token-auth/" -H 'Content-Type: application/json' \
  -d "{\"username\":\"admin\",\"password\":\"$DOJO_PASS\"}" | jq -r .token)

# Orchestrator (header của file có đủ lệnh tạo secret; bước này tạo CronJob ở trạng thái suspend)
kubectl create ns scan-orchestrator --dry-run=client -o yaml | kubectl apply -f -
kubectl -n scan-orchestrator create secret generic dojo-api --from-literal=token="$DOJO_API_KEY" --dry-run=client -o yaml | kubectl apply -f -
kubectl -n scan-orchestrator create secret generic pg-target --from-literal=password=poc-weak-pass --dry-run=client -o yaml | kubectl apply -f -
sed "s|__PG_TARGET_IP__|${PG_TARGET_IP}|" 05-admin-apps/orchestrator/orchestrator.yaml | kubectl apply -f -

# Guide 2 – bật cơ chế tự cài, rồi bật CronJob
make addons
kubectl -n scan-orchestrator patch cronjob scan-orchestrator -p '{"spec":{"suspend":false}}'

# Cấp phát workload mới (tự có đủ tool)
make provision NAME=team-a
make verify CLUSTER=team-a
make test-runtime CLUSTER=team-a && make test-policy CLUSTER=team-a
make scan CLUSTER=team-a                                       # cần DOJO_API_KEY
```

### Đưa `capi-quickstart` (đã cài Calico/Falco/Talon bằng tay) vào cơ chế tự cài

```bash
make addons
source env.sh
hw uninstall falco-talon -n falco || true     # gỡ bản cài tay để CAAPH quản lý, tránh trùng release
hw uninstall falco -n falco || true
kubectl label cluster capi-quickstart security-baseline=enabled lab-target=enabled --overwrite   # KHÔNG gắn cni=calico
make verify CLUSTER=capi-quickstart
```

## Lưu ý

- **IP đổi sau khi resume Docker**: `source env.sh`, chạy lại `make addons` (CAAPH tự cập nhật địa chỉ Loki cho Sidekick),
  và nếu `PG_TARGET_IP` đổi thì chạy lại lệnh `sed ... | kubectl apply` của orchestrator.
- `workload/addons/10-hcp-falco.yaml` chứa `__LOKI_URL__`: `scripts/render.sh` thay bằng địa chỉ thật khi apply. Đừng `kubectl apply` trực tiếp file này.
- ClusterResourceSet dùng `addons.cluster.x-k8s.io/v1beta2` (cùng phiên bản với `Cluster`/`ClusterClass` trong repo này).
- Image `trivy`, `kube-bench`, `alpine/k8s`, chart Falco/Kyverno chưa pin version: nên pin trước khi demo (xem comment trong từng file).
- Policy Kyverno chỉ áp cho namespace có nhãn `policy=enforce` (mặc định `policy-lab`); `vuln-lab` cố ý không gắn để mục tiêu lab còn chạy được.
