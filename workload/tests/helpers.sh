#!/usr/bin/env bash
# helpers.sh: tiện ích cho script test (source sau scripts/lib.sh)
PASS=0; FAILED=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; FAILED=$((FAILED + 1)); }
# poll <timeout giây> <lệnh...>: trả 0 khi lệnh thành công, 1 khi hết giờ (không dừng script)
poll() {
  local t="$1" waited=0; shift
  until "$@" >/dev/null 2>&1; do
    waited=$((waited + 3)); [ "$waited" -ge "$t" ] && return 1; sleep 3
  done
}
summary() {
  echo "---- Kết quả: $PASS PASS, $FAILED FAIL"
  [ "$FAILED" -eq 0 ]
}
# falco_has <tên rule> <tên pod>: có alert của rule cho pod đó trong log Falco 10 phút gần nhất
falco_has() {
  kw -n falco logs -l app.kubernetes.io/name=falco -c falco --tail=-1 --since=10m --max-log-requests=10 2>/dev/null \
    | grep -F "\"rule\":\"$1\"" | grep -qF "\"k8s.pod.name\":\"$2\""
}
