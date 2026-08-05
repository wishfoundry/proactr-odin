# Benchmarks

## Product TFB suite

**[TFB.md](TFB.md)** — consolidate benchmarks on kqueue and io_uring:

- Peers: **ntex**, **drogon**, **laytan**, **proactr**, **go**
- Routes: plaintext size ladder + `/fortunes`
- Hosts: **io_uring** (Ubuntu) and **kqueue** (Darwin)

Harness: `comparisons/tfb/run_bench.sh`.

## Planner A/B (experiment)

**[`comparisons/plan/`](../comparisons/plan/README.md)** — per-handler body profiles + shadow `plan_body` counters:

- Modes: `PLAN_MODE=materialize` vs `optimize`
- Routes: tiny / gen / assembled (Writev) / blob / file (Sendfile) / SSE
- Harness: `./comparisons/plan/run_plan_ab.sh`

Does not replace TFB; answers “did the planner choose the right ops?” before wire-level gather/sendfile.
