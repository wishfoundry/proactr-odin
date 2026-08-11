# TFB-style baselines

Numbers below are the **latest checked-in peer matrices** under `comparisons/tfb/results/`
and `comparisons/tls-h2/results/`. Older 2026-07-25 full-ladder tables are retired
(RPS has moved; re-run before claiming).

## Peers

| Peer | I/O (Linux) | Source |
|------|-------------|--------|
| **proactr** | proactr / io_uring | this tree |
| **laytan** | nbio → io_uring | `vendor/laytan/odin-http` |
| **ntex** | neon-uring | crates.io |
| **drogon** | trantor / **epoll** | `third_party/drogon` |
| **go** | net/http | `comparisons/*/go` (TLS matrix only so far in latest runs) |

---

## Clear HTTP/1.1 size ladder (io_uring bastion)

| Field | Value |
|-------|--------|
| **Source** | `comparisons/tfb/results/summary.tsv` (R3) · [`BASTION_PEER_MATRIX.md`](../comparisons/tfb/results/BASTION_PEER_MATRIX.md) |
| **Host** | ranch-bastion · Linux 6.14 · 40 cores |
| **Load** | `oha` · `WORKERS=8` · `c=100` · warm 3 s · **15 s** steady |
| **proactr wire** | materialize (`plan_optimize` off) — not kernel writev/sendfile |
| **Not in this matrix** | go · s4m · fortunes |

### RPS (avg requests/sec)

| Peer | plaintext | 4 KiB | 64 KiB | 1 MiB |
|------|----------:|------:|-------:|------:|
| **proactr** | **365 912** | **341 655** | **150 722** | 4 422 |
| **ntex** | 358 131 | 311 181 | 134 088 | **5 417** |
| **laytan** | 325 657 | 261 699 | 118 411 | 2 776 |
| **drogon**† | 288 261 | 159 986 | 23 781 | 1 372 |

† drogon is epoll (not same I/O class). oha `Size/request` was wrong on large bodies in this run; RPS kept as reference only after body re-check — see bastion notes.

**vs prior 2026-07-25 pin (same host class, full ladder):** proactr plaintext ~349k → ~366k; s64k ~137k → ~151k. s1m regressed in R1–R3 vs R0 best (~6.8k); do not claim s1m wins from R3 alone.

### Fortunes (partial, fairer app work)

| Field | Value |
|-------|--------|
| **Source** | `comparisons/tfb/results/fortunes_fair_v2.tsv` |
| **Peers** | proactr-mat · ntex · drogon only |

| Peer | plaintext | fortunes |
|------|----------:|---------:|
| **proactr-mat** | 344 740 | **85 385** |
| **ntex** | **357 347** | 10 653 |
| **drogon** | 283 055 | 7 551 |

Fortunes work is still not identical across stacks; see [`comparisons/tfb/WORKLOAD.md`](../comparisons/tfb/WORKLOAD.md).

---

## TLS size ladder (io_uring bastion)

| Field | Value |
|-------|--------|
| **Source** | `comparisons/tls-h2/results/bastion_summary.tsv` · [`BASTION_TLS_H2.md`](../comparisons/tls-h2/results/BASTION_TLS_H2.md) |
| **When** | 2026-08-10 |
| **Load** | h2load · `WORKERS=8` · `c=100` · 15 s |
| **Protocols** | `h2` (ALPN required) · `h1s` (TLS HTTP/1.1) |

### RPS — HTTP/2

| Peer | plaintext | 4 KiB | 64 KiB | 1 MiB |
|------|----------:|------:|-------:|------:|
| **proactr** | **187 693** | **151 181** | **51 539** | **4 329** |
| **ntex** | 141 751 | 125 717 | 34 722 | 1 128 |
| **go** | 94 778 | 85 982 | 32 557 | 3 388 |
| **drogon** | n/a | n/a | n/a | n/a |

### RPS — TLS HTTP/1.1

| Peer | plaintext | 4 KiB | 64 KiB | 1 MiB |
|------|----------:|------:|-------:|------:|
| **proactr** | **216 956** | **184 710** | **53 453** | **5 031** |
| **ntex** | 179 876 | 155 038 | 44 293 | 1 680 |
| **drogon** | 201 175 | 180 872 | 48 204 | 3 922 |
| **go** | 160 268 | 103 334 | 44 426 | 4 714 |

drogon did not negotiate h2 in this matrix (`no_h2`).

---

## kqueue (Darwin)

No full peer re-matrix checked in after 2026-07-25. Treat Darwin numbers as **stale** until
re-run; do not cite them next to the bastion tables above.

---

## Reproduce

```bash
./scripts/fetch_third_party.sh
./comparisons/tfb/schema/prepare.sh

SERVERS="proactr laytan ntex drogon" WORKERS=8 BENCH_C=100 BENCH_Z=15s \
  TESTS="plaintext s4k s64k s1m" \
  ./comparisons/tfb/run_peer_matrix.sh

# TLS/H2
SERVERS="proactr ntex drogon go" WORKERS=8 \
  ./comparisons/tls-h2/run_matrix.sh
```

Requires `oha` (clear) and `h2load` (TLS) on the bastion `PATH`.
