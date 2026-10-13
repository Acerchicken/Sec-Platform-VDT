#!/usr/bin/env bash
# scan-now.sh [cluster]: chạy scan ngay từ VM (không chờ CronJob orchestrator).
# shellcheck disable=SC1091
source "$(dirname "$0")/lib.sh"
use_cluster "${1:-$CLUSTER_NAME}"
: "${DOJO_URL:=http://${ADMIN_NODE_IP}:31080}"
: "${DOJO_API_KEY:?export DOJO_API_KEY trước (Guide 1, Bước 2e)}"
export DOJO_URL DOJO_API_KEY
"$ROOT/workload/scan/run-scans.sh" "$WK_KUBECONFIG" "$CLUSTER_NAME"
