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
