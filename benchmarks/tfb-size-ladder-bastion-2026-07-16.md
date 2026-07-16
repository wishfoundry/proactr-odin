# TFB size ladder + fortunes — ranch-bastion (full matrix)

| Field | Value |
|-------|--------|
| **Host** | ranch-bastion · Linux 6.14.0-37-generic · 40× Xeon E5-2666 v3 |
| **Date** | 2026-07-16 |
| **Loadgen** | bombardier · C=100 · warm 3s · steady **15s** · localhost |
| **Workers / shards** | 8 (where supported) |
| **Routes** | `/plaintext` (13 B), `/s/4k`, `/s/64k`, `/s/1m`, `/s/4m`, `/fortunes` |
| **Logs** | main `/tmp/proactr-tfb-logs-20260716-071305` · drogon `/tmp/proactr-tfb-drogon-20260716-135819` · seastar `/tmp/proactr-tfb-seastar-20260716-141739` |

Payload sizes are fixed `text/plain` buffers (send-path sweep). Fortunes is DB + sort + HTML escape (same SQLite seed).

## RPS matrix (complete)

| Peer | I/O | plaintext | 4 KiB | 64 KiB | 1 MiB | 4 MiB | fortunes |
|------|-----|----------:|------:|-------:|------:|------:|---------:|
| **ntex** | neon-uring | **372k** | 284k | 103k | 3.5k | 733 | 14.8k |
| **ntex-compio** | compio/uring | 327k | 273k | 87k | **5.2k** | 774 | 15.6k |
| **laytan** | nbio/uring | 370k | **340k** | **173k** | 2.0k | 543 | n/a (501) |
| **drogon** | trantor/epoll | 307k | 253k | **123k** | **5.5k** | 651 | 7.6k |
| **seastar** | reactor **io_uring** · 8 shards | 289k | 286k | 119k | 4.4k | **828** | 10.3k |
| **go** | net/http epoll | 267k | 122k | 32k | 4.3k | **1.3k** | 10.9k |
| **envoy**→ntex | L7 proxy | 101k | 94k | 58k | 2.4k | 439 | **18.0k** |
| **compio** | raw uring (1 thr) | 89k | 74k | 18k | 1.6k | 414 | **41.0k** |
| **asio** | Asio uring (1 thr) | 87k | 77k | 21k | 1.2k | 405 | 4.7k |

Values are bombardier **Avg Reqs/sec** (rounded). Non-2xx: essentially zero (envoy s4m had 3× 5xx in the main run).

### Exact RPS (from summary TSV)

| Peer | plaintext | s4k | s64k | s1m | s4m | fortunes |
|------|----------:|----:|-----:|----:|----:|---------:|
| ntex | 371868.84 | 283858.58 | 102960.44 | 3511.97 | 733.40 | 14824.11 |
| ntex-compio | 326822.37 | 273196.15 | 87030.86 | 5187.14 | 774.25 | 15640.49 |
| laytan | 370101.88 | 340463.78 | 172803.98 | 1961.92 | 542.92 | n/a |
| **drogon** | **307231.35** | **253224.21** | **123135.31** | **5454.53** | **651.11** | **7628.89** |
| **seastar** | **288638.35** | **285623.99** | **119392.75** | **4415.29** | **827.67** | **10270.10** |
| go | 267462.37 | 121960.89 | 31715.18 | 4333.66 | 1296.12 | 10897.99 |
| envoy | 100852.02 | 93552.96 | 57884.57 | 2372.12 | 439.37 | 18031.17 |
| compio | 88790.01 | 73614.68 | 18310.38 | 1574.71 | 414.11 | 41038.09 |
| asio | 87477.28 | 77356.80 | 21226.39 | 1231.44 | 405.31 | 4715.33 |

## Notes on new rows

### Drogon (trantor / epoll)

- Strong multi-worker send path: **~123k @ 64 KiB**, **~5.5k @ 1 MiB** (best 1 MiB RPS in the matrix).
- Fortunes ~7.6k (sqlite3 C API per request + HTML escape; not Drogon ORM).
- Network I/O is **epoll**, not io_uring.

### Seastar (8 shards, reactor backend = **io_uring**)

- Log line: `Reactor backend: io_uring`.
- Very flat small-body curve: plain **289k** ≈ 4k **286k** (little protocol overhead).
- 64k **119k** competitive with drogon; 4 MiB **828** among best multi-worker bulk.
- Fortunes **10.3k** (blocking sqlite open per request on shard — not a Seastar-native DB design).

## Rank notes (updated)

| Scenario | Leaders |
|----------|---------|
| Tiny plaintext | ntex ≈ laytan > drogon > seastar > go |
| 4–64 KiB send | **laytan** > drogon ≈ seastar > ntex |
| 1 MiB | **drogon** > ntex-compio > seastar ≈ go |
| 4 MiB | **go** > seastar > ntex-compio > ntex > drogon |
| Fortunes | **compio** (light HTTP) ≫ envoy > ntex* > go ≈ seastar > drogon > asio |

\*ntex fortunes limited by shared SQLite mutex × 8 workers.

## Reproduce drogon / seastar only

```bash
ssh ranch-bastion.local '
  export PATH="$HOME/.cargo/bin:$HOME/go/bin:$PATH"
  cd ~/Projects/proactr-odin/comparisons/tfb
  SERVERS="drogon seastar" WORKERS=8 BENCH_C=100 BENCH_Z=15s \
    TESTS="plaintext s4k s64k s1m s4m fortunes" ./run_bench.sh
'
```
