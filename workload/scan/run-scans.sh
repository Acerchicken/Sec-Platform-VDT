#!/usr/bin/env bash
# run-scans.sh <kubeconfig-workload> <tên-cluster>
# Chạy trong workload: Trivy (vuln + secret) cho image đang chạy, kube-bench (CIS, node),
# rồi reimport vào DefectDojo (product = tên cluster). Dùng chung cho:
#   - scripts/scan-now.sh (chạy tay trên VM)
#   - CronJob scan-orchestrator ở admin (Guide 1, Bước 5), script được mount từ ConfigMap scan-scripts
# Biến môi trường: DOJO_URL, DOJO_API_KEY (bắt buộc); SCAN_NAMESPACES (tùy chọn)
set -euo pipefail
WKCFG="${1:?kubeconfig}"; CLUSTER="${2:?tên cluster}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${DOJO_URL:?}" "${DOJO_API_KEY:?}"
NS=security-scan
SCAN_NAMESPACES="${SCAN_NAMESPACES:-vuln-lab policy-lab}"
TRIVY_IMG="${TRIVY_IMG:-aquasec/trivy:latest}"        # nên pin tag đã kiểm chứng
KB_IMG="${KB_IMG:-aquasec/kube-bench:latest}"
OUT="$(mktemp -d)"; trap 'rm -rf "$OUT"' EXIT
JOB=""; IMAGE=""; rc=0
K() { kubectl --kubeconfig="$WKCFG" "$@"; }

render() { # render <template>: thay placeholder __X__
  sed -e "s|__NS__|$NS|g" -e "s|__JOB__|$JOB|g" -e "s|__IMAGE__|$IMAGE|g" \
      -e "s|__TRIVY_IMG__|$TRIVY_IMG|g" -e "s|__KB_IMG__|$KB_IMG|g" "$DIR/$1"
}

run_job() { # run_job <template>: tạo Job, chờ xong, in JSON kết quả ra stdout
  K -n "$NS" delete job "$JOB" --ignore-not-found --wait=true >/dev/null
  render "$1" | K -n "$NS" apply -f - >/dev/null
  local i s
  for i in $(seq 1 120); do
    s="$(K -n "$NS" get job "$JOB" -o jsonpath='{.status.succeeded}/{.status.failed}' 2>/dev/null || true)"
    case "$s" in
      1/*) break ;;
      */[1-9]*) echo "[$CLUSTER] job $JOB FAILED" >&2; K -n "$NS" logs "job/$JOB" --tail=20 >&2 || true; return 1 ;;
    esac
    [ "$i" -eq 120 ] && { echo "[$CLUSTER] job $JOB quá 10 phút" >&2; return 1; }
    sleep 5
  done
  K -n "$NS" logs "job/$JOB" | sed -n '/^{/,$p'
}

reimport() { # reimport <scan_type> <file> <test_title>: lỗi thì in body DefectDojo ra stderr
  local code
  jq -e . "$2" >/dev/null 2>&1 || {
    echo "[$CLUSTER] $3 -> bỏ qua: kết quả không phải JSON hợp lệ ($(head -c 200 "$2" | tr '\n' ' '))" >&2; return 1; }
  code="$(curl -sS -X POST "$DOJO_URL/api/v2/reimport-scan/" -H "Authorization: Token $DOJO_API_KEY" \
    -F "scan_type=$1" -F "file=@$2" -F "test_title=$3" \
    -F "product_type_name=Tenant-POC" -F "product_name=$CLUSTER" -F "engagement_name=Scheduled Scan" \
    -F "auto_create_context=true" -F "close_old_findings=true" \
    -o "$OUT/resp.txt" -w '%{http_code}')" || return 1
  echo "[$CLUSTER] $3 -> HTTP $code"
  case "$code" in 2??) ;; *) echo "  $(head -c 500 "$OUT/resp.txt")" >&2; return 1 ;; esac
}

K get ns "$NS" >/dev/null || { echo "thiếu namespace $NS (ClusterResourceSet chưa apply?)" >&2; exit 1; }

# 1) Image & static analysis: Trivy cho mọi image đang chạy trong SCAN_NAMESPACES
images="$(for ns in $SCAN_NAMESPACES; do
  K -n "$ns" get pods -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{end}' 2>/dev/null || true
done | sort -u)"
for IMAGE in $images; do
  JOB="trivy-$(printf %s "$IMAGE" | md5sum | cut -c1-8)"
  if run_job trivy-job.yaml.tpl > "$OUT/$JOB.json"; then
    reimport "Trivy Scan" "$OUT/$JOB.json" "Trivy - $IMAGE" || rc=1
  else rc=1; fi
done
IMAGE=""

# 2) CIS benchmark: kube-bench trên node worker
JOB=kube-bench
if run_job kube-bench-job.yaml.tpl > "$OUT/kube-bench.json"; then
  reimport "kube-bench Scan" "$OUT/kube-bench.json" "kube-bench - $CLUSTER" || rc=1
else rc=1; fi
exit "$rc"
