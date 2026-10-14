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
