# Plan R2 P0 — `proactr.submit_*` inventory (`http/`)

**Date:** 2026-08-09  
**Scope:** every direct `proactr.submit_*` call site under `http/`, with planned I/O owner after Darwin reactor cutover.  
**Honesty note (R2 P4 / P4b / P5-lite):** Darwin TLS **product send law** is reactor until-EAGAIN + single residual CT:

| Path | Darwin owner |
|------|----------------|
| H1 oneshot flush | `reactor_tls_flush` |
| H2 frame flush | `reactor_tls_flush` |
| Handshake / WANT_WRITE drain | `tls_host_try_drain_out` → `reactor_drain_wbio` |
| Progressive stream | residual-first CT write + `reactor_arm_write_residual`; `dual_ct_try_ahead` **no-op** |
| Residual WRITE re-arm | `host_submit_send` with `conn.reactor_h1` (not charged as `soft_cq_send_completes`) |

**Still façade (plan not 100%):** accept / recv / close / timers / `ring_wait` worker loop / clear-H1 send. Matrix label: `io_engine=reactor-kqueue`; see `io_engine_note` on `/_matrix/stats`.

Linux (`ODIN_OS != .Darwin`) remains full proactor-uring; dual-CT unchanged.

---

## R2 P5-lite completion (this land)

**In scope done (solidity over full cutover):**

1. All Darwin **TLS product response/send** flushes use reactor law (H1, H2) or residual-first (stream window).
2. `dual_ct_try_ahead` is a compile-time no-op on Darwin.
3. Residual EAGAIN arms mark `reactor_h1` **before** `host_submit_send` (documented in `wire.odin` / `io_reactor_kqueue.odin`).
4. Clear-H1 is non-TLS and stays proactr façade/proactor (correct; not a TLS flush gap).
5. Duty counters: `soft_cq_send_completes` excludes residual arms; `seal_windows` / `kevent_turns` are `reactor_tls_flush` only.

**Not done (remaining façade — full P5):**

| # | Item | Why still façade |
|---|------|------------------|
| R1 | `submit_accept` (`host_arm_accept`) | No `server_loop_reactor` accept ownership; soak risk if swapped alone |
| R2 | `submit_recv` clear-H1 (`host_arm_recv`) | Scanner still arms via proactr |
| R3 | `submit_recv` TLS CT (`tls_host_arm_recv`) | Handshake + duplex CT interest still proactr |
| R4 | `submit_close` | Deferred close still rides façade CQE interest |
| R5 | `submit_timeout` | **D5 keep** — proactr software timers through cutover |
| R6 | Worker `ring_wait` / kqueue ownership | Product sockets still share proactr kqueue; no dedicated reactor wait loop |
| R7 | Residual WRITE re-arm via `host_submit_send` | Intentional hybrid: bulk windows are sync; only EAGAIN remainder uses façade WRITE |
| R8 | Clear-H1 `host_submit_send` / writev / sendfile | Non-TLS path; not R2 vertical slice |
| R9 | Stream multi-window ≠ `reactor_tls_flush` | Residual-first per window + light re-entry; shared D9 fairness / full multi-window reactor deferred |
| R10 | Dual-CT hold slab still allocated on Darwin | Unused on H1/H2 reactor product paths; drop optional |
| R11 | CI grep: no `proactr.submit_send` from `http/` on Darwin | Residual arm still needs it; full delete is true P5 |
| R12 | Nonblocking post-accept recv without `submit_recv` | Stretch skipped (too invasive vs `_server_thread_main`) |

**Plan status:** P0–P4 product TLS send law landed on Darwin hybrid; **P5 not 100%** until R1–R4, R6–R7, R11 delete façade socket path (timers R5 stay).

---

## Direct call sites

| # | File | Symbol / context | Op | Planned owner | R2 P5-lite status |
|---|------|------------------|-----|---------------|-------------------|
| 1 | `http/server.odin` | `host_arm_accept` | `submit_accept` | reactor (full P5) | **façade** (R1) |
| 2 | `http/server.odin` | `host_arm_accept` (one-shot fallback) | `submit_accept` | same | **façade** |
| 3 | `http/server.odin` | `host_arm_recv` (clear-H1) | `submit_recv` | reactor | **façade** (R2) |
| 4 | `http/server.odin` | `connection_close` path | `submit_close` | reactor / sync close | **façade** (R4) |
| 5 | `http/tls_host.odin` | `tls_host_arm_recv` (CT recv) | `submit_recv` | reactor | **façade** (R3) |
| 6 | `http/wire.odin` | `host_submit_send` | `submit_send` | **reactor residual WRITE arm** when `reactor_h1`; Linux dual-CT; clear-H1 façade | **Darwin residual only** for TLS (R7); bulk windows do not submit between seals |
| 7 | `http/wire.odin` | `host_submit_writev` | `submit_writev` | Linux proactor; Darwin Unsupported→multi_send | unchanged (clear / Linux) |
| 8 | `http/wire.odin` | `host_submit_sendfile` | `submit_sendfile` | platform façade/proactor | unchanged (clear path) |
| 9 | `http/session.odin` | session timer arm | `submit_timeout` | proactr software timers (D5) | **proactr timers** (R5 kept) |

## Indirect send paths (call `host_submit_send` → #6)

| Area | File(s) | Planned owner | R2 P5-lite status |
|------|---------|---------------|-------------------|
| Clear-H1 oneshot / plan exec | `response.odin`, `wire.odin` | façade / proactor | façade on Darwin (R8; non-TLS) |
| TLS dual-CT submit / promote | `tls_dual_ct.odin` (`tls_host_submit_ct`, `tls_host_send_ct_or_arm`) | **Linux only** for product TLS H1/H2 | Darwin H1/H2 **bypass** via `reactor_tls_flush` / residual arm |
| TLS oneshot flush | `tls_oneshot.odin` | Darwin → `reactor_tls_flush`; Linux → dual-CT | **Darwin reactor** |
| H2 frame flush | `h2_flush.odin` | Darwin → `reactor_tls_flush`; Linux → dual-CT | **Darwin reactor** (P4) |
| TLS progressive stream | `tls_stream.odin` | residual-first + residual arm | **Darwin residual-first window** (R9: not full `reactor_tls_flush`) |
| TLS handshake CT drain | `tls_host.odin` / `tls_host_try_drain_out` | Darwin → `reactor_drain_wbio` | **Darwin reactor drain** (P4b) |

## Design law (Darwin H1 + H2 bulk)

```text
reactor_tls_flush (H1 oneshot | H2 h2_out):
  residual-first write → EAGAIN arm WRITE (no SSL_write while residual > 0)
  SSL_write(64 KiB) → drain wBIO → write until EAGAIN
  fairness: 2 MiB plain or 32 windows → yield (product re-entry; no soft-Nop)
  NO soft_cq between full CT windows
  NO dual_ct_try_ahead
  H2: arm CT recv after flush (duplex)

// residual arm only:
reactor_arm_write_residual:
  reactor_h1 = true
  host_submit_send(pending = residual view)  // façade EVFILT_WRITE re-entry
  // CQE → reactor_on_send_complete; soft_cq_send_completes not charged
```

## Deferred (true P5 / later)

| Item | Phase |
|------|--------|
| Full `server_loop_reactor.odin` (own kevent wait; no façade accept/recv) | full P5 |
| Delete residual arm `submit_send` (native arm WRITE without proactr user) | full P5 |
| Progressive stream shared `reactor_tls_flush` + D9 fairness | later |
| Delete façade socket path from `http/` (accept/recv/close) | full P5 |
| Dual-CT slab drop on Darwin (hold still allocated; unused on H1/H2 reactor) | optional |
| Nonblocking post-accept recv without `submit_recv` | stretch — skipped (invasive) |
| Stub `server_loop_reactor` accept ownership | deferred — do not replace accept without soak |

## Metrics (duty / honesty)

| Key | Meaning |
|-----|---------|
| `io_engine` | `reactor-kqueue` (Darwin P5-lite), `proactor-uring` (Linux), `proactor-kqueue-facade` (other BSD) |
| `io_engine_note` | Darwin hybrid: TLS send reactor; accept/recv/close/timers/`ring_wait` façade; residual arm via `submit_send` |
| `seal_windows` | SSL_write windows on **`reactor_tls_flush` only** (H1 oneshot + H2; not stream) |
| `kevent_turns` | `reactor_tls_flush` entries (proxy for seal_windows_per_kevent_turn) |
| `soft_cq_send_completes` | proactor send CQE **without** `reactor_h1`; **0 expected** for pure Darwin H1/H2 TLS bulk cells; clear-H1 still charges |
| `eagain_arms` | residual WRITE arms after EAGAIN (`reactor_arm_write_residual`) |
| `pt_bytes` | plain sealed (existing) |

## Baseline pin (operator)

- Matrix: `comparisons/tls-h2/run_matrix.sh` (or bastion equivalent)
- Cells of interest: h1s plain, h1s s4k, h1s s1m, h2 plain, h2 s1m
- Machine class: local Darwin vs bastion Linux (do not mix)
- Git SHA: pin at first duty remeasure after this land
