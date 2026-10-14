# Security Platform – Hướng dẫn 2/2: Giải pháp bảo mật trên Workload cluster (tự cài khi cấp phát)

Điều kiện: đã xong **Hướng dẫn 1/2** (admin cluster có CAPI + CAAPH + ClusterResourceSet, DefectDojo, Loki, Grafana, CronJob orchestrator đang suspend).

Guide này không `helm install` tay vào từng workload nữa. Toàn bộ tool được khai báo một lần ở admin. **Workload nào được cấp phát với nhãn `security-baseline=enabled` sẽ tự có đủ tool**, và CI chạy kịch bản test để chứng minh điều đó.

---

## 0. Bốn giải pháp và cách chúng đến workload

| Trụ cột                      | Công cụ                                                             | Chạy trong workload              | Kết quả                           | Ai cài / kích hoạt                  |
|------------------------------|---------------------------------------------------------------------|----------------------------------|-----------------------------------|-------------------------------------|
| Image & Static analysis      | Trivy `image` (vuln + secret); Trivy `config` cho manifest trong CI | Job ở `security-scan`            | DefectDojo                        | CronJob orchestrator (admin)        |
| Cấu hình cụm theo CIS        | kube-bench `--targets node`                                         | Job ở `security-scan`            | DefectDojo                        | CronJob orchestrator                |
| Sec runtime                  | Falco + Falcosidekick + Falco-Talon                                 | DaemonSet + Deployment ở `falco` | Loki/Grafana + phản ứng tự động   | HelmChartProxy (CAAPH)              |
| **Policy enforcement (mới)** | Kyverno + 3 ValidatingPolicy (CEL)                                  | Admission webhook ở `kyverno`    | Chặn ngay khi apply, PolicyReport | HelmChartProxy + ClusterResourceSet |

    admin cluster                                                    workload cluster mới
    ─────────────                                                    ────────────────────
    make provision NAME=team-a ─► Cluster (nhãn security-baseline=enabled, cni=calico, lab-target=enabled)
                                       │
    ClusterResourceSet secplat-calico ─────┼──────────────────────────► Calico (node Ready)
    HelmChartProxy secplat-falco ──────────┼──────────────────────────► Falco + Falcosidekick ──► Loki (admin)
    HelmChartProxy secplat-falco-talon ────┼──────────────────────────► Falco-Talon (nhận webhook từ Sidekick)
    HelmChartProxy secplat-kyverno ────────┼──────────────────────────► Kyverno
    ClusterResourceSet secplat-security-baseline ─────────────────────► namespace, NetworkPolicy, ValidatingPolicy
    ClusterResourceSet secplat-lab-target ────────────────────────────► vulnerable-workload (mục tiêu lab)
    CronJob scan-orchestrator ── mỗi 6h liệt kê cluster có nhãn ──► Job Trivy / kube-bench ──► DefectDojo

| Nhãn trên đối tượng `Cluster` | Kích hoạt                                                                                                |
|-------------------------------|----------------------------------------------------------------------------------------------------------|
| `security-baseline=enabled`   | Falco, Sidekick, Talon, Kyverno, namespace, NetworkPolicy, ValidatingPolicy; orchestrator đưa vào lịch scan |
| `cni=calico`                  | Calico VXLAN (chỉ gắn cho cluster **chưa** có CNI)                                                       |
| `lab-target=enabled`          | Deployment `vulnerable-workload` trong `vuln-lab` (mục tiêu cho scan và kịch bản runtime)                |

---

## 1. Chuẩn bị repo (một lần)

Toàn bộ file nằm trong [repo GitHub](https://github.com/Acerchicken/Security-Platform-for-K8s) (public). VM, CI và mọi lần cấp phát đều lấy cấu hình từ repo này, nên mọi thay đổi chỉ cần commit + push; CI (mục 7) tự đồng bộ xuống admin cluster. Cấu trúc phần dùng cho guide này:

    sec-platform/
    ├── Makefile                         # make deps | preflight | addons | provision | verify | scan | test-* | e2e
    ├── env.example                      # copy thành .env nếu cần ghi đè
    ├── scripts/
    │   ├── install-deps.sh              # cài package/binary trên VM (dùng chung với Guide 1, Bước 0.3)
    │   ├── preflight.sh                 # kiểm tra VM + admin cluster (--install gọi install-deps.sh)
    │   ├── lib.sh                       # hàm dùng chung (kw, use_cluster, wait_for)
    │   ├── render.sh                    # nạp ConfigMap + apply HelmChartProxy/CRS lên admin
    │   ├── provision-cluster.sh         # cấp phát workload + gắn nhãn
    │   └── scan-now.sh                  # chạy scan ngay từ VM
    ├── workload/
    │   ├── addons/                      # đối tượng ở ADMIN: HelmChartProxy, ClusterResourceSet
    │   ├── manifests/                   # manifest CRS apply XUỐNG workload
    │   ├── scan/                        # run-scans.sh + template Job (orchestrator mount qua ConfigMap)
    │   └── tests/                       # verify, runtime-tests, policy-tests, e2e, fixtures
    └── .github/workflows/baseline.yml   # CI

Đã làm Guide 1, Bước 0.1 thì repo đã có ở `~/secplat/sec-platform`: chỉ cần `cd ~/secplat/sec-platform && git pull`. VM khác (chưa có repo):

```bash
sudo apt-get update && sudo apt-get install -y git           # chỉ cần git để clone; phần còn lại do install-deps.sh cài
mkdir -p ~/secplat && cd ~/secplat
git clone https://github.com/Acerchicken/Security-Platform-for-K8s.git sec-platform   # lần sau: cd sec-platform && git pull
cd sec-platform
chmod +x scripts/*.sh workload/scan/*.sh workload/tests/*.sh     # phòng khi clone mất quyền thực thi
```

### 1.1 Kiểm tra và cài phụ thuộc

VM mới (hoặc vừa dựng lại) thường thiếu `make`, `jq`, `clusterctl`... `scripts/preflight.sh` chạy bằng `bash` nên dùng được cả khi chưa có `make`. `--install` gọi `scripts/install-deps.sh`, cùng script đã dùng ở Guide 1, Bước 0.3, nên nếu đã làm Guide 1 thì thường chỉ cần chạy phần kiểm tra:

```bash
bash scripts/preflight.sh --install  # = bash scripts/install-deps.sh rồi kiểm tra (apt + /usr/local/bin, cần sudo)
bash scripts/preflight.sh            # chỉ kiểm tra; phải ra "0 FAIL" (WARN được phép)
kubectl config current-context       # phải là kind-kind (admin)
make help                            # từ giờ dùng được make; kiểm tra lại bất cứ lúc nào: make preflight
```

| Nhóm             | Kiểm tra                                                                                                    | `--install` tự xử lý                                                                       |
|------------------|-------------------------------------------------------------------------------------------------------------|--------------------------------------------------------------------------------------------|
| Lệnh trên VM     | `make` (GNU ≥ 3.82), `git`, `jq`, `curl`, `awk`, `sed`, `base64`, `tar`, `envsubst`, `md5sum`, `timeout`, `docker`, `kubectl`, `kind`, `helm`, `clusterctl`; `shellcheck`/`yamllint` (WARN, chỉ cho `make lint`) | `install-deps.sh`: cài qua apt (`envsubst` từ gói `gettext-base`); `kubectl` (stable), `kind` (latest), `helm` (script chính thức), `clusterctl` v1.14.0 vào `/usr/local/bin` |
| Docker           | daemon chạy, user hiện tại dùng được không cần `sudo`                                                       | `docker.io` + `docker compose` qua apt, bật service, thêm user vào nhóm `docker` (đăng nhập lại sau đó) |
| Host             | kernel ≥ 5.8 và có BTF (`/sys/kernel/btf/vmlinux`) cho Falco `modern_ebpf`; inotify; RAM tổng/trống; dung lượng Docker root | Ghi sysctl inotify như Guide 1, Bước 0.3. Kernel/RAM/ổ đĩa phải xử lý tay                  |
| Admin cluster    | context `kind-kind`, container `kind-control-plane`; CRD + controller CAPI, CAPD, CAAPH, cert-manager; ClusterResourceSet bật; ClusterClass `quick-start`; CronJob orchestrator; Loki `:31100`, DefectDojo `:31080` | Không tự cài: làm lại bước tương ứng ở Guide 1 (thông báo FAIL ghi rõ bước)                |
| Mạng ra ngoài    | Kết nối tới Helm repo Falco (`falcosecurity.github.io/charts`), Kyverno (`kyverno.github.io/kyverno`), `raw.githubusercontent.com`, Docker Hub (`registry-1.docker.io`); không phản hồi (HTTP `000`) là FAIL | Không tự sửa: kiểm tra proxy/firewall/DNS của VM. CAAPH và node CAPD pull chart/image qua mạng này khi cấp phát |

Phiên bản có thể ghim qua biến môi trường: `KUBECTL_VERSION=v1.36.1 KIND_VERSION=v0.31.0 bash scripts/preflight.sh --install` (biến được truyền xuống `install-deps.sh`). Tự cài chỉ hỗ trợ Ubuntu/Debian; distro khác cài tay các lệnh bị FAIL rồi chạy lại phần kiểm tra.

Workload cluster cấp phát qua CAPD là container trên chính VM này, nên không cần cài gì vào workload: preflight đạt thì `make provision` + CAAPH/ClusterResourceSet lo phần còn lại, và `make verify` (mục 3) kiểm tra workload đã đủ tool.

Script tự tính `ADMIN_NODE_IP` (từ container `kind-control-plane`) và `LOKI_URL`. Chỉ cần `.env` khi muốn ghi đè:

`env.example`

```bash
# Sao chép thành .env (KHÔNG commit) rồi sửa nếu cần. Dòng bị comment = tự tính.
CLUSTER_NS=default
CLUSTER_NAME=capi-quickstart
K8S_VERSION=v1.36.1
ADMIN_CONTAINER=kind-control-plane
# ADMIN_NODE_IP=172.18.0.2
# LOKI_URL=http://172.18.0.2:31100
# DOJO_URL=http://172.18.0.2:31080
# DOJO_API_KEY=
```

---

## 2. Bật cơ chế tự cài (một lần, và mỗi khi đổi cấu hình)

### 2.1 Chạy

```bash
make addons
kubectl get helmchartproxies,clusterresourcesets       # secplat-falco, secplat-falco-talon, secplat-kyverno, secplat-calico, secplat-security-baseline, secplat-lab-target
```

`make addons` (`scripts/render.sh`) làm 4 việc, chạy lại bao nhiêu lần cũng được:

1.  Tải `calico.yaml` (v3.29.1), vá VXLAN y như bản đã chạy ổn ở `capi-quickstart`, nạp vào ConfigMap `calico-vxlan`.
2.  Nạp các file `workload/manifests/*.yaml` vào ConfigMap cho ClusterResourceSet.
3.  Nạp `workload/scan/` vào ConfigMap `scan-orchestrator/scan-scripts` (CronJob ở Guide 1 mount vào).
4.  Thay `__LOKI_URL__` bằng địa chỉ Loki thật rồi apply `workload/addons/*.yaml`.

### 2.2 Các đối tượng ở admin

HelmChartProxy là "chart X, values Y, cài vào mọi cluster có nhãn Z". `{{ .Cluster.metadata.name }}` được CAAPH thay bằng tên từng cluster, nên alert trong Loki mang nhãn `target_id=<cluster>`. Webhook sang Talon được khai báo **ngay từ đầu** (lỗi thiếu webhook ở bản cài tay trước đây không còn xảy ra; `verify.sh` cũng kiểm tra điều này).

`workload/addons/10-hcp-falco.yaml`

```yaml
# Sec runtime: Falco (DaemonSet) + Falcosidekick (fan-out Loki + Talon).
# __LOKI_URL__ được scripts/render.sh thay bằng http://<ADMIN_NODE_IP>:31100
apiVersion: addons.cluster.x-k8s.io/v1alpha1
kind: HelmChartProxy
metadata:
  name: secplat-falco
spec:
  clusterSelector:
    matchLabels:
      security-baseline: enabled
  repoURL: https://falcosecurity.github.io/charts
  chartName: falco
  # version: "x.y.z"   # pin sau khi chạy ổn: helm search repo falcosecurity/falco --versions
  releaseName: falco
  namespace: falco
  reconcileStrategy: Continuous
  options:
    wait: true
    timeout: 10m
    install:
      createNamespace: true
  valuesTemplate: |
    driver:
      kind: modern_ebpf
    tty: true
    customRules:
      secplat-rules.yaml: |-
        - rule: Miner Binary Executed
          desc: Simulated crypto-miner binary (named xmrig) executed inside a container (PoC)
          condition: spawned_process and container and proc.name = xmrig
          output: Miner binary executed (proc=%proc.name cmdline=%proc.cmdline pod=%k8s.pod.name ns=%k8s.ns.name image=%container.image.repository)
          priority: CRITICAL
          tags: [secplat, poc, mitre_execution]
    falcosidekick:
      enabled: true
      webui:
        enabled: false
      config:
        customfields: "tenant_id:tenant-poc,target_id:{{ .Cluster.metadata.name }}"
        loki:
          hostport: "__LOKI_URL__"
          minimumpriority: "notice"
          extralabels: "tenant_id,target_id"
        webhook:
          address: "http://falco-talon:2803"
          minimumpriority: "notice"
```

`workload/addons/11-hcp-falco-talon.yaml`

```yaml
# Sec runtime: Falco-Talon (phản ứng tự động). Rule chỉ áp cho namespace vuln-lab.
apiVersion: addons.cluster.x-k8s.io/v1alpha1
kind: HelmChartProxy
metadata:
  name: secplat-falco-talon
spec:
  clusterSelector:
    matchLabels:
      security-baseline: enabled
  repoURL: https://falcosecurity.github.io/charts
  chartName: falco-talon
  releaseName: falco-talon          # cố định để Service tên falco-talon (Sidekick webhook trỏ vào đây)
  namespace: falco
  reconcileStrategy: Continuous
  options:
    wait: true
    timeout: 10m
    install:
      createNamespace: true
  valuesTemplate: |
    replicaCount: 1
    config:
      rulesOverride: |
        - action: Terminate Pod
          actionner: kubernetes:terminate
          parameters:
            ignore_daemonsets: true
            ignore_statefulsets: true
            grace_period_seconds: 0

        - action: Quarantine Pod
          actionner: kubernetes:label
          parameters:
            labels:
              quarantine: "true"

        - rule: Sensitive file read -> terminate
          description: RT-1, doc /etc/shadow trong vuln-lab thi xoa pod
          match:
            rules:
              - Read sensitive file untrusted
            output_fields:
              - k8s.ns.name=vuln-lab
          actions:
            - action: Terminate Pod

        - rule: Miner binary -> quarantine
          description: RT-2, chay binary dao coin thi gan nhan quarantine (NetworkPolicy cat mang)
          match:
            rules:
              - Miner Binary Executed
            output_fields:
              - k8s.ns.name=vuln-lab
          actions:
            - action: Quarantine Pod
```

`workload/addons/20-hcp-kyverno.yaml`

```yaml
# Policy enforcement: Kyverno (admission webhook). Policy nằm trong manifests/10-kyverno-policies.yaml (CRS).
apiVersion: addons.cluster.x-k8s.io/v1alpha1
kind: HelmChartProxy
metadata:
  name: secplat-kyverno
spec:
  clusterSelector:
    matchLabels:
      security-baseline: enabled
  repoURL: https://kyverno.github.io/kyverno/
  chartName: kyverno
  version: "3.9.1"     # Kyverno v1.19.1; ValidatingPolicy policies.kyverno.io/v1 cần Kyverno >= 1.19
  releaseName: kyverno
  namespace: kyverno
  reconcileStrategy: Continuous
  options:
    wait: true
    timeout: 10m
    install:
      createNamespace: true
  valuesTemplate: |
    admissionController:
      replicas: 1
    backgroundController:
      replicas: 1
    cleanupController:
      replicas: 1
    reportsController:
      replicas: 1
```

ClusterResourceSet cho manifest thuần. `secplat-security-baseline` dùng `strategy: Reconcile`: sửa file trong `manifests/`, chạy lại `make addons`, thay đổi tự xuống mọi cluster.

`workload/addons/30-crs.yaml`

```yaml
# ClusterResourceSet: apply manifest thuần (không phải Helm) vào workload theo nhãn.
apiVersion: addons.cluster.x-k8s.io/v1beta1
kind: ClusterResourceSet
metadata:
  name: secplat-calico
spec:
  strategy: ApplyOnce
  clusterSelector:
    matchLabels:
      cni: calico
  resources:
    - kind: ConfigMap
      name: calico-vxlan
---
apiVersion: addons.cluster.x-k8s.io/v1beta1
kind: ClusterResourceSet
metadata:
  name: secplat-security-baseline
spec:
  strategy: Reconcile          # sửa manifest + chạy lại render.sh -> tự đồng bộ xuống mọi cluster
  clusterSelector:
    matchLabels:
      security-baseline: enabled
  resources:                   # policy để cuối: cần CRD của Kyverno, CRS tự thử lại tới khi có
    - kind: ConfigMap
      name: sec-baseline-namespaces
    - kind: ConfigMap
      name: sec-baseline-netpol
    - kind: ConfigMap
      name: sec-baseline-policies
---
apiVersion: addons.cluster.x-k8s.io/v1beta1
kind: ClusterResourceSet
metadata:
  name: secplat-lab-target
spec:
  strategy: ApplyOnce
  clusterSelector:
    matchLabels:
      lab-target: enabled
  resources:
    - kind: ConfigMap
      name: sec-lab-target
```

`workload/manifests/00-namespaces.yaml`

```yaml
# Namespace dùng chung. PSA để privileged CÓ CHỦ ĐÍCH (lab):
# - falco, security-scan: DaemonSet/Job cần quyền host.
# - vuln-lab: workload cố ý vi phạm làm mục tiêu cho scan/runtime.
# - policy-lab: để Kyverno (không phải PSA) là lớp chặn khi chạy kịch bản PE-*.
apiVersion: v1
kind: Namespace
metadata:
  name: falco
  labels:
    pod-security.kubernetes.io/enforce: privileged
---
apiVersion: v1
kind: Namespace
metadata:
  name: security-scan
  labels:
    pod-security.kubernetes.io/enforce: privileged
---
apiVersion: v1
kind: Namespace
metadata:
  name: vuln-lab
  labels:
    pod-security.kubernetes.io/enforce: privileged
---
apiVersion: v1
kind: Namespace
metadata:
  name: policy-lab
  labels:
    pod-security.kubernetes.io/enforce: privileged
    policy: enforce              # Kyverno chỉ chặn ở namespace có nhãn này
```

`workload/manifests/30-lab-target.yaml`

```yaml
# Mục tiêu lab: cố ý dùng image cũ + privileged + root để có finding (scan) và để kích hoạt Falco.
apiVersion: apps/v1
kind: Deployment
metadata:
  name: vulnerable-workload
  namespace: vuln-lab
  labels:
    app: vulnerable-workload
spec:
  replicas: 1
  selector:
    matchLabels:
      app: vulnerable-workload
  template:
    metadata:
      labels:
        app: vulnerable-workload
    spec:
      containers:
        - name: web
          image: nginx:1.14.2
          securityContext:
            privileged: true
            runAsUser: 0
```

### 2.3 Bật CronJob orchestrator

ConfigMap `scan-scripts` đã có, giờ bật CronJob đã tạo ở Guide 1 (Bước 6):

```bash
kubectl -n scan-orchestrator get configmap scan-scripts -o jsonpath='{.data}' | jq -r 'keys[]'   # run-scans.sh, *.tpl
kubectl -n scan-orchestrator patch cronjob scan-orchestrator -p '{"spec":{"suspend":false}}'
```

---

## 3. Cấp phát workload

### 3.1 Cluster mới (luồng chuẩn)

```bash
make provision NAME=team-a       # tạo cluster, gắn nhãn, chờ node Ready
make verify CLUSTER=team-a       # chờ và kiểm tra mọi tool đã tự cài
```

`provision` chỉ tạo cluster và gắn nhãn, không cài tool nào. Phần còn lại do CAAPH và ClusterResourceSet làm. `verify` chờ tối đa 15 phút mỗi mục và dừng ở mục đầu tiên không đạt.

Muốn cluster không có mục tiêu lab: `./scripts/provision-cluster.sh team-b --no-lab`.

Thao tác với cluster vừa tạo từ terminal: `CLUSTER=team-a source ~/secplat/env.sh` rồi dùng `kw`, `hw`.

### 3.2 Đưa cluster `capi-quickstart` hiện có vào cơ chế tự cài

Cluster này đã có Calico và Falco/Talon cài tay. Gỡ bản cài tay trước để CAAPH quản lý (tránh trùng release), **không** gắn nhãn `cni=calico`:

```bash
source ~/secplat/env.sh                  # CLUSTER=capi-quickstart
hw uninstall falco-talon -n falco || true
hw uninstall falco -n falco || true
kubectl label cluster capi-quickstart security-baseline=enabled lab-target=enabled --overwrite
make verify CLUSTER=capi-quickstart
```

---

## 4. Giải pháp 1–2: Image & Static analysis, CIS benchmark

Orchestrator ở admin gọi `run-scans.sh` cho từng cluster có nhãn. Script tạo Job trong namespace `security-scan` của workload, đọc kết quả JSON từ log rồi `reimport-scan` vào DefectDojo. Mỗi cluster là một Product, lần reimport sau tự đóng finding đã hết (`close_old_findings`).

| Job                                                                 | Lệnh                                                 | Scan type DefectDojo    |
|---------------------------------------------------------------------|------------------------------------------------------|-------------------------|
| `trivy-<hash>` (mỗi image đang chạy trong `vuln-lab`, `policy-lab`) | `trivy image --scanners vuln,secret`                 | Trivy Scan              |
| `kube-bench`                                                        | `kube-bench run --targets node --json`               | kube-bench Scan         |

Chạy ngay, không chờ lịch:

```bash
# Cách 1: từ VM
export DOJO_API_KEY=<token>          # Guide 1, Bước 2e
make scan CLUSTER=team-a

# Cách 2: qua CronJob (scan mọi cluster có nhãn)
kubectl -n scan-orchestrator create job --from=cronjob/scan-orchestrator scan-now-$(date +%s)
kubectl -n scan-orchestrator logs -f job/$(kubectl -n scan-orchestrator get jobs --sort-by=.metadata.creationTimestamp -o name | tail -1 | cut -d/ -f2)
```

Kết quả mong đợi: mỗi dòng `[<cluster>] ... -> HTTP 201` (lần sau là 200). Trong DefectDojo, Product `<cluster>` có CVE của `nginx:1.14.2` (ví dụ CVE-2021-3711) và mục kube-bench.

**Static analysis cho manifest**: job `lint` của CI (mục 7) chạy `trivy config` trên `workload/` mỗi lần push, phát hiện cấu hình sai trong chính manifest trước khi chúng xuống cluster. `vulnerable-workload` cố ý sai nên sẽ luôn có finding; đó là kết quả đúng.

`workload/scan/run-scans.sh`

```bash
#!/usr/bin/env bash
# run-scans.sh <kubeconfig-workload> <tên-cluster>
# Chạy trong workload: Trivy (vuln + secret) cho image đang chạy, kube-bench (CIS, node),
# rồi reimport vào DefectDojo (product = tên cluster). Dùng chung cho:
#   - scripts/scan-now.sh (chạy tay trên VM)
#   - CronJob scan-orchestrator ở admin (Guide 1, Bước 5), script được mount từ ConfigMap scan-scripts
# Biến môi trường: DOJO_URL, DOJO_API_KEY (bắt buộc); SCAN_NAMESPACES (tùy chọn)
set -euo pipefail
WKCFG="${1:?kubeconfig}"; CLUSTER="${2:?tên cluster}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${DOJO_URL:?}" "${DOJO_API_KEY:?}"
NS=security-scan
SCAN_NAMESPACES="${SCAN_NAMESPACES:-vuln-lab policy-lab}"
TRIVY_IMG="${TRIVY_IMG:-aquasec/trivy:latest}"        # nên pin tag đã kiểm chứng
KB_IMG="${KB_IMG:-aquasec/kube-bench:latest}"
OUT="$(mktemp -d)"; trap 'rm -rf "$OUT"' EXIT
JOB=""; IMAGE=""; rc=0
K() { kubectl --kubeconfig="$WKCFG" "$@"; }

render() { # render <template>: thay placeholder __X__
  sed -e "s|__NS__|$NS|g" -e "s|__JOB__|$JOB|g" -e "s|__IMAGE__|$IMAGE|g" \
      -e "s|__TRIVY_IMG__|$TRIVY_IMG|g" -e "s|__KB_IMG__|$KB_IMG|g" "$DIR/$1"
}

run_job() { # run_job <template>: tạo Job, chờ xong, in JSON kết quả ra stdout
  K -n "$NS" delete job "$JOB" --ignore-not-found --wait=true >/dev/null
  render "$1" | K -n "$NS" apply -f - >/dev/null
  local i s
  for i in $(seq 1 120); do
    s="$(K -n "$NS" get job "$JOB" -o jsonpath='{.status.succeeded}/{.status.failed}' 2>/dev/null || true)"
    case "$s" in
      1/*) break ;;
      */[1-9]*) echo "[$CLUSTER] job $JOB FAILED" >&2; K -n "$NS" logs "job/$JOB" --tail=20 >&2 || true; return 1 ;;
    esac
    [ "$i" -eq 120 ] && { echo "[$CLUSTER] job $JOB quá 10 phút" >&2; return 1; }
    sleep 5
  done
  K -n "$NS" logs "job/$JOB" | sed -n '/^{/,$p'
}

reimport() { # reimport <scan_type> <file> <test_title>: lỗi thì in body DefectDojo ra stderr
  local code
  jq -e . "$2" >/dev/null 2>&1 || {
    echo "[$CLUSTER] $3 -> bỏ qua: kết quả không phải JSON hợp lệ ($(head -c 200 "$2" | tr '\n' ' '))" >&2; return 1; }
  code="$(curl -sS -X POST "$DOJO_URL/api/v2/reimport-scan/" -H "Authorization: Token $DOJO_API_KEY" \
    -F "scan_type=$1" -F "file=@$2" -F "test_title=$3" \
    -F "product_type_name=Tenant-POC" -F "product_name=$CLUSTER" -F "engagement_name=Scheduled Scan" \
    -F "auto_create_context=true" -F "close_old_findings=true" \
    -o "$OUT/resp.txt" -w '%{http_code}')" || return 1
  echo "[$CLUSTER] $3 -> HTTP $code"
  case "$code" in 2??) ;; *) echo "  $(head -c 500 "$OUT/resp.txt")" >&2; return 1 ;; esac
}

K get ns "$NS" >/dev/null || { echo "thiếu namespace $NS (ClusterResourceSet chưa apply?)" >&2; exit 1; }

# 1) Image & static analysis: Trivy cho mọi image đang chạy trong SCAN_NAMESPACES
images="$(for ns in $SCAN_NAMESPACES; do
  K -n "$ns" get pods -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{end}' 2>/dev/null || true
done | sort -u)"
for IMAGE in $images; do
  JOB="trivy-$(printf %s "$IMAGE" | md5sum | cut -c1-8)"
  if run_job trivy-job.yaml.tpl > "$OUT/$JOB.json"; then
    reimport "Trivy Scan" "$OUT/$JOB.json" "Trivy - $IMAGE" || rc=1
  else rc=1; fi
done
IMAGE=""

# 2) CIS benchmark: kube-bench trên node worker
JOB=kube-bench
if run_job kube-bench-job.yaml.tpl > "$OUT/kube-bench.json"; then
  reimport "kube-bench Scan" "$OUT/kube-bench.json" "kube-bench - $CLUSTER" || rc=1
else rc=1; fi
exit "$rc"
```

`workload/scan/trivy-job.yaml.tpl`

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: __JOB__
  namespace: __NS__
  labels:
    app.kubernetes.io/part-of: secplat-scan
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 3600
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: trivy
          image: __TRIVY_IMG__
          args: ["image", "--quiet", "--format", "json", "--scanners", "vuln,secret", "__IMAGE__"]
```

`workload/scan/kube-bench-job.yaml.tpl`

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: __JOB__
  namespace: __NS__
  labels:
    app.kubernetes.io/part-of: secplat-scan
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 3600
  template:
    spec:
      hostPID: true
      restartPolicy: Never
      containers:
        - name: kube-bench
          image: __KB_IMG__
          # nếu kube-bench không nhận diện được version Kubernetes: thêm "--benchmark", "cis-x.y"
          command: ["kube-bench", "run", "--targets", "node", "--json"]
          volumeMounts:
            - {name: kubelet, mountPath: /var/lib/kubelet, readOnly: true}
            - {name: k8s, mountPath: /etc/kubernetes, readOnly: true}
            - {name: systemd, mountPath: /etc/systemd, readOnly: true}
      volumes:
        - {name: kubelet, hostPath: {path: /var/lib/kubelet}}
        - {name: k8s, hostPath: {path: /etc/kubernetes}}
        - {name: systemd, hostPath: {path: /etc/systemd}}
```

---

## 5. Giải pháp 3: Sec runtime (Falco → Falcosidekick → Talon)

    Falco (DaemonSet, eBPF) ─► Falcosidekick ─┬─► Loki (admin) ─► Grafana        nhãn tenant_id, target_id=<cluster>
                                               └─► Falco-Talon ─┬─► Terminate Pod   (RT-1)
                                                                └─► Label quarantine=true ─► NetworkPolicy cắt mạng (RT-2)

- **Rule mặc định** `Read sensitive file untrusted` → Talon xoá pod (ReplicaSet tạo lại pod sạch).
- **Rule tự viết** `Miner Binary Executed` (trong values Falco ở mục 2.2): tiến trình tên `xmrig` chạy trong container → Talon gắn nhãn `quarantine=true`, NetworkPolicy dưới đây cắt mọi kết nối của pod. Pod vẫn còn để điều tra, nhưng không liên lạc được.
- Rule Talon chỉ áp cho `k8s.ns.name=vuln-lab`. Namespace khác chỉ có alert, không có phản ứng (RT-3 kiểm chứng).

`workload/manifests/20-quarantine-netpol.yaml`

```yaml
# Pod bị Talon gắn nhãn quarantine=true sẽ bị cắt toàn bộ mạng vào/ra (Calico thực thi).
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: quarantine-deny-all
  namespace: vuln-lab
spec:
  podSelector:
    matchLabels:
      quarantine: "true"
  policyTypes: [Ingress, Egress]
```

### Kịch bản test

| ID   | Mục tiêu                                      | Thao tác                                                        | Kết quả mong đợi                                                                          | Kiểm chứng                                                                          |
|------|-----------------------------------------------|-----------------------------------------------------------------|-------------------------------------------------------------------------------------------|-------------------------------------------------------------------------------------|
| RT-1 | Phát hiện + chặn đánh cắp thông tin đăng nhập | `exec` vào pod `vuln-lab`, `cat /etc/shadow`                    | Alert `Read sensitive file untrusted`; Talon terminate pod; pod mới thay thế              | Log Falco có rule + tên pod; pod cũ biến mất; pod mới Running                       |
| RT-2 | Phát hiện + cô lập tiến trình đào coin        | `cp /bin/sleep /tmp/xmrig && /tmp/xmrig 1` trong pod `vuln-lab` | Alert `Miner Binary Executed` (CRITICAL); pod gắn `quarantine=true`; mất kết nối mạng | Nhãn pod; kết nối tới `kubernetes.default.svc:443` từ pod thất bại sau khi gắn nhãn |
| RT-3 | Đối chứng: phản ứng đúng phạm vi              | Tạo pod `nginx:1.27` ở `default`, `cat /etc/shadow`             | Có alert, **không** bị terminate                                                          | Log Falco có alert; pod vẫn Running sau 15s                                         |

Chạy tự động (mỗi mục in PASS/FAIL, exit code khác 0 nếu có FAIL):

```bash
make test-runtime CLUSTER=team-a
```

Chạy tay để demo:

```bash
CLUSTER=team-a source ~/secplat/env.sh
kw -n vuln-lab get pods -w &                                              # theo dõi pod
P=$(kw -n vuln-lab get pod -l app=vulnerable-workload -o jsonpath='{.items[0].metadata.name}')

# RT-1
kw -n vuln-lab exec $P -- cat /etc/shadow                                  # pod bị terminate ngay sau đó

# RT-2 (lấy pod mới)
P=$(kw -n vuln-lab get pod -l app=vulnerable-workload -o jsonpath='{.items[0].metadata.name}')
kw -n vuln-lab exec $P -- sh -c 'cp /bin/sleep /tmp/xmrig && /tmp/xmrig 1'
kw -n vuln-lab get pod $P --show-labels                                    # có quarantine=true
kw -n vuln-lab exec $P -- timeout 5 bash -c 'exec 3<>/dev/tcp/kubernetes.default.svc.cluster.local/443' \
  && echo "còn mạng" || echo "đã bị cô lập"
kw -n vuln-lab delete pod $P                                               # dọn

# Xem alert và hành động
kw -n falco logs -l app.kubernetes.io/name=falco -c falco --tail=-1 --since=5m | grep -E 'shadow|xmrig'
kw -n falco logs deploy/falco-talon --tail=30
curl -sG $LOKI_URL/loki/api/v1/query --data-urlencode 'query=count_over_time({target_id="team-a"}[10m])' | jq '.data.result'
```

Lưu ý:

- Dùng `exec` **không có `-it`** trong script/CI: không có TTY thì rule "Terminal shell in container" không bắn, kịch bản chỉ phụ thuộc rule đang test. Demo tay với `-it` vẫn được, chỉ có thêm một alert.
- CAPD dùng chung kernel host: Falco trên node control-plane cũng thấy cùng syscall nhưng thiếu `k8s.*` (hiện `<NA>`). Bản trùng này không khớp rule Talon (lọc theo namespace) nên không gây phản ứng hai lần, chỉ làm Loki có log trùng.

---

## 6. Giải pháp 4: Policy enforcement (Kyverno)

Kyverno là admission webhook: mọi Pod (và Deployment/Job… nhờ autogen) đi qua policy **trước khi** được lưu vào cluster. Chọn Kyverno vì cài bằng một chart, có sẵn PolicyReport và autogen cho controller. Policy viết dạng **ValidatingPolicy** (`policies.kyverno.io/v1`) với biểu thức **CEL**, cùng ngôn ngữ với ValidatingAdmissionPolicy của Kubernetes, theo [hướng dẫn chuyển sang CEL](https://kyverno.io/docs/guides/migration-to-cel/): ClusterPolicy kiểu `pattern` đã deprecated từ Kyverno 1.19 và sẽ bị gỡ ở 1.20. (Thay thế: OPA Gatekeeper dùng Rego; Pod Security Admission có sẵn nhưng chỉ 3 mức cố định.)

| ValidatingPolicy          | Chặn                                               | Lý do                                        |
|---------------------------|----------------------------------------------------|----------------------------------------------|
| `secplat-disallow-privileged` | Container `privileged: true` (kể cả initContainer) | Privileged = gần như root trên node          |
| `secplat-disallow-latest-tag` | Image không có tag hoặc tag `:latest`              | Không truy vết/scan được phiên bản thực chạy |
| `secplat-require-nonroot`     | Pod thiếu `securityContext.runAsNonRoot: true`     | Giảm tác động khi container bị chiếm         |

Phạm vi: chỉ namespace có nhãn `policy=enforce` (mặc định `policy-lab`). `vuln-lab` cố ý không gắn nhãn để mục tiêu lab vẫn chạy được cho scan và kịch bản runtime. Muốn áp cho namespace ứng dụng: `kw label ns <ns> policy=enforce`.

`workload/manifests/10-kyverno-policies.yaml`

```yaml
# Policy Enforcement: 3 ValidatingPolicy (CEL, policies.kyverno.io/v1, Kyverno >= 1.19), chế độ Deny,
# chỉ áp cho namespace có nhãn policy=enforce.
# Viết cho Pod; Kyverno tự sinh bản cho Deployment/StatefulSet/DaemonSet/Job/CronJob... (autogen mặc định,
# đổi `object.spec` thành `object.spec.template.spec`). Muốn giới hạn: spec.autogen.podControllers.controllers.
apiVersion: policies.kyverno.io/v1
kind: ValidatingPolicy
metadata:
  name: secplat-disallow-privileged
  annotations:
    policies.kyverno.io/title: Disallow privileged containers
    policies.kyverno.io/severity: high
spec:
  validationActions: [Deny]
  evaluation:
    background: {enabled: true}
  matchConstraints:
    resourceRules:
      - apiGroups: [""]
        apiVersions: [v1]
        operations: [CREATE, UPDATE]
        resources: [pods]
    namespaceSelector:
      matchLabels:
        policy: enforce
  variables:
    - name: allContainers
      expression: object.spec.containers + object.spec.?initContainers.orValue([])
  validations:
    - expression: >-
        variables.allContainers.all(c, c.?securityContext.?privileged.orValue(false) == false)
      message: "[secplat-disallow-privileged] Privileged containers are not allowed."
---
apiVersion: policies.kyverno.io/v1
kind: ValidatingPolicy
metadata:
  name: secplat-disallow-latest-tag
  annotations:
    policies.kyverno.io/title: Require explicit, non-latest image tag
    policies.kyverno.io/severity: medium
spec:
  validationActions: [Deny]
  evaluation:
    background: {enabled: true}
  matchConstraints:
    resourceRules:
      - apiGroups: [""]
        apiVersions: [v1]
        operations: [CREATE, UPDATE]
        resources: [pods]
    namespaceSelector:
      matchLabels:
        policy: enforce
  validations:
    # Có tag = có ':' sau dấu '/' cuối (không nhầm cổng registry, vd. registry:5000/app); digest '@sha256:' cũng được
    - expression: >-
        object.spec.containers.all(c, c.image.lastIndexOf(':') > c.image.lastIndexOf('/'))
      message: "[secplat-disallow-latest-tag] Image must have an explicit tag."
    - expression: >-
        object.spec.containers.all(c, !c.image.endsWith(':latest'))
      message: "[secplat-disallow-latest-tag] Image tag ':latest' is not allowed."
---
apiVersion: policies.kyverno.io/v1
kind: ValidatingPolicy
metadata:
  name: secplat-require-nonroot
  annotations:
    policies.kyverno.io/title: Require runAsNonRoot
    policies.kyverno.io/severity: high
spec:
  validationActions: [Deny]
  evaluation:
    background: {enabled: true}
  matchConstraints:
    resourceRules:
      - apiGroups: [""]
        apiVersions: [v1]
        operations: [CREATE, UPDATE]
        resources: [pods]
    namespaceSelector:
      matchLabels:
        policy: enforce
  validations:
    - expression: >-
        object.spec.?securityContext.?runAsNonRoot.orValue(false) == true
      message: "[secplat-require-nonroot] Pod must set spec.securityContext.runAsNonRoot=true."
```

### Kịch bản test

| ID   | Thao tác (namespace `policy-lab`)                       | Kết quả mong đợi  | Kiểm chứng                                   |
|------|---------------------------------------------------------|-------------------|----------------------------------------------|
| PE-1 | Apply Pod có container privileged                       | Bị từ chối        | Thông báo lỗi chứa `secplat-disallow-privileged` |
| PE-2 | Apply Pod dùng `busybox:latest`                         | Bị từ chối        | Lỗi chứa `secplat-disallow-latest-tag`           |
| PE-3 | Apply Pod không khai báo securityContext (chạy root)    | Bị từ chối        | Lỗi chứa `secplat-require-nonroot`               |
| PE-4 | Apply Pod tuân thủ (`busybox:1.36`, non-root, drop ALL) | Được tạo, Running | `kubectl wait --for=condition=Ready`         |
| PE-5 | Apply Pod privileged ở `vuln-lab`                       | Không bị chặn     | Đúng phạm vi theo nhãn namespace             |

Mỗi fixture chỉ vi phạm đúng một policy, nên thông báo lỗi chỉ ra chính xác policy nào chặn. PE-1..3 và PE-5 dùng `--dry-run=server`: request đi qua webhook thật nhưng không tạo object, không cần dọn.

```bash
make test-policy CLUSTER=team-a
```

Chạy tay để demo:

```bash
cd ~/secplat/sec-platform/workload/tests/fixtures
kw -n policy-lab apply -f pod-privileged.yaml
# Error from server: admission webhook "...kyverno.svc-fail" denied the request: ...
#   [secplat-disallow-privileged] Privileged containers are not allowed.
kw -n policy-lab apply -f pod-latest.yaml        # bị chặn
kw -n policy-lab apply -f pod-root.yaml          # bị chặn
kw -n policy-lab apply -f pod-compliant.yaml     # pod/pt-compliant created
kw -n policy-lab delete pod pt-compliant

# Deployment cũng bị chặn (autogen): ReplicaSet không tạo được pod nào
kw -n policy-lab create deployment bad --image=nginx:latest     # bị từ chối ngay ở Deployment

# Trạng thái policy (READY=true) và báo cáo vi phạm của tài nguyên đang tồn tại (background scan)
kw get validatingpolicy                                          # viết tắt: kw get vpol
kw get policyreport -A
```

Fixture:

`workload/tests/fixtures/pod-privileged.yaml`

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: pt-privileged
  labels: {app: policy-test}
spec:
  securityContext: {runAsNonRoot: true, runAsUser: 1000}
  containers:
    - name: c
      image: busybox:1.36
      command: ["sleep", "3600"]
      securityContext: {privileged: true}
```

`workload/tests/fixtures/pod-latest.yaml`

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: pt-latest
  labels: {app: policy-test}
spec:
  securityContext: {runAsNonRoot: true, runAsUser: 1000}
  containers:
    - name: c
      image: busybox:latest
      command: ["sleep", "3600"]
```

`workload/tests/fixtures/pod-root.yaml`

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: pt-root
  labels: {app: policy-test}
spec:
  containers:
    - name: c
      image: busybox:1.36
      command: ["sleep", "3600"]
```

`workload/tests/fixtures/pod-compliant.yaml`

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: pt-compliant
  labels: {app: policy-test}
spec:
  securityContext: {runAsNonRoot: true, runAsUser: 1000}
  containers:
    - name: c
      image: busybox:1.36
      command: ["sleep", "3600"]
      securityContext:
        allowPrivilegeEscalation: false
        capabilities: {drop: ["ALL"]}
```

---

## 7. Tự động hoá và CI

### 7.1 Chuỗi tự động

| Sự kiện                        | Cái gì tự chạy                                                                         | Ai làm                             |
|--------------------------------|----------------------------------------------------------------------------------------|------------------------------------|
| Workload được cấp phát có nhãn | Calico, Falco, Sidekick, Talon, Kyverno, namespace, NetworkPolicy, policy, lab target  | CAAPH + ClusterResourceSet (admin) |
| Mỗi 6 giờ                      | Trivy, kube-bench cho **mọi** cluster có nhãn → DefectDojo                              | CronJob orchestrator               |
| Push lên `main`                | Lint, `trivy config`, `make addons` (đồng bộ cấu hình xuống mọi cluster), verify, test | CI                                 |
| Hằng đêm / bấm tay             | Cấp phát cluster tạm → chờ tự cài → toàn bộ kịch bản → xoá                             | CI (e2e)                           |
| ADMIN_NODE_IP đổi              | Chạy lại `make addons`; CAAPH (`Continuous`) tự `helm upgrade` địa chỉ Loki mới        | Bạn hoặc CI                        |

### 7.2 Pipeline (GitHub Actions)

`.github/workflows/baseline.yml`

```yaml
# CI cho workload baseline.
# - lint: chạy trên runner GitHub (không cần cluster)
# - apply/test/e2e: chạy trên self-hosted runner đặt ngay trên VM (nhãn secplat-vm), kubectl trỏ admin cluster
name: workload-baseline
on:
  push:
    branches: [main]
  pull_request:
  workflow_dispatch:
    inputs:
      e2e:
        description: "Chạy e2e (tạo cluster tạm, ~20-30 phút)"
        type: boolean
        default: false
  schedule:
    - cron: "0 18 * * *"        # 01:00 giờ Việt Nam: e2e hằng đêm
concurrency:
  group: secplat-baseline
  cancel-in-progress: false

jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: ShellCheck
        run: shellcheck scripts/*.sh workload/scan/*.sh workload/tests/*.sh
      - name: YAML lint
        run: |
          pipx run yamllint -d '{extends: relaxed, rules: {line-length: disable}}' workload .github
      - name: Static analysis manifest (Trivy config, chỉ báo cáo)
        run: |
          docker run --rm -v "$PWD:/src" aquasec/trivy:latest config --severity HIGH,CRITICAL /src/workload

  apply:
    needs: lint
    if: github.event_name != 'pull_request'
    runs-on: [self-hosted, secplat-vm]
    steps:
      - uses: actions/checkout@v4
      - name: Đồng bộ HelmChartProxy / ClusterResourceSet lên admin
        run: make addons
      - name: Kiểm tra baseline trên cluster hiện có
        run: make verify CLUSTER=capi-quickstart

  test:
    needs: apply
    runs-on: [self-hosted, secplat-vm]
    steps:
      - uses: actions/checkout@v4
      - run: make test-runtime CLUSTER=capi-quickstart
      - run: make test-policy CLUSTER=capi-quickstart

  e2e:
    needs: apply
    if: github.event_name == 'schedule' || inputs.e2e
    runs-on: [self-hosted, secplat-vm]
    timeout-minutes: 60
    steps:
      - uses: actions/checkout@v4
      - name: Cấp phát cluster tạm, chờ tự cài, chạy kịch bản, xoá
        run: make e2e
```

- `lint` chạy trên runner GitHub, không cần cluster.
- `apply`, `test`, `e2e` cần với tới admin cluster (nằm trong VM, không mở ra Internet), nên chạy trên **self-hosted runner đặt trên chính VM**.
- Dùng GitLab thì chuyển 4 job này sang `.gitlab-ci.yml` với GitLab Runner trên VM, các lệnh `make` giữ nguyên.

### 7.3 Cài self-hosted runner trên VM

1.  GitHub repo → **Settings → Actions → Runners → New self-hosted runner** → Linux x64. Làm theo các lệnh GitHub hiển thị (tải, `./config.sh --url ... --token ...`), khi được hỏi nhãn thì thêm `secplat-vm`.
2.  Chạy runner dưới user `duong` (đã có kubeconfig admin và quyền docker), cài thành service: `sudo ./svc.sh install duong && sudo ./svc.sh start`.
3.  Kiểm tra user runner có đủ: đăng nhập bằng user đó, chạy `bash scripts/preflight.sh` trong thư mục repo, phải ra 0 FAIL.
4.  Bí mật: e2e và test không cần token. Nếu thêm bước `make scan` vào CI, lưu `DOJO_API_KEY` trong **Settings → Secrets → Actions** và truyền qua `env:`.

### 7.4 e2e: chứng minh "cấp phát là có bảo mật"

```bash
make e2e              # hoặc: KEEP=1 make e2e để giữ cluster lại debug
```

Script tạo cluster `ci-<thời gian>` với đúng 3 nhãn, **không cài gì thêm**, chờ `verify.sh` thấy đủ tool, in thời gian từ lúc cấp phát tới lúc đủ baseline, chạy RT-1..3 và PE-1..5, rồi xoá cluster (kể cả khi lỗi). Tốn thêm khoảng 4 GB RAM trong lúc chạy; kiểm tra `free -h` trước.

`Makefile`

```makefile
# Dùng ">" thay cho TAB ở đầu lệnh (GNU make >= 3.82) để copy/paste không hỏng.
.RECIPEPREFIX = >
SHELL := /bin/bash
CLUSTER ?= capi-quickstart
NAME ?=

.PHONY: help deps preflight addons provision verify scan test-runtime test-policy test e2e lint
help: ## Liệt kê lệnh
> @grep -E '^[a-z0-9-]+:.*## ' Makefile | awk -F':.*## ' '{printf "  make %-13s %s\n", $$1, $$2}'
deps: ## Cài package/binary cần cho Guide 1 + 2 (= bash scripts/install-deps.sh)
> ./scripts/install-deps.sh
preflight: ## Kiểm tra lệnh/host/admin cluster (cài thiếu: bash scripts/preflight.sh --install)
> ./scripts/preflight.sh
addons: ## Nạp ConfigMap + apply HelmChartProxy/ClusterResourceSet lên admin
> ./scripts/render.sh
provision: ## Cấp phát workload mới: make provision NAME=team-a
> @test -n "$(NAME)" || { echo "thiếu NAME=..."; exit 1; }
> ./scripts/provision-cluster.sh $(NAME)
verify: ## Kiểm tra baseline đã tự cài đủ: make verify CLUSTER=...
> ./workload/tests/verify.sh $(CLUSTER)
scan: ## Chạy scan ngay và đẩy vào DefectDojo (cần DOJO_API_KEY)
> ./scripts/scan-now.sh $(CLUSTER)
test-runtime: ## Kịch bản Sec runtime RT-1..RT-3
> ./workload/tests/runtime-tests.sh $(CLUSTER)
test-policy: ## Kịch bản Policy Enforcement PE-1..PE-5
> ./workload/tests/policy-tests.sh $(CLUSTER)
test: verify test-runtime test-policy ## verify + toàn bộ kịch bản
e2e: ## Cluster tạm: cấp phát -> tự cài -> test -> xoá
> ./workload/tests/e2e.sh
lint: ## shellcheck + yamllint (cần cài sẵn)
> shellcheck scripts/*.sh workload/scan/*.sh workload/tests/*.sh
> yamllint -d '{extends: relaxed, rules: {line-length: disable}}' workload .github
```

---

## 8. Xử lý sự cố

| Triệu chứng                        | Kiểm tra                                                                                                                                                 | Hướng xử lý                                                                                                                     |
|------------------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------|---------------------------------------------------------------------------------------------------------------------------------|
| `verify` kẹt ở Falco/Talon/Kyverno | `kubectl get helmreleaseproxies -A`; `kubectl describe helmreleaseproxy <tên>`; `kubectl -n caaph-system logs deploy/caaph-controller-manager --tail=50` | Lỗi chart/values hiện trong status; sửa file trong `addons/` rồi `make addons`                                                  |
| ValidatingPolicy chưa xuất hiện    | `kubectl get clusterresourcesetbindings -o yaml`                                                                                                         | ClusterResourceSet thử lại tới khi CRD Kyverno có; thường chậm vài phút sau khi Kyverno Ready                                   |
| Sidekick không có output WebHook   | `kw -n falco logs deploy/falco-falcosidekick | grep 'Enabled Outputs'`                                                                                   | Kiểm tra `webhook.address` trong `10-hcp-falco.yaml`, `make addons`                                                             |
| Không có alert trong Loki          | `echo $LOKI_URL` vs `kw -n falco get secret falco-falcosidekick -o yaml`                                                                                 | IP admin đổi: `make addons`                                                                                                     |
| RT-1 FAIL "pod vẫn chạy"           | `kw -n falco logs deploy/falco-talon`                                                                                                                    | Rule Talon không khớp (thiếu `k8s.ns.name` trong alert) hoặc RBAC của Talon                                                     |
| PE-\* FAIL "lỗi khác"              | Đọc thông báo lỗi in ra                                                                                                                                  | Thường do Kyverno chưa sẵn sàng (webhook timeout); chạy lại                                                                     |
| kube-bench lỗi version             | `kw -n security-scan logs job/kube-bench`                                                                                                                | Thêm `--benchmark cis-x.y` vào `kube-bench-job.yaml.tpl`                                                                        |
| Đổi phiên bản chart làm hỏng       | `kubectl get helmchartproxy secplat-kyverno -o yaml`                                                                                                         | Pin `version:` trong HelmChartProxy sau khi đã chạy ổn; Kyverno bản mới có thể đánh dấu `validationFailureAction` là deprecated |

---

## 9. Mã nguồn còn lại

`scripts/install-deps.sh`

```bash
#!/usr/bin/env bash
# install-deps.sh: cài mọi package/binary VM cần cho Guide 1 (admin) và Guide 2 (workload) trên Ubuntu/Debian.
#   bash scripts/install-deps.sh                                   # cài phần còn thiếu, bỏ qua phần đã có
#   DOCKER_DATA_ROOT=/mnt/ssd/docker bash scripts/install-deps.sh  # tùy chọn, VM có SSD riêng đã mount (Guide 1, Bước 0.2)
#   WITH_LINT=1 bash scripts/install-deps.sh                       # thêm shellcheck + yamllint (cho make lint)
# Chạy lại bao nhiêu lần cũng được. Chỉ cài trên VM, không đụng tới cluster.
# Kiểm tra đầy đủ (host + admin cluster) sau khi xong Guide 1: bash scripts/preflight.sh
# shellcheck disable=SC2015
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${CLUSTERCTL_VERSION:=v1.14.0}"     # cùng bản với Guide 1, Bước 1
: "${KIND_VERSION:=latest}"            # hoặc ghim, ví dụ v0.31.0
: "${KUBECTL_VERSION:=}"               # rỗng = bản stable mới nhất
: "${DOCKER_DATA_ROOT:=}"              # rỗng = giữ mặc định /var/lib/docker
: "${WITH_LINT:=0}"
USER="${USER:-$(id -un)}"

ok=0; warns=0; fails=0
pass() { printf '  \033[1;32m[OK]\033[0m   %s\n' "$*"; ok=$((ok + 1)); }
warn() { printf '  \033[1;33m[WARN]\033[0m %s\n' "$*"; warns=$((warns + 1)); }
fail() { printf '  \033[1;31m[FAIL]\033[0m %s\n' "$*"; fails=$((fails + 1)); }
step() { printf '\n\033[1;34m== %s\033[0m\n' "$*"; }
has()  { command -v "$1" >/dev/null 2>&1; }

case "$(uname -m)" in
  x86_64) ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) ARCH="$(uname -m)" ;;
esac

install_bin() { # install_bin <tên> <url>
  local tmp; tmp="$(mktemp)"
  curl -fsSL "$2" -o "$tmp" && sudo install -m 0755 "$tmp" "/usr/local/bin/$1"
  local rc=$?; rm -f "$tmp"; return "$rc"
}

has apt-get || { echo "Chỉ hỗ trợ Ubuntu/Debian (apt). Distro khác: cài tay các lệnh ở bảng trong Guide 1, Bước 0."; exit 1; }

# ---------- 1) Gói hệ thống
step "1. Gói hệ thống (apt)"
PKGS=(git make jq curl ca-certificates gnupg coreutils gawk sed tar gzip gettext-base rsync util-linux e2fsprogs)
[ "$WITH_LINT" = 1 ] && PKGS+=(shellcheck yamllint)
sudo apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${PKGS[@]}" >/dev/null \
  && pass "apt: ${PKGS[*]}" || fail "apt-get install lỗi (xem lại mạng/apt source)"

# ---------- 2) Docker Engine + compose plugin
step "2. Docker"
if [ -n "$DOCKER_DATA_ROOT" ]; then
  sudo mkdir -p "$DOCKER_DATA_ROOT" /etc/docker
  cur="$( [ -s /etc/docker/daemon.json ] && sudo cat /etc/docker/daemon.json || echo '{}')"
  want="$(printf '%s' "$cur" | jq --arg r "$DOCKER_DATA_ROOT" '. + {"data-root": $r}' 2>/dev/null)"
  if [ -z "$want" ]; then
    fail "/etc/docker/daemon.json không phải JSON hợp lệ: sửa tay rồi chạy lại"
  elif [ "$(printf '%s' "$cur" | jq -r '."data-root" // empty')" != "$DOCKER_DATA_ROOT" ]; then
    if has docker && [ -n "$(sudo ls -A /var/lib/docker 2>/dev/null)" ] && [ "$DOCKER_DATA_ROOT" != /var/lib/docker ]; then
      warn "Docker đã có dữ liệu ở /var/lib/docker: không tự đổi data-root, làm tay theo Guide 1, Bước 0.4 (rsync rồi đổi daemon.json)"
    else
      printf '%s\n' "$want" | sudo tee /etc/docker/daemon.json >/dev/null && pass "daemon.json: data-root=$DOCKER_DATA_ROOT (merge, giữ key khác)"
      has docker && sudo systemctl restart docker
    fi
  fi
fi
if ! has docker; then
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq docker.io >/dev/null && pass "apt: docker.io" || fail "không cài được docker.io"
fi
if has docker && ! docker compose version >/dev/null 2>&1; then
  { sudo apt-get install -y -qq docker-compose-v2 >/dev/null 2>&1 || sudo apt-get install -y -qq docker-compose-plugin >/dev/null 2>&1; } \
    && pass "docker compose plugin" || warn "không cài được docker compose plugin (Guide 1/2 không bắt buộc)"
fi
if has docker; then
  sudo systemctl enable --now docker >/dev/null 2>&1 || true
  if ! id -nG "$USER" | grep -qw docker; then
    sudo usermod -aG docker "$USER" && warn "đã thêm $USER vào nhóm docker: đăng xuất rồi SSH lại (hoặc 'newgrp docker') trước khi chạy tiếp"
  fi
fi

# ---------- 3) Kubernetes CLI (/usr/local/bin)
step "3. kubectl, kind, helm, clusterctl"
if ! has kubectl; then
  v="${KUBECTL_VERSION:-$(curl -fsSL https://dl.k8s.io/release/stable.txt)}"
  install_bin kubectl "https://dl.k8s.io/release/${v}/bin/linux/${ARCH}/kubectl" && pass "cài kubectl ${v}" || fail "không tải được kubectl"
fi
if ! has kind; then
  if [ "$KIND_VERSION" = latest ]; then u="https://github.com/kubernetes-sigs/kind/releases/latest/download/kind-linux-${ARCH}"
  else u="https://github.com/kubernetes-sigs/kind/releases/download/${KIND_VERSION}/kind-linux-${ARCH}"; fi
  install_bin kind "$u" && pass "cài kind" || fail "không tải được kind"
fi
if ! has helm; then
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash >/dev/null && pass "cài helm" || fail "không cài được helm"
fi
if ! has clusterctl; then
  install_bin clusterctl "https://github.com/kubernetes-sigs/cluster-api/releases/download/${CLUSTERCTL_VERSION}/clusterctl-linux-${ARCH}" \
    && pass "cài clusterctl ${CLUSTERCTL_VERSION}" || fail "không tải được clusterctl"
fi

# ---------- 4) sysctl inotify (Guide 1, Bước 0)
step "4. sysctl inotify"
w="$(sysctl -n fs.inotify.max_user_watches 2>/dev/null || echo 0)"
i="$(sysctl -n fs.inotify.max_user_instances 2>/dev/null || echo 0)"
if [ "$w" -lt 524288 ] || [ "$i" -lt 512 ]; then
  printf 'fs.inotify.max_user_watches=524288\nfs.inotify.max_user_instances=512\n' | sudo tee /etc/sysctl.d/99-kind.conf >/dev/null
  sudo sysctl --system >/dev/null && pass "ghi /etc/sysctl.d/99-kind.conf" || fail "không áp được sysctl"
else
  pass "inotify watches=$w instances=$i"
fi
chmod +x "$ROOT"/scripts/*.sh "$ROOT"/workload/scan/*.sh "$ROOT"/workload/tests/*.sh 2>/dev/null || true

# ---------- 5) Kết quả
step "5. Kiểm tra sau khi cài"
for c in git make jq curl envsubst rsync docker kubectl kind helm clusterctl; do
  has "$c" && pass "$c" || fail "vẫn thiếu $c"
done
has docker && docker compose version >/dev/null 2>&1 && pass "docker compose" || true
has kubectl    && pass "kubectl $(kubectl version --client -o json 2>/dev/null | jq -r .clientVersion.gitVersion)"
has kind       && pass "$(kind version 2>/dev/null)"
has helm       && pass "helm $(helm version --short 2>/dev/null)"
has clusterctl && pass "clusterctl $(clusterctl version -o short 2>/dev/null)"
if has docker; then
  if docker info >/dev/null 2>&1; then pass "Docker Root Dir: $(docker info -f '{{.DockerRootDir}}')"
  else warn "user $USER chưa gọi được docker không cần sudo: đăng xuất/SSH lại rồi chạy 'docker info'"; fi
fi

printf '\nKết quả: %d OK, %d WARN, %d FAIL\n' "$ok" "$warns" "$fails"
[ "$fails" -eq 0 ]
```

`scripts/preflight.sh`

```bash
#!/usr/bin/env bash
# preflight.sh [--install]: kiểm tra VM + admin cluster trước khi chạy Guide 2.
#   (không tham số)  chỉ kiểm tra, in OK/WARN/FAIL, exit 1 nếu có FAIL
#   --install        chạy scripts/install-deps.sh (cài gói/binary còn thiếu trên VM) rồi kiểm tra lại
# Không cần make: chạy được ngay sau git clone (bash scripts/preflight.sh).
# Phần admin cluster (CAPI/CAPD/CAAPH, DefectDojo, Loki...) chỉ kiểm tra, cài theo Guide 1.
# shellcheck disable=SC1091,SC2015
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ -f "$ROOT/.env" ]; then set -a; . "$ROOT/.env"; set +a; fi
: "${CLUSTER_NS:=default}"
: "${ADMIN_CONTAINER:=kind-control-plane}"

USER="${USER:-$(id -un)}"
INSTALL=0
[ "${1:-}" = "--install" ] && INSTALL=1

ok=0; warns=0; fails=0
pass() { printf '  \033[1;32m[OK]\033[0m   %s\n' "$*"; ok=$((ok + 1)); }
warn() { printf '  \033[1;33m[WARN]\033[0m %s\n' "$*"; warns=$((warns + 1)); }
fail() { printf '  \033[1;31m[FAIL]\033[0m %s\n' "$*"; fails=$((fails + 1)); }
step() { printf '\n\033[1;34m== %s\033[0m\n' "$*"; }
has()  { command -v "$1" >/dev/null 2>&1; }

# ---------- cài đặt (chỉ khi --install): dùng chung script với Guide 1, Bước 0
do_install() {
  step "Cài gói còn thiếu (scripts/install-deps.sh)"
  bash "$ROOT/scripts/install-deps.sh" || warn "install-deps.sh báo lỗi, xem các dòng FAIL ở trên"
}

[ "$INSTALL" = 1 ] && do_install

# ---------- 1) Lệnh trên VM
step "1. Lệnh cần có trên VM"
for c in bash make git jq curl awk sed base64 tar envsubst md5sum timeout docker kubectl kind helm clusterctl; do
  if has "$c"; then pass "$c"; else fail "thiếu $c (chạy: bash scripts/preflight.sh --install)"; fi
done
if has make; then
  mv="$(make --version | awk 'NR==1{print $3}')"
  [ "$(printf '%s\n3.82\n' "$mv" | sort -V | head -1)" = 3.82 ] \
    && pass "GNU make $mv (>= 3.82, cần cho .RECIPEPREFIX)" || fail "GNU make $mv < 3.82"
fi
for c in shellcheck yamllint; do
  has "$c" && pass "$c (cho make lint)" || warn "thiếu $c: chỉ cần khi chạy 'make lint' (apt install $c)"
done
if has docker; then
  docker info >/dev/null 2>&1 && pass "docker daemon chạy, user $USER dùng được không cần sudo" \
    || fail "docker không dùng được với user $USER (daemon tắt hoặc chưa vào nhóm docker)"
fi

# ---------- 2) Host (kernel, tài nguyên)
step "2. Host"
kv="$(uname -r | cut -d- -f1)"
[ "$(printf '%s\n5.8\n' "$kv" | sort -V | head -1)" = 5.8 ] \
  && pass "kernel $kv (>= 5.8, cần cho Falco modern_ebpf)" || fail "kernel $kv < 5.8: Falco modern_ebpf không chạy"
[ -r /sys/kernel/btf/vmlinux ] && pass "BTF có sẵn (/sys/kernel/btf/vmlinux)" \
  || fail "thiếu /sys/kernel/btf/vmlinux: Falco modern_ebpf cần kernel bật CONFIG_DEBUG_INFO_BTF"
w="$(sysctl -n fs.inotify.max_user_watches 2>/dev/null || echo 0)"
i="$(sysctl -n fs.inotify.max_user_instances 2>/dev/null || echo 0)"
{ [ "$w" -ge 524288 ] && [ "$i" -ge 512 ]; } && pass "inotify watches=$w instances=$i" \
  || fail "inotify thấp (watches=$w instances=$i): Guide 1, Bước 0.3 hoặc --install"
mem_kb="$(awk '/MemTotal/{print $2}' /proc/meminfo 2>/dev/null)"
avail_kb="$(awk '/MemAvailable/{print $2}' /proc/meminfo 2>/dev/null)"
mem_gb=$(( ${mem_kb:-0} / 1024 / 1024 )); avail_gb=$(( ${avail_kb:-0} / 1024 / 1024 ))
[ "$mem_gb" -ge 15 ] && pass "RAM ${mem_gb} GB" || warn "RAM ${mem_gb} GB (< 16 GB khuyến nghị)"
[ "$avail_gb" -ge 4 ] && pass "RAM trống ${avail_gb} GB (mỗi workload ~4 GB)" \
  || warn "RAM trống ${avail_gb} GB: có thể không đủ cấp phát thêm workload"
if has docker && docker info >/dev/null 2>&1; then
  droot="$(docker info -f '{{.DockerRootDir}}')"
  free_gb=$(( $(df -Pk "$droot" | awk 'NR==2{print $4}') / 1024 / 1024 ))
  [ "$free_gb" -ge 30 ] && pass "Docker root $droot còn ${free_gb} GB" \
    || warn "Docker root $droot chỉ còn ${free_gb} GB (mỗi workload thêm vài GB image)"
fi

# ---------- 3) Mạng ra ngoài (pull chart/image khi cấp phát workload)
step "3. Mạng ra ngoài"
for u in https://falcosecurity.github.io/charts/index.yaml https://kyverno.github.io/kyverno/index.yaml \
         https://raw.githubusercontent.com https://registry-1.docker.io/v2/; do
  code="$(curl -s -o /dev/null -m 10 -w '%{http_code}' "$u")"
  [ "$code" != 000 ] && pass "$u (HTTP $code)" || fail "không kết nối được $u (kiểm tra proxy/firewall/DNS)"
done

# ---------- 4) Admin cluster (cài theo Guide 1)
step "4. Admin cluster (Guide 1)"
if ! has kubectl || ! kubectl version --request-timeout=5s >/dev/null 2>&1; then
  fail "kubectl không kết nối được admin cluster: làm Guide 1, Bước 1 trước"
else
  ctx="$(kubectl config current-context 2>/dev/null)"
  [ "$ctx" = kind-kind ] && pass "context $ctx" || warn "context hiện tại là '$ctx', mong đợi kind-kind"
  has docker && docker inspect "$ADMIN_CONTAINER" >/dev/null 2>&1 \
    && pass "container $ADMIN_CONTAINER (tính ADMIN_NODE_IP)" || fail "không thấy container $ADMIN_CONTAINER"

  for crd in clusters.cluster.x-k8s.io dockerclusters.infrastructure.cluster.x-k8s.io \
             helmchartproxies.addons.cluster.x-k8s.io clusterresourcesets.addons.cluster.x-k8s.io; do
    kubectl get crd "$crd" >/dev/null 2>&1 && pass "CRD $crd" || fail "thiếu CRD $crd (Guide 1, Bước 1)"
  done
  for d in capi-system/capi-controller-manager capd-system/capd-controller-manager \
           caaph-system/caaph-controller-manager cert-manager/cert-manager; do
    avail="$(kubectl -n "${d%%/*}" get deploy "${d#*/}" -o jsonpath='{.status.availableReplicas}' 2>/dev/null)"
    [ "${avail:-0}" -ge 1 ] && pass "deploy $d Available" || fail "deploy $d chưa Available"
  done
  kubectl -n capi-system get deploy capi-controller-manager -o jsonpath='{.spec.template.spec.containers[0].args}' 2>/dev/null \
    | grep -q 'ClusterResourceSet=false' && fail "feature gate ClusterResourceSet=false (Guide 1, Bước 1)" \
    || pass "ClusterResourceSet bật"
  kubectl -n "$CLUSTER_NS" get clusterclass quick-start >/dev/null 2>&1 \
    && pass "ClusterClass $CLUSTER_NS/quick-start (cần cho --flavor development)" \
    || fail "thiếu ClusterClass quick-start: kubectl apply -f 02-workload-cluster/clusterclass-quick-start.yaml"

  kubectl -n scan-orchestrator get cronjob scan-orchestrator >/dev/null 2>&1 \
    && pass "CronJob scan-orchestrator" || warn "chưa có CronJob scan-orchestrator (Guide 1, Bước 5)"
  ip=""
  has docker && ip="$(docker inspect -f '{{(index .NetworkSettings.Networks "kind").IPAddress}}' "$ADMIN_CONTAINER" 2>/dev/null)"
  if [ -n "$ip" ]; then
    curl -fsS -m 5 "http://$ip:31100/loki/api/v1/labels" >/dev/null 2>&1 && pass "Loki http://$ip:31100" \
      || fail "Loki http://$ip:31100 không phản hồi (Guide 1, Bước 3)"
    curl -sS -m 5 -o /dev/null "http://$ip:31080/" 2>/dev/null && pass "DefectDojo http://$ip:31080" \
      || warn "DefectDojo http://$ip:31080 không phản hồi (Guide 1, Bước 2; chỉ cần cho scan)"
  fi
fi

printf '\nKết quả: %d OK, %d WARN, %d FAIL\n' "$ok" "$warns" "$fails"
[ "$fails" -eq 0 ]
```

`scripts/lib.sh`

```bash
#!/usr/bin/env bash
# lib.sh: hàm dùng chung. Chỉ source, không chạy trực tiếp.
# Yêu cầu: kubectl đang trỏ ADMIN cluster (context kind-kind), docker, clusterctl.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ -f "$ROOT/.env" ]; then set -a; . "$ROOT/.env"; set +a; fi

: "${CLUSTER_NS:=default}"
: "${CLUSTER_NAME:=capi-quickstart}"
: "${K8S_VERSION:=v1.36.1}"
: "${ADMIN_CONTAINER:=kind-control-plane}"

log()  { printf '\033[1;34m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "thiếu lệnh: $1"; }

admin_node_ip() {
  docker inspect -f '{{(index .NetworkSettings.Networks "kind").IPAddress}}' "$ADMIN_CONTAINER"
}
if [ -z "${ADMIN_NODE_IP:-}" ] && command -v docker >/dev/null 2>&1; then
  ADMIN_NODE_IP="$(admin_node_ip 2>/dev/null || true)"
fi
: "${ADMIN_NODE_IP:=}"
: "${LOKI_URL:=http://${ADMIN_NODE_IP:-UNKNOWN}:31100}"
export ROOT CLUSTER_NS CLUSTER_NAME K8S_VERSION ADMIN_NODE_IP LOKI_URL

# use_cluster <tên>: lấy kubeconfig của workload cluster từ secret <tên>-kubeconfig (do CAPI tạo)
use_cluster() {
  CLUSTER_NAME="$1"
  WK_KUBECONFIG="$ROOT/.kube-${CLUSTER_NAME}.yaml"
  kubectl -n "$CLUSTER_NS" get secret "${CLUSTER_NAME}-kubeconfig" -o jsonpath='{.data.value}' \
    | base64 -d > "$WK_KUBECONFIG"
  [ -s "$WK_KUBECONFIG" ] || die "không lấy được kubeconfig của $CLUSTER_NAME"
  chmod 600 "$WK_KUBECONFIG"
  export CLUSTER_NAME WK_KUBECONFIG
}
kw() { kubectl --kubeconfig="$WK_KUBECONFIG" "$@"; }

# wait_for "mô tả" <timeout giây> "<lệnh>"  (lệnh chạy qua eval; hết giờ thì dừng script)
wait_for() {
  local desc="$1" timeout="$2" cmd="$3" waited=0
  until eval "$cmd" >/dev/null 2>&1; do
    waited=$((waited + 5))
    [ "$waited" -ge "$timeout" ] && die "hết ${timeout}s chờ: ${desc}"
    sleep 5
  done
  log "OK: ${desc}"
}
```

`scripts/render.sh`

```bash
#!/usr/bin/env bash
# render.sh: chạy trên VM, kubectl trỏ ADMIN cluster.
# Nạp manifest/script vào ConfigMap, rồi apply HelmChartProxy + ClusterResourceSet.
# Idempotent: chạy lại bao nhiêu lần cũng được (CI chạy mỗi lần push).
# shellcheck disable=SC1091
source "$(dirname "$0")/lib.sh"
cd "$ROOT"
need kubectl; need curl

[ "$ADMIN_NODE_IP" ] || die "không xác định được ADMIN_NODE_IP (container $ADMIN_CONTAINER?)"
log "ADMIN_NODE_IP=$ADMIN_NODE_IP  LOKI_URL=$LOKI_URL"

kubectl get crd helmchartproxies.addons.cluster.x-k8s.io >/dev/null 2>&1 \
  || die "admin chưa có CAAPH: chạy 'clusterctl init --addon helm' (Guide 1, Bước 1)"
kubectl get crd clusterresourcesets.addons.cluster.x-k8s.io >/dev/null 2>&1 \
  || die "admin chưa có CRD ClusterResourceSet"

cm() { # cm <tên ConfigMap> <file...>
  local name="$1"; shift
  local args=(); for f in "$@"; do args+=("--from-file=$f"); done
  kubectl -n "$CLUSTER_NS" create configmap "$name" "${args[@]}" --dry-run=client -o yaml \
    | kubectl apply --server-side --force-conflicts -f - >/dev/null
  log "ConfigMap $CLUSTER_NS/$name"
}

# 1) Calico (CNI) cho cluster mới: cùng bản vá VXLAN đã chạy ổn ở cluster capi-quickstart
CALICO_VERSION="${CALICO_VERSION:-v3.29.1}"
mkdir -p .build
if [ ! -s .build/calico.yaml ] || [ "${FORCE_CALICO:-0}" = 1 ]; then
  curl -fsSL "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml" -o .build/calico.yaml
  sed -i -E 's|^( +)# (- name: CALICO_IPV4POOL_CIDR)$|\1\2|g;'\
's|^( +)# (  value: )"192.168.0.0/16"|\1\2"10.243.0.0/16"|g;'\
'/- name: CLUSTER_TYPE/{ n; s/( +value: ").+/\1k8s"/g };'\
'/- name: CALICO_IPV4POOL_IPIP/{ n; s/value: "Always"/value: "Never"/ };'\
'/- name: CALICO_IPV4POOL_VXLAN/{ n; s/value: "Never"/value: "Always"/};'\
'/# Set Felix endpoint to host default action to ACCEPT./a\            - name: FELIX_VXLANPORT\n              value: "6789"' \
  .build/calico.yaml
  grep -q '"10.243.0.0/16"' .build/calico.yaml || die "vá CIDR Calico thất bại"
  grep -q 'FELIX_VXLANPORT' .build/calico.yaml || die "vá VXLAN port Calico thất bại"
fi
cm calico-vxlan .build/calico.yaml

# 2) Manifest baseline (ClusterResourceSet sẽ apply vào workload)
cm sec-baseline-namespaces workload/manifests/00-namespaces.yaml
cm sec-baseline-netpol     workload/manifests/20-quarantine-netpol.yaml
cm sec-baseline-policies   workload/manifests/10-kyverno-policies.yaml
cm sec-lab-target          workload/manifests/30-lab-target.yaml

# 3) Script scan cho CronJob orchestrator (Guide 1, Bước 5)
kubectl create ns scan-orchestrator --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n scan-orchestrator create configmap scan-scripts --from-file=workload/scan/ \
  --dry-run=client -o yaml | kubectl apply --server-side --force-conflicts -f - >/dev/null
log "ConfigMap scan-orchestrator/scan-scripts"

# 4) HelmChartProxy + ClusterResourceSet
for f in workload/addons/*.yaml; do
  sed "s|__LOKI_URL__|${LOKI_URL}|g" "$f" | kubectl -n "$CLUSTER_NS" apply -f -
done
kubectl -n "$CLUSTER_NS" get helmchartproxies,clusterresourcesets
```

`scripts/provision-cluster.sh`

```bash
#!/usr/bin/env bash
# provision-cluster.sh <tên> [--no-lab]
# Cấp phát workload cluster qua CAPI/CAPD rồi gắn nhãn. Các tool bảo mật KHÔNG cài ở đây:
# CAAPH (HelmChartProxy) và ClusterResourceSet ở admin thấy nhãn và tự cài.
# shellcheck disable=SC1091
source "$(dirname "$0")/lib.sh"
need clusterctl
NAME="${1:?usage: provision-cluster.sh <tên> [--no-lab]}"
LABELS=(security-baseline=enabled cni=calico)
[ "${2:-}" = "--no-lab" ] || LABELS+=(lab-target=enabled)

export CLUSTER_TOPOLOGY=true
export POD_CIDR='["10.243.0.0/16"]'

if kubectl -n "$CLUSTER_NS" get cluster "$NAME" >/dev/null 2>&1; then
  log "cluster $NAME đã tồn tại, chỉ gắn nhãn"
else
  log "tạo cluster $NAME (Kubernetes $K8S_VERSION)"
  clusterctl generate cluster "$NAME" -n "$CLUSTER_NS" --flavor development \
    --kubernetes-version "$K8S_VERSION" \
    --control-plane-machine-count=1 --worker-machine-count=1 | kubectl apply -f -
fi
kubectl -n "$CLUSTER_NS" label cluster "$NAME" "${LABELS[@]}" --overwrite

wait_for "kubeconfig của $NAME" 900 "kubectl -n $CLUSTER_NS get secret ${NAME}-kubeconfig"
use_cluster "$NAME"
wait_for "API server của $NAME" 600 "kw get --raw /readyz"

nodes_ready() {
  local total notready
  total=$(kw get nodes --no-headers 2>/dev/null | wc -l)
  notready=$(kw get nodes --no-headers 2>/dev/null | grep -vc ' Ready' || true)
  [ "$total" -ge 2 ] && [ "$notready" -eq 0 ]
}
wait_for "mọi node Ready (Calico do ClusterResourceSet cài)" 900 nodes_ready
log "Xong. Kiểm tra baseline: make verify CLUSTER=$NAME"
```

`scripts/scan-now.sh`

```bash
#!/usr/bin/env bash
# scan-now.sh [cluster]: chạy scan ngay từ VM (không chờ CronJob orchestrator).
# shellcheck disable=SC1091
source "$(dirname "$0")/lib.sh"
use_cluster "${1:-$CLUSTER_NAME}"
: "${DOJO_URL:=http://${ADMIN_NODE_IP}:31080}"
: "${DOJO_API_KEY:?export DOJO_API_KEY trước (Guide 1, Bước 2e)}"
export DOJO_URL DOJO_API_KEY
"$ROOT/workload/scan/run-scans.sh" "$WK_KUBECONFIG" "$CLUSTER_NAME"
```

`workload/tests/helpers.sh`

```bash
#!/usr/bin/env bash
# helpers.sh: tiện ích cho script test (source sau scripts/lib.sh)
PASS=0; FAILED=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; FAILED=$((FAILED + 1)); }
# poll <timeout giây> <lệnh...>: trả 0 khi lệnh thành công, 1 khi hết giờ (không dừng script)
poll() {
  local t="$1" waited=0; shift
  until "$@" >/dev/null 2>&1; do
    waited=$((waited + 3)); [ "$waited" -ge "$t" ] && return 1; sleep 3
  done
}
summary() {
  echo "---- Kết quả: $PASS PASS, $FAILED FAIL"
  [ "$FAILED" -eq 0 ]
}
# falco_has <tên rule> <tên pod>: có alert của rule cho pod đó trong log Falco 10 phút gần nhất
falco_has() {
  kw -n falco logs -l app.kubernetes.io/name=falco -c falco --tail=-1 --since=10m --max-log-requests=10 2>/dev/null \
    | grep -F "\"rule\":\"$1\"" | grep -qF "\"k8s.pod.name\":\"$2\""
}
```

`workload/tests/verify.sh`

```bash
#!/usr/bin/env bash
# verify.sh [cluster]: kiểm tra baseline đã được CAAPH + ClusterResourceSet cài đủ
# shellcheck disable=SC1091
source "$(dirname "$0")/../../scripts/lib.sh"
use_cluster "${1:-$CLUSTER_NAME}"
T="${VERIFY_TIMEOUT:-900}"
log "Kiểm tra baseline trên $CLUSTER_NAME (timeout ${T}s mỗi mục)"

kubectl -n "$CLUSTER_NS" get helmreleaseproxies -l "cluster.x-k8s.io/cluster-name=$CLUSTER_NAME" 2>/dev/null || true

wait_for "Falco DaemonSet" "$T" "kw -n falco rollout status ds/falco --timeout=10s"
wait_for "Falcosidekick" "$T" "kw -n falco rollout status deploy/falco-falcosidekick --timeout=10s"
wait_for "Falco-Talon" "$T" "kw -n falco rollout status deploy/falco-talon --timeout=10s"

sidekick_has() {
  kw -n falco logs deploy/falco-falcosidekick --tail=-1 2>/dev/null | grep 'Enabled Outputs' | grep -q "$1"
}
wait_for "Falcosidekick bật output Loki" 120 "sidekick_has Loki"
wait_for "Falcosidekick bật output WebHook (-> Talon)" 120 "sidekick_has WebHook"

wait_for "Kyverno admission controller" "$T" "kw -n kyverno rollout status deploy/kyverno-admission-controller --timeout=10s"
policy_ready() {
  [ "$(kw get validatingpolicy "$1" -o jsonpath='{.status.conditionStatus.ready}' 2>/dev/null)" = true ]
}
for p in secplat-disallow-privileged secplat-disallow-latest-tag secplat-require-nonroot; do
  wait_for "ValidatingPolicy $p Ready" "$T" "policy_ready $p"
done

wait_for "namespace policy-lab có nhãn policy=enforce" 300 \
  "[ \"\$(kw get ns policy-lab -o jsonpath='{.metadata.labels.policy}')\" = enforce ]"
wait_for "NetworkPolicy quarantine-deny-all" 300 "kw -n vuln-lab get networkpolicy quarantine-deny-all"
wait_for "namespace security-scan" 300 "kw get ns security-scan"

if [ "$(kubectl -n "$CLUSTER_NS" get cluster "$CLUSTER_NAME" -o jsonpath='{.metadata.labels.lab-target}')" = enabled ]; then
  wait_for "lab target vulnerable-workload" "$T" "kw -n vuln-lab rollout status deploy/vulnerable-workload --timeout=10s"
fi
log "Baseline đầy đủ trên $CLUSTER_NAME"
```

`workload/tests/runtime-tests.sh`

```bash
#!/usr/bin/env bash
# runtime-tests.sh [cluster]: kịch bản Sec runtime (Falco -> Falcosidekick -> Talon)
#   RT-1 đọc /etc/shadow trong vuln-lab   -> Falco alert + Talon terminate pod, ReplicaSet tạo pod mới
#   RT-2 chạy binary "xmrig" trong vuln-lab -> Falco alert (custom rule) + Talon gắn nhãn quarantine,
#        NetworkPolicy cắt mạng của pod
#   RT-3 (đối chứng) đọc /etc/shadow ở namespace default -> Falco vẫn alert, Talon KHÔNG xoá pod
# shellcheck disable=SC1091
source "$(dirname "$0")/../../scripts/lib.sh"
# shellcheck disable=SC1091
source "$(dirname "$0")/helpers.sh"
use_cluster "${1:-$CLUSTER_NAME}"
NS=vuln-lab; SEL=app=vulnerable-workload

cur_pod() { # pod Running, chưa bị xoá
  kw -n "$NS" get pods -l "$SEL" \
    -o go-template='{{range .items}}{{if not .metadata.deletionTimestamp}}{{if eq .status.phase "Running"}}{{.metadata.name}}{{"\n"}}{{end}}{{end}}{{end}}' \
    | head -n1
}
has_pod() { [ -n "$(cur_pod)" ]; }
pod_gone() { # đã bị xoá hoặc đang Terminating
  local d
  d="$(kw -n "$NS" get pod "$1" -o jsonpath='{.metadata.deletionTimestamp}' 2>/dev/null)" || return 0
  [ -n "$d" ]
}

poll 180 has_pod || die "không có pod $SEL Running trong $NS (lab-target chưa bật?)"

# ---------- RT-1
log "RT-1: đọc /etc/shadow trong $NS"
P1="$(cur_pod)"
kw -n "$NS" exec "$P1" -- cat /etc/shadow >/dev/null 2>&1 || true
if poll 60 falco_has "Read sensitive file untrusted" "$P1"; then ok "RT-1 Falco phát hiện (Read sensitive file untrusted, pod $P1)"
else bad "RT-1 không thấy alert Falco cho $P1"; fi
if poll 60 pod_gone "$P1"; then ok "RT-1 Talon đã terminate pod $P1"
else bad "RT-1 pod $P1 vẫn chạy (kiểm tra webhook Sidekick -> Talon)"; fi
new_pod() { local p; p="$(cur_pod)"; [ -n "$p" ] && [ "$p" != "$P1" ]; }
if poll 180 new_pod; then ok "RT-1 ReplicaSet tạo pod mới $(cur_pod)"
else bad "RT-1 không có pod mới thay thế"; fi

# ---------- RT-2
log "RT-2: chạy binary giả lập đào coin (xmrig) trong $NS"
P2="$(cur_pod)"
egress_ok() { kw -n "$NS" exec "$P2" -- timeout 5 bash -c 'exec 3<>/dev/tcp/kubernetes.default.svc.cluster.local/443'; }
NET_CHECK=1
egress_ok >/dev/null 2>&1 || { warn "RT-2: pod chưa kết nối được API trước khi test, bỏ qua kiểm tra cắt mạng"; NET_CHECK=0; }
kw -n "$NS" exec "$P2" -- sh -c 'cp /bin/sleep /tmp/xmrig && /tmp/xmrig 1' >/dev/null 2>&1 || true
if poll 60 falco_has "Miner Binary Executed" "$P2"; then ok "RT-2 Falco phát hiện (custom rule Miner Binary Executed)"
else bad "RT-2 không thấy alert custom rule cho $P2"; fi
labeled() { [ "$(kw -n "$NS" get pod "$P2" -o jsonpath='{.metadata.labels.quarantine}')" = true ]; }
if poll 60 labeled; then ok "RT-2 Talon gắn nhãn quarantine=true cho $P2"
else bad "RT-2 pod $P2 không được gắn nhãn quarantine"; fi
if [ "$NET_CHECK" = 1 ]; then
  blocked() { ! egress_ok; }
  if poll 60 blocked; then ok "RT-2 NetworkPolicy đã cắt kết nối ra ngoài của $P2"
  else bad "RT-2 pod $P2 vẫn kết nối ra ngoài được"; fi
fi
kw -n "$NS" delete pod "$P2" --wait=false >/dev/null 2>&1 || true   # dọn: ReplicaSet tạo pod sạch

# ---------- RT-3
log "RT-3 (đối chứng): đọc /etc/shadow ở namespace default"
P3="rt3-$(date +%s)"
kw -n default run "$P3" --image=nginx:1.27 --restart=Never >/dev/null
if kw -n default wait --for=condition=Ready "pod/$P3" --timeout=180s >/dev/null 2>&1; then
  kw -n default exec "$P3" -- cat /etc/shadow >/dev/null 2>&1 || true
  if poll 60 falco_has "Read sensitive file untrusted" "$P3"; then ok "RT-3 Falco vẫn phát hiện ở namespace default"
  else bad "RT-3 không thấy alert Falco cho $P3"; fi
  sleep 15
  if [ -z "$(kw -n default get pod "$P3" -o jsonpath='{.metadata.deletionTimestamp}' 2>/dev/null)" ] \
     && kw -n default get pod "$P3" >/dev/null 2>&1; then
    ok "RT-3 Talon không xoá pod ngoài phạm vi vuln-lab"
  else bad "RT-3 pod $P3 bị xoá dù nằm ngoài phạm vi rule"; fi
else
  bad "RT-3 pod $P3 không Ready"
fi
kw -n default delete pod "$P3" --wait=false >/dev/null 2>&1 || true

summary
```

`workload/tests/policy-tests.sh`

```bash
#!/usr/bin/env bash
# policy-tests.sh [cluster]: kịch bản Policy Enforcement (Kyverno, namespace policy-lab)
#   PE-1 container privileged           -> bị chặn (secplat-disallow-privileged)
#   PE-2 image tag :latest              -> bị chặn (secplat-disallow-latest-tag)
#   PE-3 pod chạy root, thiếu runAsNonRoot -> bị chặn (secplat-require-nonroot)
#   PE-4 pod tuân thủ                    -> được tạo và Running (đối chứng dương)
#   PE-5 pod privileged ở vuln-lab       -> không bị chặn (policy chỉ áp theo nhãn namespace)
# PE-1..3, PE-5 dùng --dry-run=server: đi qua admission webhook thật nhưng không tạo object.
# shellcheck disable=SC1091
source "$(dirname "$0")/../../scripts/lib.sh"
# shellcheck disable=SC1091
source "$(dirname "$0")/helpers.sh"
use_cluster "${1:-$CLUSTER_NAME}"
FX="$(cd "$(dirname "$0")" && pwd)/fixtures"
NS=policy-lab

policy_ready() {
  [ "$(kw get validatingpolicy "$1" -o jsonpath='{.status.conditionStatus.ready}' 2>/dev/null)" = true ]
}
for p in secplat-disallow-privileged secplat-disallow-latest-tag secplat-require-nonroot; do
  poll 300 policy_ready "$p" || die "ValidatingPolicy $p chưa Ready (chạy verify.sh trước)"
done

expect_denied() { # expect_denied <id> <mô tả> <file> <tên policy>
  local out
  if out="$(kw -n "$NS" apply --dry-run=server -f "$3" 2>&1)"; then
    bad "$1 $2: được chấp nhận, mong đợi bị chặn"
  elif grep -q "$4" <<<"$out"; then
    ok "$1 $2: bị chặn bởi $4"
  else
    bad "$1 $2: lỗi khác ($(head -c 300 <<<"$out"))"
  fi
}

log "Kịch bản Policy Enforcement trên $CLUSTER_NAME"
expect_denied PE-1 "Container privileged" "$FX/pod-privileged.yaml" secplat-disallow-privileged
expect_denied PE-2 "Image tag :latest" "$FX/pod-latest.yaml" secplat-disallow-latest-tag
expect_denied PE-3 "Pod chạy root (thiếu runAsNonRoot)" "$FX/pod-root.yaml" secplat-require-nonroot

kw -n "$NS" delete pod pt-compliant --ignore-not-found --wait=true >/dev/null 2>&1 || true
if kw -n "$NS" apply -f "$FX/pod-compliant.yaml" >/dev/null 2>&1 \
   && kw -n "$NS" wait --for=condition=Ready pod/pt-compliant --timeout=180s >/dev/null 2>&1; then
  ok "PE-4 Pod tuân thủ được tạo và Running"
else
  bad "PE-4 Pod tuân thủ không chạy được ($(kw -n "$NS" get pod pt-compliant --no-headers 2>&1 | head -c 200))"
fi
kw -n "$NS" delete pod pt-compliant --ignore-not-found --wait=false >/dev/null 2>&1 || true

if kw -n vuln-lab apply --dry-run=server -f "$FX/pod-privileged.yaml" >/dev/null 2>&1; then
  ok "PE-5 Pod privileged ở vuln-lab không bị chặn (đúng phạm vi policy)"
else
  bad "PE-5 Pod ở vuln-lab bị chặn, policy đang áp quá phạm vi"
fi

summary
```

`workload/tests/e2e.sh`

```bash
#!/usr/bin/env bash
# e2e.sh: cấp phát cluster tạm -> chờ baseline TỰ cài -> chạy toàn bộ kịch bản -> xoá cluster.
# Chứng minh "workload mới cấp phát là có đủ tool bảo mật" mà không cần thao tác tay.
# KEEP=1 để giữ cluster lại sau khi chạy (debug). Cần thêm ~4 GB RAM trống.
# shellcheck disable=SC1091
source "$(dirname "$0")/../../scripts/lib.sh"
NAME="${E2E_NAME:-ci-$(date +%m%d%H%M)}"
cleanup() {
  if [ "${KEEP:-0}" = 1 ]; then warn "KEEP=1, giữ cluster $NAME"; return; fi
  log "xoá cluster $NAME"
  kubectl -n "$CLUSTER_NS" delete cluster "$NAME" --wait=true --timeout=600s || warn "xoá $NAME chưa xong, kiểm tra tay"
}
trap cleanup EXIT

start=$(date +%s)
"$ROOT/scripts/provision-cluster.sh" "$NAME"
"$ROOT/workload/tests/verify.sh" "$NAME"
log "Baseline tự cài xong sau $(( $(date +%s) - start ))s kể từ lúc cấp phát"
rc=0
"$ROOT/workload/tests/runtime-tests.sh" "$NAME" || rc=1
"$ROOT/workload/tests/policy-tests.sh" "$NAME" || rc=1
exit "$rc"
```

`.gitignore`

```bash
.env
.kube-*.yaml
.build/
```

