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
for p in vdt-disallow-privileged vdt-disallow-latest-tag vdt-require-nonroot; do
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
