# EKS LLM Inference — Design Spec

Date: 2026-10-14
Status: Draft (awaiting review)

## 1. Intent

**Goal.** Gain hands-on experience building production-grade LLM inference
infrastructure on AWS, packaged as a public portfolio project.

**Done means.** From a laptop, a local script sends requests through the
cluster and shows inference working: streamed responses, which replica served
each request, and prefix-cache hits. A benchmark compares routing strategies
for long-context, agent-style sessions.

**Stated by the owner:**
- AWS, Terraform, Kubernetes; two LLM instances; test routing incl. cache-aware.
- Production-level practices; public GitHub repo as a portfolio piece.
- Session-based usage: `up` → experiment → `down` (no always-on cluster).
- Router: vLLM production-stack. Workloads deployed via GitOps (Argo CD).
- Focus workload: long contexts, like agents.

**Constraints:**
- EC2 quota "Running On-Demand G and VT instances" = 8 vCPU → at most 2× g5.xlarge.
- Public repo: no account IDs, IPs, ARNs, or secrets committed.

**Assumptions (correct if wrong):**
- Region `us-east-1` (variable); quota must exist in the chosen region.
- Single AWS account, single environment (no dev/stage/prod split).

## 2. Architecture

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

### Ownership boundaries

| Layer | Owns | Does not own |
|---|---|---|
| `terraform/bootstrap` | S3 state bucket, AWS Budget alert | Anything per-session |
| `terraform/infra` | VPC, EKS, node groups, Pod Identity associations + IAM roles, Argo CD install, Argo cluster secret (GitOps bridge), root Application | In-cluster add-ons and workloads |
| `gitops/` (Argo CD) | LB Controller, NVIDIA device plugin, kube-prometheus-stack, production-stack | AWS resources (except the NLB the LB Controller creates) |
| `clients/` | demo + benchmark | Cluster state |

### GitOps bridge

Terraform writes cluster-specific values as annotations on Argo CD's in-cluster
cluster secret: `cluster_name`, `aws_region`, `vpc_id`, `allowed_cidrs`.
ApplicationSets (cluster generator) template these into Helm values. The repo
therefore contains no account-specific data.

## 3. Components

### 3.1 Terraform

- Community modules: `terraform-aws-modules/vpc/aws`, `terraform-aws-modules/eks/aws`. All provider and module versions pinned.
- State: S3 backend with `use_lockfile = true` (Terraform ≥ 1.10). Bucket created by `bootstrap/`, versioned, encrypted, public access blocked.
- VPC: 2 AZs, public + private subnets, **single NAT gateway** (deliberate cost trade-off; documented).
- EKS: current supported Kubernetes version (pinned), API endpoint public but restricted to `allowed_cidrs`, access entries (no aws-auth ConfigMap), managed add-ons: vpc-cni, coredns, kube-proxy, eks-pod-identity-agent, aws-ebs-csi-driver.
- Node groups (managed):
  - `system`: 2× t3.large, AL2023.
  - `gpu`: 2× g5.xlarge, AL2023 NVIDIA AMI, taint `nvidia.com/gpu=true:NoSchedule`, label `workload=llm`, desired=min=max=2, 100 GiB gp3 root.
- IAM: EKS Pod Identity for AWS LB Controller and EBS CSI. No IRSA, no static keys.
- Argo CD: Helm release (pinned) on system nodes; ClusterIP only.
- Inputs: `region`, `cluster_name`, `allowed_cidrs` (required, no default), `gitops_repo_url`, `gitops_revision`.
- All resources tagged `project=eks-llm-inference`.

### 3.2 GitOps (`gitops/`)

- `bootstrap/root-app.yaml`: app-of-apps pointing at `addons/` and `workloads/`.
- `addons/`: ApplicationSets for aws-load-balancer-controller, nvidia-device-plugin (tolerates GPU taint), kube-prometheus-stack. Chart versions pinned via `targetRevision`.
- `workloads/llm-stack/`: Application for vLLM production-stack Helm chart (pinned) with `values.yaml`:
  - `servingEngineSpec`: 2 replicas, image `vllm/vllm-openai` (pinned tag), model `Qwen/Qwen3-4B`, `maxModelLen 32768`, prefix caching enabled, `gpuMemoryUtilization 0.90`, 1 GPU each, toleration + nodeSelector for GPU nodes, startup probe sized for weight download.
  - `routerSpec`: `routingLogic` (one of the strategies the pinned chart supports, at minimum `roundrobin`, `session`, `prefixaware`), session key `x-session-id`, Service type LoadBalancer → NLB via LB Controller annotations, `loadBalancerSourceRanges` from `allowed_cidrs`.
  - Prometheus ServiceMonitors for router and engines; production-stack Grafana dashboard.
- Switching routing strategy = one-line commit to `values.yaml`.

### 3.3 Clients (`clients/`)

- `demo.py`: reads endpoint from `ENDPOINT` env / `make` output; lists models, streams one chat completion, prints serving replica (from router response header if exposed, otherwise from engine metrics), TTFT, prompt/cached tokens.
- `bench.py`: ported from `local/bench.py` (synthetic agent sessions, growing context, `x-session-id`). Adds: `--label` (strategy name), per-run summary (cache-hit %, TTFT p50/p95, throughput), CSV to `results/`. A `--context-tokens` option grows sessions toward long contexts (up to ~30k tokens).
- Python ≥ 3.11, dependencies pinned in `pyproject.toml`; `ruff` + `pytest`.

### 3.4 Scripts / Makefile

| Target | Behavior |
|---|---|
| `make bootstrap` | One-time: apply `terraform/bootstrap`. |
| `make up` | `terraform apply` infra (`allowed_cidrs` = caller's current IP/32 unless overridden) → update kubeconfig → `wait-ready.sh` → print endpoint. |
| `make demo` / `make bench STRATEGY=…` | Run clients against endpoint. |
| `make grafana` / `make argocd` | Port-forward UIs. |
| `make down` | Delete root Application → wait until no `LoadBalancer` Services remain (timeout, fail loudly) → `terraform destroy` → leftover-resource check (ELBs/ENIs/EBS tagged with cluster name). |
| `make lint` | All CI checks locally. |

## 4. Data flow

1. Client POSTs `/v1/chat/completions` with `x-session-id` to NLB.
2. NLB → router pod (system node).
3. Router selects an engine by `routingLogic` (round-robin / session hash / longest prefix match) and proxies the stream.
4. vLLM serves with automatic prefix caching; `usage.prompt_tokens_details.cached_tokens` returned to the client.
5. Prometheus scrapes router and engine metrics (cache hit rate, queue depth, TTFT); Grafana visualizes.

## 5. Failure handling

- `wait-ready.sh`: explicit timeouts (cluster ~20 min, Argo apps healthy ~10 min, vLLM ready ~10 min); on timeout dumps `kubectl describe` + recent events for unready objects and exits non-zero.
- `down.sh`: refuses `terraform destroy` while any LoadBalancer Service exists.
- Clients: clear error and non-zero exit when endpoint unset/unreachable or a request fails; no silent retries.
- `docs/runbook.md`: GPU capacity/quota errors, Pending pods (taint/nodeSelector), OOM at `maxModelLen`, stuck destroy.

## 6. Security

- Nodes in private subnets; NLB and EKS public API restricted to `allowed_cidrs`.
- Argo CD and Grafana not exposed (port-forward only).
- No secrets required (public repo, public model). Nothing account-specific committed; `.gitignore` covers `*.tfstate*`, `*.tfvars` (example file committed as `*.tfvars.example`), `.terraform/`, kubeconfigs.
- Trivy config scan in CI; accepted findings get inline ignores with justification.

## 7. Testing & CI

CI (GitHub Actions, no AWS credentials, never applies):
- `terraform fmt -check`, `terraform validate` (both stacks, `-backend=false`), `tflint` (AWS ruleset).
- `trivy config` over `terraform/` and `gitops/`.
- `helm template` production-stack with repo values → `kubeconform` (incl. Argo CRD schemas).
- `ruff check`, `pytest` for clients (fake OpenAI-compatible server; no GPU).

Live verification (manual, `docs/runbook.md`):
1. `make up` exits 0 and prints endpoint.
2. `make demo` streams a reply; `/v1/models` lists Qwen3-4B.
3. `make bench` for `roundrobin`, `session`, `prefixaware` → CSVs + table in `docs/results.md`.
4. `make down` exits 0; leftover-resource check is clean.

## 8. Cost (us-east-1 on-demand, approximate)

| Item | $/hr |
|---|---|
| 2× g5.xlarge | ~2.01 |
| 2× t3.large | ~0.17 |
| EKS control plane | 0.10 |
| NAT gateway + NLB | ~0.07 |
| **Total while up** | **~2.35** |

Typical 2–4 h session ≈ $5–10. Budget alert in `bootstrap/` (threshold variable).

## 9. Out of scope (YAGNI)

- Autoscaling (Karpenter, HPA/KEDA), scale-to-zero.
- Multiple environments, multi-region, multi-account.
- TLS/custom domain, auth on the inference endpoint (mitigated by source-IP restriction).
- Model weight caching across sessions (S3/EFS); weights re-download each `up`.
- Disaggregated prefill, LMCache KV offload — candidate follow-ups.
- CI-driven `apply` (would need OIDC role) — candidate follow-up.
- `local/gateway.py` — stays outside this repo; local results summarized in `docs/results.md` as a single-machine baseline.

## 10. Open risks

- g5 capacity may be unavailable in an AZ → node group spans both AZs; runbook covers switching region.
- production-stack chart value names must be verified against the pinned chart version during implementation.
- The serving replica may not be exposed in a response header by the router; demo falls back to per-engine metrics.
