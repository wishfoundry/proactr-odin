# Plain text / HTML baselines

**No JSON.** Compares stacks on:

| Path | Role |
|------|------|
| `GET /plaintext` | I/O ceiling (`text/plain`) |
| `GET /fortunes` | **Primary** — DB + sort + HTML escape (`text/html`) |

See [`WORKLOAD.md`](WORKLOAD.md). Metrics: [`../../docs/BASELINE_METRICS.md`](../../docs/BASELINE_METRICS.md).

## Quick start

```bash
./schema/prepare.sh
export DATABASE_PATH=/tmp/proactr-tfb.sqlite

(cd go && go build -o tfb-go .)
(cd ntex && cargo build --release)

SERVERS="go ntex" ./run_bench.sh
```

## Peers

| ID | Routes |
|----|--------|
| `go` | plaintext + fortunes |
| `ntex` | plaintext + fortunes |
| `drogon` | plaintext + fortunes (build with system Drogon) |
| `laytan` | plaintext; fortunes 501 until SQLite linked |
| `proactr` | scaffold |

## Env

| Var | Default |
|-----|---------|
| `DATABASE_PATH` | `/tmp/proactr-tfb.sqlite` |
| `PORT` | `18080` |
| `WORKERS` | `1` |
| `BENCH_C` | `64` |
| `BENCH_Z` | `15s` |
| `WARMUP_Z` | `3s` |
| `SERVERS` | `go ntex` |
| `TESTS` | `plaintext fortunes` |
