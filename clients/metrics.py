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
