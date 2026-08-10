# Critic drogon iter 01

**SHA:** `5f5e9f9` (`5f5e9f94e7e86e82c4b8d87b196d94441848f12c`)  
**Host:** Benjamins-MacBook-Pro.local · Darwin 25.5.0 arm64 · ncpu=12  
**Matrix:** same-session `SERVERS=proactr drogon` · WORKERS=8 · c50 · D10 · `summary.tsv` / `SUMMARY.md` (2026-08-10T03:05Z) · duty `instrumentation.txt`  
**Anchors:** `BASELINE_P5.md` · `CONVERGENCE_COMPLETE.md` · `PROACTR_VS_DROGON_PATH_COMPARE.md`

## Verdict: FAIL

| Bar | Result | Why |
|-----|--------|-----|
| **A Architecture** | **PASS** (narrow) | 0 MISS among A1–A7; A3–A5 MATCH. A2 PARTIAL (READ still oneshot). **A8 dynlib = MISS** (called out; not in A1–A7 count). |
| **B Performance** | **FAIL** | B2 h1s s1m = **0.33×** ≪ 0.50× interim gate. B3 plain = **0.64×** fails 0.65× floor. |
| **Ship / “converged” language** | **BANNED** | Structural checklist ship ≠ drogon parity. Auto-FAIL under 0.50× s1m. |

**Headline numbers (same session):**

| Cell | proactr | drogon | ratio |
|------|--------:|-------:|------:|
| h1s s1m | **2736** | **8195** | **0.33×** |
| h1s s64k | 29144 | 63318 | 0.46× |
| h1s s4k | 84602 | 148566 | 0.57× |
| h1s plain | 95723 | 150716 | **0.64×** |

Duty (h1s s1m): `soft_cq_send_completes=0`, `seals_per_req≈9.00`, `windows/turn≈8.99`, `eagain_arms=2`, `materialize=1` (not per-req). Plain: `seals_per_req=1`, `materialize=reqs`. All matrix cells 0 failed/errored/timeout.

**Honesty ladder:** L0 was 0.30× (P5). Post-checklist stack is still **0.33×**. That is **not** L1 (0.35–0.45×) and nowhere near parity. Claiming “convergence complete” as RPS language is a lie; at best “checklist items landed, RPS still loses badly.”

---

## Architecture scores

Live read: `http/tls_reactor_flush.odin`, `http/io_reactor_kqueue.odin`, `http/server_loop_reactor.odin`, `http/reactor_law.odin`, `tls_server/provider_openssl_dynlib.odin`  
Drogon read: `OpenSSLProvider.cc` (`sendData`/`sendTLSData`), `TcpConnectionImpl.cc` (`writeCallback`/`writeInLoop`), `KQueue.cc`, `EventLoop.cc` (`loop`).

| Axis | Score | Evidence (file:symbol) |
|------|-------|------------------------|
| **A1** One blocking wait per worker | **MATCH** | proactr: `server_reactor_worker_loop` — one blocking `reactor_wait(s, loop_wait)`; soft `ring_wait(..., 0)` only non-blocking harvest (timer-due pre + post-I/O). drogon: `EventLoop::loop` → single `poller_->poll`. Not two *blocking* paths. Residual cost: always a second soft peek syscall post-I/O even when empty. |
| **A2** Readiness model | **PARTIAL** | Residual WRITE **level**: `reactor_arm_write_residual` oneshot=false + `reactor_disable_write_level` (drogon `enableWriting`/`disableWriting`). **READ still EV_ONESHOT** every arm (`reactor_host_arm_recv` → `reactor_arm_filter` default oneshot). drogon: level R/W Channel (`KQueue::update` EV_ADD\|EV_ENABLE). |
| **A3** Residual CT | **MATCH** | Single residual in `dual_ct.tx` via `reactor_residual_set` / `reactor_write_residual`; residual-first before `SSL_write` in `reactor_tls_flush` (R-ORDER). drogon: `TLSProvider::writeBuffer_` remainder only; `sendData` gates on `getBufferedData().readableBytes()==0`. |
| **A4** TLS send loop | **MATCH** | `reactor_tls_flush`: residual → drain wBIO → `reactor_ssl_write_window` (`REACTOR_SEAL_WINDOW=128KiB`) → `reactor_drain_wbio` (peek/`BIO_get_mem_data` shape → `host_try_send_nb` until EAGAIN → residual). drogon: `sendData` trunk loop + `sendTLSData` peek+write+`BIO_reset`. Multi-window, no soft-CQ between seals. |
| **A5** No proactor CQE product TLS | **MATCH** | `instrumentation.txt` h1s s1m/s64k/plain: `soft_cq_send_completes=0`. Engine note: `no_proactr_socket_submit`. Native send via `host_try_send_nb` (`posix.send`), not `submit_send` between seals. |
| **A6** Buffer ownership | **MATCH** | Darwin: `tls_host` skip `hold` slab (`when ODIN_OS != .Darwin`); single residual region; `no_dual_ct_ahead` in engine note. No dual residual. |
| **A7** Thread model | **MATCH** | N workers, conn pinned to worker reactor kq (proactr). drogon: N `ioLoops_`, conn pinned after accept. |
| **A8** OpenSSL link | **MISS** | Product default **dynlib** only: `HTTP_TLS_BACKEND=dynlib`, `provider_openssl_dynlib_load`, vtable `p.write` → dlsym `SSL_write`. drogon: linked OpenSSL, direct `SSL_write` in `OpenSSLProvider::sendData`. |

**Architecture PASS rule:** ≤1 MISS among A1–A7 **and** A3–A5 MATCH → **PASS** (A2 PARTIAL only; A8 outside A1–A7 but still a real density miss).

---

## Performance

| Gate | Value | Pass? |
|------|-------|:-----:|
| **B1** Correctness (failed/errored/timeout) | all 0 on scored cells | **YES** |
| **B2** h1s s1m ratio | **0.33×** (2736 / 8195) | **NO** (need ≥0.50× interim; ≥0.90× for parity talk) |
| **B3** h1s plain ratio | **0.64×** (95723 / 150716) | **NO** (need ≥0.65×) |
| **B4** soft_cq_send on TLS bulk | **0** | **YES** |
| **B5** No fake seals/req on plain | seals/req=**1.0** (not 2); materialize=reqs honest | **YES** |

**Performance PASS (iterate):** B1 + B4 + B2≥0.50× → **FAIL** (B2).  
**Performance WOW:** not eligible.

**Vs BASELINE_P5:** s1m 2599→2736 (**+5.3%**); plain **111730→95723 (−14%)**. Bulk barely moved; tiny **regressed**. Checklist PRs did not buy drogon-class RPS. Mid-flight SEAL128 session once printed 0.37× against a soft drogon cell — **do not cherry-pick**; scoreboard of record is this same-session matrix at **0.33×**.

---

## Lies / overclaims this session

- **`CONVERGENCE_COMPLETE.md` title + “complete” framing** while B2=0.33×. Structural checklist ≠ drogon convergence. Skill auto-FAIL: no “converged to drogon” under 0.50×.
- **“CONDITIONAL PASS” after land** in that doc — Bar B fails hard; only architecture checklist can be called landed.
- **Any implication that peek drain + 128 KiB seal + level residual WRITE “closed the drogon gap.”** Measured: still **3× slower** on bulk H1.s. Drogon wins *despite* double body copy; density beats checklist cosplay.
- **Selling plain 95k as “session noise only” without owning stack tax.** P5 plain was 112k; post-stack 95k fails B3. Investigate before claiming noise.
- **Ban reopening CLOSED_RPS_FLAGS without NEW LAW** still holds — but “leave dynlib forever” is not a free pass to claim parity while A8 is MISS and B2 is 0.33×.

---

## Top 3 code fixes (ordered by expected ×drogon impact)

1. **Kill dynlib + double-dispatch on the seal/drain hot path (A8 / AES density)**  
   - **What:** Offline A/B **static-linked OpenSSL** (or: cache direct `SSL_write` / `BIO_ctrl` / wBIO ptr on conn; stop `Provider` vtable + `SSL_get_wbio` on every `bio_pending_out` / peek). Drogon calls `SSL_write` in-process with no dynlib PLT.  
   - **Where:** `tls_server/provider_openssl_dynlib.odin` (`p.write`, `bio_pending_out`, `bio_peek_out`); `tls_server/provider.odin` wrappers; call sites `reactor_ssl_write_window` / `reactor_drain_wbio` in `http/tls_reactor_flush.odin`.  
   - **Gate:** same-session drogon matrix; target **B2 ≥ 0.50×** or document AES share + ratio if only +5–10%.  
   - **Why #1:** Structure already multi-window + peek; remaining bulk hole is per-byte encrypt/send density. Dynlib is the last named architecture MISS that still sits on every seal.

2. **Stop heading/body part-boundary fragmentation of the first bulk seal**  
   - **What:** `tls_plain_window` returns only the heading slice first (`tls_oneshot.odin`), so every ≥8 KiB response pays a **tiny first `SSL_write`** then 8×128 KiB body → `seals_per_req≈9` on s1m (1+8). Drogon’s `renderToBuffer` is one contiguous plain buffer → uniform trunks. Stage first trunk as heading+body prefix (small scratch or single concat for first window only) so first seal is a full `REACTOR_SEAL_WINDOW`.  
   - **Where:** `http/tls_oneshot.odin` (`tls_plain_window` / advance); `http/tls_reactor_flush.odin` `reactor_ssl_write_window`; plan from `response_send_ciphered_heading_body` in `http/response_ciphered.odin`.  
   - **Gate:** s1m seals/req **8.x not 9.0**; B2 up; plain/s4k not regressed (still one seal for tiny).  
   - **Why #2:** Free SSL setup tax every bulk response; pure bulk path; no CLOSED flag reopen.

3. **Level-triggered READ (drogon Channel shape) — kill oneshot re-arm per request**  
   - **What:** `reactor_host_arm_recv` always oneshot; every keep-alive request re-`EV_ADD|EV_ONESHOT`. Drogon `enableReading` stays level until disable. Residual WRITE is already level — READ is the remaining readiness hole (A2 PARTIAL). Expect help on **plain/s4k (B3)** and multi-conn kevent changelist tax; bulk secondary.  
   - **Where:** `http/io_reactor_kqueue.odin` `reactor_host_arm_recv`, `reactor_arm_filter`, readable path clear-arm bits; disable on close only.  
   - **Gate:** h1s plain **≥ 0.65×** drogon same session; no CPU spin; s1m not down.  
   - **Why #3:** Real event-model miss vs drogon; B3 already fails; sample still kevent-heavy.

**Do not** spend the next cycle on: another seal-size knob without OpenSSL density data; Dual_Ct N>2; TCP_NODELAY; floor-0 plain-split (already rejected −27%); claiming architecture “done” because soft_cq=0.

---

## Explicitly ban next

- Saying **“converged to drogon”**, **“same as drogon”**, **“architecture complete = ship”**, or **“parity”** while **B2 < 0.50×** (and never “parity” until B2 ≥ 0.90× and B3 ≥ 0.80×).  
- Treating **CONVERGENCE_COMPLETE checklist** as a performance win.  
- Reopening **CLOSED_RPS_FLAGS** (Dual_Ct N>2, dense soft-CQ, TCP_NODELAY, 1 MiB seal flag, kTLS-as-fair) without a written **NEW LAW**.  
- Cheerleading **+5% s1m** vs P5 while still **0.33×** drogon.  
- Ignoring **plain −14%** vs P5 when claiming the convergence stack is neutral.  
- Using H2 cells or ntex bulk wins to paper over the **h1s s1m drogon hole**.

---

## Next single change + remeasure recipe

Pick **one** of Top 3 (prefer #1 offline OpenSSL A/B if binary policy allows; else #2 heading coalesce as product-safe). Then:

```bash
cd comparisons/tls-h2
SERVERS="proactr drogon" WORKERS=8 BENCH_C=50 BENCH_Z=10 WARMUP_Z=3 \
  LOGDIR=/tmp/proactr-drogon-iter01-ab ./run_matrix.sh
# Require: 0 errors; soft_cq_send_completes=0 on TLS bulk
# Claim iterate PASS only if h1s s1m proactr/drogon ≥ 0.50× same session
# Report plain ratio; do not claim “converged”
```

**Scoreboard after this critic:** Verdict **FAIL** · B2 **0.33×** · Architecture checklist mostly MATCH · RPS still loses by **~3×** on bulk H1.s.
