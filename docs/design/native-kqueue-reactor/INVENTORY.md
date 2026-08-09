# Plan R2 P0 — `proactr.submit_*` inventory (`http/`)

**Date:** 2026-08-09  
**Scope:** every direct `proactr.submit_*` call site under `http/`, with planned I/O owner after Darwin reactor cutover.  
**Honesty note (R2 P2–P3 vertical slice):** Darwin TLS **H1 oneshot response send** uses reactor until-EAGAIN + single residual CT (no soft-CQ between seal windows). **Accept / recv / close / timers / H2 / progressive stream / handshake CT** still ride the kqueue **proactor façade** until P4–P5. Matrix label: `io_engine=reactor-kqueue` (H1 send law); see `io_engine_note` on `/_matrix/stats`.

Linux (`ODIN_OS != .Darwin`) remains full proactor-uring; dual-CT unchanged.

---

## Direct call sites

| # | File | Symbol / context | Op | Planned owner | R2 P2–P3 status |
|---|------|------------------|-----|---------------|-----------------|
| 1 | `http/server.odin` | `host_arm_accept` | `submit_accept` | reactor (P2 full) / façade until then | **façade** (accept still proactr) |
| 2 | `http/server.odin` | `host_arm_accept` (one-shot fallback) | `submit_accept` | same | **façade** |
| 3 | `http/server.odin` | `host_arm_recv` (clear-H1) | `submit_recv` | reactor | **façade** |
| 4 | `http/server.odin` | `connection_close` path | `submit_close` | reactor / sync close | **façade** |
| 5 | `http/tls_host.odin` | `tls_host_arm_recv` (CT recv) | `submit_recv` | reactor | **façade** |
| 6 | `http/wire.odin` | `host_submit_send` | `submit_send` | **reactor for Darwin H1 TLS bulk residual arm only**; Linux dual-CT proactor; clear-H1 / H2 / stream stay façade or proactor | **Darwin H1 bulk:** no bulk `submit_send` between seal windows; residual EAGAIN may arm WRITE via `submit_send` with `reactor_h1` (does **not** increment `soft_cq_send_completes`). **All other paths:** proactor/façade |
| 7 | `http/wire.odin` | `host_submit_writev` | `submit_writev` | Linux proactor; Darwin Unsupported→multi_send | unchanged (Linux) |
| 8 | `http/wire.odin` | `host_submit_sendfile` | `submit_sendfile` | platform façade/proactor | unchanged (clear path) |
| 9 | `http/session.odin` | session timer arm | `submit_timeout` | proactr software timers (D5) | **proactr timers** (kept) |

## Indirect send paths (call `host_submit_send` → #6)

| Area | File(s) | Planned owner | R2 P2–P3 |
|------|---------|---------------|----------|
| Clear-H1 oneshot / plan exec | `response.odin`, `wire.odin` | façade / proactor | façade on Darwin |
| TLS dual-CT submit / promote | `tls_dual_ct.odin` (`tls_host_submit_ct`, `tls_host_send_ct_or_arm`) | **Linux only** for H1 oneshot; H2/stream dual-CT until P4 | Darwin H1 oneshot **bypasses** via `reactor_tls_flush` |
| TLS oneshot flush | `tls_oneshot.odin` | Darwin → `reactor_tls_flush`; Linux → dual-CT | **Darwin reactor** |
| TLS progressive stream | `tls_stream.odin` | reactor later | **façade dual-CT** (deferred) |
| H2 frame flush | `h2_flush.odin` | reactor P4 | **façade dual-CT** (deferred) |
| TLS handshake CT drain | `tls_host.odin` / dual-CT drain | reactor HS later | **façade** (small; may soft-CQ) |

## Design law (Darwin H1 bulk)

```text
reactor_tls_flush:
  residual-first write → EAGAIN arm WRITE (no SSL_write while residual > 0)
  SSL_write(64 KiB) → drain wBIO → write until EAGAIN
  fairness: 2 MiB plain or 8 windows → yield
  NO soft_cq between full CT windows
  NO dual_ct_try_ahead
```

## Deferred (not this vertical slice)

| Item | Phase |
|------|--------|
| Full `server_loop_reactor.odin` (own kevent wait, no façade for accept/recv) | P2 full / P5 |
| H2 residual + until-EAGAIN | P4 |
| Progressive stream reactor | later |
| Handshake multi-flight reactor residual-first | P2 polish / P5 |
| Delete façade socket path from `http/` | P5 |
| Dual-CT slab drop on Darwin (hold unused for H1) | optional; hold still allocated for H2/stream |

## Metrics (duty / honesty)

| Key | Meaning |
|-----|---------|
| `io_engine` | `reactor-kqueue` (Darwin), `proactor-uring` (Linux), `proactor-kqueue-facade` (other BSD) |
| `io_engine_note` | Darwin hybrid note while accept/recv/H2 still façade |
| `seal_windows` | cumulative SSL_write windows (reactor path) |
| `kevent_turns` | reactor flush entries (proxy for turns) |
| `soft_cq_send_completes` | proactor send CQE path only; **0 expected for Darwin H1 bulk** |
| `eagain_arms` | residual WRITE arms after EAGAIN |
| `pt_bytes` | plain sealed (existing) |

## Baseline pin (operator)

- Matrix: `comparisons/tls-h2/run_matrix.sh` (or bastion equivalent)
- Cells of interest: h1s plain, h1s s4k, h1s s1m
- Machine class: local Darwin vs bastion Linux (do not mix)
- Git SHA: pin at first duty remeasure after this land
