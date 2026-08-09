# Implementation Critics — PR10 r1 (production edges)

**Posture:** harsh elite. Credit only **claimed PR10 production edges** (soft admission, H2 refuse, GOAWAY drain, fairness weights, multi-worker checklist).  
**Bar:** WOW ≥ 9 when edges are **real craft + honest residuals**, not docs ink over assert/kill paths.

| Claimed in | Claimed out |
|------------|-------------|
| Soft 503 on session over-cap (`sse_start` / `ws_start`); metric `session_metrics_admission_reject` | Soft 503 on stream-pool bytes / temp-slot admission |
| H2 multi-slot full → `RST_STREAM(REFUSED_STREAM)`; conn stays open | Engine SETTINGS max-concurrent refuse is a separate path (also REFUSED) |
| `Server.closing` → graceful `GOAWAY(NO_ERROR)` once; refuse new streams `> last_sid`; drain-idle close | Drain **deadline** / force-abort sticky SSE; kTLS |
| Optional `h2_weight_interactive` / `h2_weight_bulk` (default 2/1); `sse_start` marks interactive | Strict WFQ byte-share; host multi-round asymmetry proof |
| `PRODUCTION_CHECKLIST.md` + shared SSL_CTX + REUSEPORT workers as built | Bastion peer RPS; WS-H2; live dual-CT firehose; full h2spec |

**Not required for WOW:** bastion numbers, WS-H2, kTLS, stream-pool soft 503, live concurrent TLS CI, full h2spec.  
**Required for WOW:** soft reject is real (no panic, metric, invalid `Session`); slot-full does **not** kill the conn; GOAWAY is written (NO_ERROR), refuse is engine-real, idle close is real; weights change RR quanta with a unit pin; checklist refuses marketing overclaim.

**Date:** 2026-08-08  
**Prior:** [`impl-pr9-critics-r2.md`](impl-pr9-critics-r2.md) (product offline mean **9.2**; residual CQ-M3 slot-full → close).  
**Subject:** `http/session.odin` (`_session_admission_ok` / `_session_soft_reject`), `http/session_ws.odin`, `http/h2_host.odin` (refuse + GOAWAY drain), `http/server.odin` (`_server_thread_begin_shutdown`, opts weights), `http2/connection.odin` (`conn_send_goaway` / `conn_refuse_stream` / local-GOAWAY refuse), `http2/flow.odin` (`_flush_pending_rr` weights), tests in `session_test` / `h2_host_test` / `flow_test`, docs `{PRODUCTION_CHECKLIST,IMPLEMENTATION_STATUS,APP_CONTRACT,H2_ENGINE,SESSION_SSE}`.

---

## Verify (this pass)

| Command / check | Result |
|-----------------|--------|
| `odin test http -define:ODIN_TEST_THREADS=1 -o:none` | **159/159 pass** (OpenSSL dynlib present; includes PR10 soft admit / REFUSED / GOAWAY host tests) |
| `odin test http2 -o:none` | **23/23 pass** (incl. GOAWAY refuse + weighted RR) |
| Soft 503 H1 SSE/WS | `test_sse_start_soft_reject_over_cap`, `test_ws_start_soft_reject_over_cap` **pass** |
| Soft 503 H2 SSE | `test_h2_sse_start_soft_reject_over_cap` **pass** (503 HEADERS END_STREAM + metric) |
| Slot full REFUSED | `test_h2_host_slot_full_refused_stream` **pass** (`state < Closing`) |
| GOAWAY drain host | `test_h2_host_graceful_goaway_drain_no_error`, `test_h2_host_after_goaway_new_stream_refused` **pass** |
| Engine GOAWAY + weights | `test_h2_conn_send_goaway_no_error`, `test_h2_goaway_refuses_new_stream_keeps_prior`, `test_h2_flush_interactive_weight_vs_bulk` **pass** |
| Live multi-worker admission race | **Not measured** (TOCTOU residual; see MEM) |
| Drain deadline under sticky SSE | **Not present** (named residual) |

---

## Scoreboard

| Axis | Score | WOWED | Worst class |
|------|------:|:-----:|-------------|
| Code quality | **9.0** | **yes** | Minor / production residual (no GOAWAY drain deadline; admission check-then-act; soft-reject slot free not unit-pinned offline) |
| Performance (weights correctness) | **9.1** | **yes** | Minor (frame-quanta × window/n, not pure WFQ; no host `sse_start`→weight end-to-end pin) |
| Memory / lifecycle on soft reject | **9.2** | **yes** | Minor (global live gauge TOCTOU overshoot; offline `h2_out` blocks finish until live flush) |
| Honesty | **9.3** | **yes** | Minor (drain hang footgun not in checklist residuals; “per_worker” is process-wide product of workers) |
| **Mean** | **9.2** | — | — |

**Verdict:** PR10 production edges are **real**, not paper. Soft session admission returns `Session{id=0}` with 503 + `Retry-After` + `session_metrics_admission_reject` and never allocates `Session_State` or bumps live. H2 multi-slot overflow finally does what PR9 r2 residual demanded: `conn_refuse_stream` → `RST_STREAM(REFUSED_STREAM)` and the connection stays open (PR9 CQ-M3 closed). Graceful shutdown writes `GOAWAY(NO_ERROR)` once from `_server_thread_begin_shutdown` / cold `maybe_goaway_from_closing`, refuses new streams above `goaway_sent_last` after HPACK decode, and closes only when drain-idle. Optional weights land in the engine RR path with a tight-window unit pin; `sse_start` marks interactive. `PRODUCTION_CHECKLIST.md` is elite operator honesty — non-claims match the tree.

**All four axes clear WOW (≥9).** Harsh residuals remain (sticky-SSE can hold serve exit; soft cap is best-effort; weights are frame turns not byte WFQ) but they are **named incompleteness**, not fake edges. Mean **9.2**.

---

## Architecture map (what PR10 actually installed)

```text
Soft session admission
  sse_start / ws_start
    → _session_admission_ok(live < max_sessions_per_worker × thread_count)
    → else _session_soft_reject:
         metric admission_reject++
         status 503 + Retry-After:1 (if unset)
         H1 live: respond(503); offline: sent only
         H2: HEADERS END_STREAM on exchange sid → flush → maybe_finish
         return Session{} (id=0)  // no Session_State, no live++

H2 multi-slot admission
  h2_host_dispatch_available
    free slot? take → handler
    full? take → conn_refuse_stream(REFUSED_STREAM) → flush → continue
              // conn NOT closed (PR9 residual fixed)

Server.closing
  server_reap_if_closing → _server_thread_begin_shutdown
    H2: h2_host_on_server_closing
         h2_goaway_drain=true
         conn_send_goaway(NO_ERROR) once → flush
         state Will_Close; close when goaway_drain_idle
    H1: close_on_io / Will_Close as before
  Engine: new sid > goaway_sent_last → HPACK sync + RST REFUSED (stream not opened)
  Cold path: h2_host_maybe_goaway_from_closing on PT / send-complete

Fairness weights
  Server_Opts.h2_weight_interactive / h2_weight_bulk (default 2/1)
  h2_host_on_open copies into Http2_Connection
  sse_start → conn_stream_set_interactive(sid, true)
  _flush_pending_rr: turns = interactive ? w_inter : w_bulk frames/turn
                     (0 weight → engine defaults 2/1)
```

---

## Claim map vs reality (harsh)

| Claim | What code does | Proof strength | Lie risk |
|-------|----------------|----------------|----------|
| Soft 503 SSE/WS | Real; metric; id=0; no assert | H1 + H2 unit tests | Low — callers must check `session_status` (docs say so) |
| Metric `admission_reject` | `atomic_add` on reject path only | Tests assert increment | Low |
| H2 slot full → REFUSED, conn open | `dispatch_available` refuse loop | Host unit + log line observed in test run | Low — **PR9 kill path gone** |
| GOAWAY NO_ERROR on closing | Written once; idempotent | Host + engine units | Low |
| Refuse new streams after GOAWAY | Engine `_finish_header_block` refuse_goaway | Engine + host units | Low |
| Drain then close | Idle when no slots / pending / open_streams / wire | Idle closes offline; pending blocks close | Medium footgun: **no max wait** for SSE |
| Weights 2/1 interactive | Frame quanta in RR | Engine unit `d3 > d1` under 24-byte credit | Low claim / medium misread as WFQ |
| Multi-worker checklist | Shared SSL_CTX + REUSEPORT existing + new edges | Docs + prior TLS host | Low if read “as built” |

---

## 1. Code quality — Score **9.0** / WOWED **yes**

### What is elite for claimed production-edge scope

- **Soft reject is a real host path**, not a renamed assert. `_session_soft_reject` sets 503, default `Retry-After`, increments the metric, and returns zero `Session` without touching `Session_State` / live gauge. Same gate on `ws_start` (H1 only; H2 still hard-asserts WS as unsupported — correct non-claim).
- **PR9 CQ-M3 fixed properly.** Multi-slot full no longer `connection_close`s. `h2_host_dispatch_available` takes one ready request, `conn_refuse_stream`, flushes, and continues — connection remains open for the CAP long-lived holds. That is the production difference between “mux works until CAP then dies” and “mux works until CAP then refuses extras.”
- **GOAWAY is dual-path honest.** Error/fail: `h2_host_emit_goaway_and_close` (code + flush once + close). Graceful: `conn_send_goaway(NO_ERROR)` idempotent; host sets `h2_goaway_drain` + `Will_Close`; engine refuses `sid > goaway_sent_last` **after HPACK decode** (table stays in sync — same discipline as SETTINGS max-concurrent refuse). Shutdown entry is real: `_server_thread_begin_shutdown` walks `td.conns` and calls `h2_host_on_server_closing` for every `h2_active` conn; cold recv/send also re-check `server.closing`.
- **Weights are opt-in surface on the real RR path**, not a parallel scheduler. `sse_start` marks interactive next to the H2 HEADERS send — correct place, before Start effects enqueue DATA.

### Harsh findings

| ID | Class | Finding |
|----|-------|---------|
| **CQ-M1** | Minor / prod residual | **No GOAWAY drain deadline.** Sticky SSE (heartbeat / never-idle) keeps `h2_slot_used` + `open_streams > 0` → `h2_host_goaway_drain_idle` never true → worker loop waits forever for `len(td.conns)==0`. Claim is accurate (“drain existing incl. SSE”) but production operators get a hang, not a bound. Not a code lie — still incomplete production edge. |
| **CQ-M2** | Minor | **Soft admission is check-then-act.** `_session_admission_ok` loads live; later success path `atomic_add(live)`. Concurrent workers can overshoot `max × threads` by ~worker count. Soft caps usually accept this; it is not a hard gate. |
| **CQ-M3** | Minor | **H2 soft-reject unit does not pin slot free.** Offline `h2_host_flush_out` no-ops without SSL, so residual `h2_out` blocks `maybe_finish_exchange`. Live path frees on send-complete drain — correct — but the offline test only proves 503 frames + metric, not host slot recycling. |
| **CQ-M4** | Minor | **Refuse loop can spin** through many ready streams while CAP is full (take/refuse/continue). Fine for CAP=8; under SETTINGS-high + slow slot free it is CPU-busy on one CQE stack. Acceptable at product CAP. |

### WOW call

Craft is production-shaped: soft reject, refuse-not-kill, real GOAWAY drain wiring from server shutdown. Residuals are polish, not fakes. **WOW yes.**

---

## 2. Performance (weights correctness) — Score **9.1** / WOWED **yes**

### What is real

- `_flush_pending_rr` applies **per-turn frame quanta**: interactive → `weight_interactive` (default 2), bulk → `weight_bulk` (default 1). Zero opts still default inside the engine.
- Host copies `Server_Opts` weights on H2 open; `sse_start` sets `stream.interactive`.
- Unit `test_h2_flush_interactive_weight_vs_bulk` (weights 3/1, `max_frame=8`, residual conn credit 24) proves both streams progress and interactive receives **strictly more DATA bytes** than bulk under the same tight window.

### Harsh findings

| ID | Class | Finding |
|----|-------|---------|
| **PERF-M1** | Minor | **Weights are frame turns, not byte WFQ.** Each turn still uses `quantum = send_window / n_pending` (and peer max frame). Under residual credit, interactive gets up to `w_i` frames but bulk already consumed one quantum first in RR order — observed share is preference, not `w_i/(w_i+w_b)` of bytes. Docs say “DATA frames per RR turn” — correct; marketing as “2:1 fairness” would overclaim. |
| **PERF-M2** | Minor | **No host end-to-end weight pin.** Engine test sets `conn_stream_set_interactive` directly; no unit that runs `sse_start` + large bulk oneshot through host flush under tight windows. Integration is shallow (flag set at sse_start is trivial and greppable). |
| **PERF-M3** | Residual (pre-PR10) | Sole-pending streams still full-drain (correct). Weights only matter when ≥2 streams have pending — same multi-pending law as PR9. |

### WOW call

Claimed mechanism is implemented where fairness actually runs (`_flush_pending_rr`) and unit-proved under tight credit. **WOW yes** for optional weights — not for a QoS SLA.

---

## 3. Memory / lifecycle on soft reject — Score **9.2** / WOWED **yes**

### What is elite

- Reject path **does not** `new(Session_State)`, **does not** attach session, **does not** increment `session_metrics_live` (H1 test pins live stays 1). Metric reject is the only counter that moves.
- H2 reject is oneshot **HEADERS + END_STREAM** on the exchange stream (`end_sent` + reap path via engine). No long-lived hold, no timer, no mailbox.
- H1 reject uses `respond(503)` on a live worker; offline marks `sent` only (documented unit split — not a silent wire lie).
- H2 slot-full refuse: stream is delivered then `conn_refuse_stream` fails/closes/reaps — does not leave undelivered bodies forever, does not tear down sibling streams.
- GOAWAY refuse of *new* streams never inserts into `streams` map (decode-only + RST) — no map leak of refused ids beyond last_peer_sid tracking.

### Harsh findings

| ID | Class | Finding |
|----|-------|---------|
| **MEM-M1** | Minor | **TOCTOU overshoot** (same as CQ-M2): soft cap can admit slightly past budget under concurrent `sse_start`. Not a leak; can amplify memory vs named cap. |
| **MEM-M2** | Minor | Offline H2 soft reject leaves **503 frames in `h2_out`** and may leave the multi-slot **used** until a path that clears out + `maybe_finish` runs. Live: flush → send CQE → finish frees. Lifecycle is correct on wire; unit coverage is partial. |
| **MEM-M3** | Named residual (honest) | Stream-pool / temp-slot admission still hard or fail paths — checklist explicitly does **not** claim soft 503 there. Correct non-claim. |

### WOW call

Soft reject lifecycle matches the production story: no session object, no live bump, stream ends, metric fires. **WOW yes.**

---

## 4. Honesty — Score **9.3** / WOWED **yes**

### What is elite

- [`docs/PRODUCTION_CHECKLIST.md`](../../PRODUCTION_CHECKLIST.md) is the right artifact: operator edges, not matrix flips; explicit **Not claimed** (kTLS, WS-H2, bastion RPS, live dual-CT firehose, full h2spec, stream-pool soft 503).
- [`IMPLEMENTATION_STATUS.md`](../../IMPLEMENTATION_STATUS.md) PR10 row matches code and repeats non-claims.
- [`APP_CONTRACT.md`](../../APP_CONTRACT.md) documents soft admission as **host behavior**, not a new `Session_Event_Kind` — correct contract hygiene.
- Engine SETTINGS refuse vs host slot refuse called out as separate in checklist — avoids conflating two REFUSED sources.
- PR9 product non-claims (WS-H2, bastion RPS, bulk firehose) survive; PR10 does not smuggle them back as “production ready HTTPS/H2” (checklist §Claims forbids it).

### Harsh findings

| ID | Class | Finding |
|----|-------|---------|
| **HON-M1** | Minor | **Drain hang residual not listed** in checklist “Residuals” table. Text describes drain-incl-SSE accurately but operators will not see “no max wait / sticky SSE holds serve” unless they read the idle predicate. Add one residual row. |
| **HON-M2** | Minor | Opt name `max_sessions_per_worker` enforces **`max × thread_count` process-wide** via a single live gauge — one hot REUSEPORT worker can consume the whole budget. Documented as product of workers; still easy to misread as per-worker isolation. |
| **HON-M3** | Fringe | Weights default 2/1 are real; “fairness” language is fine if read as RR quanta. Do not publish as latency SLO. |

### WOW call

Honesty bar for PR10 is “do not fake production edges; name what is out.” The checklist and status doc clear that bar. **WOW yes.**

---

## Residuals (ordered; not WOW-blockers for claimed edges)

1. **GOAWAY drain max-wait / force-close sticky SSE** (CQ-M1 / HON-M1) — production hang footgun.
2. Soft admission **CAS/harder cap** if operators need strict max (CQ-M2 / MEM-M1).
3. Host unit: soft reject → **slot free** after simulated flush (CQ-M3 / MEM-M2).
4. Host unit: `sse_start` interactive + bulk oneshot under tight window (PERF-M2).
5. Stream-pool / temp soft 503 — already checklist residual.
6. Live multi-worker admission / GOAWAY soak — optional evidence only.

---

## Score / WOWED summary

| Axis | Score | WOWED |
|------|------:|:-----:|
| Code quality | **9.0** | **yes** |
| Performance (weights correctness) | **9.1** | **yes** |
| Memory / lifecycle on soft reject | **9.2** | **yes** |
| Honesty | **9.3** | **yes** |
| **Mean** | **9.2** | **WOW** |

**Final:** PR10 production edges are **landed and honest**. Soft 503 + metric, H2 REFUSED without conn kill, graceful GOAWAY drain with post-GOAWAY refuse, optional RR weights, and the multi-worker checklist all exist in code and offline tests (`odin test http` 159/159, `odin test http2` 23/23 this pass). Grant WOW. Next polish is drain deadline and stricter admission accounting — not rewriting fake edges into real ones.
