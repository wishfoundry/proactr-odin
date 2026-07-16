# proactr-odin

A **proactor-first** fork lineage of [laytan/odin-http](https://github.com/laytan/odin-http), optimized for **io_uring** completion-based I/O on Linux.

| | |
|--|--|
| **Name** | **proactr-odin** |
| **Upstream baseline** | `vendor/laytan/odin-http` ([laytan/odin-http](https://github.com/laytan/odin-http)) |
| **I/O model** | Proactor (submit op → completion CQ) — not readiness/reactor |
| **Primary target** | Linux + io_uring |
| **HTTP package** | `http` (forked API surface; host driven by `proactr`) |
| **I/O package** | `proactr` |

Related work: [vapor-http](https://git.mere.cloud/bngreer/odin-http) explores multi-protocol hosts on reactor/nbio demux. This tree restarts from laytan with an explicit proactor core.

## Why proactor + io_uring

laytan/odin-http (and `core:nbio`) already use io_uring on Linux, but the programming model is still largely **callback-over-tick** and cross-platform readiness-shaped. A true proactor core:

1. **Submits** work (`accept`, `recv`, `send`, `close`, file ops) into an SQ
2. **Reaps** completions from a CQ (batch-friendly, zero readiness re-arm)
3. Owns buffers and op state until completion (no “is it ready?” race)
4. Maps cleanly to IOCP on Windows later; Darwin may stay kqueue/reactor-backed

```
  app / http.Server
         │
         ▼
     proactr.Ring          ← submit ops, poll completions
         │
    ┌────┴────┐
 io_uring   (stubs: IOCP / kqueue later)
```

## Layout

```
proactr/                 # Proactor I/O core (io_uring-first)
http/                    # HTTP/1.1 server+types on proactr (fork of laytan APIs)
vendor/laytan/odin-http  # Unmodified upstream for baseline benches
third_party/             # Peer frameworks (git submodules)
  ntex/  drogon/  asio/  seastar/  compio/  envoy/
comparisons/             # Peer microservers + harness
benchmarks/              # Published numbers + methodology
docs/                    # Architecture notes
```

## Status

**Scaffold / greenfield.** Core packages and third_party peers are in place for baseline work. The proactor ring and HTTP host are intentional stubs — not production.

## Dependencies

- Recent Odin master
- Linux kernel with io_uring (5.1+; 6.x preferred for modern ops)
- For peer benches: Rust (ntex, compio), CMake/C++ (drogon, asio, seastar, envoy)

## Quick start (once implemented)

```bash
# Build empty-ok proactr server (planned)
odin build comparisons/empty-ok/proactr -out:comparisons/empty-ok/proactr/server.bin -o:speed

# Run baseline matrix (Linux)
./comparisons/empty-ok/run_bench.sh
```

## Benchmark peers

| Peer | Repo | Role in suite |
|------|------|----------------|
| **laytan** | vendored `vendor/laytan/odin-http` | Upstream nbio / reactor-shaped baseline |
| **ntex** | `third_party/ntex` | Rust composable services (tokio / neon-uring) |
| **compio** | `third_party/compio` | Rust completion I/O (io_uring / IOCP) |
| **drogon** | `third_party/drogon` | C++ high-perf HTTP |
| **Boost.Asio** | `third_party/asio` | C++ async model (proactor-capable) |
| **Seastar** | `third_party/seastar` | Shared-nothing, DPDK-class C++ |
| **Envoy** | `third_party/envoy` | Production L7 proxy baseline |

Init / update peers:

```bash
git submodule update --init --depth 1 --recursive third_party
# Envoy/Seastar pull large recursive trees — prefer:
./scripts/fetch_third_party.sh
```

## License

MIT (see `LICENSE`). Third-party and vendor trees keep their own licenses.
