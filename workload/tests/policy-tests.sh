#!/usr/bin/env bash
# policy-tests.sh [cluster]: kịch bản Policy Enforcement (Kyverno, namespace policy-lab)
#   PE-1 container privileged           -> bị chặn (vdt-disallow-privileged)
#   PE-2 image tag :latest              -> bị chặn (vdt-disallow-latest-tag)
#   PE-3 pod chạy root, thiếu runAsNonRoot -> bị chặn (vdt-require-nonroot)
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
for p in vdt-disallow-privileged vdt-disallow-latest-tag vdt-require-nonroot; do
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
expect_denied PE-1 "Container privileged" "$FX/pod-privileged.yaml" vdt-disallow-privileged
expect_denied PE-2 "Image tag :latest" "$FX/pod-latest.yaml" vdt-disallow-latest-tag
expect_denied PE-3 "Pod chạy root (thiếu runAsNonRoot)" "$FX/pod-root.yaml" vdt-require-nonroot

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
