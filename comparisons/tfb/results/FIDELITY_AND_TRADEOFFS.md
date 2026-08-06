# Goal fidelity + tradeoff benches (post writev/sendfile)

## Agents

| Skill | Role |
|-------|------|
| `proactr-goal-fidelity` | Frozen phase exits; FAIL if only multi_send/chunked stand-ins |
| `proactr-implement-wire` | Land real `IORING_OP_WRITEV` + `sendfile(2)` |

## Fidelity audit (code)

**Verdict: PASS (Linux)** — real mechanisms default on after hardening.

| Mechanism | Code | Default |
|-----------|------|---------|
| `IORING_OP_WRITEV` | `proactr/platform_linux.odin` `_prep_writev` | On for multi-segment assemble (`PLAN_WIRE_MODE=kernel`) |
| multi_send | sequential `submit_send` | Fallback / `PLAN_WIRE_MODE=fallback` |
| `sendfile(2)` | `_sendfile_drive` + soft complete / POLL | **On** with kernel wire + `plan_optimize` (prefer_sendfile only if optimize off); `PLAN_WIRE_SENDFILE=0` → chunked |
| file_chunked | pread+send 256 KiB | Fallback / env off |

Counters: `plan_wire_kernel_writev_total`, `plan_wire_multi_send_total`, `plan_wire_sendfile_total`, `plan_wire_copy_into_total`.

## Bastion tradeoff matrix (W=8, c=100, z=10s) — post-hardening

`/tmp/profile-matrix-harden2` — **no INVALID** cells. See `WRITE_MODE_HARDEN.md`.

| peer | tiny | assembled | blob | file | sse |
|------|-----:|----------:|-----:|-----:|----:|
| proactr-mat | 362k | 12.3k | 5.7k | 4.8k | 347k |
| proactr-opt WRITEV + chunked† | 376k | **15.6k** | 6.5k | 5.7k | 354k |
| proactr-opt-fallback multi_send | 363k | **15.7k** | 5.5k | 5.7k | 341k |
| proactr-opt-sendfile | 363k | 13.9k | 6.0k | **14.3k** | 356k |
| ntex | 365k | 12.2k | 6.5k | 6.4k | 351k |

† This run still had sendfile default-off on opt; defaults now enable sendfile so opt ≈ opt-sendfile on file.

### Tradeoff reading

| Question | Result |
|----------|--------|
| multi_send vs kernel WRITEV (assembled) | **tie** (~15.6k) after FIXED_FILE + close-defer |
| materialize preconcat vs gather | gather ~27% faster on 512 KiB assemble |
| file sendfile vs chunked vs mat | **14.3k / 5.7k / 4.8k** — sendfile wins decisively |
| vs ntex file full-read | sendfile **~2.2×** ntex |

### Hardening that unblocked sendfile

1. Defer `connection_close` while `wire.kind != .None` (`Wire_Kind`: Send / Writev / Sendfile)
2. Ignore **SIGPIPE** (sendfile was killing the process with exit 141)
3. `_sendfile_drive` batching + POLL on EAGAIN
4. Re-enable FIXED_FILE on WRITEV after lifecycle fix

## Fortunes (app-tier — unequal SQL)

`run_fortunes_fair.sh` FAIR=app, W=8, c=100, z=15s (prior run):

| peer | plaintext | fortunes |
|------|----------:|---------:|
| proactr-mat | 345k | **85.4k** |
| ntex | 357k | 10.7k |
| drogon | 283k | 7.6k |

**Label:** app-tier (proactr prepared ORDER BY + per-worker conn vs ntex mutex + prepare-per-req vs drogon open-per-req). Not pure framework ranking.

## Reproduce

```bash
SERVERS="proactr-mat proactr-opt proactr-opt-fallback proactr-opt-chunked ntex" \
  TESTS="tiny assembled blob file sse" \
  PLAN_WIRE_MODE=kernel WORKERS=8 \
  ./comparisons/tfb/run_profile_matrix.sh

# Force chunked file path
PLAN_WIRE_SENDFILE=0 PLAN_MODE=optimize ...

# Fortunes (declared unfair app work)
FAIR=app ./comparisons/tfb/run_fortunes_fair.sh
```
