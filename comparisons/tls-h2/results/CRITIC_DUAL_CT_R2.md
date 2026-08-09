# Harsh critic — live dual-CT seal∥send (PR5.1) — R2

Role: re-score after R1 CRITICAL fixes.  
**Prior:** [`CRITIC_DUAL_CT.md`](CRITIC_DUAL_CT.md)  
**Scope:** promote ordering / lost CT / drained false-done on live dual-CT.

**Date:** 2026-08-08

**Files re-read:**

| Path | Focus |
|------|--------|
| [`http/tls_host.odin`](../../../http/tls_host.odin) | HS / oneshot / stream `on_send_complete`; `flush_response` order |
| [`http/h2_host.odin`](../../../http/h2_host.odin) | `flush_out` order; `h2_host_conn_drained` |
| [`http/tls_host_test.odin`](../../../http/tls_host_test.odin) | dual-CT unit coverage |

---

## Verdict

**PASS**

No remaining **CRITICAL** correctness gaps on promote ordering, lost ready CT, or drained/clean false-done for the live dual-CT machine. R1 C1–C4 are fixed in-tree and verified by code audit. Progressive stream remaining **serial** is **IMPORTANT** (incomplete dual depth), not a FAIL under the stated bar: stream send-complete now promotes before residual drain.

Bastion smoke is directional evidence that seal∥send is live and helpful; it is not a peer-rank claim and was not re-run in this pass.

---

## R1 → R2 fix audit

| R1 ID | Claim | Status | Evidence |
|-------|--------|--------|----------|
| **C1** | HS stashes CT via `try_drain_out` and never promotes | **Fixed** | `tls_host_on_send_complete` HS branch: `tls_host_promote_hold` **before** `drive_handshake` / residual HS drain (`tls_host.odin` ~1119–1144). Handshake state still demuxes next CQE even when promote uses `hs=false` (`hs \|\| state==.Handshake`). |
| **C2** | Idle residual wBIO drain before promote reorders CT | **Fixed** | `tls_host_flush_response` and `h2_host_flush_out`: promote ready (`hold_n` / `tx_ready_n`) **before** `bio_pending` drain (~1030–1041, ~842–852). |
| **C3** | Stream send-complete ignores dual-CT ready | **Fixed (CQE)** | Long-lived branch promotes before residual drain / plain advance (~1158–1161). Ahead seal still not implemented (serial) — IMPORTANT only. |
| **C4** | Done/drained miss `tx_ready_n` | **Fixed** | Oneshot continue gate includes `tls_ct_tx_ready_n` (~1217–1220). `h2_host_conn_drained` checks `hold_n` and `tx_ready_n` (~950–952). |

---

## Checklist (mandated)

| Risk | Result | Notes |
|------|--------|-------|
| Clobber in-flight buffer | **OK** | `seal_dst_for_ahead` still refuses sending slab; ready_n gates free. |
| Double-submit | **OK** | Promote / idle flush only when `!_conn_wire_in_flight`; partial resubmit same buffer. |
| Lost CT | **OK (prod paths)** | HS/oneshot/H2/stream CQE promote ready slabs; clean/drained see both ready_n. |
| Promote order | **OK (prod flush + CQE)** | Ready before residual on oneshot + H2 flush; CQE promote-first on HS/stream/oneshot/H2. |
| H2 duplex | **OK** | Flush + send-complete still arm CT recv while Open. |
| Incomplete dual depth | **IMPORTANT** | Stream serial; depth-2 only; not pure `Seal_SM`. |
| Race on hold_n | **OK** | Single-threaded worker. |
| Metrics double-count | **IMPORTANT** | Unchanged: `ct_sends` at bio drain; residual seal-unit inflation; early `path_reqs`. |

---

## CRITICAL findings

*None.*

---

## IMPORTANT findings

### I1 — Progressive stream still serial (explicit residual)

`tls_host_stream_try_submit` still early-returns on inflight (`stream_flush_pending`) and always drains/seals through primary without `try_seal_hold` / `submit_ct`. Dual-CT **overlap** is oneshot + H2 only. CQE promote is correct so stashed residual during stream drain is not lost; throughput for SSE/WS remains serial seal-then-wait.

### I2 — `drive_handshake` still does not promote-before-drain

Recv-driven `tls_host_drive_handshake` still goes straight to `try_drain_out` on `bio_pending` without checking ready_n. **Reachability is low** after C1: the only way to leave inflight with ready CT is a send CQE, which now promotes first. Defense-in-depth: promote at the top of `drive_handshake` (and refuse idle drain while ready_n > 0) would close the last structural hole.

Open completion inside `drive_handshake` also does not re-check ready_n before `tls_host_open_start_protocol`; same low-reachability argument after CQE promote.

### I3 — `promote_hold` always submits with `hs=false`

HS stashed CT promoted through the shared helper is demuxed on the next complete via `tls_pipe.state == .Handshake` (still true until accept returns 1), not via `tls_hs_send`. Correct today; fragile if Open is set while a promoted “HS” buffer is still the outstanding send. Prefer `promote_hold(conn, hs=…)` or sticky `tls_hs_send` until protocol start.

### I4 — Stream submit entry still no promote-before-drain

`tls_host_stream_try_submit` does not promote ready slabs before residual `try_drain_out`. Safe if every path that clears inflight goes through send-complete promote; still a second-class citizen vs oneshot/H2 flush. Prefer promote-or-assert-ready-empty at entry; route CT submit through `tls_host_submit_ct`.

### I5 — Tests still thin

`test_tls_dual_ct_seal_dst_for_ahead` only pins destination selection. No pure tests for:

- promote order hold → primary  
- flush promote-before-residual  
- HS CQE promote before `drive_handshake`  
- `h2_host_conn_drained` with ready_n  
- oneshot done gate with `tx_ready_n` only  

Bastion 0-failed smoke reduces but does not replace these.

### I6 — Metrics / docs hygiene (carry-forward)

- `path_metrics_note_ct_send` still means “BIO drained,” including stash.  
- Docs (`TLS_H1.md` / `IMPLEMENTATION_STATUS.md`) may still say live dual-CT **Not yet** — flip only with accurate stream-serial caveat.  
- `conn_alloc` free-list still asymmetric on hold fields (destroy cleans).

---

## Bastion smoke (stated; not re-run here)

Fair-class magnitude after dual-CT (pre-R2 polish numbers, 0 failed):

| Cell | RPS (smoke) | Prior cursor-era smoke | Read |
|------|------------:|------------------------|------|
| h2 s64k | 44564 | ~6k | large lift (I/O + dual-CT + prior cursor) |
| h2 s1m | 2930 | ~1.9k | **~1.5×** on large body — consistent with seal∥send overlap |
| h1s s64k | 50226 | ~10k | control also up (not H2-only) |
| h1s s1m | 4051 | (profile-era lower) | dual-CT on oneshot bulk |

**Honesty bounds:** single smoke, not a four-peer fair matrix. Absolute levels mix workers/opts/history; use as **order-of-magnitude confirmation** that dual-CT is on the wire and not a silent no-op. Do not re-rank ntex/go from this alone.

---

## Top residual bulk risks

1. **Still ~body/64KiB SSL_write count** — dual-CT overlaps encrypt with send; does not cut seal count. Larger pull / record batch next.
2. **Multi-copy H2** — pending → `h2_out` → SSL → BIO → CT slab → kernel.
3. **Mem-BIO drain copies** — still per-window.
4. **H1 oneshot materialize O(body)** — firehose pure O(window) not on live oneshot.
5. **Depth-2 ceiling** — deep wBIO backlog waits CQE.
6. **Progressive TLS serial** — SSE/WS do not get seal∥send.
7. **No automated multi-MiB dual-CT firehose CI on ring** — bastion smoke ≠ CI gate.

---

## Scoreboard

| Axis | R1 | R2 | Note |
|------|---:|---:|------|
| Promote / lost CT | FAIL | **PASS** | C1–C4 closed |
| H2 duplex | OK | **OK** | unchanged |
| Stream dual depth | incomplete | incomplete | serial = IMPORTANT |
| Tests | weak | weak | still selection-only |
| Bulk evidence | none | smoke 0-fail | directional only |

---

## One-line summary

**PASS:** R1 CRITICAL promote/order/drained bugs are fixed on HS, oneshot, H2, and stream CQE paths; remaining serial stream and thin tests are IMPORTANT residuals, not ship-blockers for dual-CT correctness.
