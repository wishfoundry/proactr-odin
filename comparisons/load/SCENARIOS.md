# Product readiness — load scenarios

These are **capacity / SLO** checks, not ceiling microbenches.

| Suite | Question |
|-------|----------|
| `comparisons/tfb` | How fast can peers go (RPS ladder)? |
| **`comparisons/load`** | Does the server hold up under *target* load with latency/error bounds? |

## Defaults

| Knob | Default | Meaning |
|------|---------|---------|
| Peer | `proactr` | TFB binary on `:PORT` |
| `WORKERS` | 8 | Server threads/rings |
| `PORT` | 18080 | Listen port |
| Loadgen | bombardier (oha fallback) | Keep-alive unless noted |
| Machine | single host (localhost) | Same as TFB; multi-host later |

Build proactr (default build owns permanent per-connection response buffers):

```bash
odin build comparisons/tfb/proactr -out:comparisons/tfb/proactr/tfb-proactr.bin -o:speed
```

## Scenarios

Each scenario: fixed **target concurrency** and **duration**, then **pass/fail SLOs**.

| ID | Intent | Path | c | Duration | SLO (defaults) |
|----|--------|------|--:|---------:|----------------|
| `api_steady` | Typical small API / health traffic | `/plaintext` | 50 | 30s | p99 ≤ 5 ms · errors = 0 · RPS ≥ 50k\* |
| `api_busy` | Busier small responses | `/plaintext` | 200 | 30s | p99 ≤ 15 ms · errors = 0 · RPS ≥ 100k\* |
| `payload_medium` | Common static/API payload | `/s/64k` | 50 | 30s | p99 ≤ 20 ms · errors = 0 · RPS ≥ 20k\* |
| `payload_bulk` | Large download / report path | `/s/1m` | 20 | 30s | p99 ≤ 100 ms · errors = 0 · RPS ≥ 1k\* |
| `spike` | Short overload burst | `/plaintext` | 500 | 10s | p99 ≤ 50 ms · errors = 0 · (RPS informational) |
| `ramp` | Step load (c=20→50→100→200) | `/plaintext` | steps | 15s each | each step: errors = 0 · p99 ≤ step budget |
| `soak` | Longer stability (opt-in) | `/plaintext` | 50 | 5m | errors = 0 · p99 ≤ 10 ms · no process death |
| `mixed` | Weighted multi-route (phases) | see below | 50 | 60s total | errors = 0 · per-phase p99 |

\*RPS floors are **soft** on underpowered hosts; set `SLO_STRICT_RPS=0` (default) to warn instead of fail. Latency and error SLOs always fail hard.

### Mixed weights (default)

Sequential phases, same keep-alive client pool restarted per phase:

| Phase | Path | Share of wall time |
|-------|------|-------------------:|
| A | `/plaintext` | 50% |
| B | `/s/4k` | 25% |
| C | `/s/64k` | 15% |
| D | `/s/1m` | 10% |

## Pass / fail

Harness exits **non-zero** if any selected scenario fails a hard SLO.

| Signal | Hard fail? |
|--------|------------|
| Non-2xx or loadgen errors | **yes** |
| p99 above budget | **yes** |
| Server died / bind failed | **yes** |
| RPS below floor | only if `SLO_STRICT_RPS=1` |

## Run

```bash
# Default: proactr, readiness set (api_steady api_busy payload_medium payload_bulk spike ramp mixed)
./comparisons/load/run_load.sh

# Subset
SCENARIOS="api_steady spike mixed" ./comparisons/load/run_load.sh

# Peer (must already build like TFB)
PEER=ntex SCENARIOS="api_steady payload_bulk" ./comparisons/load/run_load.sh

# Long soak
SCENARIOS="soak" ./comparisons/load/run_load.sh

# Stricter RPS floors
SLO_STRICT_RPS=1 ./comparisons/load/run_load.sh
```

Logs: `LOGDIR` (default `/tmp/proactr-load-logs`).

## Interpreting results

- **Ceiling** numbers from `comparisons/tfb` may be higher; readiness uses **moderate c** and **latency budgets**.
- Failing **p99** under `api_*` usually means queueing or head-of-line (bulk work sharing workers).
- Failing **errors** under `spike` means accept/backpressure or resource limits — product issue even if steady RPS looks fine.
- `soak` is for leaks / gradual latency climb; compare first vs last minute p99 in the log.

## Not covered yet (roadmap)

- Multi-host loadgen (client ≠ server)
- HTTP/2, TLS
- Auth / multi-route true concurrent mix (needs k6 or custom client)
- Chaotic kill/restart, dependency latency injection
