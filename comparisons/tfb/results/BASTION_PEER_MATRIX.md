# ranch-bastion peer matrix — critic rounds 0–3

**Host:** ranch-bastion · Linux 6.14 · 40 cores  
**Matrix:** `WORKERS=8` · `BENCH_C=100` · `BENCH_Z=15s` · `WARMUP_Z=3s` · oha  
**Peers:** proactr · laytan · ntex · drogon  
**Routes:** size ladder only (`plaintext` 13B · `s4k` · `s64k` · `s1m`) — **not fortunes** (unfair app work)  
**proactr wire:** materialize (`plan_optimize=false`) — **not** kernel writev/sendfile  

See [`../CRITIC.md`](../CRITIC.md), [`../run_peer_matrix.sh`](../run_peer_matrix.sh).

## Backend labels

| Peer | I/O |
|------|-----|
| proactr | io_uring |
| laytan | nbio → io_uring |
| ntex | neon-uring |
| drogon | **epoll** (trantor) — not same class |

## RPS matrix

### Round 0 — baseline (before fix rounds)

| peer | plaintext | s4k | s64k | s1m |
|------|----------:|----:|-----:|----:|
| **proactr** | **358193** | **351359** | **134591** | **6823** |
| ntex | 349640 | 326268 | 130348 | 4847 |
| laytan | 335059 | 266139 | 112017 | 2580 |
| drogon | 287918 | 140813† | 23998† | 1356† |

### Round 3 — after 3 critic rounds

| peer | plaintext | s4k | s64k | s1m |
|------|----------:|----:|-----:|----:|
| **proactr** | **365912** | **341655** | **150722** | 4422 |
| ntex | 358131 | 311181 | 134088 | **5417** |
| laytan | 325657 | 261699 | 118411 | 2776 |
| drogon | 288261 | 159986† | 23781† | 1372† |

† drogon: oha `Size/request` **mismatches** expected body (74 / 222 / 2601 vs 4K/64K/1M). Curl + KA python got full bodies. **RPS treated as epoll reference only; size field untrusted.**

## Before → after (proactr)

| route | R0 (before) | R3 (after) | Δ |
|-------|------------:|-----------:|--:|
| plaintext | 358193 | 365912 | **+2.2%** |
| s4k | 351359 | 341655 | −2.8% |
| s64k | 134591 | 150722 | **+12.0%** |
| s1m | 6823 | 4422 | **−35%** (see note) |

Intermediate rounds: `results/r{0,1,2,3}_summary.tsv`.

### s1m note

R1 introduced exact-size materialize for **all** single Static bodies; s1m RPS fell (6823→5028→4234). R3 **limits fast-path to ≤256 KiB** so s1m uses the classic grow+write path again, but R3 s1m (4422) did **not** fully recover R0 (6823) in this sample — host noise and/or remaining path differences. **Do not claim s1m win from this series.** Best observed proactr s1m remains **R0 6823**.

## Critic rounds (summary)

| Round | Focus | Outcome |
|-------|--------|---------|
| **Harness** | Fake-bench audit | Fortunes unfair; body-check + warmup; backend labels; `CRITIC.md` |
| **R0** | Baseline bastion | proactr led ladder; drogon oha Size anomaly |
| **R1** | Fast materialize + date + oha size warn | s64k ↑; s1m ↓ (fast path too aggressive) |
| **R2** | `headers_set_unsafe` Server; fix size unit parse | plaintext ↑ slightly |
| **R3** | Cap fast-path at 256 KiB | s64k best; s1m still below R0 |

## What we deliver (mechanism honesty)

| Claim | Truth |
|-------|--------|
| proactr TFB size ladder | **materialize** one buffer + send |
| “Writev” optimize path | sequential multi-`submit_send` (not kernel writev) |
| “Sendfile” optimize path | chunked **pread+send** (`plan_wire_copy_into`) |
| Peer matrix | fair **size ladder**; fortunes **not** in this ranking |

## Reproduce

```bash
rsync -az --exclude '.git' --exclude '**/target' --exclude 'third_party' \
  ./ ranch-bastion.local:Projects/proactr-odin/
ssh ranch-bastion.local '
  export PATH="$HOME/.cargo/bin:/usr/local/bin:$PATH"
  cd ~/Projects/proactr-odin
  TESTS="plaintext s4k s64k s1m" SERVERS="proactr laytan ntex drogon" \
    WORKERS=8 BENCH_C=100 BENCH_Z=15s FORCE_REBUILD=1 \
    LOGDIR=/tmp/peer-matrix-run ./comparisons/tfb/run_peer_matrix.sh
'
```
