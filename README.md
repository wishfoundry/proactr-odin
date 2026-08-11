# proactr-odin

HTTP server and client for [Odin](https://odin-lang.org), built on a **proactor** I/O core (`proactr`) with Linux **io_uring** as the primary backend.

Fork lineage of [laytan/odin-http](https://github.com/laytan/odin-http) (unmodified baseline under `vendor/laytan/odin-http`). Completions own the host loop — not readiness callbacks over `core:nbio`.

## Packages

| Package | Role |
|---------|------|
| `proactr` | Ring, submit/complete, platform backends |
| `http` | Server, routing, middleware, TLS/H2 host |
| `http2` | HTTP/2 framing and connection state |
| `client` | Outbound H1/H2/H3 (blocking + async on worker) |
| `quic` / `http3` / `qpack` | QUIC + HTTP/3 client stack |
| `tls_server` / `openssl_dynlib` | TLS via system OpenSSL ≥3.5 |
| `hpack` / `huffman` | HPACK |

## Requirements

- Recent Odin
- Linux 5.1+ recommended (io_uring); Darwin uses kqueue reactor for product sockets
- OpenSSL ≥ 3.5 for TLS / QUIC (`LIBRARY_PATH` / `DYLD_LIBRARY_PATH` as needed)

## Quick start

```bash
odin run examples/empty_ok
```

## Benchmarks

Published peer matrix: **[`benchmarks/TFB.md`](benchmarks/TFB.md)**  
(proactr · laytan · ntex · drogon · go — size ladder + fortunes).

```bash
./scripts/fetch_third_party.sh   # ntex reference + drogon source
# see benchmarks/README.md for full reproduce steps
```

Harnesses: `comparisons/tfb/`, `comparisons/tls-h2/`, `comparisons/empty-ok/` (wiring canary).

## Docs

| Doc | Audience |
|-----|----------|
| [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) | Layout and I/O model |
| [`docs/APP_CONTRACT.md`](docs/APP_CONTRACT.md) | Writing handlers |
| [`docs/MIDDLEWARE_CONTRACT.md`](docs/MIDDLEWARE_CONTRACT.md) | Middleware rules |
| [`docs/PROACTR.md`](docs/PROACTR.md) | Ring / completions |
| [`docs/PRODUCTION_CHECKLIST.md`](docs/PRODUCTION_CHECKLIST.md) | Multi-worker / ops edges |
| [`client/README.md`](client/README.md) | Outbound client API |

## Layout

```
proactr/          # I/O core
http/             # Server + middleware
client/           # HTTP client
quic/ http3/ qpack/
examples/
comparisons/      # Peer microservers + harnesses
benchmarks/       # Published numbers (TFB.md)
docs/
vendor/laytan/    # Upstream Odin baseline
third_party/      # ntex (ref) + drogon (build)
```

## License

MIT — see `LICENSE`. Vendor and third-party trees keep their own licenses.
