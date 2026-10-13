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
