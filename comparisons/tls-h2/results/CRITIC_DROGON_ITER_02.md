# Critic drogon iter 02

**SHA tip:** `5f5e9f9` (`5f5e9f94e7e86e82c4b8d87b196d94441848f12c`) — live tree has post-ITER_01 landings (wbio cache, plain coalesce, level READ, connection_close level-READ leak fix); treat as uncommitted relative to tip if status dirty.  
**Host:** Benjamins-MacBook-Pro.local · Darwin arm64 · WORKERS=8 · c50 · D10 · PROTOCOLS=h1s  
**Matrix:** same-session ITER_02c `LOGDIR=/tmp/proactr-drogon-iter02c` · copies `summary.tsv` / `SUMMARY.md` / `instrumentation.txt` (2026-08-10T05:03Z)  
**Anchors:** `CRITIC_DROGON_ITER_01.md` · `PROACTR_VS_DROGON_PATH_COMPARE.md` · `BASELINE_P5.md` · live `http/tls_reactor_flush.odin` · `http/io_reactor_kqueue.odin` · `http/server.odin` · `http/tls_host.odin` · `tls_server/provider_openssl_dynlib.odin`

## Verdict: FAIL

| Bar | Result | Why |
|-----|--------|-----|
| **A Architecture** | **PASS** (narrow, improved) | 0 MISS among A1–A7; A3–A5 MATCH. **A2 upgraded MATCH** (product READ level). **A8 dynlib = MISS** (still sole product OpenSSL path). |
| **B Performance** | **FAIL** | B2 h1s s1m = **0.32×** ≪ 0.50× interim. B3 plain = **0.62×** fails 0.65× floor. |
| **Ship / parity language** | **BANNED** | ITER_01 top3 + close fix did **not** buy drogon-class bulk. Structure deeper; RPS still loses by **~3×** on s1m. |

**Headline numbers (same session ITER_02c):**

| Cell | proactr | drogon | ratio |
|------|--------:|-------:|------:|
| h1s s1m | **2761.30** | **8628.60** | **0.32×** |
| h1s s64k | 31210.10 | 65577.30 | 0.48× |
| h1s s4k | 84305.80 | 150331.90 | 0.56× |
| h1s plain | 95125.20 | 152574.30 | **0.62×** |

Duty (h1s s1m from `instrumentation.txt`): `soft_cq_send_completes=0`, `seals_per_req=9.004`, `windows/turn=8.987`, `eagain_arms=1`, `materialize=1`. Plain: `seals_per_req=1.000`, `materialize=reqs`. All scored cells **0** failed/errored/timeout.

**Honesty vs ITER_01:** s1m 2736→2761 (**+0.9%** absolute); ratio **0.33×→0.32×** (drogon also higher this session). Plain 95723→95125; ratio **0.64×→0.62×**. **No L1 band. No interim 0.50×.** Shipped top3 + leak fix = matrix health restored, bulk hole untouched.

---

## What landed since ITER_01 (code vs duty)

| Claim | Live evidence | RPS / duty outcome |
|-------|---------------|--------------------|
| 1. Cached `tls_wbio` + `bio_*_out_bio` | `tls_host.odin` sets `conn.tls_wbio`; `reactor_bio_pending` / `reactor_drain_wbio` prefer `bio_*_out_bio` | **No B2 movement.** Still Provider vtable → dynlib `BIO_ctrl` / `SSL_write`. |
| 2. First-seal heading+body coalesce | `reactor_ssl_write_window` + `reactor_plain_coalesce` when `rest_n>0 && body_rem>0` | **Gate FAILED:** s1m `seals_per_req=9.004` (need ~8). See § Coalesce autopsy. |
| 3. Level product READ (`oneshot=false`) | `reactor_host_arm_recv` arms `.Add|.Enable`; `reactor_on_readable` drain-until-EAGAIN; refresh without re-arm when `reactor_read_level` | **A2 MATCH.** B3 still **0.62×** — readiness model alone does not close tiny gap. |
| 4. **Critical:** `connection_close` must not defer on level READ armed/inflight | `server.odin` `connection_close`: defer only `!reactor_read_level` oneshot flight; comment documents prior deadlock/temp-slot leak → bulk 0 RPS | **Correctness PASS.** Matrix bulk cells non-zero. Not an RPS win vs drogon — a self-own fix so measurement is possible. |

`io_engine_note` still omits level-read / coalesce / wbio-cache tags (`path_metrics.odin`); duty string is stale marketing of older stack only.

---

## Coalesce autopsy (ITER_01 fix #2)

**Claimed gate:** s1m seals/req **8.x not 9.0**.  
**Measured:** **9.004** (`seal_calls=248625` / `reqs=27614`).

Code path **exists** and looks reachable for ciphered split (`response_send_ciphered_heading_body` sets `tls_plain_rest` + `tls_plain_body`; flush goes `reactor_ssl_write_window`).

**Math honesty (adversarial both ways):**

- Body = 1 MiB = **exactly** `8 × 128 KiB`.  
- Total plain = heading + 1 MiB. From duty: `pt_bytes/reqs ≈ 1 049 146` → heading **~570 B**.  
- `ceil((hdr+1MiB)/128KiB) = ceil(8.004) = **9**` even with **perfect** full-window first seal.  
- Without coalesce: 1 tiny heading seal + 8 body = **9**. With coalesce: 8 full-ish + 1 tail ≈ **9**.  
- So seals/req **cannot prove** coalesce ran; the ITER_01 “8 not 9” gate was **false for hdr>0 under 128 KiB**.  

**Still call fix #2 a failed *performance* claim:**

1. Stated success metric (8 seals) **not met** (9.004).  
2. No first-window size instrument (`first_seal_pt_avg`) — unproven density win.  
3. B2 **worse ratio** vs ITER_01 (0.33→0.32). Coalesce memcpy of first trunk is at best neutral noise.

**Do not** re-ship “coalesce again” to chase 8 seals without larger seal or stripping heading bytes from the seal count model. If reworking: instrument first SSL_write size; or stage drogon-style **one contiguous plain buffer** so there is no part boundary *and* no coalesce scratch.

---

## Architecture scores

Live: `http/tls_reactor_flush.odin`, `http/io_reactor_kqueue.odin`, `http/server_loop_reactor.odin`, `http/server.odin` `connection_close`, `http/tls_host.odin`, `http/tls_oneshot.odin`, `http/response_ciphered.odin`, `tls_server/provider_openssl_dynlib.odin` / `provider.odin`.  
Drogon reference unchanged: `OpenSSLProvider::sendData`/`sendTLSData`, level Channel, linked OpenSSL.

| Axis | Score | Evidence (file:symbol) |
|------|-------|------------------------|
| **A1** One blocking wait per worker | **MATCH** | `server_reactor_worker_loop`: one blocking `reactor_wait(s, loop_wait)`; soft `ring_wait(..., 0)` only non-blocking (timer-due pre + post-I/O harvest). Residual: post-I/O soft peek **always** even when empty. |
| **A2** Readiness model | **MATCH** | Product READ **level** (`reactor_host_arm_recv` oneshot=false; `reactor_read_level`; drain-until-EAGAIN in `reactor_on_readable`). Residual WRITE level (`reactor_arm_write_residual` / `reactor_disable_write_level`). Accept + fairness WRITE remain oneshot (acceptable). |
| **A3** Residual CT | **MATCH** | Single residual `dual_ct.tx` via `reactor_residual_set` / `reactor_write_residual`; residual-first in `reactor_tls_flush` (R-ORDER). |
| **A4** TLS send loop | **MATCH** | residual → drain wBIO (peek+reset when supported) → `reactor_ssl_write_window` (`REACTOR_SEAL_WINDOW=128KiB`) → drain until EAGAIN → residual arm. Multi-window, no soft-CQ between seals. |
| **A5** No proactor CQE product TLS | **MATCH** | s1m/s64k/plain/s4k: `soft_cq_send_completes=0`. Engine note `no_proactr_socket_submit`. Native `host_try_send_nb`. |
| **A6** Buffer ownership | **MATCH** | Darwin no-hold slab; single residual; `no_dual_ct_ahead`. Coalesce scratch is **extra** plain staging (not dual residual CT). |
| **A7** Thread model | **MATCH** | N workers, conn pinned to worker reactor kq. |
| **A8** OpenSSL link | **MISS** | Product **dynlib only** (`HTTP_TLS_BACKEND=dynlib`, `provider_openssl_dynlib_load`). Hot seal: `tls_server.write` → `p.write` vtable → `Dynlib_State.SSL_write` dlsym. Drogon: linked direct `SSL_write`. Wbio cache removes `SSL_get_wbio` only — **not** dynlib/vtable. |

**Architecture PASS rule:** ≤1 MISS among A1–A7 and A3–A5 MATCH → **PASS**. A2 is no longer the structural hole; **A8 + per-byte density** remain.

---

## Performance

| Gate | Value | Pass? |
|------|-------|:-----:|
| **B1** Correctness (failed/errored/timeout) | all 0 | **YES** |
| **B2** h1s s1m ratio | **0.32×** (2761.30 / 8628.60) | **NO** (need ≥0.50× interim; ≥0.90× for parity talk) |
| **B3** h1s plain ratio | **0.62×** (95125.20 / 152574.30) | **NO** (need ≥0.65×) |
| **B4** soft_cq_send on TLS bulk | **0** | **YES** |
| **B5** No fake seals/req on plain | seals/req=**1.0** (not 2); materialize=reqs honest | **YES** |

**Performance PASS (iterate):** B1 + B4 + B2≥0.50× → **FAIL** (B2).  
**Performance WOW:** not eligible.

**Ladder:** P5 L0 **0.30×** → ITER_01 **0.33×** → ITER_02c **0.32×**. Still **not** L1 (0.35–0.45). Absolute s1m only **+6.2%** vs P5 (2599→2761) while drogon sits ~8.6k. Checklist depth ≠ density.

**Vs P5 plain:** 111730 → 95125 (**−15%**). B3 fails harder than P5’s 0.74×. Level READ + stack tax did not restore tiny; investigate before blaming only session noise.

---

## Lies / overclaims this session

- Any claim that ITER_01 top3 “closed” or “mostly closed” the drogon gap — B2 **0.32×**.  
- Coalesce “success” via code presence while seals/req still **9.004** and B2 flat/down.  
- Treating **connection_close** level-READ fix as performance progress — it fixes a **self-inflicted 0 RPS leak**, not drogon distance.  
- `CONVERGENCE_COMPLETE.md` “complete” framing still live under B2≪0.50×.  
- Selling architecture MATCH as ship readiness. Bar A PASS + Bar B FAIL = **FAIL**.  
- Implying level READ would lift B3 over 0.65× without remeasure proof — measured **0.62×**.  
- `io_engine_note` implying a finished stack while omitting level-read/coalesce and still carrying `plain_split_8k` as if that were the bulk story.

---

## Top 3 code fixes (ordered by expected ×drogon impact)

**Must differ from already-shipped ITER_01 top3** (wbio cache, heading coalesce, level READ). Those are done; RPS proof negative/neutral.

1. **Static-linked OpenSSL A/B (A8) — measure real AES/send density without dynlib**  
   - **What:** Offline (or opt-in) **static/link** OpenSSL (or BoringSSL) product path: direct `SSL_write` / `BIO_ctrl` / `BIO_ctrl_pending` with **no** `core:dynlib` and minimal/no Provider vtable on seal+drain. Keep mem-BIO + residual-first law. Compare same-session drogon matrix.  
   - **Where:** new/alt `tls_server` provider (static); `default_provider` / `HTTP_TLS_BACKEND`; call sites already in `reactor_ssl_write_window` / `reactor_drain_wbio`.  
   - **Gate:** same-session drogon; **B2 ≥ 0.50×** *or* publish AES+send sample share + ratio if only +5–10%. soft_cq_send=0; 0 errors.  
   - **Why #1:** Structure is multi-window + peek + level R/W. Bulk profile historically **send ~46% / AES ~30% / memmove ~20%**. Dynlib is the last architecture MISS sitting on every seal. Drogon encrypts linked-in-process and still wins *despite* double body copy — density is the remaining bulk story.

2. **Kill remaining hot-path indirection under dynlib (if static cannot ship yet)**  
   - **What:** Cache raw `SSL_write` / `BIO_ctrl` / `BIO_ctrl_pending` function pointers on `Connection` (or thread-local dynlib state) at handshake; call them from `reactor_ssl_write_window` / `reactor_drain_wbio` **without** `tls_server.write` → `p.write(self,…)` → user_data cast each time. Optional: single contiguous CT peek loop with fewer nil checks. This is **not** “cache wbio again” — wbio is already cached; **SSL_write dispatch** is not.  
   - **Where:** `http/tls_host.odin` (fill caches after setup); `http/tls_reactor_flush.odin`; optionally thin `tls_server` hot API.  
   - **Gate:** same-session B2; if &lt;+5% document as **insufficient** and force static A/B (#1).  
   - **Why #2:** Product may keep dynlib; still need to prove how much of the 0.32× is PLT/vtable vs pure AES. Cheap before policy fight on static link.

3. **Drogon-shaped single contiguous plain for bulk + honest tiny materialize cut (B2 secondary / B3 primary)**  
   - **What:** Stop living on heading/body **part cursor + coalesce scratch**. Stage bulk H1 TLS plain as **one contiguous view** (heading prepend into a single seal-source buffer **or** one-shot format-into-body-prefix policy) so every `SSL_write` is a dense trunk with **zero** cross-part memcpy. Separately: plain/s4k still `materialize=reqs` and B3 **0.62×** — profile heading+materialize+single seal; cut format/materialize tax without reopening floor-0 plain-split (CLOSED by −27% evidence).  
   - **Where:** `response_send_ciphered_heading_body` / `response_ciphered.odin`; `reactor_ssl_write_window` (delete coalesce once contiguous); tiny path materialize in response send.  
   - **Gate bulk:** first_seal_pt ≈ min(128KiB, total); seals/req still ~9 is **OK** if first seal full; B2 up. **Gate tiny:** plain ≥ **0.65×** drogon same session; seals/req plain stays 1.  
   - **Why #3:** Coalesce #2 shipped as a patch on a split model and failed its RPS claim. Contiguous is drogon `renderToBuffer` shape. Tiny gap is a **different** problem than bulk AES — B3 still fails.

**Do not** spend the next cycle on: re-tuning seal 64↔128 without OpenSSL density data; another level-READ micro-tweak; Dual_Ct N>2; TCP_NODELAY; floor-0 plain-split; claiming Bar A “done” as ship; re-implementing coalesce to hit seals=8 (math forbids under 128 KiB + heading).

---

## Explicitly ban next

- Saying **“converged to drogon”**, **“same as drogon”**, **“architecture complete = ship”**, or **“parity”** while **B2 < 0.50×** (never “parity” until B2 ≥ 0.90× and B3 ≥ 0.80×).  
- Claiming ITER_01 top3 “worked” because code merged — **B2 0.32×** is the scoreboard.  
- Calling coalesce a win while **seals_per_req=9.004** and no first-window metric.  
- Treating the level-READ **close leak fix** as drogon RPS progress.  
- Reopening **CLOSED_RPS_FLAGS** (Dual_Ct N>2, dense soft-CQ, TCP_NODELAY, 1 MiB seal flag, kTLS-as-fair) without **NEW LAW**.  
- Using H2 or ntex bulk wins to paper over the **h1s s1m drogon hole**.  
- Ignoring plain **−15% vs P5** when stacking more structure.

---

## Next single change + remeasure recipe

Prefer **#1 static OpenSSL offline A/B** (honest density). If binary policy blocks, do **#2 hot SSL_write ptr cache** first, then remeasure; if &lt;+5% s1m, static is mandatory narrative.

```bash
cd comparisons/tls-h2
SERVERS="proactr drogon" WORKERS=8 BENCH_C=50 BENCH_Z=10 WARMUP_Z=3 \
  LOGDIR=/tmp/proactr-drogon-iter03 ./run_matrix.sh
# Require: 0 errors; soft_cq_send_completes=0 on TLS bulk
# Claim iterate PASS only if h1s s1m proactr/drogon ≥ 0.50× same session
# Report plain ratio (B3); seals_per_req s1m (expect ~9 under 128KiB+hdr — not a coalesce fail by itself)
# Optional: instrument first_seal_pt_avg if touching plain staging
# Do not claim “converged”
```

**Scoreboard after this critic:** Verdict **FAIL** · B2 **0.32×** · B3 **0.62×** · Architecture checklist MATCH (A2 fixed) · A8 dynlib MISS · coalesce duty gate failed · RPS still loses by **~3×** on bulk H1.s.
