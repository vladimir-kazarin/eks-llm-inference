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
