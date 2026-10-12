#!/usr/bin/env bash
# Scan orchestrator: tạo Scan Job trong WORKLOAD cluster, gom kết quả, reimport-scan vào DefectDojo.
# Chạy tay trên VM hoặc qua CronJob trên ADMIN cluster (07-scan/kustomization.yaml).
# Biến bắt buộc: WORKLOAD_KUBECONFIG, DOJO_URL, DOJO_API_KEY, PG_TARGET_IP
set -euo pipefail
: "${WORKLOAD_KUBECONFIG:?}" "${DOJO_API_KEY:?}" "${PG_TARGET_IP:?}"
DOJO_URL="${DOJO_URL:?export DOJO_URL=http://<ADMIN_NODE_IP>:31080}"
NS=security-scan; PRODUCT="${PRODUCT:-capi-quickstart}"; ENG="${ENGAGEMENT:-Scheduled Scan}"
TARGET_NS="${TARGET_NS:-vuln-lab}"
WORKDIR="${WORKDIR:-/tmp/vdt-scan}"; mkdir -p "$WORKDIR"

# Template Job: cạnh script (CronJob mount chung /scripts) hoặc ../workload-jobs (chạy tay từ repo)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TPL_DIR="${TEMPLATE_DIR:-$SCRIPT_DIR}"
[ -f "$TPL_DIR/kube-bench-job.yaml" ] || TPL_DIR="$SCRIPT_DIR/../workload-jobs"

K() { kubectl --kubeconfig="$WORKLOAD_KUBECONFIG" "$@"; }

reimport() {  # $1=scan_type $2=file $3=test_title
  curl -sf -X POST "$DOJO_URL/api/v2/reimport-scan/" -H "Authorization: Token $DOJO_API_KEY" \
    -F "scan_type=$1" -F "file=@$2" -F "test_title=$3" \
    -F "product_type_name=Tenant-POC" -F "product_name=$PRODUCT" -F "engagement_name=$ENG" \
    -F "auto_create_context=true" -F "close_old_findings=true" \
    -o /dev/null -w "$3 -> HTTP %{http_code}\n"
}
run_job() {   # $1=job name, manifest từ stdin; in log JSON ra stdout
  K -n $NS delete job "$1" --ignore-not-found >/dev/null
  K -n $NS apply -f - >/dev/null
  K -n $NS wait --for=condition=complete job/"$1" --timeout=600s >/dev/null
  K -n $NS logs job/"$1" | sed -n '/^{/,$p'
}

# 0) Nền: namespace, ConfigMap/Secret target (cập nhật PGHOST theo IP hiện tại)
K apply -f "$TPL_DIR/scan-target.yaml" >/dev/null
K -n $NS patch configmap scan-target --type merge -p "{\"data\":{\"PGHOST\":\"$PG_TARGET_IP\"}}" >/dev/null

# 1) Trivy: mỗi image đang chạy trong $TARGET_NS
for img in $(K -n "$TARGET_NS" get pods -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{end}' | sort -u); do
  job="trivy-$(echo -n "$img" | md5sum | cut -c1-8)"
  sed -e "s|\${JOB_NAME}|$job|g" -e "s|\${SCAN_IMAGE}|$img|g" "$TPL_DIR/trivy-job.yaml.tpl" \
    | run_job "$job" > "$WORKDIR/$job.json"
  reimport "Trivy Scan" "$WORKDIR/$job.json" "Trivy - $img"
done

# 2) kube-bench (CIS, target node)
run_job kube-bench < "$TPL_DIR/kube-bench-job.yaml" > "$WORKDIR/kube-bench.json"
reimport "kube-bench Scanner" "$WORKDIR/kube-bench.json" "kube-bench - $PRODUCT"

# 3) DB target
run_job db-scan < "$TPL_DIR/db-scan-job.yaml" > "$WORKDIR/db-scan.json"
reimport "Generic Findings Import" "$WORKDIR/db-scan.json" "PostgreSQL target"
