#!/usr/bin/env bash
# terraform apply infra -> kubeconfig -> wait for everything -> print endpoint.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
require_cmd terraform aws kubectl curl git
require_pushed

BUCKET=$(terraform -chdir="$BOOTSTRAP" output -raw state_bucket 2>/dev/null) \
  || die "no state bucket; run 'make bootstrap' first"
REGION=${REGION:-us-east-1}

if [ -z "${ALLOWED_CIDRS:-}" ]; then
  ip=$(curl -fsS https://checkip.amazonaws.com | tr -d '[:space:]') || die "cannot detect public IP"
  ALLOWED_CIDRS="[\"$ip/32\"]"
fi
log "allowed_cidrs = $ALLOWED_CIDRS"

terraform -chdir="$INFRA" init -input=false \
  -backend-config="bucket=$BUCKET" -backend-config="region=$REGION"
approve=()
[ "${AUTO_APPROVE:-0}" = 1 ] && approve=(-auto-approve)
terraform -chdir="$INFRA" apply -input=false "${approve[@]}" \
  -var "region=$REGION" -var "allowed_cidrs=$ALLOWED_CIDRS"

eval "$(terraform -chdir="$INFRA" output -raw configure_kubectl)"
"$ROOT/scripts/wait-ready.sh"
log "endpoint: $(endpoint)"
