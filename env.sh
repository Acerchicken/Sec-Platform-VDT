# source env.sh  (mỗi terminal mới, hoặc sau khi resume Docker vì IP container có thể đổi)
# Chạy từ thư mục gốc repo. kubectl mặc định trỏ ADMIN cluster (context kind-kind).
# kw / hw = kubectl / helm trỏ workload cluster đang thao tác. Đổi cluster: CLUSTER=team-a source env.sh
export VDT_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export ADMIN_NODE_IP=$(docker inspect -f '{{(index .NetworkSettings.Networks "kind").IPAddress}}' kind-control-plane 2>/dev/null)
export PG_TARGET_IP=$(docker inspect -f '{{(index .NetworkSettings.Networks "kind").IPAddress}}' pg-target 2>/dev/null)
export DOJO_URL="http://${ADMIN_NODE_IP}:31080"
export LOKI_URL="http://${ADMIN_NODE_IP}:31100"
export CLUSTER="${CLUSTER:-capi-quickstart}"
export WORKLOAD_KUBECONFIG="$VDT_HOME/$CLUSTER.kubeconfig"
clusterctl get kubeconfig "$CLUSTER" > "$WORKLOAD_KUBECONFIG" 2>/dev/null || true
kw() { kubectl --kubeconfig="$WORKLOAD_KUBECONFIG" "$@"; }
hw() { helm --kubeconfig="$WORKLOAD_KUBECONFIG" "$@"; }
