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
