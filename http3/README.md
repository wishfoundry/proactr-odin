# http3

HTTP/3 framing and connection engine (over package `quic` + `qpack`).

**Provenance:** copied from vapor-http into proactr-odin for the client-driven HTTP/3 track.

## Deps
- `../quic` (temporary BoringSSL for TLS)
- `../qpack` (+ `huffman`)
- No package `http` (server) — frame errors are local to this package

## Not yet
- Product client package
- Product H3 server host wired into proactr `http` server
