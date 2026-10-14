#!/usr/bin/env bash
# Block until nodes, GPUs, Argo apps, vLLM pods and the NLB are ready. Dump diagnostics on failure.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
require_cmd kubectl curl

diagnose() {
  echo "---- diagnostics ----" >&2
  kubectl get nodes -o wide >&2 || true
  kubectl -n argocd get applications >&2 || true
  kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded >&2 || true
  kubectl -n llm describe pods >&2 || true
  kubectl get events -A --sort-by=.lastTimestamp 2>/dev/null | tail -40 >&2 || true
}
trap diagnose ERR

nodes_ready() { [ "$(kubectl get nodes --no-headers 2>/dev/null | grep -cw Ready)" -ge 4 ]; }
gpus_allocatable() {
  [ "$(kubectl get nodes -l workload=llm \
      -o jsonpath='{range .items[*]}{.status.allocatable.nvidia\.com/gpu}{"\n"}{end}' \
      | grep -c '^1$')" -eq 2 ]
}
apps_healthy() {
  local s
  s=$(kubectl -n argocd get applications \
    -o jsonpath='{range .items[*]}{.metadata.name}={.status.sync.status}/{.status.health.status}{"\n"}{end}' 2>/dev/null)
  [ "$(echo "$s" | grep -c '=Synced/Healthy$')" -ge 5 ]   # root + 4 children
}
engines_ready() {
  [ "$(kubectl -n llm get pods -l app.kubernetes.io/component=serving-engine --no-headers 2>/dev/null | wc -l)" -eq 2 ] \
    && kubectl -n llm wait --for=condition=Ready pod -l app.kubernetes.io/component=serving-engine --timeout=10s >/dev/null 2>&1
}
endpoint_serving() { local e; e=$(endpoint) && curl -fsS --max-time 5 "$e/v1/models" >/dev/null 2>&1; }

poll 1200 15 "4 Ready nodes" nodes_ready
poll 600 15 "GPU allocatable on both GPU nodes" gpus_allocatable
poll 900 20 "2 vLLM engine pods Ready" engines_ready
poll 900 20 "Argo CD apps Synced/Healthy" apps_healthy
poll 600 15 "NLB serving /v1/models" endpoint_serving
log "ready"
