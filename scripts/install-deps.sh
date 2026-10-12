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
    && pass "docker compose plugin" || warn "không cài được docker compose plugin (chỉ cần nếu dùng 04-pg-target/compose.yaml; 'docker run' trong Guide 1 vẫn chạy)"
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
