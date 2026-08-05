# Goal fidelity + tradeoff benches (post writev/sendfile)

## Agents

| Skill | Role |
|-------|------|
| `proactr-goal-fidelity` | Frozen phase exits; FAIL if only multi_send/chunked stand-ins |
| `proactr-implement-wire` | Land real `IORING_OP_WRITEV` + `sendfile(2)` |

## Fidelity audit (code)

**Verdict: PASS (Linux)** — with production defaults noted.

| Mechanism | Code | Default |
|-----------|------|---------|
| `IORING_OP_WRITEV` | `proactr/platform_linux.odin` `_prep_writev` | On for multi-segment assemble (`PLAN_WIRE_MODE=kernel`) |
| multi_send | sequential `submit_send` | Fallback / `PLAN_WIRE_MODE=fallback` |
| `sendfile(2)` | `_sendfile_once` + soft complete / POLL | **Opt-in** `PLAN_WIRE_SENDFILE=1` (unstable under load) |
| file_chunked | pread+send | **Default** for opt file when sendfile off |

Counters: `plan_wire_kernel_writev_total`, `plan_wire_multi_send_total`, `plan_wire_sendfile_total`, `plan_wire_copy_into_total`.

## Bastion tradeoff matrix (W=8, c=100, z=10s)

`/tmp/profile-matrix-final` — **no INVALID** cells.

| peer | tiny | assembled | blob | file | sse |
|------|-----:|----------:|-----:|-----:|----:|
| proactr-mat (preconcat / materialize) | **379k** | 10637 | 4318 | 3287 | **355k** |
| proactr-opt kernel WRITEV (≥2 segs) | 355k | 9684 | 4293 | 6519† | 346k |
| proactr-opt-fallback multi_send / chunked | 377k | **14891** | 4309 | 6327† | 353k |
| ntex | 365k | 8459 | **5243** | 5219 | 345k |

† file: opt uses **chunked** by default (sendfile opt-in); not kernel sendfile unless `PLAN_WIRE_SENDFILE=1`.

### Tradeoff reading (what you asked for)

| Question | Result (this run) |
|----------|-------------------|
| multi_send vs kernel WRITEV (assembled) | **multi_send wins** (14.9k vs 9.7k) — WRITEV path needs more tuning |
| materialize preconcat vs multi_send | multi_send still faster than mat preconcat for 512 KiB assemble |
| file chunked (opt) vs full materialize | chunked **~2×** mat full-read (6.5k vs 3.3k) |
| vs ntex preconcat assemble | mat 10.6k ≥ ntex 8.5k; multi_send 14.9k > ntex |

**Honest caveat:** kernel sendfile is implemented but **not default** under load (process death with soft_post/POLL path). Enable with `PLAN_WIRE_SENDFILE=1` for experimental A/B only until hardened.

## Fortunes (app-tier — unequal SQL)

`run_fortunes_fair.sh` FAIR=app, W=8, c=100, z=15s:

| peer | plaintext | fortunes |
|------|----------:|---------:|
| proactr-mat | 345k | **85.4k** |
| ntex | 357k | 10.7k |
| drogon | 283k | 7.6k |

**Label:** app-tier (proactr prepared ORDER BY + per-worker conn vs ntex mutex + prepare-per-req vs drogon open-per-req). Not pure framework ranking.

## Reproduce

```bash
# Profile tradeoffs
SERVERS="proactr-mat proactr-opt proactr-opt-fallback ntex" \
  TESTS="tiny assembled blob file sse" \
  PLAN_WIRE_MODE=kernel WORKERS=8 \
  ./comparisons/tfb/run_profile_matrix.sh

# Experimental kernel sendfile
PLAN_WIRE_SENDFILE=1 PLAN_MODE=optimize ...

# Fortunes (declared unfair app work)
FAIR=app ./comparisons/tfb/run_fortunes_fair.sh
```
