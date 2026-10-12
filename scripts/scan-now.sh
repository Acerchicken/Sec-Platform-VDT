#!/usr/bin/env bash
# scan-now.sh [cluster]: chạy scan ngay từ VM (không chờ CronJob orchestrator).
# shellcheck disable=SC1091
source "$(dirname "$0")/lib.sh"
use_cluster "${1:-$CLUSTER_NAME}"
: "${DOJO_URL:=http://${ADMIN_NODE_IP}:31080}"
: "${DOJO_API_KEY:?export DOJO_API_KEY trước (Guide 1, Bước 2e)}"
if [ -z "${PG_TARGET_IP:-}" ]; then
  PG_TARGET_IP="$(docker inspect -f '{{(index .NetworkSettings.Networks "kind").IPAddress}}' pg-target 2>/dev/null || true)"
fi
export DOJO_URL DOJO_API_KEY PG_TARGET_IP
"$ROOT/workload/scan/run-scans.sh" "$WK_KUBECONFIG" "$CLUSTER_NAME"
