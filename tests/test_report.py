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
