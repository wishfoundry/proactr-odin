# TFB-style baselines

Honest multi-framework benchmarks shaped like **TechEmpower** tests  
(`/json`, `/plaintext`, `/fortunes`, `/db`, `/queries`).

See [`WORKLOAD.md`](WORKLOAD.md) for rules and anti-cheat policy.  
Metrics: [`../../docs/BASELINE_METRICS.md`](../../docs/BASELINE_METRICS.md).

## Quick start

```bash
# 1. Seed SQLite (TE-scale World + Fortune)
./schema/prepare.sh
export DATABASE_PATH=/tmp/proactr-tfb.sqlite

# 2. Build peers you care about
(cd go && go build -o tfb-go .)
(cd ntex && cargo build --release)

# 3. Run matrix (oha preferred)
./run_bench.sh

# Subset:
SERVERS="go ntex" TESTS="json fortunes db" ./run_bench.sh
```

## Peers

| ID | Dir | Stack |
|----|-----|--------|
| `go` | `go/` | `net/http` + `database/sql` + modernc/sqlite |
| `ntex` | `ntex/` | ntex + rusqlite (serde_json — not sonic) |
| `drogon` | `drogon/` | Drogon + SQLite |
| `laytan` | `laytan/` | vendored laytan/odin-http (fortunes via process-local DB read through `sqlite3` subprocess is **not** used — see peer README; uses linked SQLite when available, else documented skip) |
| `proactr` | `proactr/` | stub until host lands |

## Environment

| Var | Default | Meaning |
|-----|---------|---------|
| `DATABASE_PATH` | `/tmp/proactr-tfb.sqlite` | SQLite file |
| `PORT` | `18080` | listen port |
| `WORKERS` | `1` | peer worker/thread hint |
| `BENCH_C` | `64` | loadgen concurrency |
| `BENCH_Z` | `15s` | steady duration |
| `WARMUP_Z` | `3s` | warmup duration (discarded) |
| `SERVERS` | `go ntex` | peer list |
| `TESTS` | `json plaintext fortunes db queries` | which paths |

## Output

Logs under `/tmp/proactr-tfb-logs/`. Summary table prints **RPS · p50 · p99 · errors**.
