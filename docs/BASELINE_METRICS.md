# Baseline metrics (proactr-odin)

## Suite choice

| Suite | Path | Use for |
|-------|------|---------|
| **Plain text / HTML (primary)** | `comparisons/tfb/` | Honest host baselines — no JSON |
| empty-ok (canary) | `comparisons/empty-ok/` | Wiring / smoke only |

JSON is intentionally excluded: codec choice varies too much across languages.

## io_uring (Linux / ranch-bastion)

Default peers use **io_uring** for HTTP I/O. See `comparisons/tfb/IO_URING.md`.

| In matrix | Backend |
|-----------|---------|
| ntex | neon-uring |
| ntex-compio | compio |
| compio | compio-net |
| asio | Asio io_uring (`DISABLE_EPOLL`) |
| laytan | core:nbio |

Go / Drogon have **no** net io_uring path — opt-in only, label results `epoll`.

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
