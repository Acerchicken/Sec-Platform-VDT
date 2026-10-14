#!/usr/bin/env bash
# runtime-tests.sh [cluster]: kịch bản Sec runtime (Falco -> Falcosidekick -> Talon)
#   RT-1 đọc /etc/shadow trong vuln-lab   -> Falco alert + Talon terminate pod, ReplicaSet tạo pod mới
#   RT-2 chạy binary "xmrig" trong vuln-lab -> Falco alert (custom rule) + Talon gắn nhãn quarantine,
#        NetworkPolicy cắt mạng của pod
#   RT-3 (đối chứng) đọc /etc/shadow ở namespace default -> Falco vẫn alert, Talon KHÔNG xoá pod
# shellcheck disable=SC1091
source "$(dirname "$0")/../../scripts/lib.sh"
# shellcheck disable=SC1091
source "$(dirname "$0")/helpers.sh"
use_cluster "${1:-$CLUSTER_NAME}"
NS=vuln-lab; SEL=app=vulnerable-workload

cur_pod() { # pod Running, chưa bị xoá
  kw -n "$NS" get pods -l "$SEL" \
    -o go-template='{{range .items}}{{if not .metadata.deletionTimestamp}}{{if eq .status.phase "Running"}}{{.metadata.name}}{{"\n"}}{{end}}{{end}}{{end}}' \
    | head -n1
}
has_pod() { [ -n "$(cur_pod)" ]; }
pod_gone() { # đã bị xoá hoặc đang Terminating
  local d
  d="$(kw -n "$NS" get pod "$1" -o jsonpath='{.metadata.deletionTimestamp}' 2>/dev/null)" || return 0
  [ -n "$d" ]
}

poll 180 has_pod || die "không có pod $SEL Running trong $NS (lab-target chưa bật?)"

# ---------- RT-1
log "RT-1: đọc /etc/shadow trong $NS"
P1="$(cur_pod)"
kw -n "$NS" exec "$P1" -- cat /etc/shadow >/dev/null 2>&1 || true
if poll 60 falco_has "Read sensitive file untrusted" "$P1"; then ok "RT-1 Falco phát hiện (Read sensitive file untrusted, pod $P1)"
else bad "RT-1 không thấy alert Falco cho $P1"; fi
if poll 60 pod_gone "$P1"; then ok "RT-1 Talon đã terminate pod $P1"
else bad "RT-1 pod $P1 vẫn chạy (kiểm tra webhook Sidekick -> Talon)"; fi
new_pod() { local p; p="$(cur_pod)"; [ -n "$p" ] && [ "$p" != "$P1" ]; }
if poll 180 new_pod; then ok "RT-1 ReplicaSet tạo pod mới $(cur_pod)"
else bad "RT-1 không có pod mới thay thế"; fi

# ---------- RT-2
log "RT-2: chạy binary giả lập đào coin (xmrig) trong $NS"
P2="$(cur_pod)"
egress_ok() { kw -n "$NS" exec "$P2" -- timeout 5 bash -c 'exec 3<>/dev/tcp/kubernetes.default.svc.cluster.local/443'; }
NET_CHECK=1
egress_ok >/dev/null 2>&1 || { warn "RT-2: pod chưa kết nối được API trước khi test, bỏ qua kiểm tra cắt mạng"; NET_CHECK=0; }
kw -n "$NS" exec "$P2" -- sh -c 'cp /bin/sleep /tmp/xmrig && /tmp/xmrig 1' >/dev/null 2>&1 || true
if poll 60 falco_has "Miner Binary Executed" "$P2"; then ok "RT-2 Falco phát hiện (custom rule Miner Binary Executed)"
else bad "RT-2 không thấy alert custom rule cho $P2"; fi
labeled() { [ "$(kw -n "$NS" get pod "$P2" -o jsonpath='{.metadata.labels.quarantine}')" = true ]; }
if poll 60 labeled; then ok "RT-2 Talon gắn nhãn quarantine=true cho $P2"
else bad "RT-2 pod $P2 không được gắn nhãn quarantine"; fi
if [ "$NET_CHECK" = 1 ]; then
  blocked() { ! egress_ok; }
  if poll 60 blocked; then ok "RT-2 NetworkPolicy đã cắt kết nối ra ngoài của $P2"
  else bad "RT-2 pod $P2 vẫn kết nối ra ngoài được"; fi
fi
kw -n "$NS" delete pod "$P2" --wait=false >/dev/null 2>&1 || true   # dọn: ReplicaSet tạo pod sạch

# ---------- RT-3
log "RT-3 (đối chứng): đọc /etc/shadow ở namespace default"
P3="rt3-$(date +%s)"
kw -n default run "$P3" --image=nginx:1.27 --restart=Never >/dev/null
if kw -n default wait --for=condition=Ready "pod/$P3" --timeout=180s >/dev/null 2>&1; then
  kw -n default exec "$P3" -- cat /etc/shadow >/dev/null 2>&1 || true
  if poll 60 falco_has "Read sensitive file untrusted" "$P3"; then ok "RT-3 Falco vẫn phát hiện ở namespace default"
  else bad "RT-3 không thấy alert Falco cho $P3"; fi
  sleep 15
  if [ -z "$(kw -n default get pod "$P3" -o jsonpath='{.metadata.deletionTimestamp}' 2>/dev/null)" ] \
     && kw -n default get pod "$P3" >/dev/null 2>&1; then
    ok "RT-3 Talon không xoá pod ngoài phạm vi vuln-lab"
  else bad "RT-3 pod $P3 bị xoá dù nằm ngoài phạm vi rule"; fi
else
  bad "RT-3 pod $P3 không Ready"
fi
kw -n default delete pod "$P3" --wait=false >/dev/null 2>&1 || true

summary
