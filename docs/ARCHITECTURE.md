# Architecture

## Reactor vs proactor

| | Reactor | Proactor |
|--|---------|----------|
| Kernel reports | FD ready | Op finished |
| Typical APIs | epoll, kqueue | IOCP, io_uring CQ |
| Who runs I/O | App after readiness | Kernel after submit |
| Buffer ownership | Often after ready | Submit through completion |

**proactr** is a portable completion-native package (not `core:nbio`). See [`PROACTR.md`](PROACTR.md).

## Handlers and middleware

- [`APP_CONTRACT.md`](APP_CONTRACT.md) — oneshot / long-lived handlers
- [`MIDDLEWARE_CONTRACT.md`](MIDDLEWARE_CONTRACT.md) — middleware rules
- [`PRODUCTION_CHECKLIST.md`](PRODUCTION_CHECKLIST.md) — multi-worker / shutdown edges

## Package layout

```
proactr/          # Ring, submit_*, ring_wait, platform backends
http/             # Server host, routing, TLS/H2, middleware
http2/            # H2 framing (sans host I/O)
client/           # Outbound HTTP (stream + proactr jobs)
quic/ http3/ qpack/
tls_server/ openssl_dynlib/
hpack/ huffman/
```

## Completion loop

```
loop:
  submit pending SQEs (batch)
  wait/peek CQEs (batch)
  for each CQE:
    dispatch by user_data → connection / client job
    maybe enqueue more SQEs
```

No intermediate “readable → recv” step on the Linux proactr hot path.

Darwin product sockets use a reactor kqueue for readiness; soft proactr harvest covers timers and outbound client ops (dual-wait when client work is pending).

## Op identity

In-flight work is a slab/op with kind + connection (or client job) reference. CQE `user_data` is a stable op id or tagged pointer. Host inbound connections stay untagged; outbound client jobs use a low-bit tag so demux never confuses the two.

## Server state (sketch)

```
Listening ──Accept──► Connected ──Recv──► Parsing ──► Handler
 ▲ │
 │ respond
 └──────── Send ◄──────────┘
```

TLS and H2 sit on the same host with ALPN; long-lived sessions (SSE/WS) are documented in [`SESSION_SSE.md`](SESSION_SSE.md) and [`TLS_H1.md`](TLS_H1.md).

## Client

Blocking facade for CLI/tests (`get` / `request`). In-handler outbound uses `get_async` bound to the inbound `Stream_Slot` (cancel on clean). See [`../client/README.md`](../client/README.md).

## Related docs

| Doc | Topic |
|-----|--------|
| [`PROACTR.md`](PROACTR.md) / [`PROACTR_RING.md`](PROACTR_RING.md) | Ring API |
| [`H2_ENGINE.md`](H2_ENGINE.md) | HTTP/2 host notes |
| [`TLS_H1.md`](TLS_H1.md) | TLS H1 path |
| [`BENCHMARKS.md`](BENCHMARKS.md) | Bench conventions |
