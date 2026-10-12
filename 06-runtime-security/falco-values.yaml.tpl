# Falco DaemonSet + Falcosidekick trên WORKLOAD cluster
# Fan-out: Falcosidekick -> Loki (Admin, NodePort 31100) và -> Falco-Talon (webhook)
# Template: cần ADMIN_NODE_IP (IP node kind trên Docker network "kind"):
#   export ADMIN_NODE_IP=$(docker inspect -f '{{(index .NetworkSettings.Networks "kind").IPAddress}}' kind-control-plane)
#   envsubst '${ADMIN_NODE_IP}' < 06-runtime-security/falco-values.yaml.tpl > /tmp/falco-values.yaml
#   helm --kubeconfig capi-quickstart.kubeconfig upgrade --install falco falcosecurity/falco -n falco -f /tmp/falco-values.yaml
# (Webhook tới Talon đã bật sẵn; nếu Talon chưa cài, sidekick chỉ log lỗi gửi, không ảnh hưởng Loki)
driver: {kind: modern_ebpf}
tty: true
falcosidekick:
  enabled: true
  webui: {enabled: false}
  config:
    customfields: "tenant_id:tenant-poc,target_id:capi-quickstart"
    loki:
      hostport: "http://${ADMIN_NODE_IP}:31100"
      minimumpriority: "notice"
      extralabels: "tenant_id,target_id"
    webhook:
      address: "http://falco-talon:2803"
      minimumpriority: "notice"
