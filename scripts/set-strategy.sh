#!/usr/bin/env bash
# GitOps strategy switch: edit values.yaml, commit, push, wait for Argo + router rollout.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
s=${1:?usage: set-strategy.sh roundrobin|session|prefixaware}
[[ "$s" =~ ^(roundrobin|session|prefixaware)$ ]] || die "unknown strategy: $s"
VALUES="$ROOT/gitops/workloads/llm-stack/values.yaml"
require_on_revision_branch

sed -i -E "s/^  routingLogic: .*/  routingLogic: $s/" "$VALUES"
if ! git -C "$ROOT" diff --quiet -- "$VALUES"; then
  git -C "$ROOT" add "$VALUES"
  git -C "$ROOT" commit -m "chore: set router strategy to $s"
  git -C "$ROOT" push
fi
require_pushed
kubectl -n argocd annotate application llm-stack argocd.argoproj.io/refresh=hard --overwrite >/dev/null
strategy_live() { [ "$(router_strategy)" = "$s" ]; }
poll 300 5 "router running --routing-logic $s" strategy_live
kubectl -n llm rollout status deploy/llm-deployment-router --timeout=300s
log "router strategy is $s"
