# Planner A/B harness

Measures whether **per-handler plan policy** chooses the right transport shape
before (and after) the executor is wired.

| Suite | Question |
|-------|----------|
| `comparisons/tfb` | Ceiling RPS vs peers |
| `comparisons/load` | Product SLOs under target load |
| **`comparisons/plan`** | Does optimize vs materialize change *plan ops per route*? |

Design north star: [`docs/RESPONSE_COMMAND_PLANNER.md`](../../docs/RESPONSE_COMMAND_PLANNER.md).

## What this proves today (Phase 0)

The demo server still **sends** with the existing single-buffer path (`body_set` /
`respond_file` / `body_reserve`). On every request it also builds `Response_Cmd`s,
runs **shadow** `plan_body` / `plan_body_materialize_only`, and records counters
on `/metrics`.

So A/B can already show:

- `PLAN_MODE=materialize` → almost all body routes → `plan_materialize_total`
- `PLAN_MODE=optimize` → assembled → `plan_writev_total`, file → `plan_sendfile_total`
- tiny/gen stay materialize under optimize (profile bias)
- SSE never increments writev/sendfile (`stream_responses_total` only)

When Phase 3–4 wire Writev/Sendfile, the same harness measures **RPS/CPU** wins
on top of these counters.

## Routes (profiles)

| Path | Profile | Intent cmds | Optimize expect |
|------|---------|-------------|-----------------|
| `GET /api/tiny` (`/plaintext`) | tiny | 1× Static 13 B | materialize |
| `GET /gen/ok` | gen | Bytes + body_reserve | materialize + patch_cl |
| `GET /static/assembled` | assembled | 8× Static 64 KiB | **Writev** |
| `GET /static/blob/1m` | blob | 1× Static 1 MiB | Write_Slice (single; not multi-iov) or materialize policy |
| `GET /file/1m` | file | File 1 MiB | **Sendfile** (+ headers Write_Slice) |
| `GET /sse` | stream | *(no plan_body)* | stream_responses only |
| `GET /metrics` | — | counters | — |
| `GET /health` | — | liveness | — |

## Env

| Var | Default | Meaning |
|-----|---------|---------|
| `PORT` | `19090` | Listen |
| `WORKERS` | `1` | Rings / threads |
| `PLAN_MODE` | `materialize` | `materialize` \| `optimize` |
| `PLAN_SENDFILE_OK` | `1` | Allow sendfile in optimize |
| `PLAN_COPY_BUDGET` | `4096` | Global preferred_copy_budget |
| `PLAN_MAX_IOVECS` | `1024` | Gather budget |
| `PLAN_DATA_DIR` | `/tmp/proactr-plan-bench` | Generated `file-1m.bin` |

## Build & manual smoke

```bash
odin build comparisons/plan/server -out:comparisons/plan/server/plan-bench.bin -o:speed

PORT=19090 WORKERS=2 PLAN_MODE=optimize ./comparisons/plan/server/plan-bench.bin &
curl -s http://127.0.0.1:19090/health
curl -s http://127.0.0.1:19090/static/assembled | wc -c   # 524288
curl -s http://127.0.0.1:19090/metrics
```

## A/B script

```bash
# Default: short iso scenarios, modes materialize then optimize
./comparisons/plan/run_plan_ab.sh

# Subset
SCENARIOS="iso_tiny iso_assembled iso_file" ./comparisons/plan/run_plan_ab.sh

# Longer / busier
BENCH_C=50 BENCH_Z=10s WORKERS=4 ./comparisons/plan/run_plan_ab.sh
```

Needs **bombardier** or **oha** on `PATH`.

Logs: `LOGDIR` (default `/tmp/proactr-plan-logs`).

### Scenarios

| ID | Path | Default c / z | Mechanism check (optimize vs materialize) |
|----|------|---------------|-------------------------------------------|
| `iso_tiny` | `/api/tiny` | 50 / 5s | both materialize; no writev/sendfile spike |
| `iso_gen` | `/gen/ok` | 50 / 5s | materialize + patch_cl |
| `iso_assembled` | `/static/assembled` | 20 / 5s | **writev ≫ 0 only in optimize** |
| `iso_blob` | `/static/blob/1m` | 10 / 5s | materialize or single-slice plan |
| `iso_file` | `/file/1m` | 10 / 5s | **sendfile ≫ 0 only in optimize** |
| `iso_sse` | `/sse` | 50 / 5s | stream only; plan_responses not required |
| `mixed_seq` | sequential phases | 20 / short | all routes get hits |

### Pass / fail (mechanism)

Hard fails (script non-zero) when:

| Mode | Condition |
|------|-----------|
| materialize after load | `plan_writev_total > 0` or `plan_sendfile_total > 0` on body routes that ran plan |
| optimize after `iso_assembled` | `plan_writev_total == 0` (policy not choosing gather) |
| optimize after `iso_file` | `plan_sendfile_total == 0` |
| either | loadgen non-2xx errors, or server died |

RPS/p99 are **informational** until Phase 3+ (wire still materializes).

### Summary table

Script prints a markdown-ish comparison of counters and loadgen RPS/p99 for
mode A vs B per scenario.

## Interpreting results

- **Counters diverge, RPS flat** (Phase 0–1): expected. Policy works; executor not using Writev/Sendfile yet.
- **Counters diverge, RPS/CPU improve** (Phase 3–4): meaningful per-handler optimize.
- **optimize assembled still materialize**: check `PLAN_COPY_BUDGET`, slice count, profile `prefer_gather`.
- **tiny gains writev under optimize**: profile bug (tiny should force materialize).

## Layout

```
comparisons/plan/
  README.md
  run_plan_ab.sh
  server/main.odin
  server/plan-bench.bin   # build output (gitignored if you prefer)
```
