# third_party

Peer frameworks used for **architecture reference** and **benchmark baselines**.  
Tracked as **git submodules** (shallow preferred). Do not edit upstream trees except local uncommitted experiment patches.

| Directory | Upstream | Language | Why here |
|-----------|----------|----------|----------|
| `ntex/` | [ntex-rs/ntex](https://github.com/ntex-rs/ntex) | Rust | Fast composable HTTP; tokio / neon-uring / compio runtimes |
| `compio/` | [compio-rs/compio](https://github.com/compio-rs/compio) | Rust | Completion-based async runtime (io_uring / IOCP) |
| `drogon/` | [drogonframework/drogon](https://github.com/drogonframework/drogon) | C++ | High-RPS C++ HTTP framework |
| `asio/` | [boostorg/asio](https://github.com/boostorg/asio) | C++ | Boost.Asio async / proactor patterns |
| `seastar/` | [scylladb/seastar](https://github.com/scylladb/seastar) | C++ | Shared-nothing, per-core networking |
| `envoy/` | [envoyproxy/envoy](https://github.com/envoyproxy/envoy) | C++ | Production L7 proxy baseline |

## Fetch

```bash
# Preferred: scripted shallow fetch
./scripts/fetch_third_party.sh

# Or all submodules (Envoy/Seastar are large)
git submodule update --init --depth 1 third_party/ntex
git submodule update --init --depth 1 third_party/compio
git submodule update --init --depth 1 third_party/drogon
git submodule update --init --depth 1 third_party/asio
# Optional heavy peers:
git submodule update --init --depth 1 third_party/seastar
git submodule update --init --depth 1 third_party/envoy
```

**Note:** Envoy and Seastar recursive deps can exceed several GB. The fetch script skips recursive init by default. Build only what you need for a given bench peer.

## Build peers for benches

Peer **microservers** live under `comparisons/`, not inside these upstream trees.  
Upstream is for reading implementations and optionally pinning exact SHAs for reproducibility.
