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
