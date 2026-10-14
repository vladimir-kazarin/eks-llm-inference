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
