# Results

## Single-machine baseline (local GPU, two vLLM processes, custom `gateway.py`)

Earlier local experiments with the same synthetic agent workload (`local/bench.py`,
predecessor of `clients/bench.py`), vLLM 0.30, Qwen3 (0.6B/4B — the model per run
wasn't recorded), routed by a hand-written gateway.

| strategy | requests | cache hit | TTFT p50 ms | TTFT p95 ms | output tok/s |
|---|---|---|---|---|---|
| cache_on | 40 | 95.4% | 123 | 167 | 36.3 |
| conc2 | 40 | 95.7% | 101 | 135 | 34.6 |
| conc8 | 160 | 20.3% | 2567 | 9161 | 3.7 |
| rr | 96 | 18.0% | 1322 | 4020 | 8.1 |
| sticky | 96 | 60.3% | 381 | 2251 | 10.6 |

- `cache_on` / `conc2` / `conc8`: one replica, 1 / 2 / 8 concurrent sessions.
  At 8 sessions the prefix cache thrashes: hit rate falls from ~95% to ~20%.
- `rr` vs `sticky`: two replicas, 8 sessions. Round-robin spreads each session's
  turns across both replicas, so most turns miss; pinning sessions triples the hit
  rate and cuts median TTFT ~3.5×.
- `output tok/s` is per-stream: local runs didn't record wall-clock time, so
  wall = summed request time.

## EKS: 2× g5.xlarge, Qwen3-4B, vLLM v0.31.0, production-stack router v0.1.13

Workload: 6 concurrent agent sessions × 30 turns, context growing to ~28k tokens
(`make bench`). Each replica holds ~85k cached tokens, so 6 × 28k-token sessions
(~170k) only stay cached if each session sticks to one replica.

_Filled in after the first live run._
