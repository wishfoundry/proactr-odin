# TLS/H2 peer matrix results

- **Host:** ranch-bastion · Linux 6.14.0-37-generic
- **When:** 2026-08-10T15:01Z
- **WORKERS=8** · **BENCH_C=50** · **BENCH_Z=10s** · **WARMUP_Z=3s**
- **Loadgen:** h2load -c 50 -D 10 -t 4 · SSL_CERT_FILE=matrix cert
- **Protocols:** h1s (h2 = ALPN h2 required; h1s = TLS HTTP/1.1)
- **Peers requested:** proactr drogon
- **Peers built:**  proactr

## Backend labels

| Peer | Stack | TLS | H2 |
|------|-------|-----|-----|
| proactr | io_uring | OpenSSL mem-BIO | ALPN h2 product path |
| ntex | neon-uring | OpenSSL (ntex-tls) | ALPN h2 via bind_openssl |
| drogon | trantor **epoll** | OpenSSL | primarily H1; h2 cells N/A if no_h2 |
| go | net/http epoll | crypto/tls | automatic HTTP/2 |

## RPS matrix

```
peer     proto  test       rps        status  app_proto  failed  errored  timeout
proactr  h1s    plaintext  191098.10  ok      http/1.1   0       0        0
proactr  h1s    s4k        178011.50  ok      http/1.1   0       0        0
proactr  h1s    s64k       51760.00   ok      http/1.1   0       0        0
proactr  h1s    s1m        4860.40    ok      http/1.1   0       0        0
drogon   h1s    plaintext  206559.40  ok      http/1.1   0       0        0
drogon   h1s    s4k        173813.90  ok      http/1.1   0       0        0
drogon   h1s    s64k       44119.80   ok      http/1.1   0       0        0
drogon   h1s    s1m        3538.20    ok      http/1.1   0       0        0
```

## Fairness notes

- Body len + prefix verified on TLS HTTP/1.1 before load.
- h2 cells require Application protocol: h2; else status=no_h2 RPS=N/A.
- Nonzero failed/errored/timeout → status=fail RPS=INVALID.
- go: GOMAXPROCS=8 label only (not thread-per-worker).
- proactr/ntex: WORKERS=8 thread/worker model.
- drogon: setThreadNum=8, epoll — not same I/O class as uring peers.
- Instrumentation: /_matrix/stats after each cell → instrumentation.txt
- Not multi-stream SSE RPS; oneshot size ladder only.

## Instrumentation (excerpt)
```
--- stats proactr h1s.plaintext ---
peer=proactr
io_engine=proactor-uring
io_engine_note=dense_tls_flush_h1;host_try_send_nb;residual_submit_send_reactor_h1;no_soft_cq_between_seals;seal_128k;wbio_peek_drain;no_dual_ct_ahead_h1;h2_dual_ct
reqs=1911017
seal_calls=1911017
seals_per_req=1.000
ssl_write_ok=1911017
pt_bytes=215944910
ct_bytes=258081274
ct_pt_ratio=1.1951
h2_flush=0
h2_pt_bytes=0
ct_sends=1911119
materialize=1911017
seal_windows=1911017
kevent_turns=1911017
seal_windows_per_kevent_turn=1.000
soft_cq_send_completes=102
eagain_arms=0
first_seal_pt_sum=215944910
first_seal_n=1911017
first_seal_pt_avg=113.0
--- stats proactr h1s.s4k ---
peer=proactr
io_engine=proactor-uring
io_engine_note=dense_tls_flush_h1;host_try_send_nb;residual_submit_send_reactor_h1;no_soft_cq_between_seals;seal_128k;wbio_peek_drain;no_dual_ct_ahead_h1;h2_dual_ct
reqs=1780149
seal_calls=1780149
seals_per_req=1.000
ssl_write_ok=1780149
pt_bytes=7473061406
ct_bytes=7512318674
ct_pt_ratio=1.0053
h2_flush=0
h2_pt_bytes=0
ct_sends=1780251
materialize=1780149
seal_windows=1780149
kevent_turns=1780149
seal_windows_per_kevent_turn=1.000
soft_cq_send_completes=102
eagain_arms=0
first_seal_pt_sum=7473061406
first_seal_n=1780149
first_seal_pt_avg=4198.0
--- stats proactr h1s.s64k ---
peer=proactr
io_engine=proactor-uring
io_engine_note=dense_tls_flush_h1;host_try_send_nb;residual_submit_send_reactor_h1;no_soft_cq_between_seals;seal_128k;wbio_peek_drain;no_dual_ct_ahead_h1;h2_dual_ct
reqs=517630
seal_calls=1035259
seals_per_req=2.000
ssl_write_ok=1035259
pt_bytes=33976650033
ct_bytes=34033683235
ct_pt_ratio=1.0017
h2_flush=0
h2_pt_bytes=0
ct_sends=1035361
materialize=1
seal_windows=1035259
kevent_turns=517630
seal_windows_per_kevent_turn=2.000
soft_cq_send_completes=102
eagain_arms=0
first_seal_pt_sum=53315889
first_seal_n=517630
first_seal_pt_avg=103.0
--- stats proactr h1s.s1m ---
peer=proactr
io_engine=proactor-uring
io_engine_note=dense_tls_flush_h1;host_try_send_nb;residual_submit_send_reactor_h1;no_soft_cq_between_seals;seal_128k;wbio_peek_drain;no_dual_ct_ahead_h1;h2_dual_ct
reqs=48635
seal_calls=437718
seals_per_req=9.000
ssl_write_ok=437718
pt_bytes=51002731714
ct_bytes=51072373974
ct_pt_ratio=1.0014
```
