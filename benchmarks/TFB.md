# TFB-style baselines

Latest **clear HTTP/1.1** peer matrix on ranch-bastion.

| Field | Value |
|-------|--------|
| **When** | 2026-08-11 |
| **Host** | ranch-bastion · Linux 6.14.0-37-generic · 40 cores |
| **Load** | `oha` · `WORKERS=8` · `c=100` · warm 3 s · steady **15 s** · localhost |
| **Routes** | `/api/tiny` (13 B), `/s/4k`, `/s/64k`, `/s/1m`, `/s/4m`, `/fortunes` |
| **Source** | `comparisons/tfb/results/summary_20260811.tsv` |
| **Harness** | `comparisons/tfb/run_peer_matrix.sh` |

proactr wire = **materialize** (`plan_optimize` off) — not kernel writev/sendfile.

### Peers

| Peer | I/O | Notes |
|------|-----|--------|
| **proactr** | io_uring | this tree |
| **ntex** | neon-uring | crates.io |
| **laytan** | nbio → io_uring | `vendor/laytan` · fortunes n/a (501) |
| **go** | net/http | `comparisons/tfb/go` · GOMAXPROCS label only |
| **drogon** | trantor / **epoll** | not same I/O class; oha Size often wrong on large bodies |

### RPS (avg requests/sec)

| Peer | plaintext | 4 KiB | 64 KiB | 1 MiB | 4 MiB | fortunes |
|------|----------:|------:|-------:|------:|------:|---------:|
| **ntex** | **354 237** | 319 078 | 138 048 | **6 088** | **1 662** | 12 034 |
| **proactr** | 352 089 | **347 887** | **152 774** | 4 220 | 1 341 | **83 975** |
| **laytan** | 321 399 | 259 555 | 116 145 | 2 616 | 602 | n/a |
| **drogon**† | 278 285 | 147 992 | 22 983 | 1 455 | 330 | 7 813 |
| **go** | 231 598 | 194 346 | 125 224 | 5 513 | 1 788 | 8 431 |

† drogon large-body RPS is epoll reference only (oha reported wrong Size/request; body re-check passed for len path).

Fortunes app work still differs across stacks (see `comparisons/tfb/WORKLOAD.md`). proactr fortunes use per-worker SQLite; ntex uses shared mutex + prepare-per-request.

### vs older pins (plaintext)

| Pin | proactr | ntex |
|-----|--------:|-----:|
| 2026-07-25 published | ~349 k | ~362 k |
| bastion R3 (size ladder only) | ~366 k | ~358 k |
| **2026-08-11 (this run)** | **~352 k** | **~354 k** |

Host noise ± a few percent is normal. Prefer this file’s table over older docs.

---

## TLS size ladder (previous pin)

Clear H1 was re-run above. TLS/H2 matrix was **not** re-run today; last pin remains
2026-08-10 in [`comparisons/tls-h2/results/BASTION_TLS_H2.md`](../comparisons/tls-h2/results/BASTION_TLS_H2.md).

---

## Reproduce

```bash
./scripts/fetch_third_party.sh
./comparisons/tfb/schema/prepare.sh
# build drogon: comparisons/tfb/drogon/build.sh (on Linux bastion)

SERVERS="proactr laytan ntex drogon go" WORKERS=8 BENCH_C=100 BENCH_Z=15s \
  TESTS="plaintext s4k s64k s1m s4m fortunes" \
  ./comparisons/tfb/run_peer_matrix.sh
```

Requires `oha` on `PATH`.
