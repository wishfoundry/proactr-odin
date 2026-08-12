# TFB-style baselines

Clear HTTP/1.1 peer matrices. Two hosts, same harness knobs:

| | **io_uring (Linux)** | **kqueue (Darwin)** |
|--|----------------------|---------------------|
| **When** | 2026-08-11 | 2026-08-12 |
| **Host** | ranch-bastion · Linux 6.14 · 40 cores | Darwin 25.5.0 · arm64 |
| **Load** | `oha` · `WORKERS=8` · `c=100` · warm 3 s · **15 s** | same |
| **Routes** | `/api/tiny` (13 B) · `/s/4k` · `/s/64k` · `/s/1m` · `/s/4m` · `/fortunes` | same |
| **TSV** | `comparisons/tfb/results/summary_20260811.tsv` | `…/summary_kqueue_20260811.tsv` |

proactr wire = **materialize** (`plan_optimize` off) on both.

---

## io_uring — Linux bastion

| Peer | I/O | Notes |
|------|-----|--------|
| **proactr** | io_uring | this tree |
| **ntex** | neon-uring | crates.io |
| **laytan** | nbio → io_uring | fortunes n/a (501) |
| **go** | net/http | GOMAXPROCS label only |
| **drogon** | trantor / **epoll** | not same I/O class |

### RPS (avg requests/sec)

| Peer | plaintext | 4 KiB | 64 KiB | 1 MiB | 4 MiB | fortunes |
|------|----------:|------:|-------:|------:|------:|---------:|
| **ntex** | **354 237** | 319 078 | 138 048 | **6 088** | **1 662** | 12 034 |
| **proactr** | 352 089 | **347 887** | **152 774** | 4 220 | 1 341 | **83 975** |
| **laytan** | 321 399 | 259 555 | 116 145 | 2 616 | 602 | n/a |
| **drogon**† | 278 285 | 147 992 | 22 983 | 1 455 | 330 | 7 813 |
| **go** | 231 598 | 194 346 | 125 224 | 5 513 | 1 788 | 8 431 |

† drogon large-body RPS is epoll reference only (oha Size/request flaky; body re-check OK).

---

## kqueue — Darwin (arm64)

| Peer | I/O | Notes |
|------|-----|--------|
| **proactr** | reactor **kqueue** | product sockets on kqueue |
| **laytan** | nbio / kqueue | fortunes n/a (501) |
| **ntex** | **tokio** | not neon-uring on Darwin |
| **go** | net/http | |
| **drogon** | — | not built on this pass |

### RPS (avg requests/sec)

| Peer | plaintext | 4 KiB | 64 KiB | 1 MiB | 4 MiB | fortunes |
|------|----------:|------:|-------:|------:|------:|---------:|
| **go** | **130 387** | 104 462 | 56 234 | 7 726 | 1 545 | 35 810 |
| **laytan** | 119 354 | **118 952** | 71 232 | 8 002 | **1 738** | n/a |
| **proactr** | 116 505 | 115 667 | **73 978** | **8 885** | 1 598 | **119 079** |
| **ntex** | 102 701 | 98 063 | 66 313 | 8 517 | 1 473 | 68 706 |

Do not cross-rank absolute RPS between bastion (40-core Linux) and laptop (arm64) —
use each table only against peers on the **same** host.

---

## Notes

- Fortunes app work differs across stacks (`benchmarks/TFB.md`).
- TLS/H2 last pin (io_uring bastion, 2026-08-10):  
  [`comparisons/tls-h2/results/BASTION_TLS_H2.md`](../comparisons/tls-h2/results/BASTION_TLS_H2.md).

## Reproduce

```bash
./comparisons/tfb/schema/prepare.sh

# Linux bastion (io_uring + drogon)
SERVERS="proactr laytan ntex drogon go" WORKERS=8 BENCH_C=100 BENCH_Z=15s \
  TESTS="plaintext s4k s64k s1m s4m fortunes" \
  ./comparisons/tfb/run_peer_matrix.sh

# Darwin (kqueue; no drogon)
SERVERS="proactr laytan ntex go" WORKERS=8 BENCH_C=100 BENCH_Z=15s \
  TESTS="plaintext s4k s64k s1m s4m fortunes" \
  ./comparisons/tfb/run_peer_matrix.sh
```

Requires `oha` on `PATH`.
