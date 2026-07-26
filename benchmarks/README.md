# Benchmarks

## Product TFB suite

**[TFB.md](TFB.md)** — consolidate benchmarks on kqueue and io_uring:

- Peers: **ntex**, **drogon**, **laytan**, **proactr**, **go**
- Routes: plaintext size ladder + `/fortunes`
- Hosts: **io_uring** (Ubuntu) and **kqueue** (Darwin)

Harness: `comparisons/tfb/run_bench.sh`.
