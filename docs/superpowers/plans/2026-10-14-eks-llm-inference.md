# EKS LLM Inference Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A public portfolio repo that stands up an EKS cluster with two vLLM replicas (Qwen3-4B on g5.xlarge) behind the vLLM production-stack router, deployed via Argo CD, plus local clients that demo inference and benchmark routing strategies on long agent-style contexts.

**Architecture:** Terraform (`bootstrap/` for state + budget, `infra/` for VPC/EKS/IAM/Argo CD) builds the platform; Terraform hands cluster facts to Argo CD via annotations on the in-cluster cluster secret (GitOps bridge); Argo CD ApplicationSets in `gitops/apps/` deploy add-ons and the production-stack chart from this public repo. Python clients in `clients/` talk to the router's NLB.

**Tech Stack:** Terraform 1.15, AWS provider 6.69, EKS module 21.29.0, VPC module 6.7.3, eks-pod-identity module 2.9.0, Helm provider 3.3, Kubernetes provider 3.3, Kubernetes 1.36, Argo CD chart 10.10.3, argocd-apps chart 2.0.6, aws-load-balancer-controller chart 3.6.0, nvidia-device-plugin chart 0.20.1, kube-prometheus-stack chart 92.7.0, vllm-stack chart 0.1.13, vLLM image v0.31.0, router image lmcache/lmstack-router:v0.1.13, Python 3.12 + uv, openai 3.31.0, httpx, pytest, ruff.

**Spec:** `docs/superpowers/specs/2026-10-14-eks-llm-inference-design.md`

## Global Constraints

- Region default `us-east-1` (only region with the 8 vCPU G quota on this account).
- GPU node group: exactly 2× `g5.xlarge` (min = max = desired = 2). Never exceed 8 G-family vCPUs.
- Every version is pinned exactly (providers `~>` minor, modules / charts / images exact). No `latest`, no `HEAD`.
- Nothing account-specific in git: no account IDs, ARNs, IPs, emails, bucket names — not in code, docs, or this plan. These flow via `-backend-config`, `TF_VAR_*`, gitignored `*.tfvars`, or Argo cluster-secret annotations.
- All AWS resources tagged `project = "eks-llm-inference"`.
- vLLM model default `Qwen/Qwen3-4B`, `maxModelLen` 32768, prefix caching on, `gpuMemoryUtilization` 0.90.
- Router routing strategies used: `roundrobin`, `session` (key `x-session-id`), `prefixaware`.
- Nodes in private subnets; EKS public API and NLB restricted to `allowed_cidrs`; Argo CD / Grafana ClusterIP only.
- CI never holds AWS credentials and never applies.
- Commits: conventional commits, ending with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Clients: clear error + non-zero exit on bad input / failed request; no silent retries.

## Review Focus

1. **Benchmark labelled with the wrong strategy** — the router still runs the previous `routingLogic` (Argo hasn't synced). Expected: `make bench` refuses to run unless the live router's `--routing-logic` equals `STRATEGY`. Pinned in Task 9 (`scripts/check-strategy.sh`, `router_strategy` test in `test_lib.sh`).
2. **Local commits not pushed** — Argo reads GitHub, not the laptop. Expected: `make up` / `set-strategy.sh` fail with a clear message if `HEAD` isn't on `origin`. Pinned in Task 9 (`require_pushed` test).
3. **Long-context request exceeds `maxModelLen`** — expected: bench rejects `--context-tokens + --max-tokens > --max-model-len` before sending anything. Pinned in Task 2 (`test_rejects_context_over_model_len`).
4. **Server omits `cached_tokens`** — expected: summary shows cache-hit as `n/a`, never a fake `0%`. Pinned in Task 1 (`test_cache_hit_none_when_server_reports_nothing`) and Task 2 (`test_missing_cached_tokens_recorded_as_none`).
5. **`make down` with the NLB still present** — expected: destroy is refused until no `LoadBalancer` Services remain; timeout fails loudly. Pinned in Task 9 (`test_down_refuses_with_lb.sh`).

---

## File Structure

```
eks-llm-inference/
├── .github/workflows/ci.yml          # Task 10
├── .gitignore  .tflint.hcl  .trivyignore.yaml   # Task 1 / 10
├── Makefile                          # Task 9
├── pyproject.toml  uv.lock           # Task 1
├── clients/
│   ├── __init__.py
│   ├── metrics.py     # pure: Summary, percentile, summarize          (Task 1)
│   ├── report.py      # pure+CLI: results/*.json -> markdown table     (Task 1)
│   ├── workload.py    # pure: filler text, turn sizing, validation     (Task 2)
│   ├── bench.py       # CLI: concurrent agent sessions -> CSV + JSON   (Task 2)
│   └── demo.py        # CLI: 2-turn streamed demo, prints cache hits   (Task 3)
├── tests/  __init__.py fakes.py test_metrics.py test_report.py
│           test_workload.py test_bench.py test_demo.py
├── terraform/
│   ├── bootstrap/  versions.tf main.tf variables.tf outputs.tf         (Task 4)
│   └── infra/      versions.tf providers.tf variables.tf vpc.tf eks.tf iam.tf argocd.tf outputs.tf (Tasks 5–6)
├── gitops/
│   ├── apps/       aws-load-balancer-controller.yaml nvidia-device-plugin.yaml
│   │               kube-prometheus-stack.yaml llm-stack.yaml           (Task 7)
│   └── workloads/llm-stack/values.yaml                                 (Task 7)
├── scripts/  lib.sh up.sh wait-ready.sh down.sh set-strategy.sh check-strategy.sh
│             validate-gitops.sh  tests/test_*.sh                       (Tasks 8–9)
├── results/        # bench outputs (*.json committed, *.csv ignored)
└── docs/  architecture.md runbook.md results.md  + README.md           (Task 11)
```

---

### Task 1: Repo scaffold + metrics/report (pure, TDD)

**Files:**
- Create: `.gitignore`, `pyproject.toml`, `clients/__init__.py`, `clients/metrics.py`, `clients/report.py`, `tests/__init__.py`, `tests/test_metrics.py`, `tests/test_report.py`

**Interfaces:**
- Produces:
  - `clients.metrics.Summary` (frozen dataclass): `label: str, requests: int, prompt_tokens: int, cached_tokens: int | None, cache_hit_pct: float | None, ttft_p50_ms: float, ttft_p95_ms: float, output_tok_per_s: float, wall_s: float`
  - `clients.metrics.percentile(values: Sequence[float], pct: float) -> float` (nearest-rank)
  - `clients.metrics.summarize(rows: Sequence[Mapping], label: str, wall_s: float) -> Summary`; row keys: `prompt_tokens:int, cached_tokens:int|None, completion_tokens:int, ttft_ms:float`
  - `clients.report.format_table(summaries: Sequence[Summary]) -> str`
  - `clients.report.load_summaries(directory: Path) -> list[Summary]`

- [ ] **Step 1: Scaffold**

`.gitignore`:
```gitignore
# Terraform
.terraform/
*.tfstate
*.tfstate.*
*.tfvars
!*.tfvars.example
.terraform.tfstate.lock.info
crash.log
# Python
.venv/
__pycache__/
.pytest_cache/
.ruff_cache/
# Local
kubeconfig*
results/*.csv
.env
```

`pyproject.toml`:
```toml
[project]
name = "eks-llm-inference-clients"
version = "0.1.0"
requires-python = ">=3.12"
dependencies = ["openai==3.31.0", "httpx>=0.28,<1"]

[dependency-groups]
dev = ["pytest>=8", "pytest-asyncio>=0.24", "ruff>=0.7"]

[tool.pytest.ini_options]
asyncio_mode = "auto"
testpaths = ["tests"]

[tool.ruff]
line-length = 100
target-version = "py312"

[tool.ruff.lint]
select = ["E", "F", "I", "B", "UP", "SIM"]
```

`clients/__init__.py` and `tests/__init__.py`: empty files.

Run: `uv sync` → creates `.venv` and `uv.lock`.

- [ ] **Step 2: Write failing tests**

`tests/test_metrics.py`:
```python
import pytest

from clients.metrics import percentile, summarize


def row(prompt, cached, completion=10, ttft=100.0):
    return {"prompt_tokens": prompt, "cached_tokens": cached,
            "completion_tokens": completion, "ttft_ms": ttft}


def test_percentile_nearest_rank():
    values = [10, 20, 30, 40, 50, 60, 70, 80, 90, 100]
    assert percentile(values, 50) == 50
    assert percentile(values, 95) == 100
    assert percentile([7], 95) == 7


def test_percentile_rejects_empty():
    with pytest.raises(ValueError):
        percentile([], 50)


def test_summarize_computes_cache_hit_and_latency():
    rows = [row(1000, 0, ttft=500), row(2000, 1000, ttft=100), row(3000, 2000, ttft=120)]
    s = summarize(rows, "prefixaware", wall_s=2.0)
    assert s.label == "prefixaware"
    assert s.requests == 3
    assert s.prompt_tokens == 6000
    assert s.cached_tokens == 3000
    assert s.cache_hit_pct == pytest.approx(50.0)
    assert s.ttft_p50_ms == 120
    assert s.ttft_p95_ms == 500
    assert s.output_tok_per_s == pytest.approx(15.0)


def test_cache_hit_none_when_server_reports_nothing():
    rows = [row(1000, None), row(2000, None)]
    s = summarize(rows, "roundrobin", wall_s=1.0)
    assert s.cached_tokens is None
    assert s.cache_hit_pct is None


def test_summarize_rejects_empty_rows_and_bad_wall():
    with pytest.raises(ValueError):
        summarize([], "x", wall_s=1.0)
    with pytest.raises(ValueError):
        summarize([row(1, 0)], "x", wall_s=0)
```

`tests/test_report.py`:
```python
import json

from clients.metrics import Summary
from clients.report import format_table, load_summaries


def make(label, hit):
    return Summary(label=label, requests=10, prompt_tokens=1000,
                   cached_tokens=None if hit is None else 500, cache_hit_pct=hit,
                   ttft_p50_ms=120.0, ttft_p95_ms=900.0, output_tok_per_s=42.5, wall_s=10.0)


def test_format_table_sorted_and_na():
    out = format_table([make("session", 80.0), make("roundrobin", None)])
    lines = out.splitlines()
    assert lines[0].startswith("| strategy |")
    assert lines[2].startswith("| roundrobin |")
    assert "n/a" in lines[2]
    assert "80.0%" in lines[3]


def test_load_summaries_round_trip(tmp_path):
    s = make("prefixaware", 75.0)
    (tmp_path / "prefixaware-abc.json").write_text(json.dumps(s.__dict__))
    (tmp_path / "ignore.csv").write_text("x")
    assert load_summaries(tmp_path) == [s]
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `uv run pytest -q`
Expected: FAIL — `ModuleNotFoundError: No module named 'clients.metrics'`

- [ ] **Step 4: Implement**

`clients/metrics.py`:
```python
"""Pure summary statistics for benchmark rows."""
import math
from collections.abc import Mapping, Sequence
from dataclasses import dataclass


@dataclass(frozen=True)
class Summary:
    label: str
    requests: int
    prompt_tokens: int
    cached_tokens: int | None
    cache_hit_pct: float | None
    ttft_p50_ms: float
    ttft_p95_ms: float
    output_tok_per_s: float
    wall_s: float


def percentile(values: Sequence[float], pct: float) -> float:
    """Nearest-rank percentile."""
    if not values:
        raise ValueError("percentile of empty sequence")
    ordered = sorted(values)
    rank = max(1, math.ceil(pct / 100 * len(ordered)))
    return ordered[min(rank, len(ordered)) - 1]


def summarize(rows: Sequence[Mapping], label: str, wall_s: float) -> Summary:
    if not rows:
        raise ValueError("no rows to summarize")
    if wall_s <= 0:
        raise ValueError(f"wall_s must be positive, got {wall_s}")
    prompt = sum(r["prompt_tokens"] for r in rows)
    reported = [r["cached_tokens"] for r in rows if r["cached_tokens"] is not None]
    cached = sum(reported) if reported else None
    hit = None if cached is None or prompt == 0 else 100 * cached / prompt
    ttfts = [r["ttft_ms"] for r in rows]
    return Summary(
        label=label,
        requests=len(rows),
        prompt_tokens=prompt,
        cached_tokens=cached,
        cache_hit_pct=hit,
        ttft_p50_ms=percentile(ttfts, 50),
        ttft_p95_ms=percentile(ttfts, 95),
        output_tok_per_s=sum(r["completion_tokens"] for r in rows) / wall_s,
        wall_s=wall_s,
    )
```

`clients/report.py`:
```python
"""Render benchmark summaries (results/*.json) as a markdown table.

  uv run python -m clients.report results/
"""
import argparse
import json
from collections.abc import Sequence
from pathlib import Path

from clients.metrics import Summary

HEADER = ("| strategy | requests | cache hit | TTFT p50 ms | TTFT p95 ms | output tok/s |\n"
          "|---|---|---|---|---|---|")


def _pct(value: float | None) -> str:
    return "n/a" if value is None else f"{value:.1f}%"


def format_table(summaries: Sequence[Summary]) -> str:
    rows = [f"| {s.label} | {s.requests} | {_pct(s.cache_hit_pct)} | {s.ttft_p50_ms:.0f} "
            f"| {s.ttft_p95_ms:.0f} | {s.output_tok_per_s:.1f} |"
            for s in sorted(summaries, key=lambda s: s.label)]
    return "\n".join([HEADER, *rows])


def load_summaries(directory: Path) -> list[Summary]:
    return [Summary(**json.loads(p.read_text())) for p in sorted(directory.glob("*.json"))]


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("directory", type=Path, nargs="?", default=Path("results"))
    args = p.parse_args()
    summaries = load_summaries(args.directory)
    if not summaries:
        raise SystemExit(f"no *.json summaries in {args.directory}")
    print(format_table(summaries))


if __name__ == "__main__":
    main()
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `uv run pytest -q && uv run ruff check .`
Expected: all PASS, ruff clean.

- [ ] **Step 6: Commit**

```bash
git add .gitignore pyproject.toml uv.lock clients tests
git commit -m "feat: add benchmark metrics and report rendering"
```

---

### Task 2: Workload generator + bench CLI

**Files:**
- Create: `clients/workload.py`, `clients/bench.py`, `tests/fakes.py`, `tests/test_workload.py`, `tests/test_bench.py`

**Interfaces:**
- Consumes: `clients.metrics.summarize`, `Summary`; `clients.report.format_table`
- Produces:
  - `clients.workload.TOKENS_PER_WORD: float = 1.23`
  - `clients.workload.filler(rng: random.Random, n_words: int) -> str`
  - `clients.workload.turn_words_for(context_tokens: int, system_words: int, turns: int, reply_tokens: int) -> int`
  - `clients.workload.validate_budget(context_tokens: int, max_tokens: int, max_model_len: int) -> None` (raises `ValueError`)
  - `clients.bench.run_bench(client: AsyncOpenAI, args: argparse.Namespace) -> tuple[list[dict], float]` (rows, wall seconds)
  - `clients.bench.write_outputs(rows, summary: Summary, out_dir: Path, run_id: str) -> tuple[Path, Path]`
  - `tests.fakes.fake_openai(cached_tokens: int | None = 64, fail: bool = False) -> AsyncOpenAI` — backed by `httpx.MockTransport`; requests recorded in `client.recorded` as `(headers: dict, body: dict)`.
  - CLI: `python -m clients.bench --base-url URL --label NAME [--sessions N --turns N --context-tokens N --system-words N --max-tokens N --max-model-len N --model M --out-dir DIR --run-id ID]`

- [ ] **Step 1: Write failing tests**

`tests/fakes.py`:
```python
"""In-process fake of an OpenAI-compatible streaming chat endpoint."""
import json

import httpx
from openai import AsyncOpenAI


def _sse(obj) -> str:
    return f"data: {json.dumps(obj)}\n\n"


def fake_openai(cached_tokens: int | None = 64, fail: bool = False) -> AsyncOpenAI:
    recorded = []

    def handler(request: httpx.Request) -> httpx.Response:
        body = json.loads(request.content)
        recorded.append((dict(request.headers), body))
        if fail:
            return httpx.Response(500, json={"error": {"message": "boom"}})
        prompt = sum(len(m["content"].split()) for m in body["messages"])
        usage = {"prompt_tokens": prompt, "completion_tokens": 3, "total_tokens": prompt + 3}
        if cached_tokens is not None:
            usage["prompt_tokens_details"] = {"cached_tokens": cached_tokens}
        base = {"id": "x", "object": "chat.completion.chunk", "created": 0, "model": body["model"]}
        chunks = [
            {**base, "choices": [{"index": 0, "delta": {"content": "next step"},
                                  "finish_reason": None}]},
            {**base, "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}]},
            {**base, "choices": [], "usage": usage},
        ]
        text = "".join(_sse(c) for c in chunks) + "data: [DONE]\n\n"
        return httpx.Response(200, text=text, headers={"content-type": "text/event-stream"})

    client = AsyncOpenAI(base_url="http://fake/v1", api_key="none", max_retries=0,
                         http_client=httpx.AsyncClient(transport=httpx.MockTransport(handler)))
    client.recorded = recorded
    return client
```

`tests/test_workload.py`:
```python
import random

import pytest

from clients.workload import filler, turn_words_for, validate_budget


def test_filler_is_deterministic_per_seed():
    assert filler(random.Random(1), 5) == filler(random.Random(1), 5)
    assert len(filler(random.Random(1), 7).split()) == 7


def test_turn_words_reaches_target_context():
    words = turn_words_for(context_tokens=28000, system_words=1500, turns=30, reply_tokens=48)
    total_tokens = (1500 + 30 * words) * 1.23 + 30 * 48
    assert 27000 <= total_tokens <= 28000


def test_turn_words_rejects_too_small_context():
    with pytest.raises(ValueError, match="system prompt"):
        turn_words_for(context_tokens=1000, system_words=1500, turns=10, reply_tokens=48)


def test_rejects_context_over_model_len():
    with pytest.raises(ValueError, match="max-model-len"):
        validate_budget(context_tokens=32768, max_tokens=48, max_model_len=32768)
    validate_budget(context_tokens=28000, max_tokens=48, max_model_len=32768)
```

`tests/test_bench.py`:
```python
import argparse
import csv
import json

import pytest

from clients.bench import run_bench, write_outputs
from clients.metrics import summarize
from tests.fakes import fake_openai


def args(**kw):
    base = dict(sessions=2, turns=3, context_tokens=4000, system_words=200, max_tokens=8,
                max_model_len=32768, model="Qwen/Qwen3-4B", run_id="t1", label="session")
    return argparse.Namespace(**{**base, **kw})


async def test_sessions_send_stable_session_id_and_end_header():
    client = fake_openai()
    rows, wall = await run_bench(client, args())
    assert len(rows) == 6 and wall > 0
    by_session = {}
    for headers, _ in client.recorded:
        by_session.setdefault(headers["x-session-id"], []).append(headers.get("x-session-end"))
    assert set(by_session) == {"t1-0", "t1-1"}
    for ends in by_session.values():
        assert ends == [None, None, "1"]


async def test_context_grows_each_turn():
    rows, _ = await run_bench(fake_openai(), args(sessions=1))
    prompts = [r["prompt_tokens"] for r in rows]
    assert prompts == sorted(prompts) and prompts[0] < prompts[-1]


async def test_missing_cached_tokens_recorded_as_none():
    rows, _ = await run_bench(fake_openai(cached_tokens=None), args(sessions=1))
    assert all(r["cached_tokens"] is None for r in rows)


async def test_budget_checked_before_any_request():
    client = fake_openai()
    with pytest.raises(ValueError, match="max-model-len"):
        await run_bench(client, args(context_tokens=40000))
    assert client.recorded == []


async def test_server_error_propagates():
    with pytest.raises(Exception):  # noqa: B017 - any API error must surface
        await run_bench(fake_openai(fail=True), args(sessions=1))


async def test_write_outputs(tmp_path):
    rows, wall = await run_bench(fake_openai(), args(sessions=1))
    csv_path, json_path = write_outputs(rows, summarize(rows, "session", wall), tmp_path, "t1")
    assert csv_path.name == "session-t1.csv"
    assert len(list(csv.DictReader(csv_path.open()))) == 3
    assert json.loads(json_path.read_text())["label"] == "session"
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `uv run pytest -q tests/test_workload.py tests/test_bench.py`
Expected: FAIL — `ModuleNotFoundError: No module named 'clients.workload'`

- [ ] **Step 3: Implement `clients/workload.py`**

```python
"""Synthetic agent-session text: a long system prompt plus growing tool results."""
import random

# Measured locally: 1500 filler words -> ~1846 Qwen3 prompt tokens.
TOKENS_PER_WORD = 1.23

WORDS = ("node pod cache token batch queue shard replica latency tensor kernel "
         "socket buffer thread commit branch deploy rollback metric trace span "
         "volume secret ingress gateway probe quota cluster region bucket").split()


def filler(rng: random.Random, n_words: int) -> str:
    return " ".join(rng.choice(WORDS) for _ in range(n_words))


def turn_words_for(context_tokens: int, system_words: int, turns: int, reply_tokens: int) -> int:
    """Words per tool result so the final turn's context is about `context_tokens`."""
    if turns <= 0:
        raise ValueError("turns must be positive")
    budget_words = (context_tokens - turns * reply_tokens) / TOKENS_PER_WORD - system_words
    if budget_words < turns:
        raise ValueError(f"context_tokens={context_tokens} leaves no room after the system prompt "
                         f"({system_words} words) and {turns} replies")
    return int(budget_words / turns)


def validate_budget(context_tokens: int, max_tokens: int, max_model_len: int) -> None:
    if context_tokens + max_tokens > max_model_len:
        raise ValueError(f"context_tokens ({context_tokens}) + max_tokens ({max_tokens}) exceeds "
                         f"--max-model-len ({max_model_len})")
```

- [ ] **Step 4: Implement `clients/bench.py`**

```python
"""Replay synthetic long-context agent sessions against the router.

Each session is one growing conversation (system prompt + N tool results).
Every request carries x-session-id; the last one carries x-session-end: 1.
Writes results/<label>-<run_id>.csv (per request) and .json (summary).

  uv run python -m clients.bench --base-url http://<nlb>/v1 --label prefixaware \
      --sessions 6 --turns 30 --context-tokens 28000
"""
import argparse
import asyncio
import csv
import json
import os
import random
import sys
import time
import uuid
from pathlib import Path

from openai import AsyncOpenAI

from clients.metrics import Summary, summarize
from clients.report import format_table
from clients.workload import filler, turn_words_for, validate_budget

FIELDS = ["session", "turn", "prompt_tokens", "cached_tokens", "completion_tokens",
          "ttft_ms", "total_ms"]


async def _turn(client, args, messages, headers):
    start = time.perf_counter()
    ttft, text, usage = None, [], None
    stream = await client.chat.completions.create(
        model=args.model, messages=messages, temperature=0, max_tokens=args.max_tokens,
        stream=True, stream_options={"include_usage": True}, extra_headers=headers,
        extra_body={"chat_template_kwargs": {"enable_thinking": False}},
    )
    async for chunk in stream:
        if chunk.usage:
            usage = chunk.usage
        if chunk.choices and chunk.choices[0].delta.content:
            if ttft is None:
                ttft = time.perf_counter() - start
            text.append(chunk.choices[0].delta.content)
    total = time.perf_counter() - start
    if usage is None:
        raise RuntimeError("server returned no usage block; cannot measure cache hits")
    details = getattr(usage, "prompt_tokens_details", None)
    cached = getattr(details, "cached_tokens", None) if details else None
    return "".join(text) or "ok", usage, cached, ttft or total, total


async def run_session(client, args, sid, turn_words, rows):
    rng = random.Random(f"{args.run_id}-{sid}")
    # Session id first so sessions never share a prefix; run id so reruns never hit old cache.
    system = (f"Run {args.run_id} session {sid}. You are a coding agent. Tool docs: "
              + filler(rng, args.system_words))
    messages = [{"role": "system", "content": system}]
    for turn in range(args.turns):
        messages = [*messages, {"role": "user", "content":
                    f"Tool result {turn}: {filler(rng, turn_words)}\n"
                    "Reply with one short sentence on the next step."}]
        headers = {"x-session-id": f"{args.run_id}-{sid}"}
        if turn == args.turns - 1:
            headers = {**headers, "x-session-end": "1"}
        reply, usage, cached, ttft, total = await _turn(client, args, messages, headers)
        messages = [*messages, {"role": "assistant", "content": reply}]
        rows.append({"session": sid, "turn": turn, "prompt_tokens": usage.prompt_tokens,
                     "cached_tokens": cached, "completion_tokens": usage.completion_tokens,
                     "ttft_ms": round(ttft * 1000, 1), "total_ms": round(total * 1000, 1)})


async def run_bench(client: AsyncOpenAI, args) -> tuple[list[dict], float]:
    validate_budget(args.context_tokens, args.max_tokens, args.max_model_len)
    turn_words = turn_words_for(args.context_tokens, args.system_words, args.turns,
                                args.max_tokens)
    rows: list[dict] = []
    start = time.perf_counter()
    await asyncio.gather(*(run_session(client, args, s, turn_words, rows)
                           for s in range(args.sessions)))
    wall = time.perf_counter() - start
    return sorted(rows, key=lambda r: (r["session"], r["turn"])), wall


def write_outputs(rows, summary: Summary, out_dir: Path, run_id: str) -> tuple[Path, Path]:
    out_dir.mkdir(parents=True, exist_ok=True)
    csv_path = out_dir / f"{summary.label}-{run_id}.csv"
    json_path = out_dir / f"{summary.label}-{run_id}.json"
    with csv_path.open("w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=FIELDS)
        w.writeheader()
        w.writerows({**r, "cached_tokens": "" if r["cached_tokens"] is None else r["cached_tokens"]}
                    for r in rows)
    json_path.write_text(json.dumps(summary.__dict__, indent=2))
    return csv_path, json_path


def _default_base_url() -> str:
    endpoint = os.environ.get("ENDPOINT", "")
    return f"{endpoint.rstrip('/')}/v1" if endpoint else ""


def parse_args(argv=None):
    p = argparse.ArgumentParser()
    p.add_argument("--base-url", default=_default_base_url())
    p.add_argument("--label", required=True, help="routing strategy name, e.g. prefixaware")
    p.add_argument("--model", default="Qwen/Qwen3-4B")
    p.add_argument("--sessions", type=int, default=6)
    p.add_argument("--turns", type=int, default=30)
    p.add_argument("--context-tokens", type=int, default=28000)
    p.add_argument("--system-words", type=int, default=1500)
    p.add_argument("--max-tokens", type=int, default=48)
    p.add_argument("--max-model-len", type=int, default=32768)
    p.add_argument("--out-dir", type=Path, default=Path("results"))
    p.add_argument("--run-id", default=uuid.uuid4().hex[:8])
    args = p.parse_args(argv)
    if not args.base_url:
        p.error("--base-url or ENDPOINT is required (run `make endpoint`)")
    for name in ("sessions", "turns", "max_tokens"):
        if getattr(args, name) <= 0:
            p.error(f"--{name.replace('_', '-')} must be positive")
    return args


def main(argv=None) -> None:
    args = parse_args(argv)
    client = AsyncOpenAI(base_url=args.base_url, api_key="none", timeout=600, max_retries=0)
    try:
        rows, wall = asyncio.run(run_bench(client, args))
    except ValueError as e:
        sys.exit(f"invalid workload: {e}")
    except Exception as e:  # network / server failures: report and fail, no retries
        sys.exit(f"benchmark failed: {type(e).__name__}: {e}")
    summary = summarize(rows, args.label, wall)
    csv_path, json_path = write_outputs(rows, summary, args.out_dir, args.run_id)
    print(format_table([summary]))
    print(f"wrote {csv_path} and {json_path}")


if __name__ == "__main__":
    main()
```

- [ ] **Step 5: Run tests**

Run: `uv run pytest -q && uv run ruff check .`
Expected: all PASS.

- [ ] **Step 6: Commit**

```bash
git add clients tests
git commit -m "feat: add long-context agent session benchmark"
```

---

### Task 3: Demo CLI

**Files:**
- Create: `clients/demo.py`, `tests/test_demo.py`

**Interfaces:**
- Consumes: `clients.workload.filler`
- Produces: `clients.demo.TurnResult(turn:int, ttft_ms:float, prompt_tokens:int, cached_tokens:int|None, backend_headers:dict[str,str], text:str)`; `clients.demo.parse_sse_line(line: str) -> dict | None`; `clients.demo.run_demo(http: httpx.AsyncClient, base_url: str, model: str) -> list[TurnResult]`. CLI: `python -m clients.demo [--endpoint URL] [--model M]` (or `ENDPOINT` env).

- [ ] **Step 1: Write failing tests**

`tests/test_demo.py`:
```python
import json

import httpx
import pytest

from clients.demo import parse_sse_line, run_demo


def test_parse_sse_line():
    assert parse_sse_line('data: {"a": 1}') == {"a": 1}
    assert parse_sse_line("data: [DONE]") is None
    assert parse_sse_line("") is None
    assert parse_sse_line(": keepalive") is None


def transport(cached_second=1800):
    calls = {"n": 0}

    def handler(request):
        if request.url.path.endswith("/models"):
            return httpx.Response(200, json={"data": [{"id": "Qwen/Qwen3-4B"}]})
        calls["n"] += 1
        cached = 0 if calls["n"] == 1 else cached_second
        chunks = [
            {"choices": [{"delta": {"content": "hello"}}]},
            {"choices": [], "usage": {"prompt_tokens": 2000, "completion_tokens": 1,
                                      "prompt_tokens_details": {"cached_tokens": cached}}},
        ]
        body = "".join(f"data: {json.dumps(c)}\n\n" for c in chunks) + "data: [DONE]\n\n"
        return httpx.Response(200, text=body, headers={"x-backend": "pod-a"})

    return httpx.MockTransport(handler)


async def test_demo_two_turns_show_cache_hit_on_second():
    async with httpx.AsyncClient(transport=transport()) as http:
        results = await run_demo(http, "http://fake", "Qwen/Qwen3-4B")
    assert [r.turn for r in results] == [1, 2]
    assert results[0].cached_tokens == 0
    assert results[1].cached_tokens == 1800
    assert results[1].backend_headers == {"x-backend": "pod-a"}
    assert results[0].text == "hello"


async def test_demo_fails_when_model_missing():
    async with httpx.AsyncClient(transport=transport()) as http:
        with pytest.raises(RuntimeError, match="not served"):
            await run_demo(http, "http://fake", "other/model")
```

- [ ] **Step 2: Run to verify failure**

Run: `uv run pytest -q tests/test_demo.py`
Expected: FAIL — `ModuleNotFoundError: No module named 'clients.demo'`

- [ ] **Step 3: Implement `clients/demo.py`**

```python
"""Show inference working end to end through the router.

Sends two turns of one session. Turn 2 extends turn 1's prompt, so its
cached_tokens should be large: proof that prefix caching + routing work.
Prints any x-* response headers so you can see what the router exposes.

  ENDPOINT=http://<nlb> uv run python -m clients.demo
"""
import argparse
import asyncio
import json
import os
import random
import sys
import time
import uuid
from dataclasses import dataclass

import httpx

from clients.workload import filler


@dataclass(frozen=True)
class TurnResult:
    turn: int
    ttft_ms: float
    prompt_tokens: int
    cached_tokens: int | None
    backend_headers: dict[str, str]
    text: str


def parse_sse_line(line: str) -> dict | None:
    if not line.startswith("data: "):
        return None
    payload = line[len("data: "):].strip()
    return None if payload == "[DONE]" else json.loads(payload)


async def _stream_turn(http, base_url, model, messages, session_id, turn) -> TurnResult:
    body = {"model": model, "messages": messages, "stream": True, "max_tokens": 64,
            "temperature": 0, "stream_options": {"include_usage": True},
            "chat_template_kwargs": {"enable_thinking": False}}
    start = time.perf_counter()
    ttft, text, usage = None, [], None
    async with http.stream("POST", f"{base_url}/v1/chat/completions", json=body,
                           headers={"x-session-id": session_id}) as resp:
        resp.raise_for_status()
        backend = {k: v for k, v in resp.headers.items()
                   if k.lower().startswith("x-") and k.lower() != "x-request-id"}
        async for line in resp.aiter_lines():
            event = parse_sse_line(line)
            if event is None:
                continue
            usage = event.get("usage") or usage
            for choice in event.get("choices", []):
                piece = choice.get("delta", {}).get("content")
                if piece:
                    ttft = ttft or time.perf_counter() - start
                    text.append(piece)
    if usage is None:
        raise RuntimeError("no usage block in stream")
    cached = (usage.get("prompt_tokens_details") or {}).get("cached_tokens")
    return TurnResult(turn, round((ttft or time.perf_counter() - start) * 1000, 1),
                      usage["prompt_tokens"], cached, backend, "".join(text))


async def run_demo(http: httpx.AsyncClient, base_url: str, model: str) -> list[TurnResult]:
    models = (await http.get(f"{base_url}/v1/models")).raise_for_status().json()
    served = [m["id"] for m in models.get("data", [])]
    if model not in served:
        raise RuntimeError(f"model {model} not served; router reports {served}")
    sid = f"demo-{uuid.uuid4().hex[:8]}"
    rng = random.Random(sid)
    messages = [{"role": "system", "content": f"Session {sid}. Tool docs: " + filler(rng, 1500)},
                {"role": "user", "content": "In one sentence, what is a KV cache?"}]
    first = await _stream_turn(http, base_url, model, messages, sid, 1)
    messages = [*messages, {"role": "assistant", "content": first.text},
                {"role": "user", "content": "And why does routing affect it? One sentence."}]
    second = await _stream_turn(http, base_url, model, messages, sid, 2)
    return [first, second]


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--endpoint", default=os.environ.get("ENDPOINT"))
    p.add_argument("--model", default="Qwen/Qwen3-4B")
    args = p.parse_args()
    if not args.endpoint:
        p.error("--endpoint or ENDPOINT is required (run `make endpoint`)")
    base = args.endpoint.rstrip("/")

    async def go():
        async with httpx.AsyncClient(timeout=httpx.Timeout(300, connect=10)) as http:
            return await run_demo(http, base, args.model)

    try:
        results = asyncio.run(go())
    except (httpx.HTTPError, RuntimeError) as e:
        sys.exit(f"demo failed: {type(e).__name__}: {e}")
    for r in results:
        hit = "n/a" if r.cached_tokens is None else f"{r.cached_tokens}/{r.prompt_tokens}"
        print(f"turn {r.turn}: TTFT {r.ttft_ms:.0f} ms | cached {hit} | headers {r.backend_headers}")
        print(f"  > {r.text.strip()}")


if __name__ == "__main__":
    main()
```

- [ ] **Step 4: Run tests**

Run: `uv run pytest -q && uv run ruff check .`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add clients/demo.py tests/test_demo.py
git commit -m "feat: add two-turn streaming demo client"
```

---

### Task 4: Terraform bootstrap (state bucket + budget)

**Files:**
- Create: `terraform/bootstrap/{versions.tf,main.tf,variables.tf,outputs.tf,terraform.tfvars.example}`

**Interfaces:**
- Produces: output `state_bucket` (string). Consumed by `scripts/up.sh` via `terraform -chdir=terraform/bootstrap output -raw state_bucket`.

Bootstrap uses **local state** (gitignored) — the chicken-and-egg of remote state; documented in runbook.

- [ ] **Step 1: Write files**

`terraform/bootstrap/versions.tf`:
```hcl
terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.69"
    }
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = {
      project    = "eks-llm-inference"
      managed-by = "terraform"
    }
  }
}
```

`terraform/bootstrap/variables.tf`:
```hcl
variable "region" {
  type    = string
  default = "us-east-1"
}

variable "monthly_budget_usd" {
  description = "Account-wide monthly cost budget; alerts at 80% actual and 100% forecast."
  type        = number
  default     = 50
}

variable "alert_email" {
  description = "Budget alert recipient. Set in terraform.tfvars (gitignored)."
  type        = string
  validation {
    condition     = can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.alert_email))
    error_message = "alert_email must be an email address."
  }
}
```

`terraform/bootstrap/main.tf`:
```hcl
data "aws_caller_identity" "current" {}

resource "aws_s3_bucket" "state" {
  bucket = "eks-llm-inference-tfstate-${data.aws_caller_identity.current.account_id}"

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_budgets_budget" "monthly" {
  name         = "eks-llm-inference-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.alert_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.alert_email]
  }
}
```

`terraform/bootstrap/outputs.tf`:
```hcl
output "state_bucket" {
  value = aws_s3_bucket.state.bucket
}
```

`terraform/bootstrap/terraform.tfvars.example`:
```hcl
alert_email        = "you@example.com"
monthly_budget_usd = 50
```

- [ ] **Step 2: Validate**

Run: `terraform -chdir=terraform/bootstrap init -backend=false && terraform -chdir=terraform/bootstrap validate && terraform fmt -check -recursive terraform`
Expected: `Success! The configuration is valid.`; fmt exit 0.

- [ ] **Step 3: Commit**

```bash
git add terraform/bootstrap
git commit -m "feat: add terraform bootstrap for remote state and budget alert"
```

---

### Task 5: Terraform infra — VPC, EKS, node groups, Pod Identity

**Files:**
- Create: `terraform/infra/{versions.tf,providers.tf,variables.tf,vpc.tf,eks.tf,iam.tf,outputs.tf,terraform.tfvars.example}`

**Interfaces:**
- Consumes: S3 bucket name via `terraform init -backend-config=bucket=...`.
- Produces outputs: `cluster_name`, `region`, `vpc_id`, `configure_kubectl` (shell command string). Task 6 consumes `module.eks.*` and `module.vpc.vpc_id`.

- [ ] **Step 1: Write files**

`terraform/infra/versions.tf`:
```hcl
terraform {
  required_version = ">= 1.10"

  # bucket/region passed via -backend-config by scripts/up.sh (keeps account id out of git)
  backend "s3" {
    key          = "infra/terraform.tfstate"
    use_lockfile = true
    encrypt      = true
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.69"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.3"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.3"
    }
  }
}
```

`terraform/infra/providers.tf`:
```hcl
provider "aws" {
  region = var.region
  default_tags {
    tags = {
      project    = "eks-llm-inference"
      managed-by = "terraform"
    }
  }
}

locals {
  k8s_exec = {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.region]
  }
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  exec {
    api_version = local.k8s_exec.api_version
    command     = local.k8s_exec.command
    args        = local.k8s_exec.args
  }
}

provider "helm" {
  kubernetes = {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    exec                   = local.k8s_exec
  }
}
```

`terraform/infra/variables.tf`:
```hcl
variable "region" {
  type    = string
  default = "us-east-1"
}

variable "cluster_name" {
  type    = string
  default = "llm-inference"
}

variable "kubernetes_version" {
  type    = string
  default = "1.36"
}

variable "gpu_instance_type" {
  type    = string
  default = "g5.xlarge"
}

variable "allowed_cidrs" {
  description = "CIDRs allowed to reach the EKS API and the inference NLB. scripts/up.sh passes your current IP/32."
  type        = list(string)
  validation {
    condition     = length(var.allowed_cidrs) > 0 && alltrue([for c in var.allowed_cidrs : can(cidrnetmask(c)) && c != "0.0.0.0/0"])
    error_message = "allowed_cidrs must be a non-empty list of valid CIDRs and must not contain 0.0.0.0/0."
  }
}

variable "gitops_repo_url" {
  type    = string
  default = "https://github.com/vladimir-kazarin/eks-llm-inference.git"
}

variable "gitops_revision" {
  type    = string
  default = "main"
}
```

`terraform/infra/vpc.tf`:
```hcl
# Only AZs that actually offer the GPU instance type.
data "aws_ec2_instance_type_offerings" "gpu" {
  location_type = "availability-zone"
  filter {
    name   = "instance-type"
    values = [var.gpu_instance_type]
  }
}

locals {
  azs = slice(sort(data.aws_ec2_instance_type_offerings.gpu.locations), 0, 2)
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "6.7.3"

  name = var.cluster_name
  cidr = "10.0.0.0/16"
  azs  = local.azs

  private_subnets = ["10.0.0.0/19", "10.0.32.0/19"]
  public_subnets  = ["10.0.64.0/24", "10.0.65.0/24"]

  enable_nat_gateway = true
  # Cost trade-off: one NAT for both AZs. Production multi-AZ would use one per AZ.
  single_nat_gateway = true

  public_subnet_tags  = { "kubernetes.io/role/elb" = 1 }
  private_subnet_tags = { "kubernetes.io/role/internal-elb" = 1 }
}
```

`terraform/infra/eks.tf`:
```hcl
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.29.0"

  name               = var.cluster_name
  kubernetes_version = var.kubernetes_version

  endpoint_public_access                   = true
  endpoint_public_access_cidrs             = var.allowed_cidrs
  enable_cluster_creator_admin_permissions = true

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  addons = {
    vpc-cni                = { before_compute = true }
    eks-pod-identity-agent = { before_compute = true }
    kube-proxy             = {}
    coredns                = {}
  }

  eks_managed_node_groups = {
    system = {
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = ["t3.large"]
      min_size       = 2
      max_size       = 2
      desired_size   = 2
      labels         = { workload = "system" }
    }

    gpu = {
      ami_type       = "AL2023_x86_64_NVIDIA"
      instance_types = [var.gpu_instance_type]
      # Quota: 8 G-family vCPUs = exactly 2x g5.xlarge. Do not raise.
      min_size     = 2
      max_size     = 2
      desired_size = 2
      labels = {
        workload = "llm"
        # nvidia-device-plugin's default node affinity requires this label (no NFD installed).
        "nvidia.com/gpu.present" = "true"
      }
      taints = {
        gpu = { key = "nvidia.com/gpu", value = "true", effect = "NO_SCHEDULE" }
      }
      block_device_mappings = {
        xvda = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size           = 100
            volume_type           = "gp3"
            encrypted             = true
            delete_on_termination = true
          }
        }
      }
    }
  }
}
```

`terraform/infra/iam.tf`:
```hcl
module "aws_lb_controller_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "2.9.0"

  name                            = "${var.cluster_name}-aws-lbc"
  attach_aws_lb_controller_policy = true

  associations = {
    this = {
      cluster_name    = module.eks.cluster_name
      namespace       = "kube-system"
      service_account = "aws-load-balancer-controller"
    }
  }
}
```

`terraform/infra/outputs.tf`:
```hcl
output "cluster_name" {
  value = module.eks.cluster_name
}

output "region" {
  value = var.region
}

output "vpc_id" {
  value = module.vpc.vpc_id
}

output "configure_kubectl" {
  value = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name} --alias ${module.eks.cluster_name}"
}
```

`terraform/infra/terraform.tfvars.example`:
```hcl
# Normally set by scripts/up.sh from your current public IP.
allowed_cidrs = ["203.0.113.10/32"]
```

- [ ] **Step 2: Validate**

Run: `terraform -chdir=terraform/infra init -backend=false && terraform -chdir=terraform/infra validate && terraform fmt -check -recursive terraform`
Expected: `Success!`. If the kubernetes provider 3.x rejects the `exec {}` block syntax, switch it to the attribute form `exec = local.k8s_exec` (as in the helm provider) and re-run.

- [ ] **Step 3: Commit**

```bash
git add terraform/infra
git commit -m "feat: add VPC, EKS cluster, node groups and LB controller pod identity"
```

---

### Task 6: Terraform infra — Argo CD + GitOps bridge + root app

**Files:**
- Create: `terraform/infra/argocd.tf`

**Interfaces:**
- Consumes: `module.eks`, `module.vpc.vpc_id`, `var.allowed_cidrs`, `var.gitops_repo_url`, `var.gitops_revision`.
- Produces (in-cluster contract consumed by Task 7 ApplicationSets): Secret `argocd/in-cluster` labelled `argocd.argoproj.io/secret-type=cluster` with annotations `cluster_name`, `aws_region`, `vpc_id`, `allowed_cidrs` (comma-joined), `gitops_repo_url`, `gitops_revision`. Application `argocd/root` syncing path `gitops/apps`.

- [ ] **Step 1: Write `terraform/infra/argocd.tf`**

```hcl
resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = "10.10.3"
  namespace        = "argocd"
  create_namespace = true
  wait             = true
  timeout          = 900

  values = [yamlencode({
    global  = { nodeSelector = { workload = "system" } }
    configs = { params = { "server.insecure" = true } } # ClusterIP + port-forward only
  })]

  depends_on = [module.eks]
}

# GitOps bridge: cluster facts Argo ApplicationSets template into Helm values.
resource "kubernetes_secret_v1" "argocd_in_cluster" {
  metadata {
    name      = "in-cluster"
    namespace = "argocd"
    labels    = { "argocd.argoproj.io/secret-type" = "cluster" }
    annotations = {
      cluster_name    = module.eks.cluster_name
      aws_region      = var.region
      vpc_id          = module.vpc.vpc_id
      allowed_cidrs   = join(",", var.allowed_cidrs)
      gitops_repo_url = var.gitops_repo_url
      gitops_revision = var.gitops_revision
    }
  }

  data = {
    name   = "in-cluster"
    server = "https://kubernetes.default.svc"
    config = jsonencode({ tlsClientConfig = { insecure = false } })
  }

  depends_on = [helm_release.argocd]
}

# Root app-of-apps via the argocd-apps chart, so Terraform never needs the Application CRD at plan time.
resource "helm_release" "argocd_root" {
  name       = "argocd-root"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argocd-apps"
  version    = "2.0.6"
  namespace  = "argocd"

  values = [yamlencode({
    applications = {
      root = {
        namespace = "argocd"
        project   = "default"
        source = {
          repoURL        = var.gitops_repo_url
          targetRevision = var.gitops_revision
          path           = "gitops/apps"
        }
        destination = { server = "https://kubernetes.default.svc", namespace = "argocd" }
        syncPolicy  = { automated = { prune = true, selfHeal = true } }
      }
    }
  })]

  depends_on = [kubernetes_secret_v1.argocd_in_cluster]
}
```

- [ ] **Step 2: Validate**

Run: `terraform -chdir=terraform/infra init -backend=false -upgrade && terraform -chdir=terraform/infra validate && terraform fmt -check -recursive terraform`
Expected: `Success!`

- [ ] **Step 3: Commit**

```bash
git add terraform/infra/argocd.tf terraform/infra/.terraform.lock.hcl terraform/bootstrap/.terraform.lock.hcl
git commit -m "feat: install Argo CD with GitOps bridge cluster secret and root app"
```

---

### Task 7: GitOps manifests (add-ons + llm-stack)

**Files:**
- Create: `gitops/apps/aws-load-balancer-controller.yaml`, `gitops/apps/nvidia-device-plugin.yaml`, `gitops/apps/kube-prometheus-stack.yaml`, `gitops/apps/llm-stack.yaml`, `gitops/workloads/llm-stack/values.yaml`

**Interfaces:**
- Consumes: Task 6 cluster-secret annotations (exact names above).
- Produces (consumed by scripts in Task 9): namespace `llm`; Service `llm-router-service` (type LoadBalancer); Deployment `llm-deployment-router` whose container args contain `--routing-logic <value>`; engine pods labelled `app.kubernetes.io/component=serving-engine`; Argo Applications `aws-load-balancer-controller`, `nvidia-device-plugin`, `kube-prometheus-stack`, `llm-stack` (+ `root`); ApplicationSet `llm-stack`; Service `monitoring/kube-prometheus-stack-grafana`.
- The line `  routingLogic: <value>` (2-space indent) in `values.yaml` is edited by `scripts/set-strategy.sh` and read by `scripts/validate-gitops.sh` — keep it exactly that shape.

- [ ] **Step 1: Write add-on ApplicationSets**

`gitops/apps/aws-load-balancer-controller.yaml`:
```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: aws-load-balancer-controller
  namespace: argocd
spec:
  goTemplate: true
  goTemplateOptions: ["missingkey=error"]
  generators:
    - clusters: {}
  template:
    metadata:
      name: aws-load-balancer-controller
      finalizers: [resources-finalizer.argocd.argoproj.io]
    spec:
      project: default
      source:
        repoURL: https://aws.github.io/eks-charts
        chart: aws-load-balancer-controller
        targetRevision: 3.6.0
        helm:
          releaseName: aws-load-balancer-controller
          valuesObject:
            clusterName: '{{ .metadata.annotations.cluster_name }}'
            region: '{{ .metadata.annotations.aws_region }}'
            vpcId: '{{ .metadata.annotations.vpc_id }}'
            serviceAccount:
              name: aws-load-balancer-controller
            nodeSelector:
              workload: system
      destination:
        server: '{{ .server }}'
        namespace: kube-system
      syncPolicy:
        automated: { prune: true, selfHeal: true }
        retry:
          limit: 10
          backoff: { duration: 30s, factor: 2, maxDuration: 5m }
```

`gitops/apps/nvidia-device-plugin.yaml`:
```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: nvidia-device-plugin
  namespace: argocd
spec:
  goTemplate: true
  goTemplateOptions: ["missingkey=error"]
  generators:
    - clusters: {}
  template:
    metadata:
      name: nvidia-device-plugin
      finalizers: [resources-finalizer.argocd.argoproj.io]
    spec:
      project: default
      source:
        repoURL: https://nvidia.github.io/k8s-device-plugin
        chart: nvidia-device-plugin
        targetRevision: 0.20.1
        helm:
          releaseName: nvidia-device-plugin
          valuesObject:
            tolerations:
              - key: nvidia.com/gpu
                operator: Exists
                effect: NoSchedule
      destination:
        server: '{{ .server }}'
        namespace: kube-system
      syncPolicy:
        automated: { prune: true, selfHeal: true }
        retry:
          limit: 10
          backoff: { duration: 30s, factor: 2, maxDuration: 5m }
```

`gitops/apps/kube-prometheus-stack.yaml`:
```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: kube-prometheus-stack
  namespace: argocd
spec:
  goTemplate: true
  goTemplateOptions: ["missingkey=error"]
  generators:
    - clusters: {}
  template:
    metadata:
      name: kube-prometheus-stack
      finalizers: [resources-finalizer.argocd.argoproj.io]
    spec:
      project: default
      source:
        repoURL: https://prometheus-community.github.io/helm-charts
        chart: kube-prometheus-stack
        targetRevision: 92.7.0
        helm:
          releaseName: kube-prometheus-stack
          valuesObject:
            prometheus:
              prometheusSpec:
                serviceMonitorSelectorNilUsesHelmValues: false
                nodeSelector: { workload: system }
            grafana:
              nodeSelector: { workload: system }
              sidecar:
                dashboards:
                  searchNamespace: ALL
            alertmanager:
              enabled: false
      destination:
        server: '{{ .server }}'
        namespace: monitoring
      syncPolicy:
        automated: { prune: true, selfHeal: true }
        syncOptions: [CreateNamespace=true, ServerSideApply=true]
        retry:
          limit: 10
          backoff: { duration: 30s, factor: 2, maxDuration: 5m }
```

- [ ] **Step 2: Write llm-stack ApplicationSet and values**

`gitops/apps/llm-stack.yaml`:
```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: llm-stack
  namespace: argocd
spec:
  goTemplate: true
  goTemplateOptions: ["missingkey=error"]
  generators:
    - clusters: {}
  template:
    metadata:
      name: llm-stack
      # Deleting the ApplicationSet deletes the Service -> LB controller deletes the NLB.
      finalizers: [resources-finalizer.argocd.argoproj.io]
    spec:
      project: default
      sources:
        - repoURL: https://vllm-project.github.io/production-stack
          chart: vllm-stack
          targetRevision: 0.1.13
          helm:
            releaseName: llm
            valueFiles:
              - $values/gitops/workloads/llm-stack/values.yaml
            valuesObject:
              routerSpec:
                serviceAnnotations:
                  service.beta.kubernetes.io/load-balancer-source-ranges: '{{ .metadata.annotations.allowed_cidrs }}'
        - repoURL: '{{ .metadata.annotations.gitops_repo_url }}'
          targetRevision: '{{ .metadata.annotations.gitops_revision }}'
          ref: values
      destination:
        server: '{{ .server }}'
        namespace: llm
      syncPolicy:
        automated: { prune: true, selfHeal: true }
        syncOptions: [CreateNamespace=true]
        retry:
          # ServiceMonitor CRD and LB controller webhook may not exist yet on first sync.
          limit: 20
          backoff: { duration: 30s, factor: 2, maxDuration: 5m }
```

`gitops/workloads/llm-stack/values.yaml`:
```yaml
# vLLM production-stack (chart vllm-stack 0.1.13). Two Qwen3-4B replicas, one per g5.xlarge.
servingEngineSpec:
  # AL2023 NVIDIA AMI uses the NVIDIA runtime by default; no RuntimeClass object exists.
  runtimeClassName: ""
  modelSpec:
    - name: qwen3-4b
      repository: vllm/vllm-openai
      tag: v0.31.0
      modelURL: Qwen/Qwen3-4B
      replicaCount: 2
      requestCPU: 2
      requestMemory: 10Gi
      requestGPU: 1
      runtimeClassName: ""
      vllmConfig:
        enablePrefixCaching: true
        maxModelLen: 32768
        dtype: bfloat16
        maxNumSeqs: 32
        gpuMemoryUtilization: 0.90
      lmcacheConfig:
        enabled: false
      nodeSelectorTerms:
        - matchExpressions:
            - key: workload
              operator: In
              values: [llm]
      tolerations:
        - key: nvidia.com/gpu
          operator: Exists
          effect: NoSchedule
  # Weight download (~8 GB) + load: allow up to 15 min.
  startupProbe:
    initialDelaySeconds: 15
    periodSeconds: 10
    failureThreshold: 90
    httpGet:
      path: /health
      port: 8000
  serviceMonitor:
    enabled: true

routerSpec:
  repository: lmcache/lmstack-router
  tag: v0.1.13
  imagePullPolicy: IfNotPresent
  # Changed by scripts/set-strategy.sh: roundrobin | session | prefixaware
  routingLogic: roundrobin
  sessionKey: x-session-id
  serviceType: LoadBalancer
  serviceAnnotations:
    service.beta.kubernetes.io/aws-load-balancer-type: external
    service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: ip
    service.beta.kubernetes.io/aws-load-balancer-scheme: internet-facing
  nodeSelectorTerms:
    - matchExpressions:
        - key: workload
          operator: In
          values: [system]
  serviceMonitor:
    enabled: true

grafanaDashboards:
  enabled: true
```

- [ ] **Step 3: Commit** (validated in Task 8)

```bash
git add gitops
git commit -m "feat: add Argo CD ApplicationSets for add-ons and vLLM production-stack"
```

---

### Task 8: GitOps validation script (structural tests)

**Files:**
- Create: `scripts/validate-gitops.sh`

**Interfaces:**
- Produces: `scripts/validate-gitops.sh` — exit 0 when all checks pass. Used by `make lint` and CI. Requires `helm`, `kubeconform` on PATH (`brew install kubeconform` locally).

- [ ] **Step 1: Write the script (assertions are the tests)**

`scripts/validate-gitops.sh`:
```bash
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
grep -q 'image: "vllm/vllm-openai:v0.31.0"' "$TMP/llm.yaml" || fail "engine image not pinned to v0.31.0"
if grep -q 'runtimeClassName' "$TMP/llm.yaml"; then fail "runtimeClassName must not be set"; fi
if grep -qE -- '- "--(runner|convert|tensor-parallel-size)"' "$TMP/llm.yaml"; then fail "chart example defaults leaked into engine args"; fi
grep -q 'load-balancer-source-ranges' "$TMP/llm.yaml" || fail "NLB source-range annotation missing"
if grep -qE 'targetRevision: *(latest|HEAD)' "$ROOT"/gitops/apps/*.yaml; then fail "unpinned targetRevision in gitops/apps"; fi
echo "gitops validation passed (strategy=$strategy, chart=$CHART_VERSION)"
```

- [ ] **Step 2: Run it — expect PASS; then prove it catches regressions**

Run: `chmod +x scripts/validate-gitops.sh && scripts/validate-gitops.sh`
Expected: `gitops validation passed (strategy=roundrobin, chart=0.1.13)`.
If the chart rejects a value (schema) or a template errors on a missing key, fix `values.yaml` (not the script) and re-run.

Regression check: `sed -i 's/^  routingLogic: roundrobin/  routingLogic: kvaware/' gitops/workloads/llm-stack/values.yaml; scripts/validate-gitops.sh; git checkout gitops/workloads/llm-stack/values.yaml`
Expected: `FAIL: routingLogic 'kvaware' not allowed`, then file restored.

- [ ] **Step 3: Commit**

```bash
git add scripts/validate-gitops.sh
git commit -m "test: validate rendered production-stack manifests and invariants"
```

---

### Task 9: Lifecycle scripts + Makefile

**Files:**
- Create: `scripts/lib.sh`, `scripts/up.sh`, `scripts/wait-ready.sh`, `scripts/down.sh`, `scripts/set-strategy.sh`, `scripts/check-strategy.sh`, `scripts/tests/test_lib.sh`, `scripts/tests/test_down_refuses_with_lb.sh`, `Makefile`

**Interfaces:**
- Consumes: Task 4 output `state_bucket`; Task 5 outputs `cluster_name`, `configure_kubectl`; Task 7 resource names.
- Produces: `scripts/lib.sh` functions `log`, `die`, `require_cmd <cmd...>`, `require_pushed`, `poll <timeout_s> <interval_s> <description> <command...>`, `lb_service_count`, `router_strategy`, `endpoint`. Make targets: `bootstrap up down endpoint demo strategy bench report grafana argocd lint test`.

- [ ] **Step 1: Write failing script tests**

`scripts/tests/test_lib.sh`:
```bash
#!/usr/bin/env bash
# Unit tests for scripts/lib.sh using stub commands on PATH.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=../lib.sh
source "$HERE/../lib.sh"
STUBS=$(mktemp -d); trap 'rm -rf "$STUBS"' EXIT
export PATH="$STUBS:$PATH"
pass=0; failed=0
check() { if eval "$2"; then pass=$((pass+1)); else echo "FAIL: $1"; failed=$((failed+1)); fi; }

# poll: succeeds when the command eventually passes, fails on timeout
n_file=$(mktemp); echo 0 > "$n_file"
flaky() { local n; n=$(<"$n_file"); echo $((n+1)) > "$n_file"; [ "$n" -ge 2 ]; }
check "poll succeeds after retries" "poll 5 0 'flaky' flaky >/dev/null 2>&1"
check "poll times out" "! poll 1 0 'never' false >/dev/null 2>&1"

# router_strategy parses the router container args
cat > "$STUBS/kubectl" <<'EOF'
#!/usr/bin/env bash
echo '--host 0.0.0.0 --routing-logic prefixaware --session-key x-session-id'
EOF
chmod +x "$STUBS/kubectl"
check "router_strategy extracts value" '[ "$(router_strategy)" = prefixaware ]'

# require_pushed: fails when HEAD is not on any remote branch
cat > "$STUBS/git" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"fetch --quiet origin") exit 0;;
  *"rev-parse HEAD") echo aaa;;
  *"branch -r --contains aaa") echo "";;
esac
EOF
chmod +x "$STUBS/git"
check "require_pushed fails on unpushed HEAD" "! (require_pushed) >/dev/null 2>&1"

echo "lib tests: $pass passed, $failed failed"; [ "$failed" -eq 0 ]
```

`scripts/tests/test_down_refuses_with_lb.sh`:
```bash
#!/usr/bin/env bash
# down.sh must refuse to destroy while a LoadBalancer Service exists.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
STUBS=$(mktemp -d); trap 'rm -rf "$STUBS"' EXIT
cat > "$STUBS/kubectl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"get svc -A"*) echo "LoadBalancer";;   # an NLB-backed Service that never goes away
  *) exit 0;;
esac
EOF
cat > "$STUBS/terraform" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *destroy* ]]; then echo "DESTROY CALLED" >&2; exit 99; fi
echo llm-inference
EOF
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUBS/aws"
chmod +x "$STUBS"/*
out=$(PATH="$STUBS:$PATH" LB_TIMEOUT=2 "$HERE/../down.sh" 2>&1); rc=$?
[ "$rc" -ne 0 ] || { echo "FAIL: down.sh exited 0"; exit 1; }
[[ "$out" != *"DESTROY CALLED"* ]] || { echo "FAIL: destroy ran with LB present"; exit 1; }
[[ "$out" == *"LoadBalancer"* ]] || { echo "FAIL: no clear message: $out"; exit 1; }
echo "down guard test passed"
```

Run: `bash scripts/tests/test_lib.sh; bash scripts/tests/test_down_refuses_with_lb.sh`
Expected: FAIL — `lib.sh: No such file or directory` / `down.sh: No such file or directory`.

- [ ] **Step 2: Implement `scripts/lib.sh`**

```bash
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
```

- [ ] **Step 3: Implement lifecycle scripts**

`scripts/up.sh`:
```bash
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
```

`scripts/wait-ready.sh`:
```bash
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
```

`scripts/down.sh`:
```bash
#!/usr/bin/env bash
# Remove the NLB via Argo first, then terraform destroy, then check for leftovers.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
require_cmd terraform kubectl aws
REGION=${REGION:-us-east-1}
LB_TIMEOUT=${LB_TIMEOUT:-600}

if kubectl -n argocd get application root >/dev/null 2>&1; then
  log "disabling root auto-sync so Argo doesn't recreate what we delete"
  kubectl -n argocd patch application root --type merge -p '{"spec":{"syncPolicy":null}}'
  log "deleting llm-stack (Service -> NLB)"
  kubectl -n argocd delete applicationset llm-stack --ignore-not-found --wait=false
fi

no_lbs() { [ "$(lb_service_count)" -eq 0 ]; }
poll "$LB_TIMEOUT" 10 "all LoadBalancer Services (and their NLBs) deleted" no_lbs \
  || die "LoadBalancer Services still exist; refusing terraform destroy (it would orphan the NLB and hang deleting the VPC). Inspect: kubectl get svc -A"

CLUSTER=$(terraform -chdir="$INFRA" output -raw cluster_name 2>/dev/null || echo llm-inference)
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
```

`scripts/check-strategy.sh`:
```bash
#!/usr/bin/env bash
# Refuse to benchmark if the live router isn't running the strategy the results will be labelled with.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
want=${1:?usage: check-strategy.sh <strategy>}
have=$(router_strategy) || die "cannot read router deployment (is the cluster up?)"
[ "$have" = "$want" ] || die "router is running '$have', not '$want'. Run: make strategy S=$want"
kubectl -n llm rollout status deploy/llm-deployment-router --timeout=10s >/dev/null \
  || die "router rollout still in progress"
```

`scripts/set-strategy.sh`:
```bash
#!/usr/bin/env bash
# GitOps strategy switch: edit values.yaml, commit, push, wait for Argo + router rollout.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
s=${1:?usage: set-strategy.sh roundrobin|session|prefixaware}
[[ "$s" =~ ^(roundrobin|session|prefixaware)$ ]] || die "unknown strategy: $s"
VALUES="$ROOT/gitops/workloads/llm-stack/values.yaml"

sed -i -E "s/^  routingLogic: .*/  routingLogic: $s/" "$VALUES"
if ! git -C "$ROOT" diff --quiet -- "$VALUES"; then
  git -C "$ROOT" add "$VALUES"
  git -C "$ROOT" commit -m "chore: set router strategy to $s"
  git -C "$ROOT" push
fi
require_pushed
kubectl -n argocd annotate application llm-stack argocd.argoproj.io/refresh=hard --overwrite >/dev/null
strategy_live() { [ "$(router_strategy)" = "$s" ]; }
poll 300 5 "router running --routing-logic $s" strategy_live
kubectl -n llm rollout status deploy/llm-deployment-router --timeout=300s
log "router strategy is $s"
```

`Makefile`:
```makefile
SHELL := /usr/bin/env bash
.SHELLFLAGS := -euo pipefail -c
STRATEGY ?= roundrobin
SESSIONS ?= 6
TURNS ?= 30
CONTEXT ?= 28000

.PHONY: bootstrap up down endpoint demo strategy bench report grafana argocd lint test

bootstrap: ## one-time: state bucket + budget (needs terraform/bootstrap/terraform.tfvars)
	terraform -chdir=terraform/bootstrap init -input=false
	terraform -chdir=terraform/bootstrap apply -input=false

up: ## create cluster and wait until inference is ready
	scripts/up.sh

down: ## delete NLB, destroy cluster, check leftovers
	scripts/down.sh

endpoint:
	@source scripts/lib.sh && endpoint

demo:
	ENDPOINT=$$(source scripts/lib.sh && endpoint) uv run python -m clients.demo

strategy: ## make strategy S=prefixaware
	scripts/set-strategy.sh $(S)

bench: ## make bench STRATEGY=prefixaware
	scripts/check-strategy.sh $(STRATEGY)
	ENDPOINT=$$(source scripts/lib.sh && endpoint) uv run python -m clients.bench \
	  --label $(STRATEGY) --sessions $(SESSIONS) --turns $(TURNS) --context-tokens $(CONTEXT)

report:
	uv run python -m clients.report results

grafana:
	kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80

argocd:
	kubectl -n argocd port-forward svc/argocd-server 8080:80

lint:
	terraform fmt -check -recursive terraform
	for d in terraform/bootstrap terraform/infra; do \
	  terraform -chdir=$$d init -backend=false -input=false >/dev/null && terraform -chdir=$$d validate; \
	done
	tflint --init --config "$$PWD/.tflint.hcl" && tflint --recursive --config "$$PWD/.tflint.hcl"
	scripts/validate-gitops.sh
	shellcheck scripts/*.sh scripts/tests/*.sh
	uv run ruff check .

test:
	uv run pytest -q
	bash scripts/tests/test_lib.sh
	bash scripts/tests/test_down_refuses_with_lb.sh
```

- [ ] **Step 4: Run tests**

Run: `chmod +x scripts/*.sh && make test && shellcheck scripts/*.sh scripts/tests/*.sh`
Expected: pytest PASS; `lib tests: 4 passed, 0 failed`; `down guard test passed`; shellcheck clean (install via `brew install shellcheck` if missing; fix findings — only suppress with an inline comment saying why).

- [ ] **Step 5: Commit**

```bash
git add scripts Makefile
git commit -m "feat: add lifecycle scripts with readiness, strategy and teardown guards"
```

---

### Task 10: CI (GitHub Actions) + lint configs

**Files:**
- Create: `.github/workflows/ci.yml`, `.tflint.hcl`, `.trivyignore.yaml`

**Interfaces:**
- Consumes: `scripts/validate-gitops.sh`, `scripts/tests/*.sh`, pytest suite.

- [ ] **Step 1: Write configs**

`.tflint.hcl`:
```hcl
plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

plugin "aws" {
  enabled = true
  version = "0.49.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"
}
```

`.trivyignore.yaml` (start empty; add entries only with justification):
```yaml
# Each accepted finding needs: id, paths, statement (why it's acceptable here).
misconfigurations: []
```

`.github/workflows/ci.yml`:
```yaml
name: ci
on:
  push:
    branches: [main]
  pull_request:

permissions:
  contents: read

jobs:
  terraform:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v5
      - uses: hashicorp/setup-terraform@v4.0.1
        with:
          terraform_version: 1.15.8
      - uses: terraform-linters/setup-tflint@v6.3.2
      - run: terraform fmt -check -recursive terraform
      - run: |
          for d in terraform/bootstrap terraform/infra; do
            terraform -chdir=$d init -backend=false -input=false
            terraform -chdir=$d validate
          done
      - run: tflint --init --config "$PWD/.tflint.hcl" && tflint --recursive --config "$PWD/.tflint.hcl"
        env:
          GITHUB_TOKEN: ${{ github.token }}

  security:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v5
      - uses: aquasecurity/trivy-action@v0.36.0
        with:
          scan-type: config
          scan-ref: .
          trivyignores: .trivyignore.yaml
          severity: HIGH,CRITICAL
          exit-code: "1"

  gitops:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v5
      - uses: azure/setup-helm@v4
        with:
          version: v4.2.3
      - name: install kubeconform
        run: |
          curl -fsSL https://github.com/yannh/kubeconform/releases/download/v0.8.0/kubeconform-linux-amd64.tar.gz \
            | sudo tar -xz -C /usr/local/bin kubeconform
      - run: scripts/validate-gitops.sh

  python:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v5
      - uses: astral-sh/setup-uv@v6
      - run: uv sync --locked
      - run: uv run ruff check .
      - run: uv run pytest -q

  scripts:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v5
      - run: shellcheck scripts/*.sh scripts/tests/*.sh
      - run: bash scripts/tests/test_lib.sh && bash scripts/tests/test_down_refuses_with_lb.sh
```

- [ ] **Step 2: Run the same checks locally**

Run: `make lint && make test`, then `trivy config --severity HIGH,CRITICAL --exit-code 1 .` (install with `brew install trivy` if missing).
Expected: all pass. For each trivy HIGH/CRITICAL finding: fix it, or — only if it is an intended trade-off from the spec (public EKS endpoint restricted by CIDR; internet-facing NLB restricted by source range) — add a `.trivyignore.yaml` entry with a `statement:` explaining why. Never ignore without a statement.

- [ ] **Step 3: Commit**

```bash
git add .github .tflint.hcl .trivyignore.yaml terraform
git commit -m "ci: add terraform, security, gitops, python and script checks"
```

---

### Task 11: Documentation (portfolio README, architecture, runbook, baseline results)

**Files:**
- Create: `README.md`, `docs/architecture.md`, `docs/runbook.md`, `docs/results.md`
- Modify: `docs/superpowers/specs/2026-10-14-eks-llm-inference-design.md` — add "Deviations during implementation" under §10: (a) EBS CSI add-on dropped: nothing uses PVCs (Prometheus storage is ephemeral per session); (b) NLB source ranges set via the `service.beta.kubernetes.io/load-balancer-source-ranges` annotation because chart 0.1.13 exposes no `loadBalancerSourceRanges` value.

**Interfaces:**
- Consumes: Makefile targets; local baseline CSVs at `../local/*.csv` (outside the repo, read-only).

- [ ] **Step 1: Compute the local single-machine baseline**

Run (from repo root):
```bash
uv run python - <<'EOF'
import csv
from pathlib import Path
from clients.metrics import summarize
from clients.report import format_table
out = []
for name in ["rr", "sticky", "cache_on", "conc2", "conc8"]:
    raw = list(csv.DictReader(Path(f"../local/{name}.csv").open()))
    rows = [{"prompt_tokens": int(r["prompt_tokens"]),
             "cached_tokens": int(r["cached_tokens"]) if r["cached_tokens"] else None,
             "completion_tokens": int(r["completion_tokens"]), "ttft_ms": float(r["ttft_ms"])}
            for r in raw]
    wall = sum(float(r["total_ms"]) for r in raw) / 1000
    out.append(summarize(rows, name, wall))
print(format_table(out))
EOF
```

- [ ] **Step 2: Write `docs/results.md`**

```markdown
# Results

## Single-machine baseline (local GPU, two vLLM processes, custom `gateway.py`)

<paste table from Step 1>

`output tok/s` here is per-stream: local runs didn't record wall-clock time, so
wall = summed request time. `rr` = round-robin, `sticky` = session-pinned.

## EKS: 2× g5.xlarge, Qwen3-4B, vLLM v0.31.0, production-stack router v0.1.13

Workload: 6 concurrent agent sessions × 30 turns, context growing to ~28k tokens
(`make bench`). Each replica holds ~85k cached tokens, so 6 × 28k-token sessions
(~170k) only stay cached if each session sticks to one replica.

_Filled in after the first live run (Task 13)._
```

- [ ] **Step 3: Write `docs/architecture.md`**

Contains, in order: the architecture diagram from spec §2; the ownership table from spec §2; a "GitOps bridge" paragraph (Terraform → cluster-secret annotations → ApplicationSet Go templates; lists the six annotation keys); a "Request path" numbered list (spec §4); and "Design decisions" with these entries, 2–4 sentences each:
- Why GitOps (Argo CD) instead of Terraform-managed Helm releases.
- Why a single NAT gateway.
- Why g5.xlarge + Qwen3-4B, with this table:

  | Setup | Free for KV | Tokens cached / replica | 30k sessions held |
  |---|---|---|---|
  | g4dn (T4) + 0.6B | ~12 GB | ~110k | ~3 |
  | g4dn (T4) + 4B | ~5 GB | ~35k | ~1 |
  | g5 (A10G) + 4B | ~12 GB | ~85k | ~2–3 |
  | g5 (A10G) + 0.6B | ~19 GB | ~170k | ~5 |

  and the note: KV/token ≈ 112 KB (0.6B, 28 layers) vs ≈ 144 KB (4B, 36 layers), both 8 KV heads × 128 dim; the 4B model makes cache misses expensive enough to measure.
- Why EKS Pod Identity over IRSA.
- Why the NLB is source-IP restricted rather than authenticated.
- Why the root app is created via the argocd-apps chart (Application CRD doesn't exist at plan time).

- [ ] **Step 4: Write `docs/runbook.md`**

Sections, each with exact commands:
1. **Prerequisites:** terraform ≥ 1.10, aws CLI v2 with credentials, kubectl, helm, uv, gh, kubeconform, shellcheck. Quota check: `aws service-quotas get-service-quota --service-code ec2 --quota-code L-DB2E81BA --region us-east-1 --query Quota.Value` must be ≥ 8.
2. **One-time bootstrap:** `cp terraform/bootstrap/terraform.tfvars.example terraform/bootstrap/terraform.tfvars`, set `alert_email`, `make bootstrap`, confirm the AWS Budgets email. Bootstrap state is local (`terraform/bootstrap/terraform.tfstate`, gitignored) — back it up; the bucket has `prevent_destroy`.
3. **A session:** `make up` (≈ 20–25 min) → `make demo` → `make strategy S=roundrobin && make bench STRATEGY=roundrobin` → same for `session`, `prefixaware` → `make report` → `make down`. Cost ≈ $2.35/hr while up.
4. **Live verification checklist:** the four checks from spec §7.
5. **Troubleshooting:**
   - `InsufficientInstanceCapacity` for g5: retry later; the VPC only uses AZs offering the type, so changing region requires quota there first.
   - GPU nodes Ready but no `nvidia.com/gpu` allocatable: `kubectl -n kube-system logs ds/nvidia-device-plugin`; confirm label `nvidia.com/gpu.present=true` on GPU nodes.
   - vLLM pod fails with CUDA / "no NVIDIA driver": the node's default runtime isn't NVIDIA → add a `RuntimeClass` `nvidia` (handler `nvidia`) under `gitops/apps/` and set `runtimeClassName: nvidia` in `values.yaml` (update the `validate-gitops.sh` assertion accordingly).
   - vLLM OOM at startup: lower `maxModelLen` or `gpuMemoryUtilization`.
   - Engine pods Pending: check toleration for `nvidia.com/gpu` and node label `workload=llm`.
   - `make down` stuck on LoadBalancer: `kubectl -n kube-system logs deploy/aws-load-balancer-controller`.
   - Grafana password: `kubectl -n monitoring get secret kube-prometheus-stack-grafana -o jsonpath='{.data.admin-password}' | base64 -d`.

- [ ] **Step 5: Write `README.md`**

Sections: title + one-line pitch; CI badge (`https://github.com/vladimir-kazarin/eks-llm-inference/actions/workflows/ci.yml/badge.svg`); "What this demonstrates" (Terraform modules + remote state with native locking; EKS GPU node groups under a hard quota; GitOps with Argo CD + GitOps bridge; cache-aware LLM routing measured on long agent contexts; guarded lifecycle automation that can't orphan an NLB); architecture diagram (spec §2); "Run it" (`make bootstrap` once, then `make up`, `make demo`, `make down`; ~$2.35/hr); "Results" (link to `docs/results.md`); "Design decisions" (link to `docs/architecture.md`); "Repo layout" (tree from this plan's File Structure); "Cost" (table from spec §8).

- [ ] **Step 6: Commit**

```bash
git add README.md docs
git commit -m "docs: add README, architecture, runbook and baseline results"
```

---

### Task 12: Publish the public GitHub repo ⚠️ outward-facing — owner confirms first

**Files:** none (git remote, history rewrite of author email).

- [ ] **Step 1: Set a GitHub no-reply author email** (personal email would be public in commit metadata)

Owner confirms which identity to use, then:
```bash
NOREPLY="$(gh api user -q '.id')+$(gh api user -q '.login')@users.noreply.github.com"
git -C . config user.email "$NOREPLY"
git rebase -r --root --exec 'git commit --amend --no-edit --reset-author'
git log --format='%ae' | sort -u   # expect only the noreply address
```

- [ ] **Step 2: Secret / PII scan before going public**

```bash
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
OLD_EMAIL=$(git config --global user.email)
git log -p --all | grep -nE "$ACCOUNT|arn:aws:iam::[0-9]{12}|AKIA[0-9A-Z]{16}" && echo "LEAK FOUND" || echo "no account ids / keys"
git log --all --format='%ae%n%ce' | grep -F "$OLD_EMAIL" && echo "PERSONAL EMAIL IN METADATA" || echo "metadata clean"
docker run --rm -v "$PWD":/repo zricethezav/gitleaks:v8.28.0 git /repo
```
Expected: `no account ids / keys`, `metadata clean`, gitleaks `no leaks found`. Anything else: stop and fix before pushing.

- [ ] **Step 3: Create and push** (after owner's explicit OK)

```bash
gh repo create vladimir-kazarin/eks-llm-inference --public --source . --push \
  --description "Production-style LLM inference on EKS: Terraform, Argo CD, vLLM production-stack, cache-aware routing"
```

- [ ] **Step 4: Verify CI green**

Run: `gh run watch --exit-status "$(gh run list --limit 1 --json databaseId -q '.[0].databaseId')"`
Expected: all five jobs succeed. Fix failures with new commits (no force-push after publishing).

---

### Task 13: Live run ⚠️ spends money (~$2.35/hr) — owner confirms first

**Files:**
- Modify: `docs/results.md`, `README.md`; Create: `results/*.json`

- [ ] **Step 1: Bootstrap (once)** — owner fills `terraform/bootstrap/terraform.tfvars`; `make bootstrap`. Expected: `state_bucket` output; budget email arrives.
- [ ] **Step 2: Up** — `make up` (review the plan, approve). Expected: exits 0 printing `endpoint: http://…elb.amazonaws.com`.
- [ ] **Step 3: Demo** — `make demo`. Expected: two turns streamed; turn 2 `cached` ≥ ~1800 tokens.
- [ ] **Step 4: Benchmarks** — for each `S` in `roundrobin session prefixaware`: `make strategy S=$S && make bench STRATEGY=$S`. Expected: each writes `results/<S>-<id>.{csv,json}`; `session` and `prefixaware` cache-hit % clearly above `roundrobin`. If not, inspect Grafana (`make grafana`) before drawing conclusions.
- [ ] **Step 5: Report** — `make report`; paste the table into `docs/results.md` (replacing the placeholder line) and README; add 3–5 sentences interpreting it (cache-hit and TTFT p95 differences, tied to the KV-capacity math). Then:
```bash
git add results/*.json docs/results.md README.md
git commit -m "docs: add EKS routing benchmark results"
git push
```
- [ ] **Step 6: Down** — `make down`. Expected: exits 0 with `clean`. Confirm via AWS: no EKS clusters, no load balancers, no running EC2 instances tagged `project=eks-llm-inference` in us-east-1.
