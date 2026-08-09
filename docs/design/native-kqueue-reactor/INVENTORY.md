# Plan R2 P0 — `proactr.submit_*` inventory (`http/`)

**Date:** 2026-08-09  
**Scope:** every direct `proactr.submit_*` call site under `http/`, with I/O owner after Darwin reactor cutover.  
**Status:** **P5 full wait ownership SHIPPED** on Darwin.

## Darwin product I/O (P5)

| Path | Darwin owner |
|------|----------------|
| Worker wait | `server_loop_reactor` — reactor kqueue (product sockets) + `ring_wait(0)` soft_cq (timers D5) |
| Accept | `reactor_host_submit_accept` — EVFILT_READ listen |
| Recv (TLS CT + clear) | `reactor_host_arm_recv` — EVFILT_READ; dispatch by fd → `td.conns` |
| Residual / clear WRITE | `reactor_host_submit_send` — EVFILT_WRITE native (no `proactr.submit_send`) |
| Close | `reactor_host_close` — EV_DELETE + sync `net.close` + destroy |
| H1/H2 TLS flush | `reactor_tls_flush` residual-first until-EAGAIN |
| HS / stream residual | residual-first + native WRITE arm |
| Timers | proactr software timers → soft_cq (D5 keep) |

Linux (`ODIN_OS != .Darwin`) remains full proactor-uring; dual-CT unchanged.

---

## R2 P5 completion (this land)

1. Separate per-worker **reactor kqueue** (never share udata with proactr op_ids).
2. Accept / recv / write / close native; no Darwin product `proactr.submit_accept/recv/send/close`.
3. Timers only via soft_cq drain merged into worker loop.
4. **Reentrancy guards:** defer `clean_request_loop` after sync oneshot finish; TLS PT inject without nested `scanner_on_bytes`.
5. Dispatch by **fd → map** (not Connection* udata) + purge filters on close.
6. Duty: `soft_cq_send_completes=0` on TLS bulk matrix cells.

### Crash classes fixed

| Class | Fix |
|-------|-----|
| Shared kq op_id vs conn udata | Separate reactor kqueue |
| Stale kevent after close / slab reuse | fd-map dispatch + EV_DELETE when armed |
| EV_DELETE ENOENT dropping other arms | Delete-only flush; ignore ENOENT |
| Sync finish nested in scanner | `reactor_defer_clean` + drain after kevent batch |
| TLS inject nested `scanner_on_bytes` | `reactor_scan_injected` + tail rescan |

---

## Direct call sites

| # | File | Symbol / context | Op | Darwin owner |
|---|------|------------------|-----|--------------|
| 1–2 | `http/server.odin` | `host_submit_accept` | `submit_accept` | **reactor** (`when` Linux only for proactr) |
| 3 | `http/server.odin` | `host_submit_recv` clear | `submit_recv` | **reactor** |
| 4 | `http/server.odin` | `connection_close` | `submit_close` | **reactor sync close** |
| 5 | `http/tls_host.odin` | `tls_host_arm_recv` | `submit_recv` | **reactor** |
| 6 | `http/wire.odin` | `host_submit_send` | `submit_send` | **reactor WRITE arm** |
| 7–8 | `http/wire.odin` | writev / sendfile | — | clear/Linux (unchanged) |
| 9 | `http/session.odin` | session timer | `submit_timeout` | **proactr timers (D5)** |

Linux still uses proactr submit_* in the `else` branches of the same symbols.

---

## Metrics

| Key | Meaning |
|-----|---------|
| `io_engine` | `reactor-kqueue` (Darwin P5), `proactor-uring` (Linux) |
| `io_engine_note` | full wait ownership note |
| `soft_cq_send_completes` | **0** expected for pure Darwin TLS bulk cells |
| `seal_windows` / `kevent_turns` | reactor flush duty |
| `eagain_arms` | residual WRITE arms |

## Plan status

**P0–P5 complete** on Darwin (product socket façade deleted; timers remain in proactr).
