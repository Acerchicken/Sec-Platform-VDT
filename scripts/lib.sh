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
