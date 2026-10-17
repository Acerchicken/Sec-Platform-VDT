# Dùng ">" thay cho TAB ở đầu lệnh (GNU make >= 3.82) để copy/paste không hỏng.
.RECIPEPREFIX = >
SHELL := /bin/bash
CLUSTER ?= capi-quickstart
NAME ?=

.PHONY: help deps admin workload preflight addons provision verify scan test-runtime test-policy test e2e lint
help: ## Liệt kê lệnh
> @grep -E '^[a-z0-9-]+:.*## ' Makefile | awk -F':.*## ' '{printf "  make %-13s %s\n", $$1, $$2}'
deps: ## Cài package/binary cần cho Guide 1 + 2 (= bash scripts/install-deps.sh)
> ./scripts/install-deps.sh
admin: ## Dựng toàn bộ admin cluster (Guide 1) bằng 1 lệnh; cài lại sạch DefectDojo: bash scripts/deploy-admin.sh --reset-dojo
> ./scripts/deploy-admin.sh
workload: ## Dựng toàn bộ phần workload (Guide 2) cho demo: make workload [NAME=team-a] (mặc định capi-quickstart)
> ./scripts/deploy-workload.sh $(or $(NAME),$(CLUSTER))
preflight: ## Kiểm tra lệnh/host/admin cluster (cài thiếu: bash scripts/preflight.sh --install)
> ./scripts/preflight.sh
addons: ## Nạp ConfigMap + apply HelmChartProxy/ClusterResourceSet lên admin
> ./scripts/render.sh
provision: ## Cấp phát workload mới: make provision NAME=team-a
> @test -n "$(NAME)" || { echo "thiếu NAME=..."; exit 1; }
> ./scripts/provision-cluster.sh $(NAME)
verify: ## Kiểm tra baseline đã tự cài đủ: make verify CLUSTER=...
> ./workload/tests/verify.sh $(CLUSTER)
scan: ## Chạy scan ngay và đẩy vào DefectDojo (cần DOJO_API_KEY)
> ./scripts/scan-now.sh $(CLUSTER)
test-runtime: ## Kịch bản Sec runtime RT-1..RT-3
> ./workload/tests/runtime-tests.sh $(CLUSTER)
test-policy: ## Kịch bản Policy Enforcement PE-1..PE-5
> ./workload/tests/policy-tests.sh $(CLUSTER)
test: verify test-runtime test-policy ## verify + toàn bộ kịch bản
e2e: ## Cluster tạm: cấp phát -> tự cài -> test -> xoá
> ./workload/tests/e2e.sh
lint: ## shellcheck + yamllint (cần cài sẵn)
> shellcheck scripts/*.sh workload/scan/*.sh workload/tests/*.sh
> yamllint -d '{extends: relaxed, rules: {line-length: disable}}' workload
