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
