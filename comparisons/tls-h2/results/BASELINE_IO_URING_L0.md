# Baseline — io_uring L0 (pre density work)

**Pinned before Linux dense-flush / soft_cq work. Do not mix with Darwin sessions.**

| Field | Value |
|-------|--------|
| **Date** | 2026-08-10T14:50Z |
| **Git SHA** | `47a8cbe` (tree synced to bastion) |
| **Host** | ranch-bastion · Linux 6.14.0-37-generic x86_64 · **40** logical CPUs · ~46 GiB |
| **Load** | h2load `-c 50 -D 10 -t 4` · warmup 3 s |
| **WORKERS** | 8 |
| **Peers** | proactr + drogon · PROTOCOLS=**h1s** only |
| **proactr engine** | `io_engine=proactor-uring` |
| **Artifacts** | `/tmp/proactr-iou-l0` on bastion · local `BASTION_TLS_H2.md` / `bastion_summary.tsv` / `bastion_instrumentation.txt` (this run) |
| **Plan** | `PLAN_IO_URING_DROGON_PARITY.md` |

---

## 1. RPS matrix (same session)

| peer | plaintext | s4k | s64k | s1m |
|------|----------:|----:|-----:|----:|
| **proactr** | **200242** | **182633** | **49179** | **4740** |
| **drogon** | 192283 | 168810 | 48671 | **3455** |
| **proactr/drogon** | **1.04×** | **1.08×** | **1.01×** | **1.37×** |

All scored cells: **0 failed / 0 errored / 0 timeout**.

**Reading:** On this bastion session, proactr **already beats drogon** on every h1s cell, bulk **1.37×**. Performance WOW gates for B2/B3 are met *numerically*. Architecture / duty law is **not** met (see §3).

---

## 2. Scale ladder (proactr only, `/s/1m`, 5 s)

| c | RPS (approx) |
|--:|-------------:|
| 4 | 1629 |
| 8 | 3785 |
| 16 | 4026 |
| 50 | 4761 |

Under c=50 load: **8 worker threads** all ~38–62% CPU (multi-worker busy).  
**A7 scale:** healthy — not the Darwin REUSEPORT single-worker pin.

---

## 3. Duty (path_metrics) — honesty

| Cell | soft_cq_send | seals/req (scrape) | materialize | notes |
|------|-------------:|-------------------:|------------:|-------|
| h1s plain | **≈ ct_sends** (2.00M) | 1.0 | = reqs | **One soft send CQE per CT send** |
| h1s s4k | **≈ ct_sends** | 1.0 | = reqs | same |
| h1s s64k | **≈ ct_sends** (984k) | scrape broken (`reqs=1`) | 1 | bulk multi-seal; **soft CQ still tracks sends** |
| h1s s1m | **≈ ct_sends** (237k) | scrape broken (`reqs=1`) | 1 | same |

- `seal_windows` / `kevent_turns` = 0 (Darwin-only counters — expected).  
- **`soft_cq_send_completes` ≫ 0** on all cells → product TLS still pays a **proactor send completion per CT flight**.  
- Bulk `path_reqs` scrape stuck at 1 after s64k/s1m — instrumentation bug (reset/req count); RPS from h2load is authoritative.

**Law label:** L0 proactor façade density — **not** Darwin multi-window soft_cq=0 law.

---

## 4. Honesty labels

| Label | Status |
|-------|--------|
| Performance vs same-session drogon B2/B3 | **PASS / WOW numbers** (1.37× / 1.04×) |
| Architecture A5 soft_cq | **FAIL** (soft_cq ≈ every send) |
| Architecture A7 workers | **PASS** (8 busy) |
| “Converged architecture to drogon” | **BANNED** until dense flush + soft_cq honesty |
| Next work | Dense multi-window TLS without soft CQE between seals; fix bulk path_metrics req count |

---

## 5. Remeasure recipe

```bash
cd comparisons/tls-h2
SERVERS="proactr drogon" WORKERS=8 BENCH_C=50 BENCH_Z=10 WARMUP_Z=3 \
  PROTOCOLS=h1s REMOTE_LOG=/tmp/proactr-iou-iterN ./run_on_bastion.sh
# Scale + workers under c=50 as above
# Claim WOW only if critic: B2≥0.90 B3≥0.80 **and** A5 soft_cq=0 (or NEW LAW)
```
