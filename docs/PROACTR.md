# proactr

Portable completion I/O (not `core:nbio`).

```
submit_*(ring, …) → park Operation
ring_wait → Completions (+ software timers)
complete_apply → Completed
operation_free → recycle
```

Buffers stay valid from submit until `operation_free`.

## Backends

| OS | Engine |
|----|--------|
| Linux | io_uring |
| Windows | IOCP |
| Darwin/BSD | kqueue façade |
| WASI | host/pollable + soft CQ |

```odin
proactr.ring_backend_name() // "io_uring" | "iocp" | "kqueue" | "wasi"
```

## Timeouts

Software timers on every backend (`submit_timeout` / `cancel_timeout`).  
`TIMEOUT_ETIME` (−62) expired; `TIMEOUT_CANCELED` (−125) canceled. Monotonic clock.
