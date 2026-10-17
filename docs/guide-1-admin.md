# Security Platform – Hướng dẫn 1/2: Admin cluster

Hướng dẫn này dựng **Admin cluster** (kind + Cluster API) và các dịch vụ trung tâm: DefectDojo, Loki, Grafana, Scan orchestrator. Các giải pháp chạy **bên trong workload cluster** (Trivy, kube-bench, Falco/Talon, Kyverno) và cơ chế tự cài khi cấp phát workload nằm ở **Hướng dẫn 2/2**.

| Thành phần (sơ đồ kiến trúc)                                           | Chạy ở           | Cách deploy        | Bước |
|------------------------------------------------------------------------|------------------|--------------------|------|
| Host: package, Docker (+ SSD data-root tùy chọn)                       | VM               | install-deps.sh    | 0    |
| CAPI controllers + CAPD + **CAAPH** (Helm add-on) + ClusterResourceSet | Admin (kind)     | `clusterctl init`  | 1    |
| DefectDojo                                                             | Admin            | Helm               | 2    |
| Loki                                                                   | Admin            | Helm               | 3    |
| Grafana + dashboard                                                    | Admin            | Helm + UI          | 4, 7 |
| Scan orchestrator (đa cluster)                                         | Admin            | CronJob            | 5    |

Luồng dữ liệu phía admin:

    clusterctl / Guide 2 ──► CAPI + CAPD ──► tạo workload cluster (container Docker)
    CAAPH + ClusterResourceSet ──► tự cài tool bảo mật vào workload có nhãn (Guide 2)
    Scan orchestrator (CronJob) ──► Job Trivy / kube-bench trong workload ──► DefectDojo
    Falcosidekick (workload) ──► Loki
    DefectDojo DB + Loki ──► Grafana

Quy ước: mọi lệnh chạy trên VM, thư mục `~/secplat`, `kubectl` mặc định trỏ admin cluster (context `kind-kind`). `kw`/`hw` là kubectl/helm trỏ một workload cluster, định nghĩa trong `env.sh` (Bước 1).

Thư mục trên VM (giống nhau ở mọi guide):

    ~/secplat/
    ├── env.sh                        # dùng chung cho mọi guide: source ~/secplat/env.sh
    ├── <cluster>.kubeconfig          # env.sh tự sinh, ví dụ capi-quickstart.kubeconfig
    ├── manual/                       # chỉ Deploy Guide v2 (làm tay)
    │   ├── manifests/
    │   └── fixtures/
    └── sec-platform/                 # repo clone, dùng cho Guide 1, Guide 2, make ...

**Chạy tự động cả Guide 1 bằng 1 lệnh** (sau khi đã clone repo ở Bước 0.1; script tự gọi `install-deps.sh` nếu thiếu lệnh, chạy lại bao nhiêu lần cũng được, log ở `~/secplat/deploy-admin.log`):

```bash
cd ~/secplat/sec-platform && git pull
bash scripts/deploy-admin.sh            # hoặc: make admin
# lần đầu nếu script báo phải SSH lại (nhóm docker): đăng xuất, SSH lại, chạy lại đúng lệnh trên
# cài lại sạch DefectDojo (xóa cả dữ liệu): bash scripts/deploy-admin.sh --reset-dojo
```

Script làm Bước 1 → 5, dựng sẵn dashboard Bước 7 và kiểm tra Bước 8, rồi in URL, mật khẩu và lệnh SSH tunnel. Còn lại làm tay: SSD (0.2, 0.4). Các bước dưới đây là bản làm tay tương đương.

---

## Bước 0 – Chuẩn bị host (repo, package, Docker, sysctl; SSD tùy chọn)

Làm **trước khi tạo bất kỳ cụm nào**. Toàn bộ node kind/CAPD, image và PVC đều nằm trong Docker data-root (mặc định `/var/lib/docker`). Nếu VM có ổ/phân vùng SSD riêng, đưa data-root lên SSD ngay từ đầu (0.2) sẽ nhanh hơn. VM chạy trên HDD hoặc chỉ có 1 ổ thì bỏ qua 0.2 và 0.4, giữ mặc định.

**0.1 Lấy repo** (VM sạch chỉ cần `git` để clone; mọi package khác do script ở 0.3 cài)

```bash
sudo apt-get update && sudo apt-get install -y git
mkdir -p ~/secplat && cd ~/secplat
git clone https://github.com/Acerchicken/Security-Platform-for-K8s.git sec-platform   # lần sau: cd sec-platform && git pull
```

**0.2 (Tùy chọn) Format + mount SSD**: chỉ khi VM có ổ/phân vùng SSD riêng; VM chạy trên HDD hoặc chỉ có 1 ổ thì bỏ qua 0.2 và 0.4. Kiểm tra kỹ tên thiết bị, `mkfs` XÓA sạch ổ.

```bash
lsblk -f                              # SSD chưa có FSTYPE/MOUNTPOINT, giả sử /dev/vdb
sudo mkfs.ext4 -L ssd-data /dev/vdb
sudo mkdir -p /mnt/ssd
echo "UUID=$(sudo blkid -s UUID -o value /dev/vdb) /mnt/ssd ext4 defaults,nofail 0 2" | sudo tee -a /etc/fstab
sudo mount -a && df -h /mnt/ssd
```

**0.3 Cài package** bằng `scripts/install-deps.sh` (Ubuntu/Debian, cần sudo). Mặc định Docker giữ data-root `/var/lib/docker`; chỉ khi đã làm 0.2 thì đặt `DOCKER_DATA_ROOT` để Docker cài xong là chạy thẳng trên SSD:

```bash
cd ~/secplat/sec-platform
bash scripts/install-deps.sh                                     # mặc định (HDD / 1 ổ)
# hoặc, chỉ khi đã mount SSD ở 0.2:
# DOCKER_DATA_ROOT=/mnt/ssd/docker bash scripts/install-deps.sh
# Script thêm user vào nhóm docker: đăng xuất rồi SSH lại (hoặc: newgrp docker), sau đó:
docker info | grep "Docker Root Dir"     # /var/lib/docker (mặc định) hoặc /mnt/ssd/docker (nếu làm 0.2)
bash scripts/install-deps.sh                                     # chạy lại: phải ra 0 FAIL
```

| Nhóm | Script cài / làm | Dùng ở |
|---|---|---|
| Gói apt | `git make jq curl ca-certificates gnupg coreutils gawk sed tar gzip gettext-base rsync util-linux e2fsprogs` | `envsubst` (gói `gettext-base`) cho values Grafana, `rsync` cho 0.4, `jq` cho API DefectDojo, `make` cho Guide 2 |
| Docker | `docker.io` + plugin `docker compose`, bật service, thêm user vào nhóm `docker`; ghi `data-root` vào `/etc/docker/daemon.json` (merge, giữ key khác) khi có `DOCKER_DATA_ROOT` | kind, CAPD |
| Kubernetes CLI | `kubectl` (stable), `kind` (latest), `helm` (script chính thức), `clusterctl` `v1.14.0` vào `/usr/local/bin` | Bước 1 trở đi |
| sysctl | `fs.inotify.max_user_watches=524288`, `max_user_instances=512` vào `/etc/sysctl.d/99-kind.conf` | nhiều node kind/CAPD trên 1 host |
| Tùy chọn | `WITH_LINT=1` thêm `shellcheck yamllint` | `make lint` |

Script chạy lại bao nhiêu lần cũng được: phần đã có thì bỏ qua. Ghim phiên bản qua biến môi trường, ví dụ `KUBECTL_VERSION=v1.36.1 KIND_VERSION=v0.31.0 bash scripts/install-deps.sh`. Có `make` rồi thì dùng `make deps`. Distro không dùng apt: cài tay các lệnh trong bảng.

**0.4 (Tùy chọn, chỉ khi dùng SSD ở 0.2) Docker đã chạy từ trước, còn dữ liệu ở `/var/lib/docker`**: script không tự chuyển dữ liệu (báo WARN), làm tay:

```bash
sudo systemctl stop docker docker.socket
sudo mkdir -p /mnt/ssd/docker
sudo rsync -aHAX /var/lib/docker/ /mnt/ssd/docker/
sudo jq '. + {"data-root": "/mnt/ssd/docker"}' /etc/docker/daemon.json 2>/dev/null > /tmp/daemon.json \
  || echo '{"data-root": "/mnt/ssd/docker"}' > /tmp/daemon.json
sudo mv /tmp/daemon.json /etc/docker/daemon.json
sudo systemctl start docker
docker info | grep "Docker Root Dir"                     # phải là /mnt/ssd/docker
sudo mv /var/lib/docker /var/lib/docker.bak              # xóa hẳn sau khi chạy ổn
```

Ghi chú: ổ chứa Docker data-root (kể cả SSD nếu dùng) phải là ext4/xfs (overlay2 không chạy trên NTFS/exFAT); nếu Docker cài bằng snap thì đường dẫn cấu hình khác; nếu đã chuyển sang SSD thì sau khi chạy cụm, `du -sh /var/lib/docker /var/lib/containerd` không được tăng. Cần tối thiểu ~16 GB RAM (`free -h`): DefectDojo tự nó đã request ~5 GB.

---

## Bước 1 – Admin cluster (kind) + CAPI, CAAPH, ClusterResourceSet

```bash
cd ~/secplat
clusterctl version          # v1.14.0, đã cài ở Bước 0.3

cat > kind-config.yaml <<'EOF'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
networking:
  ipFamily: dual
nodes:
- role: control-plane
  extraMounts:                     # BẮT BUỘC: để CAPD tạo được container node
    - hostPath: /var/run/docker.sock
      containerPath: /var/run/docker.sock
  extraPortMappings:               # tùy chọn: mở cổng ra VM; truy cập từ laptop dùng SSH tunnel nên không bắt buộc
    - {containerPort: 31080, hostPort: 31080, listenAddress: "0.0.0.0"}   # DefectDojo
    - {containerPort: 32000, hostPort: 32000, listenAddress: "0.0.0.0"}   # Grafana
    - {containerPort: 31100, hostPort: 31100, listenAddress: "0.0.0.0"}   # Loki
EOF
kind create cluster --config kind-config.yaml

export CLUSTER_TOPOLOGY=true
export EXP_CLUSTER_RESOURCE_SET=true          # bật ClusterResourceSet (mặc định đã bật ở các bản CAPI gần đây)
clusterctl init --infrastructure docker --addon helm
kubectl get pods -A        # capi-*, capd-system, caaph-system, cert-manager: Running
```

`--addon helm` cài **Cluster API Add-on Provider for Helm (CAAPH)**: controller ở admin tự `helm install` chart vào mọi workload cluster khớp nhãn (đối tượng `HelmChartProxy`). Đây là nền cho việc tự cài tool ở Guide 2.

**Admin cluster đã có từ trước** (đã chạy `clusterctl init --infrastructure docker`): chỉ cần bổ sung CAAPH:

```bash
clusterctl init --addon helm
kubectl -n caaph-system get pods                                   # caaph-controller-manager Running
kubectl get crd helmchartproxies.addons.cluster.x-k8s.io clusterresourcesets.addons.cluster.x-k8s.io
kubectl -n capi-system get deploy capi-controller-manager \
  -o jsonpath='{.spec.template.spec.containers[0].args}' | grep -o 'ClusterResourceSet=[a-z]*'   # phải là ClusterResourceSet=true
```

Nếu ra `ClusterResourceSet=false`: `kubectl -n capi-system edit deploy capi-controller-manager`, sửa trong arg `--feature-gates` thành `ClusterResourceSet=true`.

`env.sh` (source lại **mỗi lần** mở terminal mới hoặc sau khi resume Docker, vì IP container có thể đổi):

```bash
cat > ~/secplat/env.sh <<'EOF'
export ADMIN_NODE_IP=$(docker inspect -f '{{(index .NetworkSettings.Networks "kind").IPAddress}}' kind-control-plane)
export DOJO_URL=http://$ADMIN_NODE_IP:31080
export LOKI_URL=http://$ADMIN_NODE_IP:31100
export CLUSTER=${CLUSTER:-capi-quickstart}                 # workload đang thao tác; đổi: CLUSTER=team-a source ~/secplat/env.sh
export WORKLOAD_KUBECONFIG="$HOME/secplat/$CLUSTER.kubeconfig"
clusterctl get kubeconfig "$CLUSTER" > "$WORKLOAD_KUBECONFIG" 2>/dev/null || true
kw() { kubectl --kubeconfig="$WORKLOAD_KUBECONFIG" "$@"; }
hw() { helm --kubeconfig="$WORKLOAD_KUBECONFIG" "$@"; }
EOF
source ~/secplat/env.sh
```

---

## Bước 2 – DefectDojo (gỡ bản cũ, cài lại sạch)

Thiết kế truy cập: DefectDojo chạy NodePort **31080** trên node kind. Không phụ thuộc `extraPortMappings` hay port-forward: các lệnh trên VM dùng `http://<IP node kind>:31080`, còn laptop mở browser qua **SSH tunnel** (xem Bước 6). PVC nằm trong node kind nên nằm trong Docker data-root (trên SSD nếu đã làm 0.2).

**a) Gỡ bản cũ**

```bash
pkill -f "port-forward.*defectdojo" 2>/dev/null || true     # dọn port-forward còn treo (đang giữ cổng 8080)
helm uninstall defectdojo -n defectdojo 2>/dev/null || true
kubectl delete pvc --all -n defectdojo --ignore-not-found
kubectl delete ns defectdojo --ignore-not-found --wait=true
```

**b) Cài mới**

```bash
cd ~/secplat && source ~/secplat/env.sh      # cần ADMIN_NODE_IP

cat > defectdojo-value.yaml <<'EOV'
host: localhost
alternativeHosts: ["*"]        # lab: cho phép truy cập qua IP node và tunnel (tránh lỗi "Invalid HTTP_HOST header")

admin:
  username: "admin"
  password: "AdminDojoPassword123!"      # chỉ dùng cho lab, đổi nếu mở ra ngoài

django:
  nodePort: 31080              # CHÚ Ý: chart đọc django.nodePort; django.service.nodePort bị bỏ qua (nên trước đây svc ra cổng ngẫu nhiên 31700)
  ingress:
    enabled: false
  service:
    type: NodePort
  livenessProbe:
    initialDelaySeconds: 180
    periodSeconds: 15
    timeoutSeconds: 5
    failureThreshold: 10
  readinessProbe:
    initialDelaySeconds: 120
    periodSeconds: 10
    timeoutSeconds: 5
    failureThreshold: 10

  uwsgi:
    resources:
      requests:
        cpu: 200m
        memory: 1500Mi
      limits:
        memory: 3Gi
    appSettings:
      maxFd: 102400
      processes: 1
      threads: 2
    livenessProbe:
      initialDelaySeconds: 180
      periodSeconds: 15
      failureThreshold: 10
    readinessProbe:
      initialDelaySeconds: 120
      periodSeconds: 10
      failureThreshold: 10

  nginx:
    resources:
      requests:
        cpu: 100m
        memory: 1028Mi
      limits:
        memory: 2056Mi

postgresql:
  enabled: true
  primary:
    persistence:
      size: 5Gi

celery:
  beat:
    resources:
      limits:
        memory: 2512Mi
      requests:
        cpu: 100m
        memory: 256Mi
  worker:
    replicas: 1
    resources:
      limits:
        memory: 2536Mi
      requests:
        cpu: 200m
        memory: 512Mi
EOV

helm repo add defectdojo https://raw.githubusercontent.com/DefectDojo/django-DefectDojo/helm-charts
helm repo update
helm install defectdojo defectdojo/defectdojo -n defectdojo --create-namespace \
  -f defectdojo-value.yaml \
  --set createSecret=true --set createValkeySecret=true --set createPostgresqlSecret=true \
  --wait --timeout 15m

kubectl -n defectdojo get pods       # initializer Completed, django/celery Running
kubectl -n defectdojo get svc defectdojo-django     # PORT(S) phải là 80:31080/TCP
```

Nếu cột PORT(S) không phải `80:31080`, ép lại (key trong values khác nhau giữa các phiên bản chart):

```bash
kubectl -n defectdojo patch svc defectdojo-django --type=json \
  -p='[{"op":"replace","path":"/spec/type","value":"NodePort"},{"op":"replace","path":"/spec/ports/0/nodePort","value":31080}]'
```

**c) Kiểm tra từ VM**

```bash
export DOJO_URL=http://$ADMIN_NODE_IP:31080
curl -s -o /dev/null -w "%{http_code}\n" $DOJO_URL/login      # 200 (hoặc 302)
```

**d) Truy cập từ laptop**: mở SSH tunnel theo Bước 6, rồi vào `http://127.0.0.1:18080`, đăng nhập `admin` với mật khẩu ở mục e).

**e) Mật khẩu admin và API key**

Mật khẩu admin lấy từ secret (trùng `admin.password` trong values, hoặc do chart sinh nếu bạn bỏ khai báo):

```bash
export DOJO_PASS=$(kubectl -n defectdojo get secret defectdojo -o jsonpath='{.data.DD_ADMIN_PASSWORD}' | base64 -d)
echo "$DOJO_PASS"        # dùng để đăng nhập UI, không dán vào tài liệu

curl -sS -X POST "$DOJO_URL/api/v2/api-token-auth/" \
  -H 'Content-Type: application/json' \
  -d "{\"username\":\"admin\",\"password\":\"$DOJO_PASS\"}"
# thành công: {"token":"..."}

export DOJO_API_KEY=$(curl -sS -X POST "$DOJO_URL/api/v2/api-token-auth/" \
  -H 'Content-Type: application/json' \
  -d "{\"username\":\"admin\",\"password\":\"$DOJO_PASS\"}" | jq -r .token)
echo "${DOJO_API_KEY:0:6}..."
```

Nếu lỗi:

- `Connection refused` hoặc `000`: sai IP/cổng. Kiểm tra `kubectl -n defectdojo get svc` (phải `80:31080`) và `echo $ADMIN_NODE_IP`.
- `400 Invalid HTTP_HOST header`: thiếu `alternativeHosts`. Thêm vào values rồi `helm upgrade ... -f defectdojo-value.yaml`.
- `Unable to log in with provided credentials`: dùng đúng mật khẩu lấy từ secret ở trên.
- `502/503`: pod django chưa Ready, đợi thêm (`kubectl -n defectdojo get pods`).
- Token rỗng hoặc `null`: thiếu `jq` hoặc phản hồi không phải JSON.

Các bước sau dùng `$DOJO_URL` và `$DOJO_API_KEY` (orchestrator ở Bước 5 và `make scan` ở Guide 2). `env.sh` đã đặt `DOJO_URL`; `DOJO_API_KEY` cần export lại mỗi terminal mới.

---

## Bước 3 – Loki (single binary, lưu filesystem)

```bash
helm repo add grafana https://grafana.github.io/helm-charts && helm repo update
cat > loki-values.yaml <<'EOF'
deploymentMode: SingleBinary
loki:
  auth_enabled: false
  commonConfig: {replication_factor: 1}
  storage: {type: filesystem}
  schemaConfig:
    configs:
      - from: "2024-04-01"
        store: tsdb
        object_store: filesystem
        schema: v13
        index: {prefix: loki_index_, period: 24h}
singleBinary: {replicas: 1, persistence: {size: 10Gi}}
read: {replicas: 0}
write: {replicas: 0}
backend: {replicas: 0}
chunksCache: {enabled: false}
resultsCache: {enabled: false}
lokiCanary: {enabled: false}
test: {enabled: false}
gateway:
  service: {type: NodePort, nodePort: 31100}    # Workload cluster push log vào đây
EOF
helm install loki grafana/loki -n logging --create-namespace -f loki-values.yaml
curl -s http://$ADMIN_NODE_IP:31100/loki/api/v1/labels    # {"status":"success",...} (gateway không route /ready, 404 ở /ready là bình thường)
```

Falcosidekick trong mọi workload sẽ đẩy alert vào `$LOKI_URL` (= `http://<ADMIN_NODE_IP>:31100`). Guide 2 tự điền địa chỉ này khi chạy `make addons`.

---

## Bước 4 – Grafana (datasource: Loki + DefectDojo DB)

```bash
export GRAFANA_PASS='<đặt-mật-khẩu>'
# tên secret có thể khác: kubectl -n defectdojo get secret
export DOJO_DB_PASS=$(kubectl -n defectdojo get secret defectdojo-postgresql-specific -o jsonpath='{.data.postgresql-password}' | base64 -d)

cat > grafana-values.yaml <<EOF
adminPassword: "${GRAFANA_PASS}"
service: {type: NodePort, nodePort: 32000}
datasources:
  datasources.yaml:
    apiVersion: 1
    datasources:
    - name: Loki
      type: loki
      access: proxy
      url: http://loki-gateway.logging.svc.cluster.local
    - name: DefectDojo
      type: postgres
      url: defectdojo-postgresql.defectdojo.svc.cluster.local:5432
      user: defectdojo
      secureJsonData: {password: "${DOJO_DB_PASS}"}
      jsonData: {database: defectdojo, sslmode: disable, postgresVersion: 1500}
EOF
helm install grafana grafana/grafana -n monitoring --create-namespace -f grafana-values.yaml
```

Truy cập qua SSH tunnel (xem Bước 6): `http://localhost:3000` (user `admin`). Kiểm tra Connections → Data sources → *Save & test* cả hai datasource.

---

## Bước 5 – Scan orchestrator (đa cluster)

Orchestrator là CronJob ở admin. Mỗi lần chạy, nó **tự liệt kê mọi workload cluster có nhãn `security-baseline=enabled`**, lấy kubeconfig từ secret `<cluster>-kubeconfig` do CAPI tạo, rồi chạy `run-scans.sh` (Trivy, kube-bench) và reimport vào DefectDojo, mỗi cluster là một Product. Workload mới cấp phát được scan ở lần chạy kế tiếp mà không cần sửa gì.

Script scan (`run-scans.sh` và template Job) thuộc phần workload nên nằm ở Guide 2. Guide 2 nạp chúng vào ConfigMap `scan-orchestrator/scan-scripts` khi chạy `make addons`. Vì vậy CronJob ở đây tạo với `suspend: true`; Guide 2 (mục 2.3) bật nó lên.

```bash
source ~/secplat/env.sh
: "${DOJO_API_KEY:?export DOJO_API_KEY trước (Bước 2e)}"

kubectl create ns scan-orchestrator --dry-run=client -o yaml | kubectl apply -f -
kubectl -n scan-orchestrator create secret generic dojo-api --from-literal=token="$DOJO_API_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -
# dọn bản orchestrator 1 cluster cũ (nếu từng làm theo guide v2)
kubectl -n scan-orchestrator delete secret workload-kubeconfig --ignore-not-found
kubectl -n scan-orchestrator delete configmap orchestrator-script --ignore-not-found

cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata: {name: orchestrator, namespace: scan-orchestrator}
---
# Quyền tối thiểu: đọc Cluster và secret kubeconfig trong namespace default (nơi chứa các Cluster CAPI)
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: {name: scan-orchestrator-read, namespace: default}
rules:
- apiGroups: ["cluster.x-k8s.io"]
  resources: ["clusters"]
  verbs: ["get", "list"]
- apiGroups: [""]
  resources: ["secrets"]
  verbs: ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: {name: scan-orchestrator-read, namespace: default}
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: Role, name: scan-orchestrator-read}
subjects:
- {kind: ServiceAccount, name: orchestrator, namespace: scan-orchestrator}
---
apiVersion: batch/v1
kind: CronJob
metadata: {name: scan-orchestrator, namespace: scan-orchestrator}
spec:
  schedule: "0 */6 * * *"
  suspend: true                      # Guide 2 mục 2.3 bật lên sau khi có ConfigMap scan-scripts
  concurrencyPolicy: Forbid
  jobTemplate:
    spec:
      backoffLimit: 0
      template:
        spec:
          serviceAccountName: orchestrator
          restartPolicy: Never
          containers:
          - name: orchestrator
            image: alpine/k8s:1.31.2     # cần bash, kubectl, curl, jq; pin tag đã kiểm chứng
            command: ["bash", "-c"]
            args:
            - |
              set -euo pipefail
              clusters=$(kubectl -n default get clusters -l security-baseline=enabled -o jsonpath='{.items[*].metadata.name}')
              [ -n "$clusters" ] || { echo "không có cluster nào gắn nhãn security-baseline=enabled"; exit 0; }
              rc=0
              for c in $clusters; do
                echo "===== $c"
                kubectl -n default get secret "$c-kubeconfig" -o jsonpath='{.data.value}' | base64 -d > "/tmp/$c.kubeconfig"
                bash /scripts/run-scans.sh "/tmp/$c.kubeconfig" "$c" || rc=1
              done
              exit $rc
            env:
            - {name: DOJO_URL, value: "http://defectdojo-django.defectdojo.svc.cluster.local"}
            - name: DOJO_API_KEY
              valueFrom: {secretKeyRef: {name: dojo-api, key: token}}
            volumeMounts:
            - {name: scripts, mountPath: /scripts}
          volumes:
          - name: scripts
            configMap: {name: scan-scripts, optional: true}
EOF
kubectl -n scan-orchestrator get cronjob scan-orchestrator      # SUSPEND = True
```

Ghi chú:

- Cluster CAPI đặt ở namespace khác `default` thì thêm Role/RoleBinding tương tự cho namespace đó và sửa `-n default` trong script.
- Pod orchestrator gọi API server của workload qua địa chỉ trong kubeconfig CAPD (IP container trên mạng `kind`), đi được từ pod trong kind.
- PoC dùng kubeconfig admin của từng workload. Bản production nên cấp ServiceAccount riêng, quyền hẹp trong workload.

---

## Bước 6 – Truy cập UI từ laptop (SSH tunnel)

Các NodePort (DefectDojo 31080, Grafana 32000, Loki 31100) nằm trên IP container của node kind, chỉ đi được từ trong VM. Chạy trên **laptop**, giữ cửa sổ mở:

```bash
# <ADMIN_NODE_IP>: lấy bằng `source ~/secplat/env.sh; echo $ADMIN_NODE_IP` trên VM (thường 172.18.0.x)
ssh -N -o ExitOnForwardFailure=yes \
  -L 18080:<ADMIN_NODE_IP>:31080 \
  -L 13000:<ADMIN_NODE_IP>:32000 \
  duong@<IP_VM>
# DefectDojo: http://127.0.0.1:18080   Grafana: http://127.0.0.1:13000
```

- Đích forward phải là `<ADMIN_NODE_IP>`, không phải `localhost` (VM không có gì ở `localhost:31080` khi kind không map cổng).
- `bind ... Permission denied` trên laptop (thường gặp trên Windows do dải cổng bị reserve): đổi cổng local khác. Xem dải bị reserve: `netsh interface ipv4 show excludedportrange protocol=tcp`.
- Dùng `127.0.0.1` thay `localhost` để browser không thử IPv6 trước.
- IP node có thể đổi sau khi resume Docker: lấy lại rồi mở tunnel lại.

---

## Bước 7 – Grafana dashboard tổng hợp

Dashboard này đã có sẵn trong repo (`05-admin-apps/grafana/dashboards/secplat-overview.json`): `deploy-admin.sh` nạp nó vào ConfigMap `monitoring/secplat-dashboards` (nhãn `grafana_dashboard=1`), sidecar của Grafana tự import, mở Dashboards → *Security Platform Overview*. Làm tay theo các bước dưới chỉ khi muốn dựng lại từ đầu. Sửa trên UI xong thì *Export → JSON* đè vào file đó để lần deploy sau giữ được.

Dashboards → New → Add visualization. Màu severity: Critical `#E02F44`, High `#FF780A`, Medium `#FAAD14`, Low `#56A64B`.

**Datasource DefectDojo (PostgreSQL, Format as: Table)**

1.  *Open findings by severity* (Pie chart, Donut):

    ``` sql
    SELECT severity, count(*) AS value FROM dojo_finding
    WHERE active AND NOT is_mitigated AND NOT duplicate AND NOT false_p GROUP BY severity
    ```

2.  *Findings by product / severity* (Bar gauge, Horizontal):

    ``` sql
    SELECT p.name AS product, f.severity, count(*) AS value
    FROM dojo_finding f JOIN dojo_test t ON f.test_id = t.id
    JOIN dojo_engagement e ON t.engagement_id = e.id JOIN dojo_product p ON e.product_id = p.id
    WHERE f.active AND NOT f.is_mitigated GROUP BY 1, 2
    ```

3.  *Critical open* (Stat, Color mode Background, Thresholds: Green → Red từ 1):

    ``` sql
    SELECT count(*) FROM dojo_finding WHERE severity = 'Critical' AND active AND NOT is_mitigated
    ```

4.  *Finding lifecycle* (Time series, Format as: Time series):

    ``` sql
    SELECT $__timeGroup(created, '1d') AS time, count(*) AS "new" FROM dojo_finding WHERE $__timeFilter(created) GROUP BY 1 ORDER BY 1
    ```

**Datasource Loki**

5.  *Runtime violations over time* (Time series):

        sum by (rule, priority) (count_over_time({rule=~".+"}[$__interval]))

6.  *Falco alerts* (Logs): `{rule=~".+"}`

Auto-refresh 5s, Save dashboard. Tên bảng/cột DefectDojo có thể đổi theo phiên bản: kiểm tra bằng `\d dojo_finding` nếu query lỗi.

Mỗi workload là một Product trong DefectDojo (tên = tên cluster), nên panel 2 tách được theo cluster. Panel Loki lọc theo cluster bằng nhãn `target_id` (Falcosidekick gắn tự động): `{target_id="team-a"}`.

---

## Bước 8 – Kiểm tra admin và bàn giao cho Guide 2

```bash
source ~/secplat/env.sh
kubectl -n caaph-system get pods                                          # Running
curl -s -o /dev/null -w "DefectDojo %{http_code}\n" $DOJO_URL/login       # 200/302
curl -s $LOKI_URL/loki/api/v1/labels | jq -r .status                      # success
kubectl -n monitoring get pods                                            # grafana Running
kubectl -n scan-orchestrator get cronjob scan-orchestrator                # tồn tại, SUSPEND=True
echo "ADMIN_NODE_IP=$ADMIN_NODE_IP DOJO_API_KEY=${DOJO_API_KEY:0:6}..."
```

| Guide 2 cần                                 | Lấy từ | Dùng vào                                       |
|---------------------------------------------|--------|------------------------------------------------|
| CAAPH + ClusterResourceSet                  | Bước 1 | Tự cài tool khi cấp phát workload              |
| `LOKI_URL` = `http://<ADMIN_NODE_IP>:31100` | Bước 3 | Falcosidekick (điền tự động bởi `make addons`) |
| `DOJO_URL`, `DOJO_API_KEY`                  | Bước 2 | `make scan`; CronJob đọc secret `dojo-api`     |
| CronJob `scan-orchestrator` (đang suspend)  | Bước 5 | Guide 2 bật lên                                |

---

## Dừng / tiếp tục / dọn dẹp

```bash
# Dọn hoàn toàn (khuyến nghị, đúng tài liệu CAPI): xóa object cluster, KHÔNG xóa bằng file yaml
kubectl delete cluster --all -n default
kind delete cluster

# Tạm dừng: chỉ dừng container của kind/CAPD, không đụng container khác
docker stop $(docker ps -q --filter "label=io.x-k8s.kind.cluster")
# Tiếp tục: bật admin trước, workload sau, rồi nạp lại IP
docker start kind-control-plane
sleep 30 && docker start $(docker ps -aq --filter "label=io.x-k8s.kind.cluster" --filter "status=exited")
source ~/secplat/env.sh
```

Sau khi resume, IP container có thể đổi. Nếu `ADMIN_NODE_IP` đổi: chạy lại `make addons` (Guide 2), CAAPH tự cập nhật địa chỉ Loki cho Falcosidekick ở mọi workload.

---

## Phụ lục A – Khôi phục CAPD controller (webhook lỗi/kẹt)

Chạy trên Admin cluster (không dùng `--kubeconfig`):

```bash
kubectl get pods -n capd-system                       # CrashLoopBackOff / OOMKilled / Error?
kubectl rollout restart deployment capd-controller-manager -n capd-system
kubectl rollout status deployment capd-controller-manager -n capd-system --timeout=60s
docker ps -a --filter "label=io.x-k8s.kind.cluster=capi-quickstart"    # Exited thì docker start lại
```

