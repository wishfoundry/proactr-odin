# Critic drogon iter 03

**SHA tip:** live tree post-ITER_02 (hot SSL/BIO fn cache, timer-gated soft harvest, first_seal metrics, engine-note honesty) — treat as uncommitted relative to tip if status dirty.  
**Host:** Benjamins-MacBook-Pro.local · Darwin 25.5.0 arm64 · WORKERS=8 · c50 · D10 · PROTOCOLS=h1s  
**Matrix:** same-session ITER_03 `LOGDIR=/tmp/proactr-drogon-iter03` · copies `comparisons/tls-h2/results/summary.tsv` / `SUMMARY.md` / `instrumentation.txt` (2026-08-10T05:14Z)  
**Anchors:** `CRITIC_DROGON_ITER_02.md` · `CRITIC_DROGON_ITER_01.md` · `PROACTR_VS_DROGON_PATH_COMPARE.md` · `BASELINE_P5.md` · live `http/tls_reactor_flush.odin` · `http/tls_host.odin` · `http/server_loop_reactor.odin` · `http/path_metrics.odin` · `tls_server/provider_openssl_dynlib.odin`

## Verdict: FAIL

| Bar | Result | Why |
|-----|--------|-----|
| **A Architecture** | **PASS** (narrow, unchanged) | 0 MISS among A1–A7; A3–A5 MATCH. A2 MATCH (level READ). **A8 dynlib = MISS** (fn-cache does not make linked OpenSSL). |
| **B Performance** | **FAIL** | B2 h1s s1m = **0.32×** ≪ 0.50× interim. B3 plain = **0.63×** fails 0.65× floor. |
| **Ship / parity language** | **BANNED** | ITER_02 top3 item #2 (hot SSL fn cache) **shipped and measured**: smoke ~2803 → full matrix **2765** — **no B2 movement**. Structure deeper; RPS still loses by **~3×** on s1m. |

**Headline numbers (same session ITER_03):**

| Cell | proactr | drogon | ratio |
|------|--------:|-------:|------:|
| h1s s1m | **2765.20** | **8637.30** | **0.32×** |
| h1s s64k | 31294.10 | 65582.20 | 0.48× |
| h1s s4k | 84720.30 | 151175.60 | 0.56× |
| h1s plain | 96032.60 | 152246.70 | **0.63×** |

Duty (h1s s1m from `instrumentation.txt`): `soft_cq_send_completes=0`, `seals_per_req=9.003`, `windows/turn=8.987`, `eagain_arms=2`, `materialize=1`, **`first_seal_pt_avg=131067.3`** (coalesce proven: full first 128 KiB window), engine note carries `ssl_fn_cache`. Plain: `seals_per_req=1.000`, `first_seal_pt_avg=113.0`, `materialize=reqs`. All scored cells **0** failed/errored/timeout.

**Honesty vs ITER_02c:** s1m 2761→2765 (**+0.1%** absolute); ratio **0.32×→0.32×** (flat). Plain 95125→96032 (**+0.9%**); ratio **0.62×→0.63×** (still under 0.65×). Smoke ~2803 vs full matrix 2765 = noise band, not a win. **No L1 band. No interim 0.50×.** Fn-cache + timer-gated soft harvest = **RPS-null**.

---

## What landed since ITER_02 (code vs duty)

| Claim | Live evidence | RPS / duty outcome |
|-------|---------------|--------------------|
| 1. Hot SSL/BIO fn ptr cache (ITER_02 top3 #2) | `tls_host.odin`: `provider_cache_hot_ssl` → `conn.tls_hot`; `reactor_ssl_write_raw` / `reactor_bio_pending` / `reactor_bio_peek_hot` / `reactor_bio_reset_hot` call cached C fns (skip Provider vtable) | **Gate FAILED for RPS:** B2 still **0.32×**. Dispatch tax was not the 3× hole. |
| 2. Timer-gated soft harvest | `server_loop_reactor.odin`: pre-I/O soft only when `has_timer && tms==0`; post-I/O soft only when `has_timer_post` | **Duty:** soft_cq_send still 0. **RPS:** no B2 movement. Residual dual-wait cost may remain when timers registered; empty soft peels reduced. |
| 3. First-seal PT metrics | `path_metrics_note_first_seal_pt`; s1m `first_seal_pt_avg=131067` | **Honesty win.** Coalesce **proven** (full first window ≈128 KiB). seals/req=9.003 is expected under hdr+1 MiB / 128 KiB — not a coalesce fail. |
| 4. Engine note honesty | `path_metrics_io_engine_note` tags: `level_read;…;ssl_fn_cache;plain_coalesce;…` | **Honesty win.** Note matches shipped stack. Does not move RPS. |

**Coalesce autopsy closed:** ITER_01/02 “seals=8” gate was false math. ITER_03 first_seal instrument **proves** full first window. Do **not** re-ship coalesce. Density problem is AES/send/copy under dynlib OpenSSL, not heading/body part boundary.

---

## Architecture scores

Live: `http/tls_reactor_flush.odin`, `http/io_reactor_kqueue.odin`, `http/server_loop_reactor.odin`, `http/tls_host.odin`, `http/path_metrics.odin`, `tls_server/provider_openssl_dynlib.odin`.  
Drogon reference unchanged: `OpenSSLProvider::sendData`/`sendTLSData`, level Channel, **linked** OpenSSL.

| Axis | Score | Evidence (file:symbol) |
|------|-------|------------------------|
| **A1** One blocking wait per worker | **MATCH** | `server_reactor_worker_loop`: one blocking `reactor_wait(s, loop_wait)`; soft harvest non-blocking and **timer-gated** (pre only when due; post only when timers registered). Residual: dual soft ring still exists (D5); not two blocking product waits. |
| **A2** Readiness model | **MATCH** | Product READ level; residual WRITE level. Accept + fairness WRITE oneshot (acceptable). |
| **A3** Residual CT | **MATCH** | Single residual `dual_ct.tx`; residual-first in `reactor_tls_flush` (R-ORDER). |
| **A4** TLS send loop | **MATCH** | residual → drain wBIO (peek+reset hot path) → `reactor_ssl_write_window` (128 KiB) → drain until EAGAIN → residual arm. Multi-window, no soft-CQ between seals. **sendTLSData-shaped drain already mostly done.** |
| **A5** No proactor CQE product TLS | **MATCH** | s1m/s64k/plain/s4k: `soft_cq_send_completes=0`. Engine note `no_proactr_socket_submit`. |
| **A6** Buffer ownership | **MATCH** | Darwin no-hold slab; single residual; `no_dual_ct_ahead`. Coalesce scratch is staging only. |
| **A7** Thread model | **MATCH** | N workers, conn pinned to worker reactor kq. |
| **A8** OpenSSL link | **MISS** | Product still **dynlib**. Hot fn cache = direct `dlsym` pointers on `conn.tls_hot` — **not** static link. Every seal still hits dylib OpenSSL (`SSL_write` / AES-GCM inside). Drogon: linked in-process. **Fn-cache closed the vtable story; A8 remains MISS.** |

**Architecture PASS rule:** ≤1 MISS among A1–A7 and A3–A5 MATCH → **PASS**. sendTLSData parity is largely landed; **A8 + per-byte AES/send density** are the remaining bulk story.

---

## Performance

| Gate | Value | Pass? |
|------|-------|:-----:|
| **B1** Correctness (failed/errored/timeout) | all 0 | **YES** |
| **B2** h1s s1m ratio | **0.32×** (2765.20 / 8637.30) | **NO** (need ≥0.50× interim; ≥0.90× for parity talk) |
| **B3** h1s plain ratio | **0.63×** (96032.60 / 152246.70) | **NO** (need ≥0.65×) |
| **B4** soft_cq_send on TLS bulk | **0** | **YES** |
| **B5** No fake seals/req on plain | seals/req=**1.0** (not 2); materialize=reqs honest | **YES** |

**Performance PASS (iterate):** B1 + B4 + B2≥0.50× → **FAIL** (B2).  
**Performance WOW:** not eligible.

**Ladder:** P5 L0 **0.30×** → ITER_01 **0.33×** → ITER_02c **0.32×** → ITER_03 **0.32×**. Still **not** L1 (0.35–0.45). Absolute s1m only **+6.4%** vs P5 (2599→2765) while drogon sits ~8.6k. Checklist depth ≠ density.

**Vs P5 plain:** 111730 → 96032 (**−14%**). B3 **0.63×** still under floor; slight uptick vs ITER_02c (0.62→0.63) is not a ship signal.

**Fn-cache verdict (adversarial):** ITER_02 said: if hot ptr cache &lt;+5% s1m, **static is mandatory narrative**. Measured: **~0%**. That experiment is **closed**. Next cycle does **not** re-tune dispatch under dynlib.

---

## Lies / overclaims this session

- Any claim that hot SSL/BIO fn cache “closed” or “mostly closed” the drogon gap — B2 **0.32×**, flat vs ITER_02.  
- Selling engine-note tags (`ssl_fn_cache`, `plain_coalesce`) as performance progress — honesty only.  
- Treating first_seal instrument or coalesce-proven as an RPS win — it **refutes** a false seals=8 gate; it does **not** move B2.  
- Claiming sendTLSData still the hole — peek/reset + residual-first already MATCH on A4; **density under OpenSSL + send** remains.  
- “Architecture complete = ship” while B2≪0.50×. Bar A PASS + Bar B FAIL = **FAIL**.  
- Implying timer-gated soft harvest fixed dual-wait — reduced empty peels; product still dual soft+reactor rings; RPS flat.  
- Smoke ~2803 as “movement” — full matrix **2765** is the scoreboard; noise band.

---

## Top 3 code fixes (ordered by expected ×drogon impact)

**Must differ from already-shipped / measured-null work:** wbio cache, heading coalesce, level READ, hot SSL/BIO fn cache, timer-gated soft harvest. Those are done; RPS proof negative/neutral. **Do not** re-list fn-cache.

1. **Static-linked OpenSSL A/B (A8) — now mandatory, not optional**  
   - **What:** Offline (or opt-in build) **static/link** OpenSSL (or BoringSSL) product path: direct `SSL_write` / `BIO_ctrl` / `BIO_ctrl_pending` with **no** `core:dynlib` and no Provider vtable on seal+drain. Keep mem-BIO + residual-first + peek drain law. Same-session drogon matrix only.  
   - **Where:** new/alt `tls_server` static provider; `default_provider` / `HTTP_TLS_BACKEND`; call sites already direct via `conn.tls_hot` in `tls_reactor_flush.odin` — swap source of symbols from dlsym to link.  
   - **Gate:** same-session drogon; **B2 ≥ 0.50×** *or* publish full sample stack (AES + send + memmove shares) + ratio if only +5–10%. soft_cq_send=0; 0 errors.  
   - **Why #1 (mandatory):** Hot fn cache **proved** PLT/vtable was not the 3×. Remaining A8 gap is **process-linked crypto/runtime** (dylib vs static, OpenSSL build flags, AES-GCM path) vs drogon’s linked OpenSSL. Structure is multi-window + peek + level R/W. **Static A/B is the next honest experiment** — not another dynlib micro-opt.

2. **AES / send density on bulk H1 (profile-driven, same binary class as matrix)**  
   - **What:** Darwin `-o:speed` (not `-debug`) sample of proactr **and** drogon under h1s s1m (Instruments / `sample` / dtrace). Attribute **send vs AES-GCM vs BIO/memmove vs kevent**. Then one density cut guided by top share: e.g. fewer CT staging copies on residual path, tighter drain loop, larger effective trunk if AES setup dominates, or send coalescing only if send dominates — **no** CLOSED_RPS_FLAGS reopen without NEW LAW.  
   - **Where:** `reactor_drain_wbio` / `host_try_send_nb` / `reactor_ssl_write_window`; OpenSSL cipher config if sample shows setup tax; **not** seal-window thrash without sample.  
   - **Gate:** publish before/after sample shares + same-session B2. Claim iterate only if B2 ≥ 0.50× or a single share drops with correlated RPS.  
   - **Why #2:** Historical busy bulk ~**send 46% / AES ~30% / memmove ~20%**. Fn-cache and coalesce closed side stories; **per-byte work** is the remaining bulk hole. Drogon still wins *despite* double body copy — density beats zero-copy body.

3. **Kill residual dual-wait soft peel cost (D5 honesty without empty tax)**  
   - **What:** Product TLS bulk already `soft_cq_send=0`. Further: ensure **zero** soft-ring syscalls on the hot bulk path when no session timer is armed (post-I/O path already gated; verify pre-path + mailbox/wake do not reintroduce empty peels under load). Optional: fold timer deadline solely into `reactor_wait` timeout with **no** second kevent family for idle workers under pure matrix load.  
   - **Where:** `server_loop_reactor.odin` / soft ring interest; avoid regressing D5 timer correctness.  
   - **Gate:** same-session B2 + B3; if &lt;+3% document as **insufficient** and do not re-spend. Prefer #1/#2 if sample shows AES/send dominate over wait.  
   - **Why #3:** Dual wait is the last structural non-MATCH vs drogon’s single `EventLoop::loop` poll. Unlikely to alone buy 0.50×, but cheap honesty after static/density data — and B3 tiny path is wait/materialize-sensitive.

**Do not** spend the next cycle on: re-caching SSL_write under dynlib; re-coalesce; seals=8 chasing; seal 64↔128 without sample; Dual_Ct N>2; TCP_NODELAY; floor-0 plain-split; claiming sendTLSData still “the” miss (mostly done); claiming Bar A “done” as ship.

---

## Explicitly ban next

- Saying **“converged to drogon”**, **“same as drogon”**, **“architecture complete = ship”**, or **“parity”** while **B2 < 0.50×** (never “parity” until B2 ≥ 0.90× and B3 ≥ 0.80×).  
- Claiming fn-cache “worked” because code merged / engine note tags — **B2 0.32×** is the scoreboard.  
- Re-running dynlib dispatch micro-opts as if static A/B were optional after a null fn-cache result.  
- Calling coalesce a win **or** a fail via seals/req alone — use `first_seal_pt_avg` (now **131067** = proven full window).  
- Reopening **CLOSED_RPS_FLAGS** without **NEW LAW**.  
- Using H2 or ntex bulk wins to paper over the **h1s s1m drogon hole**.  
- Ignoring plain still **~−14% vs P5** when stacking more structure.

---

## Next single change + remeasure recipe

**#1 static OpenSSL offline A/B is mandatory.** Fn-cache experiment closed at ~0% RPS. Do not start with #3 dual-wait unless sample proves wait dominates.

```bash
cd comparisons/tls-h2
# Prefer: build proactr with static/linked OpenSSL provider, then:
SERVERS="proactr drogon" WORKERS=8 BENCH_C=50 BENCH_Z=10 WARMUP_Z=3 \
  LOGDIR=/tmp/proactr-drogon-iter04 ./run_matrix.sh
# Require: 0 errors; soft_cq_send_completes=0 on TLS bulk
# Claim iterate PASS only if h1s s1m proactr/drogon ≥ 0.50× same session
# Report plain ratio (B3); first_seal_pt_avg s1m (expect ~131k); seals_per_req ~9 OK
# Parallel: sample AES/send/memmove shares under matrix-class binary
# Do not claim “converged”
```

**Scoreboard after this critic:** Verdict **FAIL** · B2 **0.32×** · B3 **0.63×** · Architecture checklist MATCH · A8 dynlib MISS · fn-cache **RPS-null** · coalesce **proven full first window** · RPS still loses by **~3×** on bulk H1.s.
