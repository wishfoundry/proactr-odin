# Planner A/B harness

Measures whether **per-handler plan policy** chooses the right transport shape
before (and after) the executor is wired.

| Suite | Question |
|-------|----------|
| `comparisons/tfb` | Ceiling RPS vs peers |
| `comparisons/load` | Product SLOs under target load |
| **`comparisons/plan`** | Does optimize vs materialize change *plan ops per route*? |

Design north star: [`docs/RESPONSE_COMMAND_PLANNER.md`](../../docs/RESPONSE_COMMAND_PLANNER.md).

## What this proves today (Phase 4)

- **Shadow** counters (`plan_writev_total`, `plan_sendfile_total`, …): pure `plan_body` policy per route
- **Wire** counters (`plan_wire_writev_total`, `plan_wire_materialize_total`,
  `plan_wire_copy_into_total`, `plan_wire_sendfile_total`): what the host executor
  actually did (`Server_Opts.plan_optimize` + route profiles)

| Mode | Wire behavior |
|------|----------------|
| `PLAN_MODE=materialize` | `plan_optimize=false`; multi-static routes still **materialize** (copy into `resp_buf`); `/file/1m` uses preloaded bytes |
| `PLAN_MODE=optimize` | `plan_optimize=true`; assembled → **multi-buffer Writev-style**; `/file/1m` → `body_file` + **chunked pread stream** (`plan_wire_copy_into`) |

So A/B shows:

- materialize → shadow + wire materialize; `plan_wire_writev_total == 0`, `plan_wire_copy_into_total == 0`
- optimize → assembled → shadow `plan_writev` **and** `plan_wire_writev`
- optimize → file → shadow `plan_sendfile` **and** `plan_wire_copy_into` (chunked; kernel sendfile reserved)
- tiny/gen stay materialize under optimize (profile bias)
- SSE never increments writev/sendfile (`stream_responses_total` only)

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

RPS/p99: wire Writev may show wins on `iso_assembled`; file path avoids full 1 MiB
`resp_buf` materialize under optimize (`plan_wire_copy_into`). Kernel sendfile still
future (`plan_wire_sendfile` reserved).

### Summary table

Script prints a markdown-ish comparison of counters and loadgen RPS/p99 for
mode A vs B per scenario.

## Interpreting results

- **Shadow writev, wire materialize**: optimize off or profile missing `prefer_gather`.
- **Shadow + wire writev on assembled (Phase 3)**: multi-buffer path is live.
- **Wire writev under materialize mode**: bug (profile/optimize gate).
- **optimize assembled still materialize**: check `PLAN_COPY_BUDGET`, slice count, profile `prefer_gather`, `plan_optimize`.
- **tiny gains writev under optimize**: profile bug (tiny should force materialize).

## Layout

```
comparisons/plan/
  README.md
  run_plan_ab.sh
  server/main.odin
  server/plan-bench.bin   # build output (gitignored if you prefer)
```
