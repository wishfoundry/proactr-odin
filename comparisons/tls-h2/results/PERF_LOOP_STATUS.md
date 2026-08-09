# PERF_LOOP — Plan R2 P5 complete (2026-08-09)

## Architecture

Darwin product sockets: **native kqueue reactor** (separate from proactr ring kq).
Timers: proactr soft_cq only (D5). Linux: unchanged io_uring proactor.

## Matrix (WORKERS=8, BENCH_C=50, BENCH_Z=8s, proactr only)

| proto | test | RPS | status | soft_cq_send |
|-------|------|-----|--------|--------------|
| h2 | plaintext | 101115 | ok | 0 |
| h2 | s4k | 87209 | ok | 0 |
| h2 | s64k | 31390 | ok | 0 |
| h2 | s1m | 2253 | ok | 0 |
| h1s | plaintext | 115637 | ok | 0 |
| h1s | s4k | 96803 | ok | 0 |
| h1s | s64k | 31256 | ok | 0 |
| h1s | s1m | 2563 | ok | 0 |

All cells: 0 failed / 0 errored / 0 timeout. `io_engine=reactor-kqueue`.

## Duty

- `soft_cq_send_completes=0` on TLS cells
- h2 s1m `seal_windows_per_kevent_turn` ≈ 8.5 (multi-window reactor law)

## Closed for this plan

P0–P5 done. Temporary RPS vs P4 hybrid is acceptable; do not reopen CLOSED_RPS_FLAGS.
Further RPS is a new law / evidence cycle, not façade density flags.
