#!/usr/bin/env bash
# Remove the NLB via Argo first, then terraform destroy, then check for leftovers.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
require_cmd terraform kubectl aws
REGION=${REGION:-us-east-1}
LB_TIMEOUT=${LB_TIMEOUT:-600}

init_infra "$REGION"
eval "$(terraform -chdir="$INFRA" output -raw configure_kubectl)" \
  || die "cannot configure kubectl from terraform state (is the cluster already gone?)"
# Without API access we can't see (or delete) the NLB; destroying anyway would orphan it.
kubectl get --raw /readyz >/dev/null 2>&1 \
  || die "cannot reach the cluster API. If your public IP changed since 'make up', run 'make up' again (it re-applies allowed_cidrs), then 'make down'."

if kubectl -n argocd get application root >/dev/null 2>&1; then
  log "disabling root auto-sync so Argo doesn't recreate what we delete"
  kubectl -n argocd patch application root --type merge -p '{"spec":{"syncPolicy":null}}'
  log "deleting llm-stack (Service -> NLB)"
  kubectl -n argocd delete applicationset llm-stack --ignore-not-found --wait=false
fi

no_lbs() { local n; n=$(lb_service_count) || return 1; [ "$n" -eq 0 ]; }
poll "$LB_TIMEOUT" 10 "all LoadBalancer Services (and their NLBs) deleted" no_lbs \
  || die "LoadBalancer Services still exist; refusing terraform destroy (it would orphan the NLB and hang deleting the VPC). Inspect: kubectl get svc -A"

CLUSTER=$(terraform -chdir="$INFRA" output -raw cluster_name)
approve=()
[ "${AUTO_APPROVE:-0}" = 1 ] && approve=(-auto-approve)
terraform -chdir="$INFRA" destroy -input=false "${approve[@]}" \
  -var "region=$REGION" -var 'allowed_cidrs=["127.0.0.1/32"]'

log "checking for leftover load-balancer resources tagged for $CLUSTER"
left=$(aws resourcegroupstaggingapi get-resources --region "$REGION" \
  --tag-filters "Key=elbv2.k8s.aws/cluster,Values=$CLUSTER" \
  --query 'ResourceTagMappingList[].ResourceARN' --output text)
[ -z "$left" ] || die "leftover load-balancer resources: $left"
log "clean"
