# Security Platform: manifests

Matches **Guide 1/2 (Admin cluster)** and **Guide 2/2 (Workload cluster, auto-installed at provisioning)**, see [`docs/guide-1-admin.md`](docs/guide-1-admin.md) and [`docs/guide-2-workload.md`](docs/guide-2-workload.md).
The admin cluster (kind + CAPI + CAPD + CAAPH) is declared once; any workload cluster labeled `security-baseline=enabled`
automatically gets Falco/Sidekick/Talon, Kyverno, namespaces, NetworkPolicy and policies. No more manual `helm install` into workloads.

![Lab architecture](docs/images/lab-architecture.svg)

```
01-admin-cluster/kind-config.yaml            Admin: kind
02-workload-cluster/                         Admin (kubectl): ClusterClass, Cluster (labeled), calico.yaml (for clusters with Calico installed manually)
05-admin-apps/defectdojo|loki|grafana        Admin (helm): values
05-admin-apps/orchestrator/orchestrator.yaml Admin: scan-orchestrator CronJob (multi-cluster, suspended by default)
workload/addons/                             Admin: HelmChartProxy (Falco, Talon, Kyverno) + ClusterResourceSet
workload/manifests/                          Applied to workloads by CRS: namespaces, Kyverno ValidatingPolicy (CEL), quarantine NetworkPolicy, lab target
workload/scan/                               run-scans.sh + Job templates (loaded into the scan-scripts ConfigMap)
workload/tests/                              verify, RT-1..3, PE-1..5, e2e, fixtures
scripts/                                     install-deps.sh, deploy-admin.sh, deploy-workload.sh, preflight.sh, lib.sh, render.sh, provision-cluster.sh, scan-now.sh
Makefile, env.sh, env.example                Entry points: make deps | admin | workload | preflight | addons | provision | verify | scan | test | e2e
docs/                                        Guide 1/2 (Admin) and Guide 2/2 (Workload), in Vietnamese
```

Labels on the `Cluster` object: `security-baseline=enabled` (security tools), `lab-target=enabled` (vulnerable-workload),
`cni=calico` (Calico via CRS, only for clusters that have no CNI yet).

## Prerequisites

An Ubuntu/Debian VM with sudo. On a clean VM, `scripts/install-deps.sh` installs everything both guides need
(`git make jq curl gettext-base rsync`, Docker + compose plugin, `kubectl kind helm clusterctl`, inotify sysctl); see Guide 1, Step 0:

```bash
sudo apt-get update && sudo apt-get install -y git
mkdir -p ~/secplat && cd ~/secplat && git clone https://github.com/Acerchicken/Security-Platform-for-K8s.git sec-platform && cd sec-platform
bash scripts/install-deps.sh                                    # re-login afterwards for the docker group
# optional, only with a dedicated SSD: mount it at /mnt/ssd (Guide 1, Step 0.2), then instead:
# DOCKER_DATA_ROOT=/mnt/ssd/docker bash scripts/install-deps.sh
bash scripts/install-deps.sh                                    # re-run: must end with 0 FAIL
```

After Guide 1, `bash scripts/preflight.sh` (or `make preflight`) checks the VM and the admin cluster before Guide 2; `--install` runs `install-deps.sh` first.
All commands run on the VM, from the repo root, with kubectl pointing at the admin cluster (`kind-kind`).

## Deployment order

Guide 1 in one command (idempotent, safe to re-run; log in `~/secplat/deploy-admin.log`):

```bash
cd ~/secplat/sec-platform && git pull
bash scripts/deploy-admin.sh          # or: make admin; add --reset-dojo to wipe and reinstall DefectDojo
bash scripts/deploy-workload.sh       # or: make workload; Guide 2 for capi-quickstart (or pass a name), ready for the demo
```

The manual equivalent:

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

source env.sh
DOJO_PASS=$(kubectl -n defectdojo get secret defectdojo -o jsonpath='{.data.DD_ADMIN_PASSWORD}' | base64 -d)
export DOJO_API_KEY=$(curl -sS -X POST "$DOJO_URL/api/v2/api-token-auth/" -H 'Content-Type: application/json' \
  -d "{\"username\":\"admin\",\"password\":\"$DOJO_PASS\"}" | jq -r .token)

# Orchestrator (the file header has all the secret-creation commands; this step creates the CronJob in suspended state)
kubectl create ns scan-orchestrator --dry-run=client -o yaml | kubectl apply -f -
kubectl -n scan-orchestrator create secret generic dojo-api --from-literal=token="$DOJO_API_KEY" --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f 05-admin-apps/orchestrator/orchestrator.yaml

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

- **IPs change after Docker resumes**: `source env.sh`, re-run `make addons` (CAAPH updates the Loki address for Sidekick automatically).
- `workload/addons/10-hcp-falco.yaml` contains `__LOKI_URL__`: `scripts/render.sh` replaces it with the real address when applying. Do not `kubectl apply` this file directly.
- ClusterResourceSet uses `addons.cluster.x-k8s.io/v1beta2` (same version as `Cluster`/`ClusterClass` in this repo).
- The `trivy`, `kube-bench`, `alpine/k8s` images and the Falco chart are not version-pinned yet (the Kyverno chart is pinned to 3.9.1 / Kyverno v1.19.1, needed for `policies.kyverno.io/v1`): pin them before the demo (see the comments in each file).
- Kyverno policies are CEL-based `ValidatingPolicy` objects (`kubectl get vpol`), following the [Kyverno migration guide](https://kyverno.io/docs/guides/migration-to-cel/); they only apply to namespaces labeled `policy=enforce` (default `policy-lab`); `vuln-lab` is intentionally left unlabeled so the lab target keeps running.
