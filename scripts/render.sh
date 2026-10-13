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
