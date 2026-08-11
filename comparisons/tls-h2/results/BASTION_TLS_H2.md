# TLS/H2 peer matrix results

- **Host:** ranch-bastion · Linux 6.14.0-37-generic
- **When:** 2026-08-10T16:38Z
- **WORKERS=8** · **BENCH_C=100** · **BENCH_Z=15s** · **WARMUP_Z=3s**
- **Loadgen:** h2load -c 100 -D 15 -t 4 · SSL_CERT_FILE=matrix cert
- **Protocols:** h2 h1s (h2 = ALPN h2 required; h1s = TLS HTTP/1.1)
- **Peers requested:** proactr ntex drogon go
- **Peers built:**  proactr ntex go

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
proactr  h2     plaintext  187693.40  ok      h2         0       0        0
proactr  h2     s4k        151181.13  ok      h2         0       0        0
proactr  h2     s64k       51538.87   ok      h2         0       0        0
proactr  h2     s1m        4328.80    ok      h2         0       0        0
proactr  h1s    plaintext  216956.13  ok      http/1.1   0       0        0
proactr  h1s    s4k        184709.67  ok      http/1.1   0       0        0
proactr  h1s    s64k       53452.87   ok      http/1.1   0       0        0
proactr  h1s    s1m        5031.20    ok      http/1.1   0       0        0
ntex     h2     plaintext  141751.40  ok      h2         0       0        0
ntex     h2     s4k        125717.00  ok      h2         0       0        0
ntex     h2     s64k       34722.40   ok      h2         0       0        0
ntex     h2     s1m        1127.67    ok      h2         0       0        0
ntex     h1s    plaintext  179876.20  ok      http/1.1   0       0        0
ntex     h1s    s4k        155037.93  ok      http/1.1   0       0        0
ntex     h1s    s64k       44293.47   ok      http/1.1   0       0        0
ntex     h1s    s1m        1680.47    ok      http/1.1   0       0        0
drogon   h2     plaintext  N/A        no_h2   http/1.1   0       0        0
drogon   h2     s4k        N/A        no_h2   http/1.1   0       0        0
drogon   h2     s64k       N/A        no_h2   http/1.1   0       0        0
drogon   h2     s1m        N/A        no_h2   http/1.1   0       0        0
drogon   h1s    plaintext  201175.20  ok      http/1.1   0       0        0
drogon   h1s    s4k        180871.60  ok      http/1.1   0       0        0
drogon   h1s    s64k       48204.40   ok      http/1.1   0       0        0
drogon   h1s    s1m        3921.73    ok      http/1.1   0       0        0
go       h2     plaintext  94777.53   ok      h2         0       0        0
go       h2     s4k        85981.80   ok      h2         0       0        0
go       h2     s64k       32557.33   ok      h2         0       0        0
go       h2     s1m        3388.20    ok      h2         0       0        0
go       h1s    plaintext  160268.07  ok      http/1.1   0       0        0
go       h1s    s4k        103333.53  ok      http/1.1   0       0        0
go       h1s    s64k       44425.67   ok      http/1.1   0       0        0
go       h1s    s1m        4713.93    ok      http/1.1   0       0        0
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
io_engine=proactor-uring
io_engine_note=dense_tls_flush_h1;host_try_send_nb;residual_submit_send_reactor_h1;no_soft_cq_between_seals;seal_128k;wbio_peek_only;no_dual_ct_ahead_h1;h2_dual_ct
reqs=5631101
seal_calls=2815659
seals_per_req=0.500
ssl_write_ok=1
pt_bytes=95767060
ct_bytes=157897048
ct_pt_ratio=1.6488
h2_flush=2815658
h2_pt_bytes=95766958
ct_sends=2815861
materialize=1
seal_windows=1
kevent_turns=1
seal_windows_per_kevent_turn=1.000
soft_cq_send_completes=202
eagain_arms=0
wbio_bio_read_fallback=0
wbio_peek_empty=0
first_seal_pt_sum=102
first_seal_n=1
first_seal_pt_avg=102.0
--- stats proactr h2.s4k ---
peer=proactr
io_engine=proactor-uring
io_engine_note=dense_tls_flush_h1;host_try_send_nb;residual_submit_send_reactor_h1;no_soft_cq_between_seals;seal_128k;wbio_peek_only;no_dual_ct_ahead_h1;h2_dual_ct
reqs=4535788
seal_calls=2267976
seals_per_req=0.500
ssl_write_ok=1
pt_bytes=9336471577
ct_bytes=9386552539
ct_pt_ratio=1.0054
h2_flush=2267975
h2_pt_bytes=9336471475
ct_sends=2268178
materialize=1
seal_windows=1
kevent_turns=1
seal_windows_per_kevent_turn=1.000
soft_cq_send_completes=202
eagain_arms=0
wbio_bio_read_fallback=0
wbio_peek_empty=0
first_seal_pt_sum=102
first_seal_n=1
first_seal_pt_avg=102.0
--- stats proactr h2.s64k ---
peer=proactr
io_engine=proactor-uring
io_engine_note=dense_tls_flush_h1;host_try_send_nb;residual_submit_send_reactor_h1;no_soft_cq_between_seals;seal_128k;wbio_peek_only;no_dual_ct_ahead_h1;h2_dual_ct
reqs=1546477
seal_calls=773352
seals_per_req=0.500
ssl_write_ok=1
pt_bytes=50706377086
ct_bytes=50791613608
ct_pt_ratio=1.0017
h2_flush=773351
h2_pt_bytes=50706376984
ct_sends=773554
materialize=1
seal_windows=1
kevent_turns=1
seal_windows_per_kevent_turn=1.000
soft_cq_send_completes=202
eagain_arms=0
wbio_bio_read_fallback=0
wbio_peek_empty=0
first_seal_pt_sum=102
first_seal_n=1
first_seal_pt_avg=102.0
--- stats proactr h2.s1m ---
peer=proactr
io_engine=proactor-uring
io_engine_note=dense_tls_flush_h1;host_try_send_nb;residual_submit_send_reactor_h1;no_soft_cq_between_seals;seal_128k;wbio_peek_only;no_dual_ct_ahead_h1;h2_dual_ct
reqs=130168
```
