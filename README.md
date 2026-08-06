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
  middleware/            # Static file server (see docs/STATIC.md)
vendor/laytan/odin-http  # Unmodified upstream for baseline benches
third_party/             # Peer frameworks (git submodules)
  ntex/  drogon/  asio/  seastar/  compio/  envoy/
comparisons/             # Peer microservers + harness
benchmarks/              # Published numbers + methodology
docs/                    # Architecture notes (STATIC.md = static middleware guide)
```

## Status

**Scaffold / greenfield.** Core packages and third_party peers are in place for baseline work. The proactor ring and HTTP host are intentional stubs — not production.

## Dependencies

- Recent Odin master
- Linux kernel with io_uring (5.1+; 6.x preferred for modern ops)
- For peer benches: Rust (ntex, compio), CMake/C++ (drogon, asio, seastar, envoy)

## Quick start (once implemented)

```bash
# Fair empty-ok matrix (WORKERS=8 default; peers honor WORKERS)
./comparisons/empty-ok/proactr/build.sh
SERVERS="ntex laytan proactr" WORKERS=8 ./comparisons/empty-ok/run_bench.sh
```

## Benchmarks (primary: TFB-style)

**Published numbers:** [`benchmarks/TFB.md`](benchmarks/TFB.md) — ntex · drogon ·
laytan · proactr · go · size ladder + fortunes · **io_uring + kqueue**.

**Harness:** [`comparisons/tfb/`](comparisons/tfb/) — plain text/html only
(`/plaintext` size ladder + `/fortunes`). **No JSON**.

```bash
# Full product matrix (Linux bastion / Darwin)
SERVERS="ntex proactr laytan go drogon" \
  TESTS="plaintext s4k s64k s1m s4m fortunes" WORKERS=8 \
  ./comparisons/tfb/run_bench.sh
```

`comparisons/empty-ok/` is a wiring/ceiling canary — always pass the same `WORKERS`
to multi-worker peers (see `comparisons/empty-ok/README.md`).

### Peer sources

| Peer | Repo | Role |
|------|------|------|
| **laytan** | `vendor/laytan/odin-http` | Upstream nbio baseline |
| **ntex** | `third_party/ntex` | Rust HTTP (tokio / neon-uring) |
| **compio** | `third_party/compio` | Completion I/O runtime |
| **drogon** | `third_party/drogon` | C++ HTTP |
| **Boost.Asio** | `third_party/asio` | C++ async / proactor patterns |
| **Seastar** | `third_party/seastar` | Shared-nothing C++ |
| **Envoy** | `third_party/envoy` | L7 proxy overhead baseline |

```bash
./scripts/fetch_third_party.sh
```

## License

MIT (see `LICENSE`). Third-party and vendor trees keep their own licenses.
