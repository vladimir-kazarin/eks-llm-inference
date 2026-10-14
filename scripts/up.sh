#!/usr/bin/env bash
# terraform apply infra -> kubeconfig -> wait for everything -> print endpoint.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
require_cmd terraform aws kubectl curl git
require_pushed

REGION=${REGION:-us-east-1}

if [ -z "${ALLOWED_CIDRS:-}" ]; then
  ip=$(curl -fsS https://checkip.amazonaws.com | tr -d '[:space:]') || die "cannot detect public IP"
  ALLOWED_CIDRS="[\"$ip/32\"]"
fi
log "allowed_cidrs = $ALLOWED_CIDRS"

init_infra "$REGION"
approve=()
[ "${AUTO_APPROVE:-0}" = 1 ] && approve=(-auto-approve)
terraform -chdir="$INFRA" apply -input=false "${approve[@]}" \
  -var "region=$REGION" -var "allowed_cidrs=$ALLOWED_CIDRS" -var "gitops_revision=$GITOPS_REVISION"

eval "$(terraform -chdir="$INFRA" output -raw configure_kubectl)"
restore_root_sync >/dev/null
"$ROOT/scripts/wait-ready.sh"
log "endpoint: $(endpoint)"
