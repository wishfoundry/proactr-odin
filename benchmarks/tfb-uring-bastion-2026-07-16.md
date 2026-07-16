# TFB plaintext/HTML baseline — ranch-bastion (io_uring)

| Field | Value |
|-------|--------|
| **Host** | ranch-bastion |
| **Date** | 2026-07-16 |
| **Kernel** | Linux 6.14.0-37-generic x86_64 · `CONFIG_IO_URING=y` · `io_uring_disabled=0` |
| **CPU** | 2× Intel Xeon E5-2666 v3 @ 2.90 GHz · **40** logical CPUs (10c/socket × 2 × HT) |
| **RAM** | ~46 GiB |
| **Loadgen** | bombardier · `C=100` · warm 3 s · steady **15 s** · localhost |
| **Workers** | `WORKERS=8` (honored by ntex / ntex-compio; laytan uses its own nbio workers; pure compio & asio are single-thread accept loops) |
| **DB** | SQLite `/tmp/proactr-tfb.sqlite` · TE 12-row Fortune seed |
| **Routes** | `GET /plaintext` · `GET /fortunes` (no JSON) |
| **Logs** | `/tmp/proactr-tfb-logs-20260716-061932` on bastion |
| **Repo** | proactr-odin @ post-io_uring config |

**Latency column** is bombardier **average** latency (not true p50). **Max** latency listed separately. Zero non-2xx on all completed cells.

## Summary (Reqs/sec)

| Peer | Backend | plaintext RPS | avg lat | max lat | fortunes RPS | avg lat | max lat |
|------|---------|--------------:|--------:|--------:|-------------:|--------:|--------:|
| **laytan** | nbio / io_uring | **375 440** | 261 µs | 16 ms | n/a (501) | — | — |
| **ntex** | neon-uring | **372 404** | 265 µs | 19 ms | 15 193 | 6.57 ms | 24 ms |
| **ntex-compio** | compio / io_uring | 334 366 | 295 µs | 11 ms | 14 457 | 6.91 ms | 21 ms |
| **asio** | Asio io_uring (`DISABLE_EPOLL`) | 94 959 | 1.05 ms | 20 ms | 4 134 | 24.2 ms | 625 ms |
| **compio** | raw compio-net | 87 129 | 1.14 ms | 22 ms | **41 337** | 2.41 ms | 54 ms |

## Rank notes

### `/plaintext` (I/O ceiling)

1. **laytan ≈ ntex(neon-uring)** top tier (~370–375 k RPS)
2. ntex-compio close behind (~334 k)
3. asio / pure compio ~87–95 k — **single-threaded** accept/event loops in our peers, not multi-worker

### `/fortunes` (primary — DB + sort + HTML escape)

1. **pure compio ~41 k** leads among finished peers  
2. ntex / ntex-compio ~14–15 k — likely **SQLite mutex contention** with `WORKERS=8` on one connection  
3. asio ~4 k — peer opens SQLite **per request** (honest but harsh; not a production pattern)  
4. **laytan** fortunes not implemented yet (fail-closed 501)

All fortune cells **100% 2xx** where measured.

## Caveats (read before citing)

1. **Not TE cloud hardware** — localhost bombardier on one box; do not claim TE rank.
2. **bombardier latency** is closed-loop average; install `oha --latency-correction` for p50/p99 next run.
3. **CPU scaling** reported ~40% of max MHz during inventory — numbers may rise with performance governor.
4. **Worker fairness**: ntex multi-worker vs single-thread asio/compio is **not** apples-to-apples on plaintext; fortunes is more about DB+escape cost + lock design.
5. SQLite is shared-file; WAL on. Not Postgres TE.

## Reproduce

```bash
ssh ranch-bastion.local '
  export PATH="$HOME/.cargo/bin:$HOME/go/bin:/usr/local/bin:$PATH"
  cd ~/Projects/proactr-odin/comparisons/tfb
  SERVERS="ntex ntex-compio compio asio laytan" \
    WORKERS=8 BENCH_C=100 BENCH_Z=15s WARMUP_Z=3s \
    ./run_bench.sh
'
```

## Next for a stronger baseline

- [ ] Link SQLite into **laytan** fortunes (unblock primary comparison vs ntex)
- [ ] Multi-thread / multi-worker **asio** and **compio** peers
- [ ] Connection pool per worker for ntex fortunes (drop global mutex)
- [ ] `oha` p50/p99 + optional open-loop
- [ ] WORKERS=1 matrix for pure I/O-model comparison
