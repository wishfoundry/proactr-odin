# Write-mode performance + quality hardening

**Date:** 2026-08-05 · **Host:** ranch-bastion · W=8 c=100 z=10s  
**Artifacts:** `/tmp/profile-matrix-harden2/summary.tsv`

## What broke (and what fixed it)

| Failure mode | Root cause | Fix |
|--------------|------------|-----|
| opt silent death under load (WRITEV/sendfile) | `connection_close` only deferred on `pending_send`; kernel WRITEV/sendfile leave it empty → close frees conn/iovecs under in-flight SQE | `_conn_wire_in_flight` = `wire.kind != .None` (`Wire_Kind`: Send / Writev / Sendfile) |
| sendfile process exit 141 (SIGPIPE) | synchronous `sendfile(2)` raises SIGPIPE on client disconnect; io_uring SEND returns -EPIPE without killing | `server_ignore_sigpipe()` in `serve` / interrupt install |
| WRITEV ≪ multi_send on assembled | raw fd only (post “stabilize”) + lifecycle noise | re-enable FIXED_FILE after close-defer; WRITEV now ≈ multi_send |
| sendfile soft_post thrash | one soft_cq post per short transfer | `_sendfile_drive` batches up to 1 MiB / EAGAIN then soft-completes |
| partial WRITEV submit fail → hard close | no graceful path | rebuild multi_send queue from remaining iovecs |
| chunked too chatty | 64 KiB pread+send | `FILE_SEND_CHUNK` → 256 KiB |

## Bastion matrix (all cells VALID)

| peer | mechanism | tiny | assembled | blob | file | sse |
|------|-----------|-----:|----------:|-----:|-----:|----:|
| proactr-mat | materialize / preconcat / full-read | 362k | 12.3k | 5.7k | 4.8k | 347k |
| proactr-opt | **kernel WRITEV** + **chunked**† | 376k | **15.6k** | 6.5k | 5.7k | 354k |
| proactr-opt-fallback | multi_send + chunked | 363k | **15.7k** | 5.5k | 5.7k | 341k |
| proactr-opt-sendfile | WRITEV + **sendfile(2)** | 363k | 13.9k | 6.0k | **14.3k** | 356k |
| ntex | preconcat / full-read | 365k | 12.2k | 6.5k | 6.4k | 351k |

† harden2 matrix used opt with sendfile still env-default-off; after this report, Linux kernel default is **sendfile on** (`PLAN_WIRE_SENDFILE=0` forces chunked). Peer `proactr-opt-chunked` A/Bs that.

### Tradeoff reading

| Question | Result |
|----------|--------|
| multi_send vs kernel WRITEV (assembled) | **tie** (~15.6–15.7k) after FIXED_FILE + lifecycle |
| materialize preconcat vs gather | gather ~27% faster on 512 KiB assembled |
| file: sendfile vs chunked vs mat | **sendfile 14.3k** ≫ chunked 5.7k ≫ mat 4.8k; **~2.2× ntex** |
| blob (1 MiB static) | peers similar; mat/opt not sendfile (in-memory) |
| quality under load | no INVALID; sendfile survives c=100 after SIGPIPE ignore |

## Defaults (post-hardening)

| Mode | When |
|------|------|
| materialize | `PLAN_MODE=materialize` / no prefer_* |
| kernel WRITEV | Linux + `PLAN_WIRE_MODE=kernel` + multi-seg assemble |
| multi_send | non-Linux, `PLAN_WIRE_MODE=fallback`, or WRITEV Unsupported |
| sendfile(2) | Linux + kernel wire; plan_optimize keeps Sendfile (prefer_sendfile only if optimize off) |
| file_chunked | `PLAN_WIRE_SENDFILE=0` or non-Linux |

## Reproduce

```bash
SERVERS="proactr-mat proactr-opt proactr-opt-fallback proactr-opt-chunked ntex" \
  TESTS="tiny assembled blob file sse" WORKERS=8 BENCH_Z=10s \
  FORCE_REBUILD=1 ./comparisons/tfb/run_profile_matrix.sh
```
