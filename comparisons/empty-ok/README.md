# empty-ok comparison

Minimal ceiling: `GET /` → `200` + body `OK`.

## Fairness

All multi-worker peers honor **`WORKERS`** (default **8** in `run_bench.sh`, default **1** if you run a binary bare).

| Peer | Workers |
|------|---------|
| **proactr** | `opts.thread_count` via `listen_and_serve` 4th arg |
| **laytan** | same (explicit count — *not* all-cores when unset) |
| **ntex** | `.workers(WORKERS)` |
| **drogon** | `.setThreadNum(WORKERS)` |
| asio / compio | single accept loop (document as W=1 baseline) |

**Pitfall:** proactr `listen()` always assigns `s.opts = opts`. Setting `s.opts.thread_count` and calling `listen_and_serve` *without* the 4th arg still runs **1 worker**. Always pass `opts`.

## Peers

| ID | Dir | Stack |
|----|-----|--------|
| `proactr` | `proactr/` | this tree `http` + io_uring host |
| `laytan` | `laytan/` | vendored laytan/odin-http nbio |
| `ntex` | `ntex/` | ntex web |
| `compio` | `compio/` | raw compio TCP |
| `drogon` | `drogon/` | drogon |
| `asio` | `asio/` | Boost.Asio sample |
| `seastar` | `seastar/` | optional, heavy |
| `envoy` | `envoy/` | reverse proxy, optional |

## Run

```bash
# Default WORKERS=8, BENCH_C=100, 10s + 2s warm (bombardier preferred)
./run_bench.sh

SERVERS="ntex laytan proactr" WORKERS=8 PORT=18080 ./run_bench.sh
WORKERS=1 SERVERS="proactr laytan" ./run_bench.sh   # single-worker A/B
SKIP_HEAVY=1 ./run_bench.sh
```

Requires `bombardier`, `oha`, or `wrk` on `PATH`.

## Primary baseline

For product numbers prefer **`comparisons/tfb`** (plaintext size ladder + fortunes). This suite is a wiring / ceiling canary with a fair worker matrix.
