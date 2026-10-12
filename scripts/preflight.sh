#!/usr/bin/env bash
# preflight.sh [--install]: kiểm tra VM + admin cluster trước khi chạy Guide 2.
#   (không tham số)  chỉ kiểm tra, in OK/WARN/FAIL, exit 1 nếu có FAIL
#   --install        cài các gói/binary còn thiếu trên VM (apt + /usr/local/bin) rồi kiểm tra lại
# Không cần make: chạy được ngay sau git clone (bash scripts/preflight.sh).
# Phần admin cluster (CAPI/CAPD/CAAPH, DefectDojo, Loki...) chỉ kiểm tra, cài theo Guide 1.
# shellcheck disable=SC1091,SC2015
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ -f "$ROOT/.env" ]; then set -a; . "$ROOT/.env"; set +a; fi
: "${CLUSTER_NS:=default}"
: "${ADMIN_CONTAINER:=kind-control-plane}"
: "${CLUSTERCTL_VERSION:=v1.14.0}"     # cùng bản với Guide 1, Bước 1
: "${KIND_VERSION:=latest}"            # hoặc ghim, ví dụ v0.31.0
: "${KUBECTL_VERSION:=}"               # rỗng = bản stable mới nhất

USER="${USER:-$(id -un)}"
INSTALL=0
[ "${1:-}" = "--install" ] && INSTALL=1

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

# ---------- cài đặt (chỉ khi --install)
install_bin() { # install_bin <tên> <url>
  local tmp; tmp="$(mktemp)"
  curl -fsSL "$2" -o "$tmp" && sudo install -m 0755 "$tmp" "/usr/local/bin/$1"
  rm -f "$tmp"
}

do_install() {
  step "Cài gói còn thiếu"
  has apt-get || { fail "chỉ hỗ trợ tự cài trên Ubuntu/Debian (apt); distro khác cài tay các lệnh bên dưới"; return; }
  sudo apt-get update -qq
  sudo apt-get install -y -qq make git jq curl ca-certificates coreutils gawk sed tar gzip >/dev/null \
    && pass "apt: make git jq curl ca-certificates coreutils gawk sed tar gzip"

  if ! has docker; then
    sudo apt-get install -y -qq docker.io >/dev/null && pass "apt: docker.io"
  fi
  if has docker && ! docker info >/dev/null 2>&1; then
    sudo systemctl enable --now docker >/dev/null 2>&1 || true
    if ! id -nG "$USER" | grep -qw docker; then
      sudo usermod -aG docker "$USER"
      warn "đã thêm $USER vào nhóm docker: đăng xuất/đăng nhập lại (hoặc 'newgrp docker') rồi chạy lại preflight"
    fi
  fi

  if ! has kubectl; then
    local v="${KUBECTL_VERSION:-$(curl -fsSL https://dl.k8s.io/release/stable.txt)}"
    install_bin kubectl "https://dl.k8s.io/release/${v}/bin/linux/${ARCH}/kubectl" && pass "kubectl ${v}"
  fi
  if ! has kind; then
    if [ "$KIND_VERSION" = latest ]; then
      install_bin kind "https://github.com/kubernetes-sigs/kind/releases/latest/download/kind-linux-${ARCH}"
    else
      install_bin kind "https://github.com/kubernetes-sigs/kind/releases/download/${KIND_VERSION}/kind-linux-${ARCH}"
    fi
    has kind && pass "kind $(kind version 2>/dev/null | awk '{print $2}')"
  fi
  if ! has helm; then
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash >/dev/null \
      && pass "helm"
  fi
  if ! has clusterctl; then
    install_bin clusterctl \
      "https://github.com/kubernetes-sigs/cluster-api/releases/download/${CLUSTERCTL_VERSION}/clusterctl-linux-${ARCH}" \
      && pass "clusterctl ${CLUSTERCTL_VERSION}"
  fi

  local w i
  w="$(sysctl -n fs.inotify.max_user_watches 2>/dev/null || echo 0)"
  i="$(sysctl -n fs.inotify.max_user_instances 2>/dev/null || echo 0)"
  if [ "$w" -lt 524288 ] || [ "$i" -lt 512 ]; then
    printf 'fs.inotify.max_user_watches=524288\nfs.inotify.max_user_instances=512\n' \
      | sudo tee /etc/sysctl.d/99-kind.conf >/dev/null
    sudo sysctl --system >/dev/null && pass "sysctl inotify (giống Guide 1, Bước 0.3)"
  fi
  chmod +x "$ROOT"/scripts/*.sh "$ROOT"/workload/scan/*.sh "$ROOT"/workload/tests/*.sh 2>/dev/null || true
}

[ "$INSTALL" = 1 ] && do_install

# ---------- 1) Lệnh trên VM
step "1. Lệnh cần có trên VM"
for c in bash make git jq curl awk sed base64 tar docker kubectl kind helm clusterctl; do
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

# ---------- 3) Admin cluster (cài theo Guide 1)
step "3. Admin cluster (Guide 1)"
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
    && pass "CronJob scan-orchestrator" || warn "chưa có CronJob scan-orchestrator (Guide 1, Bước 6)"
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
