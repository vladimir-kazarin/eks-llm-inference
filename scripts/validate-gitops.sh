#!/usr/bin/env bash
# Render the llm-stack chart with repo values and assert the invariants we rely on.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
VALUES="$ROOT/gitops/workloads/llm-stack/values.yaml"
CHART_VERSION=$(grep -A3 'chart: vllm-stack' "$ROOT/gitops/apps/llm-stack.yaml" | awk '/targetRevision/{print $2}')
CRD_SCHEMAS='https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

strategy=$(awk '/^  routingLogic:/{print $2}' "$VALUES")
[[ "$strategy" =~ ^(roundrobin|session|prefixaware)$ ]] || fail "routingLogic '$strategy' not allowed"

helm template llm vllm-stack --repo https://vllm-project.github.io/production-stack \
  --version "$CHART_VERSION" -n llm -f "$VALUES" \
  --set-string 'routerSpec.serviceAnnotations.service\.beta\.kubernetes\.io/load-balancer-source-ranges=203.0.113.10/32' \
  > "$TMP/llm.yaml"

kubeconform -strict -summary -ignore-missing-schemas \
  -schema-location default -schema-location "$CRD_SCHEMAS" "$TMP/llm.yaml"
kubeconform -strict -summary -schema-location default -schema-location "$CRD_SCHEMAS" \
  "$ROOT"/gitops/apps/*.yaml

grep -A1 -- '- "--routing-logic"' "$TMP/llm.yaml" | grep -q "\"$strategy\"" || fail "router not rendered with --routing-logic $strategy"
grep -A1 -- '- "--session-key"' "$TMP/llm.yaml" | grep -q 'x-session-id' || fail "router session key missing"
grep -q -- '- "--enable-prefix-caching"' "$TMP/llm.yaml" || fail "engine prefix caching not enabled"
grep -q -- '- "--enable-prompt-tokens-details"' "$TMP/llm.yaml" || fail "engine must report cached_tokens (--enable-prompt-tokens-details)"
# 2 replicas on exactly 2 GPUs: a surge rollout would leave new pods Pending forever.
awk '/name: "llm-qwen3-4b-deployment-vllm"/{f=1} f&&/strategy:/{getline; print; exit}' "$TMP/llm.yaml" | grep -q 'type: Recreate' || fail "engine Deployment must use Recreate strategy"
# Router imports torch at startup (~20-30s on t3.large); the chart default probe allows ~20s.
router_threshold=$(awk '/name: "llm-deployment-router"/{f=1} f&&/startupProbe:/{s=1} s&&/failureThreshold:/{print $2; exit}' "$TMP/llm.yaml")
[ "${router_threshold:-0}" -ge 24 ] || fail "router startupProbe failureThreshold ${router_threshold:-unset} < 24 (2 min)"
grep -q 'SkipDryRunOnMissingResource=true' "$ROOT/gitops/apps/llm-stack.yaml" || fail "llm-stack must not block on missing ServiceMonitor CRD"
grep -q 'image: "vllm/vllm-openai:v0.31.0"' "$TMP/llm.yaml" || fail "engine image not pinned to v0.31.0"
if grep -q 'runtimeClassName' "$TMP/llm.yaml"; then fail "runtimeClassName must not be set"; fi
if grep -qE -- '- "--(runner|convert|tensor-parallel-size)"' "$TMP/llm.yaml"; then fail "chart example defaults leaked into engine args"; fi
grep -q 'load-balancer-source-ranges' "$TMP/llm.yaml" || fail "NLB source-range annotation missing"
if grep -qE 'targetRevision: *(latest|HEAD)' "$ROOT"/gitops/apps/*.yaml; then fail "unpinned targetRevision in gitops/apps"; fi
echo "gitops validation passed (strategy=$strategy, chart=$CHART_VERSION)"
