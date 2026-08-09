# Baseline — Plan R2 P5 (post native reactor)

**Pinned for next performance cut. Do not mix with older sessions.**

| Field | Value |
|-------|--------|
| **Date** | 2026-08-09 |
| **Git SHA** | `c93ddb8` |
| **Host** | Benjamins-MacBook-Pro.local · Darwin 25.5.0 arm64 · **12** logical CPUs · 32 GiB |
| **Load** | h2load `-c 50 -D 10 -t 4` · warmup 3 s |
| **WORKERS** | 8 |
| **PORT** | 18443 |
| **Peers** | proactr · ntex · drogon (same session) |
| **proactr engine** | `io_engine=reactor-kqueue` (P5 full wait) |
| **Artifacts** | `results/baseline_p5_20260809/` · raw also `/tmp/proactr-baseline-20260809-182614/` |

---

## 1. RPS matrix (same session)

| peer | proto | plaintext | s4k | s64k | s1m |
|------|-------|----------:|----:|-----:|----:|
| **proactr** | h1s | **111730** | 86942 | 30554 | **2599** |
| **ntex** | h1s | 137403 | 139036 | 57249 | 1996 |
| **drogon** | h1s | **150542** | 149807 | 65093 | **8612** |
| **proactr** | h2 | **96253** | 84995 | 30489 | **2216** |
| **ntex** | h2 | **128478** | 129834 | 44087 | 1018 |
| drogon | h2 | N/A (no_h2) | N/A | N/A | N/A |

All scored cells: **0 failed / 0 errored / 0 timeout**.

### Ratios (proactr / peer)

| Cell | vs drogon | vs ntex | Reading |
|------|----------:|--------:|---------|
| **h1s s1m** | **0.30×** | **1.30×** | Main bulk hole vs drogon; **ahead of ntex** |
| h1s s64k | 0.47× | 0.53× | Mid bulk still half-ish of peers |
| h1s s4k | 0.58× | 0.63× | Setup + one seal still costly |
| h1s plaintext | **0.74×** | 0.81× | Closest to drogon on tiny H1 |
| **h2 s1m** | — | **2.18×** | proactr **wins** bulk H2 vs ntex |
| h2 plaintext | — | **0.75×** | Tiny H2 still behind ntex |
| h2 s4k | — | 0.65× | |
| h2 s64k | — | 0.69× | |

**Honesty:** L0 still ~0.30× drogon on h1s s1m. L1 “reactor law OK” band (0.35–0.45×) **not yet hit on RPS** even though duty law is satisfied.

---

## 2. proactr duty (path_metrics)

| Cell | soft_cq_send | windows/turn | eagain_arms | seals/req | materialize |
|------|-------------:|-------------:|------------:|----------:|------------:|
| h1s plain | **0** | 1.00 | 0 | 1 | **= reqs** |
| h1s s1m | **0** | **16.96** | 10 | **17.0** | 1 (not per-req) |
| h2 plain | **0** | 0.50 | 0 | 0.50 | 1 |
| h2 s1m | **0** | **8.49** | 0 | 8.49 | 1 |

Interpretation:

- **Reactor law is live:** multi-window seal in one turn on bulk; no soft-CQ send tax.
- **h1s s1m:** ~17× 64 KiB windows per MiB body; almost no EAGAIN → not re-arm thrashing.
- **h1s plain:** every response **materializes** (`materialize == reqs`) — different bottleneck than bulk.
- **h2 plain:** 0.5 seals/req (frame-path accounting); small responses still 1 kevent turn per half-unit of seal.

---

## 3. CPU sample (macOS `sample`, proactr only)

Load during sample: h2load `-c 50 -D 12` h1s `/s/1m` → **~2572 RPS / 2.51 GB/s** (matches matrix class).

### h1s s1m — top of stack (collapsed, ≥5)

| Samples | Symbol | Class |
|--------:|--------|--------|
| 47655 | `kevent` | **idle / wait** (dominant) |
| 2862 | `__sendto` | socket send |
| 1857 | `unroll8_eor3_aes_gcm_enc_128_kernel` | **AES-GCM encrypt** |
| 1241 | `_platform_memmove` | copies (BIO / buffers) |
| 307 | `_platform_memset` | zeroing |

Among **non-kevent** heavy tops (~6.3k): roughly **~46% send**, **~30% AES-GCM**, **~20% memmove**.

Call-graph (busy path): `reactor_tls_flush` → `SSL_write` → OpenSSL GCM → `armv8_aes_gcm_encrypt`.

**Bound call for bulk H1:** when working, CPU is **encrypt + send + copy**, not façade soft-CQ. Large `kevent` share means workers are often waiting (peer/window/backpressure or incomplete CPU saturation), not spinning on proactr.

### h1s plaintext — top of stack

| Samples | Symbol | Class |
|--------:|--------|--------|
| 35949 | `kevent` | idle / wait |
| 1906 | `__sendto` | send |
| 1462 | `__recvfrom` | recv |
| 268 | memmove | copy |
| (lower) | scanner / header_parse / route / map_get | **HTTP parse/route** |
| (lower) | AES/CTR bits | small crypto |

**Bound call for tiny H1:** setup + parse/route + send/recv, not multi-window AES.

Artifacts: `baseline_p5_20260809/sample_h1s_s1m.txt`, `sample_h1s_plain.txt`.

---

## 4. What the baseline licenses next

### Do **not** cut yet without a one-cell A/B against this table

| Candidate next cut | Supported by baseline? | Target cell |
|--------------------|------------------------|-------------|
| **Seal window 64→128 KiB A/B** | **Yes (bulk)** — 17 SSL_write/req; AES+setup tax visible under flush | h1s s1m |
| **Reduce memmove/BIO CT copies** | **Yes (bulk)** — memmove #3 busy top | h1s s1m |
| **Kill H1 materialize on static/tiny** | **Yes (tiny)** — materialize=reqs on plain | h1s plain/s4k |
| **H2 plain frame/dispatch tax** | **Yes (tiny H2)** — 0.75× ntex plain; not AES-bound | h2 plain |
| Dual_Ct N>2 / soft-CQ density flags | **No** — soft_cq=0; law already multi-window | — |
| “Less AES” as a win | **No** — AES is useful work; want duty/goodput | — |

### Recommended **first** implement cut (after this pin)

Pick **one**:

1. **Bulk track:** seal-window A/B (64 vs 128 KiB) under reactor law — cheapest experiment, duty-first gates.  
2. **Or bulk track:** profile-guided BIO/memmove reduction in `reactor_drain_wbio`.  
3. **Tiny track (separate):** eliminate full materialize on static plaintext/s4k.

Do **not** mix bulk and tiny in one PR.

### Gates for any next cut (relative to this baseline)

- Same machine / WORKERS=8 / h2load `-c 50 -D 10` (or restate if changed).
- Matrix 0 errors; `soft_cq_send_completes=0` on TLS bulk.
- **h1s s1m:** claim only if RPS **≥ +15%** vs **2599** *and* windows/turn stays healthy *or* document AES/send ceiling if duty up / RPS +8–14%.
- Report ratio vs drogon same session (parity still not required).

---

## 5. Ceiling ladder (updated with this pin)

```text
L0 measured:   h1s s1m 0.30× drogon (2599 / 8612)   ← P5 baseline
L1 target:     0.35–0.45×  (+15–50% RPS from L0)     ← next bulk A/B band
L2 refine:     0.45–0.60×
L3 drogon:     ~1.0×                                  ← not next
```

H2 bulk vs ntex is already a win (2.18× s1m); do not use H2 bulk RPS as the drogon-gap narrative.

---

## 6. Reproduce

```bash
cd comparisons/tls-h2
SERVERS="proactr ntex drogon" WORKERS=8 BENCH_C=50 BENCH_Z=10 WARMUP_Z=3 \
  LOGDIR=/tmp/proactr-baseline-rerun ./run_matrix.sh

# CPU sample (optional)
WORKERS=8 ./proactr/server.bin &
h2load -c 50 -D 12 -t 4 --h1 https://127.0.0.1:18443/s/1m &
sample <pid> 8 -file sample_h1s_s1m.txt
```
