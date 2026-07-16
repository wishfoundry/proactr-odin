# Benchmark suite

## Goals

1. Establish **baselines** for peer stacks before optimizing proactr.
2. Keep workloads **equal** across languages (same routes, body sizes, headers).
3. Prefer **Linux** numbers for publication (io_uring path).
4. Prefer **text/plain + text/html** (fortunes with DB + escape) over JSON or vapor gen-HTML.

## Workloads

| Suite | Purpose |
|-------|---------|
| **`comparisons/tfb`** | **Primary.** `/plaintext` + `/fortunes` only (no JSON) |
| `comparisons/empty-ok` | Wiring canary only — not a product baseline |

## Peers

| ID | Source | Build notes |
|----|--------|-------------|
| `laytan` | `vendor/laytan/odin-http` | `odin build` example empty server |
| `proactr` | this tree `http` + `proactr` | scaffold until host lands |
| `ntex` | `third_party/ntex` + peer crate in comparisons | `cargo build --release`; Linux: try `neon-uring` / compio feature |
| `compio` | `third_party/compio` + peer crate | completion I/O Rust baseline |
| `drogon` | `third_party/drogon` | CMake; needs trantor etc. |
| `asio` | `third_party/asio` | header-only Asio HTTP sample |
| `seastar` | `third_party/seastar` | heavy; optional / SKIP by default |
| `envoy` | `third_party/envoy` | proxy config in front of static cluster; optional |

## Methodology (default)

- Tool: `oha` or `wrk` (document which in results)
- Warmup + timed run
- Fixed concurrency (`-c`) and duration or request count
- Single machine, isolate CPU frequency if possible
- Report RPS, p50/p99 latency, errors

## Publishing

Write-ups land in `benchmarks/*.md` with date, kernel, CPU, and commit SHAs of this repo + submodules.
