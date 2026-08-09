# TLS/H2 peer matrix results

- **Host:** Benjamins-MacBook-Pro.local · Darwin 25.5.0
- **When:** 2026-08-09T23:17Z
- **WORKERS=8** · **BENCH_C=50** · **BENCH_Z=8s** · **WARMUP_Z=2s**
- **Loadgen:** h2load -c 50 -D 8 -t 4 · SSL_CERT_FILE=matrix cert
- **Protocols:** h2 h1s (h2 = ALPN h2 required; h1s = TLS HTTP/1.1)
- **Peers requested:** proactr
- **Peers built:**  proactr

## Backend labels

| Peer | Stack | TLS | H2 |
|------|-------|-----|-----|
| proactr | **kqueue** | OpenSSL mem-BIO | ALPN h2 product path |
| ntex | **tokio** (not neon-uring) | OpenSSL (ntex-tls) | ALPN h2 via bind_openssl |
| drogon | trantor **kqueue** | OpenSSL | primarily H1; h2 cells N/A if no_h2 |
| go | net/http **kqueue** | crypto/tls | automatic HTTP/2 |

## RPS matrix

```
peer     proto  test       rps        status  app_proto  failed  errored  timeout
proactr  h2     plaintext  101114.75  ok      h2         0       0        0
proactr  h2     s4k        87209.38   ok      h2         0       0        0
proactr  h2     s64k       31390.25   ok      h2         0       0        0
proactr  h2     s1m        2253.38    ok      h2         0       0        0
proactr  h1s    plaintext  115636.62  ok      http/1.1   0       0        0
proactr  h1s    s4k        96802.50   ok      http/1.1   0       0        0
proactr  h1s    s64k       31255.62   ok      http/1.1   0       0        0
proactr  h1s    s1m        2562.75    ok      http/1.1   0       0        0
```

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
--- stats proactr h2.plaintext ---
peer=proactr
io_engine=reactor-kqueue
io_engine_note=reactor_kqueue_wait;accept_recv_write_close_native;timers_soft_cq;tls_h1_h2_send_reactor;stream_residual_first;hs_drain_reactor;no_proactr_socket_submit;no_dual_ct_ahead;no_soft_nop_fairness
reqs=1617937
seal_calls=809044
seals_per_req=0.500
ssl_write_ok=809044
pt_bytes=55033926
ct_bytes=45410746
ct_pt_ratio=0.8251
h2_flush=809043
h2_pt_bytes=27516912
ct_sends=809146
materialize=1
seal_windows=809044
kevent_turns=1617937
seal_windows_per_kevent_turn=0.500
soft_cq_send_completes=0
eagain_arms=0
--- stats proactr h2.s4k ---
peer=proactr
io_engine=reactor-kqueue
io_engine_note=reactor_kqueue_wait;accept_recv_write_close_native;timers_soft_cq;tls_h1_h2_send_reactor;stream_residual_first;hs_drain_reactor;no_proactr_socket_submit;no_dual_ct_ahead;no_soft_nop_fairness
reqs=1395451
seal_calls=697801
seals_per_req=0.500
ssl_write_ok=697801
pt_bytes=5744887602
ct_bytes=2887890238
ct_pt_ratio=0.5027
h2_flush=697800
h2_pt_bytes=2872443750
ct_sends=697903
materialize=1
seal_windows=697801
kevent_turns=1395451
seal_windows_per_kevent_turn=0.500
soft_cq_send_completes=0
eagain_arms=0
--- stats proactr h2.s64k ---
peer=proactr
io_engine=reactor-kqueue
io_engine_note=reactor_kqueue_wait;accept_recv_write_close_native;timers_soft_cq;tls_h1_h2_send_reactor;stream_residual_first;hs_drain_reactor;no_proactr_socket_submit;no_dual_ct_ahead;no_soft_nop_fairness
reqs=502319
seal_calls=502369
seals_per_req=1.000
ssl_write_ok=502369
pt_bytes=32940770314
ct_bytes=16498106934
ct_pt_ratio=0.5008
h2_flush=502368
h2_pt_bytes=16470385106
ct_sends=502471
materialize=1
seal_windows=502369
kevent_turns=502319
seal_windows_per_kevent_turn=1.000
soft_cq_send_completes=0
eagain_arms=0
--- stats proactr h2.s1m ---
peer=proactr
io_engine=reactor-kqueue
io_engine_note=reactor_kqueue_wait;accept_recv_write_close_native;timers_soft_cq;tls_h1_h2_send_reactor;stream_residual_first;hs_drain_reactor;no_proactr_socket_submit;no_dual_ct_ahead;no_soft_nop_fairness
reqs=36107
seal_calls=306577
seals_per_req=8.491
ssl_write_ok=306577
pt_bytes=37828812882
ct_bytes=18940283584
ct_pt_ratio=0.5007
h2_flush=306576
h2_pt_bytes=18914406390
ct_sends=306679
materialize=1
seal_windows=306577
kevent_turns=36109
seal_windows_per_kevent_turn=8.490
soft_cq_send_completes=0
eagain_arms=0
```
