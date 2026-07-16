# Baseline metrics (proactr-odin)

## Suite choice

| Suite | Path | Use for |
|-------|------|---------|
| **Plain text / HTML (primary)** | `comparisons/tfb/` | Honest host baselines — no JSON |
| empty-ok (canary) | `comparisons/empty-ok/` | Wiring / smoke only |

JSON is intentionally excluded: codec choice varies too much across languages.

## Endpoints

| Test | Content-Type | Role |
|------|--------------|------|
| `/fortunes` | `text/html` | **Primary** — DB + sort + escape |
| `/plaintext` | `text/plain` | Ceiling only |

## Headline numbers (every peer × every test)

1. **Goodput RPS** — successful responses / second only  
2. **p50 / p99 latency** — client-side; prefer oha `--latency-correction`  
3. **Error rate** — timeouts, resets, non-2xx  
4. **RPS/core** — goodput ÷ configured workers  

## Ranking rules

| Test | Weight |
|------|--------|
| `/fortunes` | **Primary** |
| `/plaintext` | Ceiling only — never lead a claim |
