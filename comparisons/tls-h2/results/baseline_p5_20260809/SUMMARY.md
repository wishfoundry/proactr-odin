# TLS/H2 peer matrix results

- **Host:** Benjamins-MacBook-Pro.local · Darwin 25.5.0
- **When:** 2026-08-09T23:31Z
- **WORKERS=8** · **BENCH_C=50** · **BENCH_Z=10s** · **WARMUP_Z=3s**
- **Loadgen:** h2load -c 50 -D 10 -t 4 · SSL_CERT_FILE=matrix cert
- **Protocols:** h2 h1s (h2 = ALPN h2 required; h1s = TLS HTTP/1.1)
- **Peers requested:** proactr ntex drogon
- **Peers built:**  proactr ntex drogon

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
proactr  h2     plaintext  96253.30   ok      h2         0       0        0
proactr  h2     s4k        84994.70   ok      h2         0       0        0
proactr  h2     s64k       30488.90   ok      h2         0       0        0
proactr  h2     s1m        2215.80    ok      h2         0       0        0
proactr  h1s    plaintext  111729.80  ok      http/1.1   0       0        0
proactr  h1s    s4k        86941.80   ok      http/1.1   0       0        0
proactr  h1s    s64k       30553.50   ok      http/1.1   0       0        0
proactr  h1s    s1m        2598.90    ok      http/1.1   0       0        0
ntex     h2     plaintext  128477.90  ok      h2         0       0        0
ntex     h2     s4k        129834.20  ok      h2         0       0        0
ntex     h2     s64k       44087.00   ok      h2         0       0        0
ntex     h2     s1m        1017.80    ok      h2         0       0        0
ntex     h1s    plaintext  137403.10  ok      http/1.1   0       0        0
ntex     h1s    s4k        139035.50  ok      http/1.1   0       0        0
ntex     h1s    s64k       57248.60   ok      http/1.1   0       0        0
ntex     h1s    s1m        1995.50    ok      http/1.1   0       0        0
drogon   h2     plaintext  N/A        no_h2   http/1.1   0       0        0
drogon   h2     s4k        N/A        no_h2   http/1.1   0       0        0
drogon   h2     s64k       N/A        no_h2   http/1.1   0       0        0
drogon   h2     s1m        N/A        no_h2   http/1.1   0       0        0
drogon   h1s    plaintext  150542.00  ok      http/1.1   0       0        0
drogon   h1s    s4k        149807.20  ok      http/1.1   0       0        0
drogon   h1s    s64k       65093.00   ok      http/1.1   0       0        0
drogon   h1s    s1m        8611.90    ok      http/1.1   0       0        0
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

## Errors / warnings
```
WARN drogon h2 plaintext negotiated 'http/1.1' not h2 → N/A
WARN drogon h2 s4k negotiated 'http/1.1' not h2 → N/A
WARN drogon h2 s64k negotiated 'http/1.1' not h2 → N/A
WARN drogon h2 s1m negotiated 'http/1.1' not h2 → N/A
```

## Instrumentation (excerpt)
```
--- stats proactr h2.plaintext ---
peer=proactr
io_engine=reactor-kqueue
io_engine_note=reactor_kqueue_wait;accept_recv_write_close_native;timers_soft_cq;tls_h1_h2_send_reactor;stream_residual_first;hs_drain_reactor;no_proactr_socket_submit;no_dual_ct_ahead;no_soft_nop_fairness
reqs=1925147
seal_calls=962649
seals_per_req=0.500
ssl_write_ok=962649
pt_bytes=65483666
ct_bytes=54014926
ct_pt_ratio=0.8249
h2_flush=962648
h2_pt_bytes=32741782
ct_sends=962751
materialize=1
seal_windows=962649
kevent_turns=1925147
seal_windows_per_kevent_turn=0.500
soft_cq_send_completes=0
eagain_arms=0
--- stats proactr h2.s4k ---
peer=proactr
io_engine=reactor-kqueue
io_engine_note=reactor_kqueue_wait;accept_recv_write_close_native;timers_soft_cq;tls_h1_h2_send_reactor;stream_residual_first;hs_drain_reactor;no_proactr_socket_submit;no_dual_ct_ahead;no_soft_nop_fairness
reqs=1699993
seal_calls=850072
seals_per_req=0.500
ssl_write_ok=850072
pt_bytes=6998691616
ct_bytes=3518142207
ct_pt_ratio=0.5027
h2_flush=850071
h2_pt_bytes=3499345757
ct_sends=850174
materialize=1
seal_windows=850072
kevent_turns=1699993
seal_windows_per_kevent_turn=0.500
soft_cq_send_completes=0
eagain_arms=0
--- stats proactr h2.s64k ---
peer=proactr
io_engine=reactor-kqueue
io_engine_note=reactor_kqueue_wait;accept_recv_write_close_native;timers_soft_cq;tls_h1_h2_send_reactor;stream_residual_first;hs_drain_reactor;no_proactr_socket_submit;no_dual_ct_ahead;no_soft_nop_fairness
reqs=609849
seal_calls=609899
seals_per_req=1.000
ssl_write_ok=609899
pt_bytes=39993022434
ct_bytes=20030147144
ct_pt_ratio=0.5008
h2_flush=609898
h2_pt_bytes=19996511166
ct_sends=610001
materialize=1
seal_windows=609899
kevent_turns=609849
seal_windows_per_kevent_turn=1.000
soft_cq_send_completes=0
eagain_arms=0
--- stats proactr h2.s1m ---
peer=proactr
io_engine=reactor-kqueue
io_engine_note=reactor_kqueue_wait;accept_recv_write_close_native;timers_soft_cq;tls_h1_h2_send_reactor;stream_residual_first;hs_drain_reactor;no_proactr_socket_submit;no_dual_ct_ahead;no_soft_nop_fairness
reqs=44371
seal_calls=376823
seals_per_req=8.493
ssl_write_ok=376823
pt_bytes=46499370922
ct_bytes=23281471540
ct_pt_ratio=0.5007
h2_flush=376822
h2_pt_bytes=23249685410
ct_sends=376925
materialize=1
seal_windows=376823
kevent_turns=44373
seal_windows_per_kevent_turn=8.492
soft_cq_send_completes=0
eagain_arms=0
```
