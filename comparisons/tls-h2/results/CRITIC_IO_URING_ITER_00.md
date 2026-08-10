# Critic io_uring iter 00

**SHA:** `47a8cbe` (bastion sync)  
**Host:** ranch-bastion · Linux 6.14.0-37-generic · ncpu=40  
**Matrix:** same-session `SERVERS=proactr drogon` · WORKERS=8 · c50 · D10 · h1s · `/tmp/proactr-iou-l0` · local `BASTION_TLS_H2.md` / `bastion_summary.tsv` / `bastion_instrumentation.txt`  
**Anchors:** `BASELINE_IO_URING_L0.md` · `PLAN_IO_URING_DROGON_PARITY.md`

## Verdict: CONDITIONAL (perf WOW numbers · arch FAIL A5)

| Bar | Result | Why |
|-----|--------|-----|
| **A Architecture** | **FAIL** | **A5 MISS:** `soft_cq_send_completes` ≈ every CT send on plain/s4k/s64k/s1m. A4 PARTIAL (dual-CT + submit_send façade, not until-backpressure multi-window). A7 **MATCH** (8 workers busy). |
| **B Performance** | **WOW numbers** | B2 s1m **1.37×**, B3 plain **1.04×** same-session drogon. B1 clean. **B4 FAIL** (soft_cq ≠ 0). |
| **Loop exit (full WOW)** | **NO** | Skill requires A3–A5 + A7 MATCH **and** B WOW. A5/B4 block. |
| **Ship “parity” language** | **RPS OK to say ahead of bastion drogon this session** | Do **not** say multi-window law / soft_cq=0 / “same density architecture as Darwin reactor.” |

**Headline numbers:**

| Cell | proactr | drogon | ratio |
|------|--------:|-------:|------:|
| h1s s1m | **4740** | **3455** | **1.37×** |
| h1s s64k | 49179 | 48671 | 1.01× |
| h1s s4k | 182633 | 168810 | 1.08× |
| h1s plain | 200242 | 192283 | **1.04×** |

---

## Architecture scores

Live Linux path: `tls_host_flush_response` (non-Darwin) → dual-CT `tls_seal_window` / `tls_dual_ct_try_ahead` → `host_submit_send` → soft/proactor CQE. Engine `proactor-uring`.

| Axis | Score | Evidence |
|------|-------|----------|
| **A1** One primary wait | **MATCH** | Worker host loop: ring_wait on io_uring (not dual blocking reactor+soft as Darwin). |
| **A2** Completions vs product TLS | **MISS** | Every product CT send completes via soft_cq_send path (plain: soft_cq≈2.00M = ct_sends). |
| **A3** Residual CT | **PARTIAL** | dual-CT residual/promote exists; not residual-first reactor shape; order rules present but dual slab. |
| **A4** TLS send loop | **PARTIAL** | Seal + drain + submit; multi-window via dual-CT ahead **across CQEs**, not dense until-backpressure in one turn with soft_cq=0. |
| **A5** soft_cq honesty | **MISS** | soft_cq_send_completes ≫ 0 on all h1s cells. |
| **A6** Buffer ownership | **PARTIAL** | dual_ct hold/tx; Darwin forbids dual-CT ahead; Linux still uses it. |
| **A7** Thread model / load | **MATCH** | WORKERS=8; c=50: 8 threads ~38–62% CPU; scale c=4→50 rises 1.6k→4.8k. |
| **A8** OpenSSL | **MISS** | dynlib product default. |

**Arch PASS rule fails:** A5 MISS (required MATCH).

---

## Performance

| Gate | Value | Pass? |
|------|-------|:-----:|
| B1 errors | all 0 | **YES** |
| B2 s1m | **1.37×** (4740/3455) | **YES / WOW** |
| B3 plain | **1.04×** (200242/192283) | **YES / WOW** |
| B4 soft_cq bulk | **≠ 0** (~1 per send) | **NO** |
| B5 plain seals/req | 1.0 | **YES** |

**Performance iterate PASS (B1+B4+B2≥0.5):** **FAIL** only on B4.  
**Numeric peer standing:** already ahead of bastion drogon.

---

## Scale / workers

| c | RPS s1m |
|--:|--------:|
| 4 | 1629 |
| 8 | 3785 |
| 16 | 4026 |
| 50 | 4761 |

Workers busy under c=50: **yes** (8 TIDs). Not Darwin accept-pin class.

---

## Lies / overclaims

- “Need scale fix first on Linux” — **false for this bastion**; A7 already healthy.  
- “soft_cq=0 multi-window law on Linux” — **false**; duty shows soft CQ per send.  
- Bulk `seals_per_req` scrape (reqs=1) — **do not** use for law; h2load RPS + seal_calls/pt_bytes only.  
- Mixing Darwin drogon ~8.6k s1m with bastion drogon ~3.5k — **different machine/class**; only same-session ratios count.

---

## Top 3 code fixes (ordered by law + headroom)

1. **Dense TLS flush on Linux (A5 / A4) — kill soft_cq between seals**  
   - **What:** Product H1 bulk: SSL_write trunk + peek/drain + `send` until EAGAIN/SQ full **without** posting soft send CQE between full windows (Darwin `reactor_tls_flush` law in proactor form: native send or batch; residual arm only on backpressure).  
   - **Where:** `http/tls_oneshot.odin` (`tls_host_flush_response` non-Darwin), `http/tls_dual_ct.odin`, `http/wire.odin` / `host_submit_send`, possibly Linux-only dense path parallel to Darwin reactor.  
   - **Gate:** h1s s1m **soft_cq_send_completes=0** (or ≪ seals); B2 not below L0 by &gt;10%; 0 errors.  
   - **Why #1:** B2 already WOW; remaining bar is **law honesty** + headroom when CQE tax is removed.

2. **Fix path_metrics req accounting on bulk cells**  
   - **What:** After s64k/s1m, scrape shows `reqs=1` while seal_calls hundreds of thousands — reset/scrape race or missing `path_metrics_note_req` on dual-CT finish.  
   - **Where:** `path_metrics.odin`, dual-CT / oneshot complete → `path_metrics_note_req`.  
   - **Gate:** seals_per_req sensible (~ seal_calls/reqs); not required for B2 but required for duty honesty.

3. **Dual-CT ahead: measure after #1**  
   - **What:** If dense flush lands, re-evaluate dual-CT hold/ahead on Linux bulk (may become dead weight).  
   - **Gate:** A/B same-session; keep only if B2 up or latency wins.

**Do not:** dynlib static first; port kqueue reactor to Linux; ban REUSEPORT without evidence; claim full WOW without A5.

---

## Explicitly ban next

- Calling L0 “full WOW” / “architecture converged” while soft_cq ≫ 0.  
- Optimizing OpenSSL dynlib before dense flush.  
- Using broken bulk `reqs=1` scrape to invent seals/req stories.  
- Reopening CLOSED_RPS_FLAGS without NEW LAW.  
- Comparing bastion drogon RPS to Darwin drogon as the same peer class.

---

## Next single change + remeasure

Implement **Top 1 dense flush**. Then:

```bash
SERVERS="proactr drogon" WORKERS=8 BENCH_C=50 BENCH_Z=10 WARMUP_Z=3 \
  PROTOCOLS=h1s REMOTE_LOG=/tmp/proactr-iou-iter01 ./run_on_bastion.sh
```

Critic ITER_01: require soft_cq=0 on s1m **and** B2 ≥ L0×0.9.
