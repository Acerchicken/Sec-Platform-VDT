#!/usr/bin/env bash
# deploy-workload.sh [tên-cluster] [--no-scan]: dựng TOÀN BỘ phần workload (Guide 2) bằng một lệnh,
# để sẵn sàng demo theo guides/demo-script.md. Chạy SAU scripts/deploy-admin.sh.
#   1. make addons: ConfigMap + HelmChartProxy (Falco, Sidekick, Talon, Kyverno) + ClusterResourceSet
#   2. bật CronJob scan-orchestrator
#   3. workload: chưa có thì cấp phát (CAPI/CAPD, Calico qua CRS); đã có (vd capi-quickstart làm tay)
#      thì gỡ Falco/Talon cài tay rồi gắn nhãn để CAAPH quản lý (Guide 2, mục 3.2)
#   4. make verify: chờ mọi tool tự cài xong
#   5. chuẩn bị demo (demo-script Phần 0.4): kéo sẵn image, chạy trước 1 lượt scan vào DefectDojo
#
#   cd ~/secplat/sec-platform && git pull
#   bash scripts/deploy-workload.sh                  # = capi-quickstart (cluster dùng trong demo)
#   bash scripts/deploy-workload.sh team-a           # cluster mới khác
#   bash scripts/deploy-workload.sh --no-scan        # bỏ lượt scan trước (nhanh hơn)
#
# Idempotent: chạy lại bao nhiêu lần cũng được. Log ghi thêm vào ~/secplat/deploy-workload.log.
# shellcheck disable=SC1091,SC2015
set -euo pipefail

NAME=""; SCAN=1
for a in "$@"; do
  case "$a" in
    --no-scan) SCAN=0 ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    -*) echo "tham số không hợp lệ: $a (xem --help)"; exit 1 ;;
    *) NAME="$a" ;;
  esac
done
NAME="${NAME:-capi-quickstart}"
SECPLAT_DIR="${SECPLAT_DIR:-$HOME/secplat}"
mkdir -p "$SECPLAT_DIR"
exec > >(tee -a "$SECPLAT_DIR/deploy-workload.log") 2>&1

source "$(dirname "$0")/lib.sh"      # ROOT, CLUSTER_NS, ADMIN_NODE_IP, LOKI_URL, log/die/wait_for, use_cluster, kw
cd "$ROOT"
step() { printf '\n\033[1;34m==== %s\033[0m\n' "$*"; }
for c in kubectl helm clusterctl docker jq curl; do need "$c"; done

# ---------------------------------------------------------------- 0) Admin sẵn sàng?
step "0. Kiểm tra admin cluster (Guide 1)"
kubectl config use-context kind-kind >/dev/null 2>&1 || die "không có context kind-kind: chạy bash scripts/deploy-admin.sh trước"
kubectl get --raw /readyz >/dev/null 2>&1 || die "admin cluster không trả lời (docker start kind-control-plane?)"
for d in capi-system/capi-controller-manager capd-system/capd-controller-manager caaph-system/caaph-controller-manager; do
  kubectl -n "${d%%/*}" rollout status deploy "${d#*/}" --timeout=60s >/dev/null || die "$d chưa chạy: bash scripts/deploy-admin.sh"
done
kubectl -n "$CLUSTER_NS" get clusterclass quick-start >/dev/null 2>&1 || die "thiếu ClusterClass quick-start: bash scripts/deploy-admin.sh"
kubectl -n scan-orchestrator get secret dojo-api >/dev/null 2>&1 || die "thiếu secret scan-orchestrator/dojo-api: bash scripts/deploy-admin.sh"
[ -n "$ADMIN_NODE_IP" ] || die "không lấy được ADMIN_NODE_IP"
curl -fsS -m 5 "$LOKI_URL/loki/api/v1/labels" >/dev/null || die "Loki $LOKI_URL không phản hồi (Guide 1, Bước 3)"
log "admin OK, ADMIN_NODE_IP=$ADMIN_NODE_IP"

# ---------------------------------------------------------------- 1) make addons
step "1. Bật cơ chế tự cài (Guide 2, mục 2: make addons)"
bash "$ROOT/scripts/render.sh"

# ---------------------------------------------------------------- 2) CronJob
step "2. Bật CronJob scan-orchestrator (Guide 2, mục 2.3)"
kubectl -n scan-orchestrator patch cronjob scan-orchestrator -p '{"spec":{"suspend":false}}' >/dev/null
log "CronJob scan-orchestrator: suspend=false (quét mỗi 6 giờ)"

# ---------------------------------------------------------------- 3) Workload cluster
step "3. Workload cluster $NAME (Guide 2, mục 3)"
if kubectl -n "$CLUSTER_NS" get cluster "$NAME" >/dev/null 2>&1; then
  log "cluster $NAME đã có"
  baseline="$(kubectl -n "$CLUSTER_NS" get cluster "$NAME" -o jsonpath='{.metadata.labels.security-baseline}')"
  wait_for "kubeconfig của $NAME" 600 "kubectl -n $CLUSTER_NS get secret ${NAME}-kubeconfig"
  use_cluster "$NAME"
  wait_for "API server của $NAME" 600 "kw get --raw /readyz"
  if [ "$baseline" != enabled ]; then
    # Lần đầu đưa vào cơ chế tự cài: gỡ Falco/Talon cài tay (guide v2) để CAAPH cài lại với cấu hình chuẩn.
    # Kyverno cài tay thì giữ: CAAPH upgrade đè lên cùng release (gỡ đi sẽ vướng CRD còn sót).
    for r in falco/falco-talon falco/falco; do
      if helm --kubeconfig="$WK_KUBECONFIG" -n "${r%%/*}" status "${r#*/}" >/dev/null 2>&1; then
        log "gỡ release cài tay ${r#*/} (namespace ${r%%/*})"
        helm --kubeconfig="$WK_KUBECONFIG" -n "${r%%/*}" uninstall "${r#*/}" --wait
      fi
    done
  fi
  LABELS=(security-baseline=enabled lab-target=enabled)
  # Chỉ để CRS cài Calico khi cluster chưa có CNI (capi-quickstart đã cài Calico tay thì KHÔNG gắn)
  if ! kw -n kube-system get ds calico-node >/dev/null 2>&1; then LABELS+=(cni=calico); fi
  kubectl -n "$CLUSTER_NS" label cluster "$NAME" "${LABELS[@]}" --overwrite
else
  bash "$ROOT/scripts/provision-cluster.sh" "$NAME"      # tạo + gắn nhãn (có cni=calico) + chờ node Ready
fi
clusterctl get kubeconfig "$NAME" > "$SECPLAT_DIR/$NAME.kubeconfig"     # cho kw/hw trong ~/secplat/env.sh
chmod 600 "$SECPLAT_DIR/$NAME.kubeconfig"

# ---------------------------------------------------------------- 4) verify
step "4. Chờ CAAPH + ClusterResourceSet cài đủ baseline (make verify)"
bash "$ROOT/workload/tests/verify.sh" "$NAME"

# ---------------------------------------------------------------- 5) Chuẩn bị demo
step "5. Chuẩn bị demo (demo-script, Phần 0.4)"
use_cluster "$NAME"
log "kéo sẵn image nginx:1.27, busybox:1.36 (PE-4, RT-3)"
kw -n default delete pod warm-1 warm-2 --ignore-not-found --wait=true >/dev/null
kw -n default run warm-1 --image=nginx:1.27 --restart=Never >/dev/null
kw -n default run warm-2 --image=busybox:1.36 --restart=Never -- sleep 5 >/dev/null
wait_for "image đã kéo về" 300 \
  "[ \"\$(kw -n default get pod warm-1 warm-2 -o jsonpath='{.items[*].status.containerStatuses[0].imageID}' | wc -w)\" = 2 ]"
kw -n default delete pod warm-1 warm-2 --ignore-not-found >/dev/null

DOJO_API_KEY="$(kubectl -n scan-orchestrator get secret dojo-api -o jsonpath='{.data.token}' | base64 -d)"
DOJO_URL="${DOJO_URL:-http://${ADMIN_NODE_IP}:31080}"
export DOJO_API_KEY DOJO_URL
if [ "$SCAN" = 1 ]; then
  log "chạy trước 1 lượt scan (Trivy + kube-bench -> DefectDojo), có thể mất vài phút"
  bash "$ROOT/scripts/scan-now.sh" "$NAME" || printf '\033[1;33m[WARN]\033[0m scan lỗi, xem ở trên; chạy lại: make scan CLUSTER=%s\n' "$NAME"
fi

cat <<EOF

================ WORKLOAD $NAME SẴN SÀNG DEMO ================
Kiểm tra : kubectl get helmreleaseproxies -A | grep $NAME
DefectDojo: Products -> $NAME (Engagement "Scheduled Scan")
Grafana   : Dashboards -> Security Platform Overview

Mỗi pane tmux khi demo (demo-script, Phần 0.2):
  CLUSTER=$NAME source ~/secplat/env.sh
  export DOJO_API_KEY=\$(kubectl -n scan-orchestrator get secret dojo-api -o jsonpath='{.data.token}' | base64 -d)
Fixture cho Phần 4 nằm ở: $ROOT/workload/tests/fixtures/
Chạy thử toàn bộ kịch bản: make test CLUSTER=$NAME (RT-1/RT-2 xoá/cách ly pod trong vuln-lab,
  nên chạy SAU demo, hoặc trước demo rồi: kw -n vuln-lab rollout restart deploy/vulnerable-workload)
EOF
