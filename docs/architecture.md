# Architecture

```
 laptop                                AWS (1 region, 2 AZs)
 demo.py / bench.py ──HTTP──▶ NLB (source-restricted to allowed_cidrs)
                                 │
                 ┌───────────────┴──── EKS, private subnets ───────────────────┐
                 │ system node group: 2× t3.large                              │
                 │   production-stack router, Argo CD, AWS LB Controller,      │
                 │   kube-prometheus-stack                                     │
                 │ gpu node group: 2× g5.xlarge (taint nvidia.com/gpu)         │
                 │   vLLM replica 1 (Qwen3-4B)   vLLM replica 2 (Qwen3-4B)     │
                 └─────────────────────────────────────────────────────────────┘
                                 ▲
                   Argo CD pulls ┘ public GitHub repo (gitops/)
```

## Who owns what

| Layer | Owns | Does not own |
|---|---|---|
| `terraform/bootstrap` | S3 state bucket, AWS Budget alert | Anything per-session |
| `terraform/infra` | VPC, EKS, node groups, Pod Identity, Argo CD, GitOps-bridge secret, root Application | In-cluster add-ons and workloads |
| `gitops/` (Argo CD) | LB Controller, NVIDIA device plugin, kube-prometheus-stack, vLLM production-stack | AWS resources (except the NLB the LB Controller creates) |
| `clients/` | demo + benchmark | Cluster state |

## GitOps bridge

The repo is public and must not contain account-specific values, but Helm charts
need them (cluster name, VPC ID, the caller's IP). Terraform writes them as
annotations on Argo CD's in-cluster cluster secret — `cluster_name`, `aws_region`,
`vpc_id`, `allowed_cidrs`, `gitops_repo_url`, `gitops_revision` — and each
ApplicationSet's cluster generator templates them into Helm values
(`'{{ .metadata.annotations.vpc_id }}'`). Same pattern as the AWS EKS Blueprints
gitops-bridge.

## Request path

1. Client POSTs `/v1/chat/completions` with `x-session-id` to the NLB.
2. NLB → router pod (IP target, system node).
3. Router picks an engine by `routingLogic`: round-robin, session hash on
   `x-session-id`, or longest prefix match; proxies the stream.
4. vLLM serves with automatic prefix caching and returns
   `usage.prompt_tokens_details.cached_tokens`.
5. Prometheus scrapes router and engine metrics; Grafana shows the
   production-stack dashboard.

## Design decisions

**GitOps (Argo CD) instead of Terraform-managed Helm.** Terraform is good at
cloud resources and bad at in-cluster lifecycle (provider config depends on a
cluster created in the same apply; drift is invisible). Argo continuously
reconciles from git, so changing the routing strategy is a reviewed commit rather
than a re-apply. Terraform only bootstraps Argo and hands it the cluster facts.

**One NAT gateway.** A NAT per AZ is the HA answer but doubles a fixed cost that
runs every hour the cluster is up. For a session-based lab the trade-off favours
cost; losing the NAT AZ only interrupts image/weight pulls.

**g5.xlarge + Qwen3-4B.** The account's G-family quota is 8 vCPUs, so two GPU
nodes means 4-vCPU instances: g5.xlarge (A10G 24 GB) or g4dn.xlarge (T4 16 GB).
KV cache per token is similar across Qwen3 sizes because both use 8 KV heads ×
128 dims (≈112 KB/token for 0.6B with 28 layers, ≈144 KB for 4B with 36 layers),
so capacity is set by memory left after weights:

| Setup | Free for KV | Tokens cached / replica | 30k sessions held |
|---|---|---|---|
| g4dn (T4) + 0.6B | ~12 GB | ~110k | ~3 |
| g4dn (T4) + 4B | ~5 GB | ~35k | ~1 |
| g5 (A10G) + 4B | ~12 GB | ~85k | ~2–3 |
| g5 (A10G) + 0.6B | ~19 GB | ~170k | ~5 |

The 4B model also makes a cache miss expensive (seconds of prefill at 30k
tokens), which is what makes routing differences measurable. The model is one
value in `gitops/workloads/llm-stack/values.yaml`.

**EKS Pod Identity over IRSA.** No OIDC provider to manage, no role ARN
annotations in manifests (which would leak account IDs into the public repo); the
association lives entirely in Terraform.

**NLB restricted by source IP rather than authenticated.** Adding auth (API keys,
OIDC at an ALB) is real production work but orthogonal to routing. The endpoint
only accepts the caller's /32, set fresh by `make up`.

**Root app via the argocd-apps chart.** A `kubernetes_manifest` of kind
Application fails at plan time on a fresh cluster because the CRD doesn't exist
yet; a Helm release has no such check.
