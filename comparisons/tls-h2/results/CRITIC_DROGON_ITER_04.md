# Critic drogon iter 04

**SHA tip:** live tree post-ITER_03 — **Darwin shared listen multi-kq accept** (no `SO_REUSEPORT` on Darwin) + prior stack (level READ/WRITE residual, wbio peek+cache, ssl_fn_cache, plain coalesce, connection_close level fix). Treat as uncommitted relative to tip if status dirty.  
**Host:** Benjamins-MacBook-Pro.local · Darwin 25.5.0 arm64 · WORKERS=8 · c50 · D10 · PROTOCOLS=h1s  
**Matrix:** same-session ITER_04 `LOGDIR=/tmp/proactr-drogon-iter04` · copies `comparisons/tls-h2/results/summary.tsv` / `SUMMARY.md` / `instrumentation.txt` (2026-08-10T05:30Z)  
**Anchors:** `CRITIC_DROGON_ITER_03.md` · `CRITIC_DROGON_ITER_02.md` · `CRITIC_DROGON_ITER_01.md` · `PROACTR_VS_DROGON_PATH_COMPARE.md` · `BASELINE_P5.md` · live `http/server_posix.odin` · `http/server.odin` · `http/io_reactor_kqueue.odin` · `http/tls_reactor_flush.odin` · `tls_server/provider_openssl_dynlib.odin`

## Verdict: WOW

| Bar | Result | Why |
|-----|--------|-----|
| **A Architecture** | **PASS** (narrow) | 0 MISS among A1–A7; A3–A5 MATCH. Accept model now **1 shared listen + multi-kq race** (closer to drogon single-listen / multi-ioLoop fanout than REUSEPORT-per-worker). **A8 dynlib = MISS** (unchanged; not the bulk hole). |
| **B Performance** | **WOW** | B2 h1s s1m = **1.143×** ≥ 0.90× parity gate. B3 plain = **0.979×** ≥ 0.80× WOW floor. B1/B4/B5 clean. |
| **Ship / parity language** | **Allowed for h1s bulk performance vs same-session drogon** | May say **performance parity (or better) on h1s s1m / s64k** this session. **Do not** say “identical architecture” or “converged OpenSSL link” while A8 is dynlib. |

**Headline numbers (same session ITER_04):**

| Cell | proactr | drogon | ratio |
|------|--------:|-------:|------:|
| h1s s1m | **10540.60** | **9224.30** | **1.143×** |
| h1s s64k | 89089.30 | 67733.30 | **1.315×** |
| h1s s4k | 148376.20 | 150441.90 | **0.986×** |
| h1s plain | 148955.00 | 152183.50 | **0.979×** |

Duty (h1s s1m from `instrumentation.txt`): `soft_cq_send_completes=0`, `seals_per_req=9.000`, `windows/turn=8.989`, `eagain_arms=127`, `materialize=1`, `first_seal_pt_avg=131070.8` (coalesce full first 128 KiB window). Plain: `seals_per_req=1.000`, `first_seal_pt_avg=113.0`, `materialize=reqs`. All scored cells **0** failed/errored/timeout.

**Honesty vs ITER_03:** s1m **2765 → 10540** (**+281%** absolute); ratio **0.32× → 1.143×**. Plain **96033 → 148955** (**+55%**); ratio **0.63× → 0.979×**. This is **not** noise and **not** dynlib. **Scaling was the hole; density was already enough once all 8 workers were busy.**

---

## What landed since ITER_03 (code vs duty)

| Claim | Live evidence | RPS / duty outcome |
|-------|---------------|--------------------|
| 1. **Darwin shared listen multi-kq accept (no REUSEPORT)** | `server_posix.odin`: `host_listen_shared` → `reuse_port=false`. `server.odin` `listen`: Darwin binds one `s.tcp_sock`. `io_reactor_kqueue.odin`: level accept on shared fd; multi-worker drain limit=1 so peers race; EAGAIN = peer won (OK). | **Gate PASSED hard.** B2 **1.143×**, B3 **0.979×**. Root cause of 0.32×: `SO_REUSEPORT` + localhost affinity pinned **all accepts to 1 worker** (1×100% CPU, 7 idle). After fix: 8 workers busy, c=50 s1m ~10k. |
| 2. Prior stack retained | level READ, level residual WRITE, wbio peek/cache, ssl_fn_cache, plain coalesce, seal 128k, fairness re-arm, darwin no-hold, connection_close level fix | Still present in `io_engine_note`. These were **not** the 3× hole; they are the density floor that **wins** once accept spreads. |
| 3. Duty still honest under load | s1m soft_cq=0; seals/req=9.000; first_seal≈131071 | Multi-window law intact with real multi-worker contention (`eagain_arms=127` vs ITER_03 `eagain_arms=2` — residual pressure **visible** only when 8 workers share the pipe). |

**Accept autopsy (closes ITER_01–03 bulk narrative):**

- ITER_03 scoreboard **0.32×** with structure MATCH was **not** “AES under dynlib loses 3×.”
- Symptom: one hot worker, seven idle under WORKERS=8 — classic Darwin REUSEPORT localhost pin.
- Drogon matrix peer: single listen / multi-ioLoop RR (REUSEPORT opt-in, default off). proactr REUSEPORT multi-listen was **not** “leave for fairness”; it **broke** multi-worker fairness on this host.
- `PROACTR_VS_DROGON_PATH_COMPARE.md` § Accept / REUSEPORT (“Leave … Do not chase REUSEPORT parity as bulk fix”) was **wrong for Darwin localhost**. Own that.

---

## Architecture scores

Live: `http/server_posix.odin`, `http/server.odin` `listen`, `http/io_reactor_kqueue.odin`, `http/tls_reactor_flush.odin`, `http/server_loop_reactor.odin`, `http/tls_host.odin`, `http/path_metrics.odin`, `tls_server/provider_openssl_dynlib.odin`.  
Drogon reference: `OpenSSLProvider::sendData`/`sendTLSData`, level Channel, **linked** OpenSSL, single listen + multi-ioLoop.

| Axis | Score | Evidence (file:symbol) |
|------|-------|------------------------|
| **A1** One blocking wait per worker | **MATCH** | `server_reactor_worker_loop`: one blocking `reactor_wait`; soft harvest non-blocking / timer-gated. Residual dual soft ring (D5) remains; not two blocking product waits. |
| **A2** Readiness model | **MATCH** | Product READ level; residual WRITE level; **shared accept level** multi-kq (`reactor_host_submit_accept` oneshot=false). Fairness WRITE oneshot OK. |
| **A3** Residual CT | **MATCH** | Single residual `dual_ct.tx`; residual-first in `reactor_tls_flush` (R-ORDER). |
| **A4** TLS send loop | **MATCH** | residual → drain wBIO (peek+reset hot) → `reactor_ssl_write_window` (128 KiB) → drain until EAGAIN → residual arm. Multi-window; no soft-CQ between seals. |
| **A5** No proactor CQE product TLS | **MATCH** | s1m/s64k/plain/s4k: `soft_cq_send_completes=0`. Engine note `no_proactr_socket_submit`. |
| **A6** Buffer ownership | **MATCH** | Darwin no-hold slab; single residual; `no_dual_ct_ahead`. Coalesce scratch staging only. |
| **A7** Thread model | **MATCH** | N workers, conn pinned. **Accept fanout fixed:** shared listen + multi-kq race ≈ drogon “one listen, many loops” (not REUSEPORT-per-worker pin). Drain budget multi=1 prevents one worker steal. |
| **A8** OpenSSL link | **MISS** | Product still **dynlib** (`HTTP_TLS_BACKEND=dynlib`, `provider_openssl_dynlib_load`). Hot fn cache = dlsym pointers — **not** static link. Drogon: linked in-process. **A8 remains the only architecture MISS; RPS no longer requires it for ≥0.90×.** |

**Architecture PASS rule:** ≤1 MISS among A1–A7 and A3–A5 MATCH → **PASS**. Accept model is now **structurally closer** to drogon than PATH_COMPARE admitted; A8 still blocks “identical OpenSSL architecture” language.

---

## Performance

| Gate | Value | Pass? |
|------|-------|:-----:|
| **B1** Correctness (failed/errored/timeout) | all 0 | **YES** |
| **B2** h1s s1m ratio | **1.143×** (10540.60 / 9224.30) | **YES** (≥0.50 iterate; ≥0.90 parity/WOW) |
| **B3** h1s plain ratio | **0.979×** (148955.00 / 152183.50) | **YES** (≥0.65 floor; ≥0.80 WOW) |
| **B4** soft_cq_send on TLS bulk | **0** | **YES** |
| **B5** No fake seals/req on plain | seals/req=**1.0** (not 2); materialize=reqs honest | **YES** |

**Performance PASS (iterate):** B1 + B4 + B2≥0.50× → **PASS**.  
**Performance WOW (parity language):** B2≥0.90× and B3≥0.80× → **PASS**.

**Ladder (h1s s1m proactr/drogon, same-session each iter):**

| Session | proactr s1m | drogon s1m | B2 | B3 plain |
|---------|------------:|-----------:|---:|---------:|
| P5 | 2599 | 8612 | **0.30×** | 0.74× |
| ITER_01 | ~2736 | ~ | **0.33×** | ~0.64× |
| ITER_02c | 2761 | 8629 | **0.32×** | 0.62× |
| ITER_03 | 2765 | 8637 | **0.32×** | 0.63× |
| **ITER_04** | **10541** | **9224** | **1.143×** | **0.979×** |

**Reading (adversarial):** Absolute s1m **~4.1×** vs P5. Drogon s1m also ~+7% this session vs ITER_03 — **proactr still leads**. Mid bulk s64k **1.315×** (proactr ahead). Tiny plain/s4k within **2%** of drogon. The “3× density hole under dynlib” story is **dead** for this host/matrix.

**eagain_arms note:** 127 on s1m with 8 live workers is **expected residual backpressure**, not a soft-CQ regression (soft_cq still 0). Do not treat higher eagain as a loss vs ITER_03’s eagain=2 (that was single-worker pin, low contention).

---

## Lies / overclaims this session

- **ITER_03 (and this critic’s own prior top-1):** “Static OpenSSL A/B is mandatory; dynlib/AES density is the 3× hole.” **False root cause.** Accept pin explained 0.32×. Own it: **static-openssl-first narrative missed the accept pin.**  
- **PATH_COMPARE § Accept / REUSEPORT:** “Leave for matrix fairness. Do not chase REUSEPORT parity as bulk fix.” On Darwin localhost, REUSEPORT was the bulk **loss**. Document is stale until rewritten.  
- Any claim that hot SSL/BIO fn cache, coalesce, or level READ “finally” bought 1.14× — those shipped under 0.32× with **no** B2 movement; they are prerequisites/honesty, not this iter’s multiplier.  
- **“Identical architecture to drogon”** — **banned.** A8 dynlib MISS; soft ring still coexists; accept is multi-kq race not trantor acceptor RR. Performance parity ≠ architecture clone.  
- **“Converged OpenSSL”** while product remains dynlib.  
- Selling engine-note tags without `shared_listen` / `multi_kq_accept` as if the note fully describes the stack that won.  
- Using H2 cells or older P5 plain ratios to dilute this scoreboard — this session is the scoreboard.

---

## Top 3 code fixes (ordered by expected ×drogon impact)

**Context:** B2 already **1.143×**. Top fixes are **lock the win**, then optional headroom — not “chase 0.50×.”

1. **Lock Darwin shared-listen multi-kq as law; ban REUSEPORT regression on Darwin matrix**  
   - **What:** Keep `host_listen_shared` (no REUSEPORT) for Darwin multi-worker; multi-kq level accept + drain multi=1. Add regression guard: under WORKERS>1 matrix load, refuse silent return to per-worker REUSEPORT listen. Optional: tag `io_engine_note` with `shared_listen_multi_kq`. Update PATH_COMPARE / PRODUCTION docs that still say REUSEPORT-per-worker as the Darwin story.  
   - **Where:** `http/server_posix.odin`, `http/server.odin` `listen`, `http/io_reactor_kqueue.odin` accept path; docs that claim REUSEPORT-only multi-worker.  
   - **Gate:** same-session drogon matrix; **B2 ≥ 0.90×** and **B3 ≥ 0.80×** still hold; soft_cq_send=0; 0 errors. If anyone reintroduces REUSEPORT on Darwin and B2 collapses toward ~0.3× with 1 hot CPU — treat as **P0 regression**, not “density.”  
   - **Why #1:** The entire 0.32→1.14 jump is this lever. Losing it reopens the 3× hole overnight.

2. **Optional headroom only: AES/send density + A8 static A/B (no longer mandatory for parity)**  
   - **What:** Offline static/linked OpenSSL A/B **or** sample-guided residual/send cut under the **winning multi-worker** binary. Goal is margin (1.14→higher) or architecture identity — **not** interim 0.50×.  
   - **Where:** `tls_server` static provider; `reactor_drain_wbio` / `host_try_send_nb` only if sample shows share.  
   - **Gate:** same-session B2; claim gain only if **≥+5%** s1m or published sample share drop. soft_cq=0.  
   - **Why #2:** Dynlib still A8 MISS. RPS no longer depends on it for WOW language. Do **not** prioritize static as if 0.32× returns without it.

3. **Doc + measurement hygiene (prevent false next-hole hunting)**  
   - **What:** Rewrite PATH_COMPARE accept row; note eagain_arms under multi-worker is residual, not dual-CQ; keep `first_seal_pt_avg` + soft_cq as duty gates. Do not reopen CLOSED_RPS_FLAGS without NEW LAW.  
   - **Where:** `PROACTR_VS_DROGON_PATH_COMPARE.md`, critic ladder, matrix README if it still teaches REUSEPORT as Darwin default.  
   - **Gate:** next iter critic must not re-blame dynlib for bulk without **CPU spread** evidence (all workers busy).  
   - **Why #3:** ITER_01–03 spent cycles on density while one worker owned the port. Process fix is as important as code.

**Do not** spend the next cycle on: re-caching SSL_write under dynlib “to fix bulk”; re-coalesce; seals=8 chasing; claiming static is mandatory for 0.90× after this matrix; reintroducing Darwin REUSEPORT for “Seastar style” without multi-worker CPU proof.

---

## Explicitly ban next

- Saying **“identical to drogon architecture”** or **“fully converged”** while **A8 dynlib = MISS**.  
- Performance language is OK: **“h1s bulk ≥ drogon this session (B2 1.143×)”** / **“plain near parity (B3 0.979×)”**.  
- Re-blaming **dynlib / AES density** for historical 0.32× without acknowledging **accept pin**.  
- Reverting Darwin to **SO_REUSEPORT multi-listen** without same-session proof that all workers share accepts (watch top/sample: 1 hot vs N busy).  
- Reopening **CLOSED_RPS_FLAGS** without **NEW LAW**.  
- Using pre-ITER_04 matrices (0.32×) as current scoreboard.  
- Claiming fn-cache / coalesce “caused” the WOW jump.

---

## Next single change + remeasure recipe

**#1 lock shared-listen + document; only then optional density A/B.**

```bash
cd comparisons/tls-h2
# Confirm Darwin log: "host listen: shared fd (Darwin multi-kq accept)"
# Confirm under load: multiple workers busy (not 1×100% + 7 idle)
SERVERS="proactr drogon" WORKERS=8 BENCH_C=50 BENCH_Z=10 WARMUP_Z=3 \
  LOGDIR=/tmp/proactr-drogon-iter05 ./run_matrix.sh
# Require: 0 errors; soft_cq_send_completes=0 on TLS bulk
# WOW hold: h1s s1m proactr/drogon ≥ 0.90×; plain ≥ 0.80×
# Report first_seal_pt_avg s1m (~131k); seals_per_req ~9 OK
# Do not claim architecture identity with A8 dynlib
```

**Scoreboard after this critic:** Verdict **WOW** · B2 **1.143×** · B3 **0.979×** · Architecture A1–A7 MATCH · **A8 dynlib MISS** · critical fix **Darwin shared listen multi-kq (not REUSEPORT)** · prior 0.32× was **accept pin / scaling**, not density · h1s bulk **performance parity language allowed**; **identical architecture language banned**.
