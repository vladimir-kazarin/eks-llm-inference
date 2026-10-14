# Runbook

## 1. Prerequisites

- terraform ≥ 1.10, AWS CLI v2 with credentials, kubectl, helm, uv, gh,
  kubeconform, shellcheck, tflint
- GPU quota (must be ≥ 8):
  ```bash
  aws service-quotas get-service-quota --service-code ec2 \
    --quota-code L-DB2E81BA --region us-east-1 --query Quota.Value
  ```
- The repo pushed to GitHub — Argo CD deploys `origin/main` (override with
  `GITOPS_REVISION`), not your laptop. `make up` and `make strategy` refuse to run
  if `HEAD` isn't on that branch.

## 2. One-time bootstrap

```bash
cp terraform/bootstrap/terraform.tfvars.example terraform/bootstrap/terraform.tfvars
$EDITOR terraform/bootstrap/terraform.tfvars    # set alert_email
make bootstrap
```

Confirm the AWS Budgets subscription email. Bootstrap state is local
(`terraform/bootstrap/terraform.tfstate`, gitignored) — back it up. The state
bucket has `prevent_destroy`.

## 3. A session (~$2.35/hr while up)

```bash
make up                                   # ≈ 20–25 min; review and approve the plan
make demo                                 # turn 2 should report large cached tokens
make strategy S=roundrobin && make bench STRATEGY=roundrobin
make strategy S=session    && make bench STRATEGY=session
make strategy S=prefixaware && make bench STRATEGY=prefixaware
make report                               # markdown table from results/*.json
make down                                 # NLB first, then destroy, then leftover check
```

`make strategy` commits and pushes the one-line change to
`gitops/workloads/llm-stack/values.yaml`, then waits until the router is running
it. `make bench` refuses to run if the live router's strategy doesn't match
`STRATEGY`.

UIs: `make grafana` (http://localhost:3000), `make argocd` (http://localhost:8080).
If a port is taken locally: `make grafana GRAFANA_PORT=3001`, `make argocd ARGOCD_PORT=8081`.

## 4. Live verification checklist

1. `make up` exits 0 and prints the endpoint.
2. `make demo` streams a reply; `/v1/models` lists `Qwen/Qwen3-4B`.
3. `make bench` for `roundrobin`, `session`, `prefixaware` writes CSV + JSON to
   `results/`; `make report` renders the comparison.
4. `make down` exits 0 with `clean`.

## 5. Troubleshooting

| Symptom | Check / fix |
|---|---|
| `InsufficientInstanceCapacity` for g5 | Retry later. The VPC only uses AZs that offer the instance type; another region needs G quota there first. |
| GPU nodes Ready, no `nvidia.com/gpu` allocatable | `kubectl -n kube-system logs ds/nvidia-device-plugin`; confirm label `nvidia.com/gpu.present=true` on GPU nodes. |
| vLLM fails with CUDA / "no NVIDIA driver" | The node's default runtime isn't NVIDIA. Add a `RuntimeClass` named `nvidia` (handler `nvidia`) under `gitops/apps/`, set `runtimeClassName: nvidia` in `values.yaml`, and update the matching assertion in `scripts/validate-gitops.sh`. |
| vLLM OOM at startup | Lower `maxModelLen` or `gpuMemoryUtilization` in `values.yaml`. |
| Engine pods Pending | Toleration for `nvidia.com/gpu`, node label `workload=llm`, `kubectl -n llm describe pod`. |
| `make bench` says router strategy mismatch | `make strategy S=<name>`; check `kubectl -n argocd get app llm-stack`. |
| `make down`: "cannot reach the cluster API" | Your public IP changed since `make up`. Run `make up` again (re-applies `allowed_cidrs`, restores Argo auto-sync), then `make down`. |
| `make down` stuck on LoadBalancer | `kubectl -n kube-system logs deploy/aws-load-balancer-controller`. |
| Grafana password | `kubectl -n monitoring get secret kube-prometheus-stack-grafana -o jsonpath='{.data.admin-password}' \| base64 -d` |
