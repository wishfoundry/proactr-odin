# Benchmarks

## Peers we actually run

| Peer | Stack | Where |
|------|--------|--------|
| **proactr** | this tree | `comparisons/tfb/proactr`, `tls-h2/proactr` |
| **laytan** | vendored odin-http / nbio | `vendor/laytan` |
| **ntex** | Rust (crates.io; neon-uring on Linux) | `comparisons/*/ntex` |
| **drogon** | C++ (built from `third_party/drogon`) | `comparisons/*/drogon` |
| **go** | `net/http` | `comparisons/*/go` |

No Asio / Seastar / Envoy / Compio trees in-repo. Optional experimental peers
under `comparisons/` may still exist as local crates; they are not the published set.

## Numbers

**[TFB.md](TFB.md)** — last published size-ladder + fortunes RPS (io_uring + kqueue).

Re-run:

```bash
./scripts/fetch_third_party.sh
./comparisons/tfb/schema/prepare.sh
# build peers as needed (ntex: cargo; drogon: comparisons/tfb/drogon/build.sh; go: go build)
SERVERS="proactr laytan ntex drogon go" WORKERS=8 \
  TESTS="plaintext s4k s64k s1m s4m fortunes" \
  ./comparisons/tfb/run_peer_matrix.sh
```

TLS/H2 matrix: `comparisons/tls-h2/` (peers: proactr, ntex, drogon, go).

Empty-OK wiring canary: `comparisons/empty-ok/` (not product numbers).
