# TLS/H2 peer matrix results

- **Host:** Benjamins-MacBook-Pro.local · Darwin 25.5.0
- **When:** 2026-08-10T14:32Z
- **WORKERS=8** · **BENCH_C=50** · **BENCH_Z=10s** · **WARMUP_Z=3s**
- **Loadgen:** h2load -c 50 -D 10 -t 4 · SSL_CERT_FILE=matrix cert
- **Protocols:** h1s (h2 = ALPN h2 required; h1s = TLS HTTP/1.1)
- **Peers requested:** proactr drogon
- **Peers built:**  proactr drogon

## Backend labels

| Peer | Stack | TLS | H2 |
|------|-------|-----|-----|
| proactr | **kqueue** | OpenSSL mem-BIO | ALPN h2 product path |
| ntex | **tokio** (not neon-uring) | OpenSSL (ntex-tls) | ALPN h2 via bind_openssl |
| drogon | trantor **kqueue** | OpenSSL | primarily H1; h2 cells N/A if no_h2 |
| go | net/http **kqueue** | crypto/tls | automatic HTTP/2 |

## RPS matrix (this session)

```
peer     proto  test       rps        status  app_proto  failed  errored  timeout
proactr  h1s    plaintext  150002.60  ok      http/1.1   0       0        0
proactr  h1s    s4k        148878.00  ok      http/1.1   0       0        0
proactr  h1s    s64k       75288.60   ok      http/1.1   0       0        0
proactr  h1s    s1m        10293.30   ok      http/1.1   0       0        0
drogon   h1s    plaintext  152441.10  ok      http/1.1   0       0        0
drogon   h1s    s4k        150255.50  ok      http/1.1   0       0        0
drogon   h1s    s64k       65582.70   ok      http/1.1   0       0        0
drogon   h1s    s1m        8630.10    ok      http/1.1   0       0        0
```

### vs drogon (this session)

| test | proactr | drogon | proactr/drogon |
|------|--------:|-------:|---------------:|
| plaintext | 150003 | 152441 | **0.98×** |
| s4k | 148878 | 150256 | **0.99×** |
| s64k | 75289 | 65583 | **1.15×** |
| s1m | 10293 | 8630 | **1.19×** |

## Historical proactr (before shared multi-kq / accept fix)

Same host class · WORKERS=8 · h2load `-c 50 -D 10 -t 4` · h1s.  
**Not same-session** with drogon above — use for proactr self-compare only.

| Anchor | When / SHA | plain | s4k | s64k | s1m | vs drogon s1m (that session) | Note |
|--------|------------|------:|----:|-----:|----:|-----------------------------:|------|
| **P5 baseline** | 2026-08-09 · `c93ddb8` · `BASELINE_P5.md` | **111730** | 86942 | 30554 | **2599** | **0.30×** (8612) | Native reactor wait; **SO_REUSEPORT** multi-worker — 1 hot worker on localhost |
| **Pre-shared-listen** | 2026-08-10 · `5f5e9f9` · `CRITIC_DROGON_ITER_01` | **95723** | 84602 | 29144 | **2736** | **0.33×** (8195) | Checklist stack (peek, 128 KiB seal, …); still REUSEPORT pin |
| **This session** | 2026-08-10T14:32Z · post `server_kqueue` refactor | **150003** | 148878 | 75289 | **10293** | **1.19×** (8630) | **Shared listen multi-kq** + cleanup; 8 workers busy |

### proactr absolute delta (this session / P5)

| test | P5 | now | now/P5 |
|------|---:|----:|-------:|
| plaintext | 111730 | 150003 | **1.34×** |
| s4k | 86942 | 148878 | **1.71×** |
| s64k | 30554 | 75289 | **2.46×** |
| s1m | 2599 | 10293 | **3.96×** |

Sources: `results/BASELINE_P5.md` · `results/baseline_p5_20260809/summary.tsv` · `results/CRITIC_DROGON_ITER_01.md` · live `summary.tsv`.

## Fairness notes

- Body len + prefix verified on TLS HTTP/1.1 before load.
- h2 cells require Application protocol: h2; else status=no_h2 RPS=N/A.
- Nonzero failed/errored/timeout → status=fail RPS=INVALID.
- go: GOMAXPROCS=8 label only (not thread-per-worker).
- proactr/ntex: WORKERS=8 thread/worker model.
- **Darwin/kqueue host:** proactr uses kqueue (not io_uring). ntex uses tokio+openssl (not neon-uring).
- drogon: setThreadNum=8, trantor kqueue — not Linux epoll class.
- Instrumentation: /_matrix/stats after each cell → instrumentation.txt
- Not multi-stream SSE RPS; oneshot size ladder only.

## Instrumentation (excerpt)
```
--- stats proactr h1s.plaintext ---
peer=proactr
io_engine=reactor-kqueue
io_engine_note=reactor_kqueue_wait;shared_listen_multi_kq;level_read;level_residual_write;timers_merged_wait;wbio_peek_drain;wbio_cache;seal_128k;fairness_write_rearm;darwin_no_hold_slab;plain_split_8k;no_proactr_socket_submit;no_dual_ct_ahead
reqs=1500075
seal_calls=1500075
seals_per_req=1.000
ssl_write_ok=1500075
pt_bytes=169508464
ct_bytes=202605178
ct_pt_ratio=1.1953
h2_flush=0
h2_pt_bytes=0
ct_sends=1500177
materialize=1500075
seal_windows=1500075
kevent_turns=1500075
seal_windows_per_kevent_turn=1.000
soft_cq_send_completes=0
eagain_arms=0
first_seal_pt_sum=169508464
first_seal_n=1500075
first_seal_pt_avg=113.0
--- stats proactr h1s.s4k ---
peer=proactr
io_engine=reactor-kqueue
io_engine_note=reactor_kqueue_wait;shared_listen_multi_kq;level_read;level_residual_write;timers_merged_wait;wbio_peek_drain;wbio_cache;seal_128k;fairness_write_rearm;darwin_no_hold_slab;plain_split_8k;no_proactr_socket_submit;no_dual_ct_ahead
reqs=1488827
seal_calls=1488827
seals_per_req=1.000
ssl_write_ok=1488827
pt_bytes=6250091650
ct_bytes=6282940908
ct_pt_ratio=1.0053
h2_flush=0
h2_pt_bytes=0
ct_sends=1488929
materialize=1488827
seal_windows=1488827
kevent_turns=1488827
seal_windows_per_kevent_turn=1.000
soft_cq_send_completes=0
eagain_arms=0
first_seal_pt_sum=6250091650
first_seal_n=1488827
first_seal_pt_avg=4198.0
--- stats proactr h1s.s64k ---
peer=proactr
io_engine=reactor-kqueue
io_engine_note=reactor_kqueue_wait;shared_listen_multi_kq;level_read;level_residual_write;timers_merged_wait;wbio_peek_drain;wbio_cache;seal_128k;fairness_write_rearm;darwin_no_hold_slab;plain_split_8k;no_proactr_socket_submit;no_dual_ct_ahead
reqs=752933
seal_calls=1505865
seals_per_req=2.000
ssl_write_ok=1505865
pt_bytes=49421703650
ct_bytes=49504621256
ct_pt_ratio=1.0017
h2_flush=0
h2_pt_bytes=0
ct_sends=1505967
materialize=1
seal_windows=1505865
kevent_turns=752933
seal_windows_per_kevent_turn=2.000
soft_cq_send_completes=0
eagain_arms=0
first_seal_pt_sum=77552098
first_seal_n=752933
first_seal_pt_avg=103.0
--- stats proactr h1s.s1m ---
peer=proactr
io_engine=reactor-kqueue
io_engine_note=reactor_kqueue_wait;shared_listen_multi_kq;level_read;level_residual_write;timers_merged_wait;wbio_peek_drain;wbio_cache;seal_128k;fairness_write_rearm;darwin_no_hold_slab;plain_split_8k;no_proactr_socket_submit;no_dual_ct_ahead
reqs=102967
seal_calls=926710
seals_per_req=9.000
ssl_write_ok=926710
pt_bytes=107980192094
ct_bytes=108127530892
ct_pt_ratio=1.0014
```
