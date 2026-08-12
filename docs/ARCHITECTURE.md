# Architecture

Proactor I/O (`proactr`) drives the HTTP host (`http`). Completions own the loop on Linux (io_uring); Darwin product sockets use a kqueue reactor with soft proactr harvest for timers and outbound client work.

## Packages

| Package | Role |
|---------|------|
| `proactr` | Ring, submit/complete, platform backends |
| `http` | Server, routing, middleware, TLS/H2 host |
| `http2` | H2 framing (sans host I/O) |
| `client` | Outbound H1/H2/H3 |
| `quic` / `http3` / `qpack` | QUIC + HTTP/3 |
| `tls_server` / `openssl_dynlib` | TLS via system OpenSSL ≥3.5 |
| `hpack` / `huffman` | HPACK |

## Handlers

See [`APP_CONTRACT.md`](APP_CONTRACT.md) and [`MIDDLEWARE_CONTRACT.md`](MIDDLEWARE_CONTRACT.md).

## Ring

See [`PROACTR.md`](PROACTR.md).
