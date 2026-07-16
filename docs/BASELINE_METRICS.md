# Baseline metrics (proactr-odin)

## Suite choice

| Suite | Path | Use for |
|-------|------|---------|
| **TFB-style (primary)** | `comparisons/tfb/` | Honest framework baselines — JSON, Fortunes, DB |
| empty-ok (canary) | `comparisons/empty-ok/` | Wiring / smoke only |

Vapor-http’s `realistic-gen-html` is **not** imported here as a headline suite.
It under-exercises encoding, escaping, and data access.

## Headline numbers (every peer × every test)

1. **Goodput RPS** — successful responses / second only  
2. **p50 / p99 latency** — client-side; prefer oha `--latency-correction`  
3. **Error rate** — timeouts, resets, non-2xx  
4. **RPS/core** — goodput ÷ configured workers  

Secondary: RSS, CPU%, knee of RPS-vs-p99 curve.

## Ranking rules

| Test | Weight in discussion |
|------|----------------------|
| `/fortunes` | **Primary** (matches TE default narrative) |
| `/json` | High (serialization + headers) |
| `/db` | High (I/O wait + JSON) |
| `/queries` | Medium (concurrency under multi-query) |
| `/plaintext` | Ceiling only — never lead a claim |

Envoy: report **p99 delta vs direct upstream** at fixed offered load, not max RPS.
