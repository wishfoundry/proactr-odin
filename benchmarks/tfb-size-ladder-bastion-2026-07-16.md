# TFB size ladder + fortunes — ranch-bastion

| Field | Value |
|-------|--------|
| **Host** | ranch-bastion · Linux 6.14.0-37-generic · 40× Xeon E5-2666 v3 |
| **Date** | 2026-07-16 |
| **Loadgen** | bombardier · C=100 · warm 3s · steady **15s** · localhost |
| **Workers** | 8 (where supported) |
| **Routes** | `/plaintext` (13 B), `/s/4k`, `/s/64k`, `/s/1m`, `/s/4m`, `/fortunes` |
| **Logs** | `/tmp/proactr-tfb-logs-20260716-071305` |

Payload sizes are fixed `text/plain` buffers (send-path sweep). Fortunes is DB + sort + HTML escape.

## RPS matrix

| Peer | I/O | plaintext | 4 KiB | 64 KiB | 1 MiB | 4 MiB | fortunes |
|------|-----|----------:|------:|-------:|------:|------:|---------:|
| **ntex** | neon-uring | **372k** | 284k | 103k | 3.5k | 733 | 14.8k |
| **ntex-compio** | compio/uring | 327k | 273k | 87k | **5.2k** | 774 | 15.6k |
| **laytan** | nbio/uring | 370k | **340k** | **173k** | 2.0k | 543 | n/a (501) |
| **go** | net/http epoll | 267k | 122k | 32k | 4.3k | **1.3k** | 10.9k |
| **envoy**→ntex | proxy | 101k | 94k | 58k | 2.4k | 439 | **18.0k** |
| **asio** | io_uring | 87k | 77k | 21k | 1.2k | 405 | 4.7k |
| **compio** | raw uring | 89k | 74k | 18k | 1.6k | 414 | **41.0k** |
| drogon | trantor/epoll | — | — | — | — | — | build failed this run |
| seastar | — | — | — | — | — | — | not automated |

Values rounded from bombardier Avg Reqs/sec. **0 non-2xx** on almost all cells (envoy s4m had 3× 5xx).

## Throughput view (approx from RPS × size)

At large bodies, goodput is GB/s-class on loopback:

| Peer | 64 KiB goodput | 1 MiB goodput | 4 MiB goodput |
|------|---------------:|--------------:|--------------:|
| ntex | ~6.3 GB/s | ~3.4 GB/s | ~2.9 GB/s |
| laytan | **~10.5 GB/s** | ~1.9 GB/s | ~2.1 GB/s |
| go | ~1.9 GB/s | ~4.0 GB/s | ~4.9 GB/s |
| envoy | ~3.5 GB/s | ~2.3 GB/s | ~1.7 GB/s |

(Using RPS × body size; headers omitted.)

## Rank notes

### Size ladder (send path)

- **Small/medium (plain→64k):** multi-worker **laytan** and **ntex** lead; laytan especially strong at 4k/64k.
- **1–4 MiB:** **go** and **ntex-compio** competitive on RPS; single-thread **asio/compio** lag (expected).
- Curve is clear: RPS falls as body grows — use this table to track bulk send work for proactr.

### Fortunes (app-shaped)

1. **compio ~41k** (single conn, light HTTP)
2. **envoy→ntex ~18k** (proxy + upstream; interesting — warm caches / different path)
3. ntex / ntex-compio ~15–16k  
4. go ~11k  
5. asio ~4.7k (per-request sqlite open)  
6. laytan n/a until SQLite linked  

### Envoy

Proxy overhead vs direct ntex plaintext: **~101k vs ~372k** (~3.7×). On 64k gap narrows relatively. Fortunes through envoy can look high when upstream is lightly loaded differently — treat as **proxy class**, not app-server rank.

## Missing / follow-ups

- **drogon**: trantor-based build failed on bastion this run — fix `drogon/build.sh` deps and re-run row.
- **seastar**: still manual (`comparisons/tfb/seastar/README.md`).
- **laytan fortunes**: wire SQLite for primary app comparison.
- Multi-worker asio/compio for fair large-body RPS.
- Prefer `oha` for true p50/p99 next time.

## Reproduce

```bash
ssh ranch-bastion.local '
  export PATH="$HOME/.cargo/bin:$HOME/go/bin:$PATH"
  cd ~/Projects/proactr-odin/comparisons/tfb
  SERVERS="ntex ntex-compio compio asio laytan go envoy" \
    WORKERS=8 BENCH_C=100 BENCH_Z=15s \
    TESTS="plaintext s4k s64k s1m s4m fortunes" \
    ./run_bench.sh
'
```
