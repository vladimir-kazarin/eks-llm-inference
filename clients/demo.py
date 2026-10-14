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
        print(f"turn {r.turn}: TTFT {r.ttft_ms:.0f} ms | cached {hit} "
              f"| headers {r.backend_headers}")
        print(f"  > {r.text.strip()}")


if __name__ == "__main__":
    main()
