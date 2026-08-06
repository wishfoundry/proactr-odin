# Architecture: proactor core for odin-http

## Reactor vs proactor

| | Reactor | Proactor |
|--|---------|----------|
| Kernel tells you | “FD ready” | “Op finished (result)” |
| Typical APIs | epoll, kqueue, `poll` | IOCP, io_uring CQ |
| Who issues the I/O | App, after readiness | App submits; kernel runs it |
| Buffer ownership | Often after ready | At submit time through completion |
| Re-arm | Often every readiness cycle | Op is one-shot (or multi-shot CQEs) |

**laytan / `core:nbio`:** on Linux uses io_uring under the hood, but the public model is still “queue callback ops + `tick`” shared with readiness-backed OS paths. Useful, portable, not optimized as a pure proactor surface.

**proactr:** portable completion-native package (separate from `core:nbio`). See `docs/PROACTR.md`.

## Package split

```
proactr/                    # standalone proactor (compare vs nbio later)
  proactr.odin              # Ring, Op, Completion, submit_*, ring_wait
  platform_linux.odin       # io_uring (true proactor)
  platform_windows.odin     # IOCP (true proactor)
  platform_kqueue.odin      # kqueue façade (Darwin/BSD)
  platform_wasi.odin        # WASI host façade (only WASM port; no js_wasm32)
  timers.odin / registration_stub.odin

http/
  # Protocol + host; driven by proactr completions
  middleware/           # Static files etc. (import as middleware; see http/middleware/STATIC.md)
```

## Completion loop (target)

```
loop:
  submit pending SQEs (batch)
  wait/peek CQEs (batch)
  for each CQE:
    dispatch by user_data → connection state machine
    maybe enqueue more SQEs (recv after accept, send after respond, …)
```

No intermediate “readable → recv” step on the hot path.

## Op user data

Prefer a tagged pointer or dense `Op_Id` into a slab:

```odin
Op_Kind :: enum u8 { Accept, Recv, Send, Close, Cancel, … }
Op :: struct {
    kind:   Op_Kind,
    conn:   ^Conn,   // or index
    // buffer views, iovecs, flags …
}
```

`user_data` in the SQE/CQE is the stable id or pointer to `Op`.

## HTTP host state machine (sketch)

```
Listening ──Accept──► Connected ──Recv──► Parsing ──► Handler
                              ▲                         │
                              │                      respond
                              └──────── Send ◄──────────┘
                                         │
                                      Close?
```

Handlers stay synchronous w.r.t. the connection’s logical request (like laytan), but I/O is always async-completion under the hood.

## Multi-worker

v1: one ring per worker thread, SO_REUSEPORT listen sockets (classic Seastar/ntex style).
Shared accept via multishot accept on one ring is a later option.

## Non-goals (near term)

- HTTP/2 / HTTP/3 (I have a different fork: vapor-http that owns that experiment space)
- Drop-in `core:nbio` API compatibility (packages stay separate for comparison)
- Fixed files/buffers on non-Linux backends
// Non-Linux: fixed files / registered recv pool are unavailable.
// Real implementations live only in platform_linux.odin.
