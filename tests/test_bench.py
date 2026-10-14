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
