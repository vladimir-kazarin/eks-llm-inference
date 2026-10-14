#!/usr/bin/env bash
# Refuse to benchmark if the live router isn't running the strategy the results will be labelled with.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
want=${1:?usage: check-strategy.sh <strategy>}
have=$(router_strategy) || die "cannot read router deployment (is the cluster up?)"
[ "$have" = "$want" ] || die "router is running '$have', not '$want'. Run: make strategy S=$want"
kubectl -n llm rollout status deploy/llm-deployment-router --timeout=10s >/dev/null \
  || die "router rollout still in progress"
