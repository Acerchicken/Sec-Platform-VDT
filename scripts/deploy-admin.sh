#!/usr/bin/env bash
# deploy-admin.sh: dựng TOÀN BỘ admin cluster theo Guide 1 bằng một lệnh.
#   kind + CAPI/CAPD/CAAPH (+ClusterResourceSet) -> ClusterClass quick-start -> ~/secplat/env.sh
#   -> DefectDojo -> Loki -> Grafana (+dashboard) -> scan-orchestrator (CronJob, suspend) -> kiểm tra (Bước 8)
#
#   cd ~/secplat/sec-platform && git pull
#   bash scripts/deploy-admin.sh                      # hoặc: make admin
#   GRAFANA_PASS='...' bash scripts/deploy-admin.sh   # đặt mật khẩu Grafana (mặc định: giữ cái cũ / tự sinh)
#   bash scripts/deploy-admin.sh --reset-dojo         # gỡ sạch DefectDojo (cả PVC) rồi cài lại (Guide 1, Bước 2a)
#
# Idempotent: chạy lại bao nhiêu lần cũng được, bước nào đã xong thì bỏ qua / chỉ cập nhật.
# Log ghi thêm vào ~/secplat/deploy-admin.log. Không đụng workload cluster (đó là Guide 2: make addons).
# shellcheck disable=SC2016,SC2015
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SECPLAT_DIR="${SECPLAT_DIR:-$HOME/secplat}"
KIND_NAME=kind
ADMIN_CONTAINER=kind-control-plane
RESET_DOJO=0
for a in "$@"; do
  case "$a" in
    --reset-dojo) RESET_DOJO=1 ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    *) echo "tham số không hợp lệ: $a (xem --help)"; exit 1 ;;
  esac
done

mkdir -p "$SECPLAT_DIR"
exec > >(tee -a "$SECPLAT_DIR/deploy-admin.log") 2>&1

log()  { printf '\033[1;34m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
step() { printf '\n\033[1;34m==== %s\033[0m\n' "$*"; }
ok()   { printf '  \033[1;32m[OK]\033[0m   %s\n' "$*"; }
warn() { printf '  \033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }
has()  { command -v "$1" >/dev/null 2>&1; }
# wait_for "mô tả" <timeout giây> <lệnh...>
wait_for() {
  local desc="$1" timeout="$2" waited=0; shift 2
  until "$@" >/dev/null 2>&1; do
    waited=$((waited + 5))
    [ "$waited" -ge "$timeout" ] && die "hết ${timeout}s chờ: $desc"
    sleep 5
  done
  ok "$desc"
}
admin_ip() { docker inspect -f '{{(index .NetworkSettings.Networks "kind").IPAddress}}' "$ADMIN_CONTAINER" 2>/dev/null; }

# ---------------------------------------------------------------- 0) VM
step "0. Kiểm tra VM (Guide 1, Bước 0)"
missing=""
for c in git jq curl envsubst docker kubectl kind helm clusterctl; do has "$c" || missing="$missing $c"; done
if [ -n "$missing" ]; then
  log "thiếu:$missing -> chạy scripts/install-deps.sh"
  bash "$ROOT/scripts/install-deps.sh" || die "install-deps.sh còn FAIL, xem ở trên"
fi
docker info >/dev/null 2>&1 \
  || die "user $(id -un) chưa dùng được docker. Đăng xuất rồi SSH lại (nhóm docker), sau đó chạy lại script này."
ok "docker: $(docker info -f '{{.DockerRootDir}}')"
mem_gb=$(( $(awk '/MemTotal/{print $2}' /proc/meminfo) / 1024 / 1024 ))
[ "$mem_gb" -ge 15 ] && ok "RAM ${mem_gb} GB" || warn "RAM ${mem_gb} GB < 16 GB: DefectDojo có thể không lên nổi"

# ---------------------------------------------------------------- 1) kind + CAPI
step "1. Admin cluster kind + CAPI/CAPD/CAAPH (Bước 1)"
if kind get clusters 2>/dev/null | grep -qx "$KIND_NAME"; then
  ok "kind cluster '$KIND_NAME' đã có"
  docker start "$ADMIN_CONTAINER" >/dev/null 2>&1 || true      # VM vừa reboot / docker vừa resume
else
  kind create cluster --name "$KIND_NAME" --config "$ROOT/01-admin-cluster/kind-config.yaml"
fi
kubectl config use-context "kind-$KIND_NAME" >/dev/null
wait_for "API server admin trả lời" 180 kubectl get --raw /readyz

export CLUSTER_TOPOLOGY=true EXP_CLUSTER_RESOURCE_SET=true
if ! kubectl get ns capi-system >/dev/null 2>&1; then
  log "clusterctl init --infrastructure docker --addon helm (tải provider từ GitHub)"
  clusterctl init --infrastructure docker --addon helm --wait-providers
elif ! kubectl get ns caaph-system >/dev/null 2>&1; then
  log "đã có CAPI nhưng thiếu CAAPH -> clusterctl init --addon helm"
  clusterctl init --addon helm --wait-providers
else
  ok "CAPI/CAPD/CAAPH đã cài"
fi
for d in cert-manager/cert-manager capi-system/capi-controller-manager \
         capd-system/capd-controller-manager caaph-system/caaph-controller-manager; do
  kubectl -n "${d%%/*}" rollout status deploy "${d#*/}" --timeout=10m >/dev/null \
    && ok "deploy $d" || die "deploy $d chưa Available sau 10 phút (kubectl -n ${d%%/*} get pods)"
done

# Feature gate ClusterResourceSet phải là true (bản cũ có thể tắt)
args="$(kubectl -n capi-system get deploy capi-controller-manager -o json | jq -c '.spec.template.spec.containers[0].args')"
if grep -q 'ClusterResourceSet=false' <<<"$args"; then
  log "bật feature gate ClusterResourceSet=true"
  new="$(jq -c 'map(sub("ClusterResourceSet=false"; "ClusterResourceSet=true"))' <<<"$args")"
  kubectl -n capi-system patch deploy capi-controller-manager --type=json \
    -p "[{\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/args\",\"value\":$new}]"
  kubectl -n capi-system rollout status deploy capi-controller-manager --timeout=5m
fi
ok "ClusterResourceSet bật"

# ClusterClass dùng cho workload (Guide 2 / make provision). Webhook CAPI có thể chưa sẵn ngay sau init -> thử lại.
wait_for "ClusterClass default/quick-start" 300 \
  kubectl apply -f "$ROOT/02-workload-cluster/clusterclass-quick-start.yaml"

# ---------------------------------------------------------------- env.sh dùng chung
ADMIN_NODE_IP="$(admin_ip)"
[ -n "$ADMIN_NODE_IP" ] || die "không lấy được IP của $ADMIN_CONTAINER trên mạng docker 'kind'"
DOJO_URL="http://$ADMIN_NODE_IP:31080"
LOKI_URL="http://$ADMIN_NODE_IP:31100"
if [ ! -f "$SECPLAT_DIR/env.sh" ]; then
  cat > "$SECPLAT_DIR/env.sh" <<'EOF'
export ADMIN_NODE_IP=$(docker inspect -f '{{(index .NetworkSettings.Networks "kind").IPAddress}}' kind-control-plane)
export DOJO_URL=http://$ADMIN_NODE_IP:31080
export LOKI_URL=http://$ADMIN_NODE_IP:31100
export CLUSTER=${CLUSTER:-capi-quickstart}                 # workload đang thao tác; đổi: CLUSTER=team-a source ~/secplat/env.sh
export WORKLOAD_KUBECONFIG="$HOME/secplat/$CLUSTER.kubeconfig"
clusterctl get kubeconfig "$CLUSTER" > "$WORKLOAD_KUBECONFIG" 2>/dev/null || true
kw() { kubectl --kubeconfig="$WORKLOAD_KUBECONFIG" "$@"; }
hw() { helm --kubeconfig="$WORKLOAD_KUBECONFIG" "$@"; }
EOF
  ok "tạo $SECPLAT_DIR/env.sh"
else
  ok "$SECPLAT_DIR/env.sh đã có, giữ nguyên"
fi
log "ADMIN_NODE_IP=$ADMIN_NODE_IP"

helm repo add defectdojo https://raw.githubusercontent.com/DefectDojo/django-DefectDojo/helm-charts --force-update >/dev/null
helm repo add grafana https://grafana.github.io/helm-charts --force-update >/dev/null
helm repo update defectdojo grafana >/dev/null

# ---------------------------------------------------------------- 2) DefectDojo
step "2. DefectDojo (Bước 2)"
if [ "$RESET_DOJO" = 1 ]; then
  log "--reset-dojo: gỡ DefectDojo cũ (cả dữ liệu)"
  pkill -f "port-forward.*defectdojo" 2>/dev/null || true
  helm uninstall defectdojo -n defectdojo --wait 2>/dev/null || true
  kubectl delete pvc --all -n defectdojo --ignore-not-found
  kubectl delete ns defectdojo --ignore-not-found --wait=true
fi
# Đã cài rồi thì KHÔNG helm upgrade: chart sinh lại mật khẩu PostgreSQL trong secret nhưng DB vẫn giữ mật khẩu cũ,
# DefectDojo sẽ không vào được DB. Muốn cài lại: --reset-dojo.
if [ "$(helm status defectdojo -n defectdojo -o json 2>/dev/null | jq -r '.info.status // empty')" = deployed ]; then
  ok "DefectDojo đã cài (bỏ qua; cài lại sạch: --reset-dojo)"
else
  helm uninstall defectdojo -n defectdojo --wait 2>/dev/null || true   # bản cài dở (failed/pending)
  log "helm install defectdojo (thường 5-15 phút, image lớn)"
  helm install defectdojo defectdojo/defectdojo -n defectdojo --create-namespace \
    -f "$ROOT/05-admin-apps/defectdojo/values.yaml" --wait --timeout 20m
fi
if [ "$(kubectl -n defectdojo get svc defectdojo-django -o jsonpath='{.spec.ports[0].nodePort}')" != 31080 ]; then
  log "ép service defectdojo-django về NodePort 31080"
  kubectl -n defectdojo patch svc defectdojo-django --type=json \
    -p='[{"op":"replace","path":"/spec/type","value":"NodePort"},{"op":"replace","path":"/spec/ports/0/nodePort","value":31080}]'
fi
dojo_up() { [[ "$(curl -s -o /dev/null -m 5 -w '%{http_code}' "$DOJO_URL/login")" =~ ^(200|302)$ ]]; }
wait_for "DefectDojo $DOJO_URL/login" 900 dojo_up

DOJO_PASS="$(kubectl -n defectdojo get secret defectdojo -o jsonpath='{.data.DD_ADMIN_PASSWORD}' | base64 -d)"
DOJO_API_KEY=""
for _ in $(seq 1 30); do
  DOJO_API_KEY="$(curl -sS -m 10 -X POST "$DOJO_URL/api/v2/api-token-auth/" -H 'Content-Type: application/json' \
    -d "$(jq -nc --arg p "$DOJO_PASS" '{username:"admin",password:$p}')" 2>/dev/null | jq -r '.token // empty' 2>/dev/null || true)"
  [ -n "$DOJO_API_KEY" ] && break
  sleep 10
done
[ -n "$DOJO_API_KEY" ] || die "không lấy được API token DefectDojo (đăng nhập admin lỗi? xem Guide 1, Bước 2e)"
ok "API token DefectDojo: ${DOJO_API_KEY:0:6}..."

# ---------------------------------------------------------------- 3) Loki
step "3. Loki (Bước 3)"
helm upgrade --install loki grafana/loki -n logging --create-namespace \
  -f "$ROOT/05-admin-apps/loki/values.yaml" --wait --timeout 10m >/dev/null
loki_up() { curl -fsS -m 5 "$LOKI_URL/loki/api/v1/labels" | jq -e '.status == "success"'; }
wait_for "Loki $LOKI_URL" 600 loki_up

# ---------------------------------------------------------------- 4) Grafana
step "4. Grafana (Bước 4)"
if [ -z "${GRAFANA_PASS:-}" ]; then
  GRAFANA_PASS="$(kubectl -n monitoring get secret grafana -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d || true)"
  [ -n "$GRAFANA_PASS" ] || GRAFANA_PASS="$(head -c 18 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 16)"
fi
DOJO_DB_PASS=""
for s in "defectdojo-postgresql-specific:postgresql-password" "defectdojo-postgresql:password" "defectdojo-postgresql:postgres-password"; do
  DOJO_DB_PASS="$(kubectl -n defectdojo get secret "${s%%:*}" -o jsonpath="{.data.${s#*:}}" 2>/dev/null | base64 -d || true)"
  [ -n "$DOJO_DB_PASS" ] && break
done
[ -n "$DOJO_DB_PASS" ] || warn "không tìm thấy mật khẩu DB DefectDojo (kubectl -n defectdojo get secret): datasource DefectDojo sẽ lỗi"
export GRAFANA_PASS DOJO_DB_PASS
envsubst '${GRAFANA_PASS} ${DOJO_DB_PASS}' < "$ROOT/05-admin-apps/grafana/values.yaml.tpl" \
  | helm upgrade --install grafana grafana/grafana -n monitoring --create-namespace -f - --wait --timeout 10m >/dev/null
ok "Grafana NodePort 32000"
# Dashboard dựng sẵn (Bước 7): ConfigMap có nhãn grafana_dashboard=1, sidecar của Grafana tự nạp
kubectl -n monitoring create configmap secplat-dashboards --from-file="$ROOT/05-admin-apps/grafana/dashboards/" \
  --dry-run=client -o yaml | kubectl label -f - --local grafana_dashboard=1 -o yaml | kubectl apply -f - >/dev/null
ok "dashboard 'Security Platform Overview' (Dashboards -> General)"

# ---------------------------------------------------------------- 5) Scan orchestrator
step "5. Scan orchestrator (Bước 5)"
kubectl create ns scan-orchestrator --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n scan-orchestrator create secret generic dojo-api --from-literal=token="$DOJO_API_KEY" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n scan-orchestrator delete secret workload-kubeconfig --ignore-not-found >/dev/null   # bản 1 cluster cũ (guide v2)
kubectl -n scan-orchestrator delete configmap orchestrator-script --ignore-not-found >/dev/null
# Guide 2 có thể đã bật CronJob (suspend=false): giữ nguyên trạng thái đó sau khi apply lại
was_suspended="$(kubectl -n scan-orchestrator get cronjob scan-orchestrator -o jsonpath='{.spec.suspend}' 2>/dev/null || true)"
kubectl apply -f "$ROOT/05-admin-apps/orchestrator/orchestrator.yaml" >/dev/null
if [ "$was_suspended" = false ]; then
  kubectl -n scan-orchestrator patch cronjob scan-orchestrator -p '{"spec":{"suspend":false}}' >/dev/null
  ok "CronJob scan-orchestrator (đang bật, giữ nguyên)"
else
  ok "CronJob scan-orchestrator (suspend, Guide 2 bật lên)"
fi

# ---------------------------------------------------------------- 8) Kiểm tra + bàn giao
step "Kiểm tra (Bước 8)"
fails=0
chk() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else warn "$d"; fails=$((fails + 1)); fi; }
chk "CAAPH Running"            kubectl -n caaph-system rollout status deploy caaph-controller-manager --timeout=10s
chk "DefectDojo $DOJO_URL"     dojo_up
chk "Loki $LOKI_URL"           loki_up
chk "Grafana Running"          kubectl -n monitoring rollout status deploy grafana --timeout=10s
chk "CronJob scan-orchestrator" kubectl -n scan-orchestrator get cronjob scan-orchestrator
chk "ClusterClass quick-start" kubectl -n default get clusterclass quick-start

cat <<EOF

================ ADMIN CLUSTER XONG ($fails cảnh báo) ================
ADMIN_NODE_IP  $ADMIN_NODE_IP
DefectDojo     $DOJO_URL         user admin / $DOJO_PASS
Grafana        http://$ADMIN_NODE_IP:32000   user admin / $GRAFANA_PASS
Loki           $LOKI_URL

Mỗi terminal mới:
  source ~/secplat/env.sh
  export DOJO_API_KEY=\$(kubectl -n scan-orchestrator get secret dojo-api -o jsonpath='{.data.token}' | base64 -d)

Mở UI từ laptop (Guide 1, Bước 6):
  ssh -N -L 18080:$ADMIN_NODE_IP:31080 -L 13000:$ADMIN_NODE_IP:32000 $(id -un)@<IP_VM>
  -> DefectDojo http://127.0.0.1:18080   Grafana http://127.0.0.1:13000

Tiếp theo: Guide 2 (make addons, make provision NAME=...).
EOF
[ "$fails" -eq 0 ]
