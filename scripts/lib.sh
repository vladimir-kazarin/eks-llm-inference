#!/usr/bin/env bash
# Shared helpers for lifecycle scripts. Source, don't execute.
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
INFRA="$ROOT/terraform/infra"
BOOTSTRAP="$ROOT/terraform/bootstrap"
GITOPS_REVISION=${GITOPS_REVISION:-main}
export ROOT INFRA BOOTSTRAP GITOPS_REVISION

log() { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

require_cmd() {
  local c
  for c in "$@"; do command -v "$c" >/dev/null || die "missing required command: $c"; done
}

# Argo CD deploys origin/$GITOPS_REVISION: anything not on that branch silently won't deploy.
require_pushed() {
  git -C "$ROOT" fetch --quiet origin || die "cannot fetch origin"
  git -C "$ROOT" merge-base --is-ancestor HEAD "origin/$GITOPS_REVISION" \
    || die "HEAD is not on origin/$GITOPS_REVISION, which Argo CD deploys. Merge and push to $GITOPS_REVISION first."
}

# Strategy commits must land on the branch Argo CD watches.
require_on_revision_branch() {
  local branch; branch=$(git -C "$ROOT" rev-parse --abbrev-ref HEAD)
  [ "$branch" = "$GITOPS_REVISION" ] \
    || die "on branch '$branch', but Argo CD deploys '$GITOPS_REVISION'. Run: git switch $GITOPS_REVISION"
}

# init infra state backend; needs the bootstrap bucket. Usage: init_infra <region>
init_infra() {
  local bucket
  bucket=$(terraform -chdir="$BOOTSTRAP" output -raw state_bucket 2>/dev/null) \
    || die "no state bucket; run 'make bootstrap' first"
  terraform -chdir="$INFRA" init -input=false \
    -backend-config="bucket=$bucket" -backend-config="region=$1" >/dev/null
}

# A partial 'make down' disables root auto-sync; 'make up' must turn it back on.
restore_root_sync() {
  kubectl -n argocd patch application root --type merge \
    -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'
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

# Fails (rather than reporting 0) when the cluster can't be queried.
lb_service_count() {
  local types
  types=$(kubectl get svc -A -o jsonpath='{range .items[*]}{.spec.type}{"\n"}{end}') || return 1
  printf '%s\n' "$types" | grep -c '^LoadBalancer$' || true
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
