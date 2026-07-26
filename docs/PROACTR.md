# proactr — portable proactor package

Standalone completion I/O (not `core:nbio`). Same host-facing API on all first-class
OS backends so HTTP/demos share one model and we can benchmark against nbio later.

## Model

```
submit_*(ring, …)      → park Operation (buffer owned until free)
ring_submit / ring_wait → harvest Completions (+ software timers)
complete_apply         → mark Completed (or keep Submitted if COMPLETION_MORE)
operation_free         → backend cleanup + recycle id
```

Hosts never see readiness. **Buffers stay valid from submit until `operation_free`.**

## Types

| Name | Role |
|------|------|
| `Ring` | Per-worker proactor + software timer heap + soft CQ |
| `Operation` | Portable in-flight/completed unit (`Op` is a deprecated alias) |
| `Completion` | `{op_id, result, flags}` |
| `COMPLETION_MORE` | More results will follow (continuous accept) |

## Backends

| OS | Engine | Notes |
|----|--------|--------|
| Linux | **io_uring** | True proactor; fixed files/bufs via registration API |
| Windows | **IOCP** | WSASend/WSARecv/AcceptEx; `Win_Ov` table keyed by op id |
| Darwin/BSD | **kqueue façade** | Readiness → nonblocking perform → CQ (sockets nonblocking) |
| WASI | **host/pollable façade** | Park ops; `ring_wasi_complete` → portable `soft_cq` |

No generic stub backend. Unsupported OS (e.g. freestanding) has no platform file
and will not link.

**WASM:** WASI (`wasi_wasm32`) is the only port. Browser or other JS embeddings should
load WASI modules and post completions with `ring_wasi_complete` (no separate
`js_wasm32` / `ring_js_complete` backend). WASI posts into the **same soft_cq** as
software timers (`_soft_post`); `_ring_wait` sleeps the wait budget when empty so
portable `ring_wait` can re-fire timers.

### Prove WASI façade

| Demo | Command | Proves |
|------|---------|--------|
| WASI | `odin run examples/wasi_demo/build.odin -file` (`wasmtime` on PATH) | soft_cq, timers, host complete; Accept/Send/Recv **cannot** complete alone |

Real TCP/HTTP on WASM is **not** wired (needs wasi-sockets or an equivalent host bridge).

```odin
proactr.ring_backend_name()  // "io_uring" | "iocp" | "kqueue" | "wasi"
```

## Timeouts

Portable **software timers** on every backend (no per-timeout threads; no Linux-only
`IORING_OP_TIMEOUT` requirement).

```
submit_timeout  → min-heap by monotonic deadline
cancel_timeout  → soft_cq Completion{TIMEOUT_CANCELED}; never frees
expiry          → soft_cq Completion{TIMEOUT_ETIME}
ring_wait       → fire due → drain soft_cq → platform wait (remaining-time retry)
complete_apply → operation_free   // same as Recv/Send
```

| Result | Value | Meaning |
|--------|------:|---------|
| `TIMEOUT_ETIME` | -62 | timer expired |
| `TIMEOUT_CANCELED` | -125 | `cancel_timeout` |

Deadlines use a **monotonic** clock (`tick_now`), not wall time. Timers fire only
when `deadline <= now` (no multi-ms grace). Early platform wakes are handled by
`ring_wait` remaining-time retry, so short arms (e.g. 5 ms) stay meaningful.

Implementation: `proactr/timers.odin`.

## Accept

`submit_accept(..., continuous=false)` by default.

- `continuous=true` on Linux → multishot accept when supported  
- `continuous=true` on kqueue → re-arm + `COMPLETION_MORE`  
- Windows → one-shot (host re-submits)

## Registration (Linux only)

`REGISTER_FILES` / `REGISTER_BUFFERS` public API lives in **`platform_linux.odin`**
(`ring_has_fixed_files`, `ring_file_*`, `ring_register_recv_pool`, …).

Non-Linux builds get no-ops from **`registration_stub.odin`** (`#+build !linux`) that
return false / `.Unsupported` so hosts compile everywhere without dual homes in
`proactr.odin`.

## Crash recovery (HTTP host)

Thin proactor policy: **no per-op crash tax**. The HTTP host uses a minimal crash listener:

1. **Listener** — `server_shutdown_on_interrupt` installs SIGINT/SIGTERM; handler only sets `Server.closing` (signal-safe).
2. **Reaper** — workers notice after `ring_wait`, close listen sockets once, drain connections (existing path).
3. **Fatal** — `server_fatal` exits the process; OS reclaims FDs/rings; systemd/k8s restarts.

See `http/crash_listener.odin`.

## Related

- `docs/ARCHITECTURE.md` — reactor vs proactor, package split
- `docs/PROACTR_RING.md` — ring lifecycle, buffer rules
- `examples/wasi_demo/` — WASI soft_cq / host-complete proof
