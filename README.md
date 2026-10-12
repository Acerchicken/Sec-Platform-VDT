# VDT Phase 2 – Security Platform: manifests

Matches **Guide 1/2 (Admin cluster)** and **Guide 2/2 (Workload cluster, auto-installed at provisioning)**, see [`docs/vdt-guide-1-admin.md`](docs/vdt-guide-1-admin.md) and [`docs/vdt-guide-2-workload.md`](docs/vdt-guide-2-workload.md).
The admin cluster (kind + CAPI + CAPD + CAAPH) is declared once; any workload cluster labeled `security-baseline=enabled`
automatically gets Falco/Sidekick/Talon, Kyverno, namespaces, NetworkPolicy and policies. No more manual `helm install` into workloads.

```
01-admin-cluster/kind-config.yaml            Admin: kind
02-workload-cluster/                         Admin (kubectl): ClusterClass, Cluster (labeled), calico.yaml (for clusters with Calico installed manually)
04-pg-target/compose.yaml                    Docker (kind network): PostgreSQL target
05-admin-apps/defectdojo|loki|grafana        Admin (helm): values
05-admin-apps/orchestrator/orchestrator.yaml Admin: scan-orchestrator CronJob (multi-cluster, suspended by default)
workload/addons/                             Admin: HelmChartProxy (Falco, Talon, Kyverno) + ClusterResourceSet
workload/manifests/                          Applied to workloads by CRS: namespaces, Kyverno policies, quarantine NetworkPolicy, lab target
workload/scan/                               run-scans.sh + Job templates (loaded into the scan-scripts ConfigMap)
workload/tests/                              verify, RT-1..3, PE-1..5, e2e, fixtures
scripts/                                     lib.sh, render.sh, provision-cluster.sh, scan-now.sh
Makefile, env.sh, env.example                Entry points: make addons | provision | verify | scan | test | e2e
.github/workflows/baseline.yml               CI (lint on GitHub; apply/test/e2e on the self-hosted runner vdt-vm)
docs/                                        Guide 1/2 (Admin) and Guide 2/2 (Workload), in Vietnamese
```

Labels on the `Cluster` object: `security-baseline=enabled` (security tools), `lab-target=enabled` (vulnerable-workload),
`cni=calico` (Calico via CRS, only for clusters that have no CNI yet).

## Prerequisites

Step 0 of Guide 1 is done (SSD, Docker data-root, inotify) and `docker kubectl kind helm clusterctl jq make` are installed.
All commands run on the VM, from the repo root, with kubectl pointing at the admin cluster (`kind-kind`). After cloning: `chmod +x scripts/*.sh workload/scan/*.sh workload/tests/*.sh`.

## Deployment order

```bash
# Guide 1 – Admin
kind create cluster --config 01-admin-cluster/kind-config.yaml
export CLUSTER_TOPOLOGY=true EXP_CLUSTER_RESOURCE_SET=true
clusterctl init --infrastructure docker --addon helm           # CAPI + CAPD + CAAPH
kubectl wait --for=condition=Available deploy --all -A --timeout=10m

helm repo add defectdojo https://raw.githubusercontent.com/DefectDojo/django-DefectDojo/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update
helm upgrade --install defectdojo defectdojo/defectdojo -n defectdojo --create-namespace \
  -f 05-admin-apps/defectdojo/values.yaml --wait --timeout 15m
helm upgrade --install loki grafana/loki -n logging --create-namespace -f 05-admin-apps/loki/values.yaml
export GRAFANA_PASS='<set-a-password>'
export DOJO_DB_PASS=$(kubectl -n defectdojo get secret defectdojo-postgresql-specific -o jsonpath='{.data.postgresql-password}' | base64 -d)
envsubst '${GRAFANA_PASS} ${DOJO_DB_PASS}' < 05-admin-apps/grafana/values.yaml.tpl \
  | helm upgrade --install grafana grafana/grafana -n monitoring --create-namespace -f -

docker compose -f 04-pg-target/compose.yaml up -d
source env.sh
DOJO_PASS=$(kubectl -n defectdojo get secret defectdojo -o jsonpath='{.data.DD_ADMIN_PASSWORD}' | base64 -d)
export DOJO_API_KEY=$(curl -sS -X POST "$DOJO_URL/api/v2/api-token-auth/" -H 'Content-Type: application/json' \
  -d "{\"username\":\"admin\",\"password\":\"$DOJO_PASS\"}" | jq -r .token)

# Orchestrator (the file header has all the secret-creation commands; this step creates the CronJob in suspended state)
kubectl create ns scan-orchestrator --dry-run=client -o yaml | kubectl apply -f -
kubectl -n scan-orchestrator create secret generic dojo-api --from-literal=token="$DOJO_API_KEY" --dry-run=client -o yaml | kubectl apply -f -
kubectl -n scan-orchestrator create secret generic pg-target --from-literal=password=poc-weak-pass --dry-run=client -o yaml | kubectl apply -f -
sed "s|__PG_TARGET_IP__|${PG_TARGET_IP}|" 05-admin-apps/orchestrator/orchestrator.yaml | kubectl apply -f -

# Guide 2 – enable auto-install, then enable the CronJob
make addons
kubectl -n scan-orchestrator patch cronjob scan-orchestrator -p '{"spec":{"suspend":false}}'

# Provision a new workload (gets all tools automatically)
make provision NAME=team-a
make verify CLUSTER=team-a
make test-runtime CLUSTER=team-a && make test-policy CLUSTER=team-a
make scan CLUSTER=team-a                                       # requires DOJO_API_KEY
```

### Bringing `capi-quickstart` (Calico/Falco/Talon installed manually) under auto-install

```bash
make addons
source env.sh
hw uninstall falco-talon -n falco || true     # remove the manual install so CAAPH manages it, avoiding duplicate releases
hw uninstall falco -n falco || true
kubectl label cluster capi-quickstart security-baseline=enabled lab-target=enabled --overwrite   # do NOT add cni=calico
make verify CLUSTER=capi-quickstart
```

## Notes

- **IPs change after Docker resumes**: `source env.sh`, re-run `make addons` (CAAPH updates the Loki address for Sidekick automatically),
  and if `PG_TARGET_IP` changed, re-run the orchestrator `sed ... | kubectl apply` command.
- `workload/addons/10-hcp-falco.yaml` contains `__LOKI_URL__`: `scripts/render.sh` replaces it with the real address when applying. Do not `kubectl apply` this file directly.
- ClusterResourceSet uses `addons.cluster.x-k8s.io/v1beta2` (same version as `Cluster`/`ClusterClass` in this repo).
- The `trivy`, `kube-bench`, `alpine/k8s` images and the Falco/Kyverno charts are not version-pinned yet: pin them before the demo (see the comments in each file).
- Kyverno policies only apply to namespaces labeled `policy=enforce` (default `policy-lab`); `vuln-lab` is intentionally left unlabeled so the lab target keeps running.
