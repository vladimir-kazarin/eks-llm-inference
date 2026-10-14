#!/usr/bin/env bash
# Shared helpers for lifecycle scripts. Source, don't execute.
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
INFRA="$ROOT/terraform/infra"
BOOTSTRAP="$ROOT/terraform/bootstrap"
export ROOT INFRA BOOTSTRAP

log() { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

require_cmd() {
  local c
  for c in "$@"; do command -v "$c" >/dev/null || die "missing required command: $c"; done
}

# Argo CD pulls from GitHub: local commits it can't see would silently not deploy.
require_pushed() {
  git -C "$ROOT" fetch --quiet origin || die "cannot fetch origin"
  local head; head=$(git -C "$ROOT" rev-parse HEAD)
  [ -n "$(git -C "$ROOT" branch -r --contains "$head")" ] \
    || die "HEAD $head is not pushed to origin; Argo CD would deploy stale config. Run: git push"
}

# poll <timeout_s> <interval_s> <description> <command...>
poll() {
  local timeout=$1 interval=$2 desc=$3; shift 3
  local deadline=$((SECONDS + timeout))
  log "waiting for $desc (timeout ${timeout}s)"
  until "$@"; do
    [ "$SECONDS" -lt "$deadline" ] || { echo "timed out waiting for $desc" >&2; return 1; }
    sleep "$interval"
  done
}

lb_service_count() {
  kubectl get svc -A -o jsonpath='{range .items[*]}{.spec.type}{"\n"}{end}' 2>/dev/null \
    | grep -c '^LoadBalancer$' || true
}

router_strategy() {
  kubectl -n llm get deploy llm-deployment-router \
    -o jsonpath='{.spec.template.spec.containers[0].args[*]}' \
    | tr ' ' '\n' | grep -A1 -- '--routing-logic' | tail -1
}

endpoint() {
  local host
  host=$(kubectl -n llm get svc llm-router-service \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
  [ -n "$host" ] || return 1
  echo "http://$host"
}
