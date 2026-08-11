# Benchmark suite

## Goals

1. Establish **baselines** for peer stacks before optimizing proactr.
2. Keep workloads **equal** across languages (same routes, body sizes, headers).
3. Prefer **Linux** numbers for publication (io_uring path).
4. Prefer **text/plain + text/html** (fortunes with DB + escape) over JSON or vapor gen-HTML.

## Workloads

| Suite | Purpose |
|-------|---------|
| **`comparisons/tfb`** | **Ceiling.** Size ladder + fortunes; max RPS peer matrix |
| **`comparisons/load`** | **Product readiness.** Target load + **latency/error SLOs** (pass/fail) |
| `comparisons/empty-ok` | Wiring / empty-OK canary — **pass `WORKERS`**; not the product baseline |

See `comparisons/load/SCENARIOS.md` for readiness scenarios (`api_steady`, `spike`, `mixed`, `soak`, …).

## Peers (published set)

| ID | Source | Build notes |
|----|--------|-------------|
| `proactr` | this tree | io_uring host on Linux |
| `laytan` | `vendor/laytan/odin-http` | nbio baseline |
| `ntex` | crates.io (`comparisons/*/ntex`) | neon-uring on Linux |
| `drogon` | `third_party/drogon` | CMake peer builds |
| `go` | `comparisons/*/go` | `net/http` |

Published tables: [`benchmarks/TFB.md`](../benchmarks/TFB.md).

## Methodology

### Ceiling (`tfb` / `empty-ok`)

- Tool: `bombardier` (preferred), `oha`, or `wrk`
- Warmup + timed run; fixed concurrency
- **Same `WORKERS`** for multi-worker peers (default 8)
- Report RPS, p50/p99, errors

### Readiness (`load`)

- Moderate concurrency (not max RPS chase)
- **Pass/fail SLOs**: p99 budget, zero errors; optional RPS floor
- Scenarios: steady API, busy API, medium/bulk payload, spike, ramp, mixed, soak
- Exit non-zero on hard SLO failure

Never compare 1-worker proactr against multi-core peers. Prefer multi-host loadgen for production claims.

## Publishing

**Product TFB report:** [`benchmarks/TFB.md`](../benchmarks/TFB.md) (single matrix for
ntex / drogon / laytan / proactr / go · sizes + fortunes · io_uring + kqueue).

Other write-ups (timers, experiments) stay as dated files under `benchmarks/`.
