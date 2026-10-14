SHELL := /usr/bin/env bash
.SHELLFLAGS := -euo pipefail -c
STRATEGY ?= roundrobin
SESSIONS ?= 6
TURNS ?= 30
CONTEXT ?= 28000
GRAFANA_PORT ?= 3000
ARGOCD_PORT ?= 8080

.PHONY: bootstrap up down endpoint demo strategy bench report grafana argocd lint test

bootstrap: ## one-time: state bucket + budget (needs terraform/bootstrap/terraform.tfvars)
	terraform -chdir=terraform/bootstrap init -input=false
	terraform -chdir=terraform/bootstrap apply -input=false

up: ## create cluster and wait until inference is ready
	scripts/up.sh

down: ## delete NLB, destroy cluster, check leftovers
	scripts/down.sh

endpoint:
	@source scripts/lib.sh && endpoint

demo:
	ENDPOINT=$$(source scripts/lib.sh && endpoint) uv run python -m clients.demo

strategy: ## make strategy S=prefixaware
	scripts/set-strategy.sh $(S)

bench: ## make bench STRATEGY=prefixaware
	scripts/check-strategy.sh $(STRATEGY)
	ENDPOINT=$$(source scripts/lib.sh && endpoint) uv run python -m clients.bench \
	  --label $(STRATEGY) --sessions $(SESSIONS) --turns $(TURNS) --context-tokens $(CONTEXT)

report:
	uv run python -m clients.report results

grafana:
	kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana $(GRAFANA_PORT):80

argocd:
	kubectl -n argocd port-forward svc/argocd-server $(ARGOCD_PORT):80

lint:
	terraform fmt -check -recursive terraform
	for d in terraform/bootstrap terraform/infra; do \
	  terraform -chdir=$$d init -backend=false -input=false >/dev/null && terraform -chdir=$$d validate; \
	done
	tflint --init --config "$$PWD/.tflint.hcl" && tflint --recursive --config "$$PWD/.tflint.hcl"
	scripts/validate-gitops.sh
	shellcheck scripts/*.sh scripts/tests/*.sh
	uv run ruff check .

test:
	uv run pytest -q
	bash scripts/tests/test_lib.sh
	bash scripts/tests/test_down_refuses_with_lb.sh
	bash scripts/tests/test_down_refuses_unreachable.sh
