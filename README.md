# proactr-odin

HTTP server and client for [Odin](https://odin-lang.org), on a **proactor** I/O core
with Linux **io_uring** as the primary backend.

Fork lineage of [laytan/odin-http](https://github.com/laytan/odin-http)
(baseline under `vendor/laytan/odin-http`).

## Packages

| Package | Role |
|---------|------|
| `proactr` | Ring, submit/complete |
| `http` | Server, routing, middleware, TLS/H2 |
| `http2` | H2 framing |
| `client` | Outbound H1/H2/H3 |
| `quic` / `http3` / `qpack` | QUIC + HTTP/3 |
| `tls_server` / `openssl_dynlib` | OpenSSL ≥3.5 dynlib |
| `hpack` / `huffman` | HPACK |

## Requirements

- Recent Odin
- Linux 5.1+ recommended; Darwin uses kqueue for product sockets
- OpenSSL ≥3.5 for TLS/QUIC

```bash
odin run examples/empty_ok
```

## Benchmarks

[`benchmarks/TFB.md`](benchmarks/TFB.md) — peer matrix (io_uring + kqueue).  
Harnesses: `comparisons/tfb/`, `comparisons/tls-h2/`.

```bash
./scripts/fetch_third_party.sh   # ntex ref + drogon source
```

## Docs

| Doc | |
|-----|--|
| [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) | Layout |
| [`docs/APP_CONTRACT.md`](docs/APP_CONTRACT.md) | Handlers |
| [`docs/MIDDLEWARE_CONTRACT.md`](docs/MIDDLEWARE_CONTRACT.md) | Middleware |
| [`docs/PROACTR.md`](docs/PROACTR.md) | Ring API |
| [`client/README.md`](client/README.md) | Client API |

## License

MIT — see `LICENSE`.
