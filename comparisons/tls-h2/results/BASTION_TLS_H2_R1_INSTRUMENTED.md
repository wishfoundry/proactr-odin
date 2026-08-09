# TLS/H2 peer matrix results

- **Host:** ranch-bastion · Linux 6.14.0-37-generic
- **When:** 2026-08-09T02:12Z
- **WORKERS=8** · **BENCH_C=100** · **BENCH_Z=15s** · **WARMUP_Z=3s**
- **Loadgen:** h2load -c 100 -D 15 -t 4 · SSL_CERT_FILE=matrix cert
- **Protocols:** h2 h1s (h2 = ALPN h2 required; h1s = TLS HTTP/1.1)
- **Peers requested:** proactr ntex drogon go
- **Peers built:**  proactr ntex drogon go

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
proactr  h2     plaintext  182563.93  ok      h2         0       0        0
proactr  h2     s4k        152391.20  ok      h2         0       0        0
proactr  h2     s64k       6046.47    ok      h2         0       0        0
proactr  h2     s1m        1227.27    ok      h2         0       0        0
proactr  h1s    plaintext  207839.40  ok      http/1.1   0       0        0
proactr  h1s    s4k        182224.40  ok      http/1.1   0       0        0
proactr  h1s    s64k       18392.33   ok      http/1.1   0       0        0
proactr  h1s    s1m        3610.87    ok      http/1.1   0       0        0
ntex     h2     plaintext  145452.80  ok      h2         0       0        0
ntex     h2     s4k        123992.40  ok      h2         0       0        0
ntex     h2     s64k       36304.07   ok      h2         0       0        0
ntex     h2     s1m        1153.53    ok      h2         0       0        0
ntex     h1s    plaintext  179175.33  ok      http/1.1   0       0        0
ntex     h1s    s4k        156737.93  ok      http/1.1   0       0        0
ntex     h1s    s64k       44106.53   ok      http/1.1   0       0        0
ntex     h1s    s1m        1806.00    ok      http/1.1   0       0        0
drogon   h2     plaintext  N/A        no_h2   http/1.1   0       0        0
drogon   h2     s4k        N/A        no_h2   http/1.1   0       0        0
drogon   h2     s64k       N/A        no_h2   http/1.1   0       0        0
drogon   h2     s1m        N/A        no_h2   http/1.1   0       0        0
drogon   h1s    plaintext  215371.00  ok      http/1.1   0       0        0
drogon   h1s    s4k        178787.13  ok      http/1.1   0       0        0
drogon   h1s    s64k       50124.67   ok      http/1.1   0       0        0
drogon   h1s    s1m        4595.67    ok      http/1.1   0       0        0
go       h2     plaintext  95373.87   ok      h2         0       0        0
go       h2     s4k        85414.33   ok      h2         0       0        0
go       h2     s64k       32019.93   ok      h2         0       0        0
go       h2     s1m        3405.73    ok      h2         0       0        0
go       h1s    plaintext  166896.73  ok      http/1.1   0       0        0
go       h1s    s4k        103346.13  ok      http/1.1   0       0        0
go       h1s    s64k       45307.73   ok      http/1.1   0       0        0
go       h1s    s1m        4937.13    ok      http/1.1   0       0        0
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
reqs=2738723
seal_calls=2738723
ssl_write_ok=1
pt_bytes=183484676
ct_bytes=243736582
ct_pt_ratio=1.3284
h2_flush=2738722
h2_pt_bytes=183484574
ct_sends=2738723
materialize=1
--- stats proactr h2.s4k ---
peer=proactr
reqs=2286121
seal_calls=2286121
ssl_write_ok=1
pt_bytes=9486571702
ct_bytes=9536866364
ct_pt_ratio=1.0053
h2_flush=2286120
h2_pt_bytes=9486571600
ct_sends=2286121
materialize=1
--- stats proactr h2.s64k ---
peer=proactr
reqs=90989
seal_calls=181777
ssl_write_ok=1
pt_bytes=5957239898
ct_bytes=5959241656
ct_pt_ratio=1.0003
h2_flush=181776
h2_pt_bytes=5957239796
ct_sends=181777
materialize=1
--- stats proactr h2.s1m ---
peer=proactr
reqs=18661
seal_calls=314129
ssl_write_ok=1
pt_bytes=19375258210
ct_bytes=19375668752
ct_pt_ratio=1.0000
h2_flush=314128
h2_pt_bytes=19375258108
ct_sends=314129
materialize=1
--- stats proactr h1s.plaintext ---
peer=proactr
reqs=3117652
seal_calls=3117652
ssl_write_ok=3117652
pt_bytes=352294665
ct_bytes=420883009
ct_pt_ratio=1.1947
h2_flush=0
h2_pt_bytes=0
ct_sends=3117652
materialize=3117652
--- stats proactr h1s.s4k ---
peer=proactr
reqs=2733421
seal_calls=2733421
ssl_write_ok=2733421
pt_bytes=11474897262
ct_bytes=11535032524
ct_pt_ratio=1.0052
h2_flush=0
h2_pt_bytes=0
ct_sends=2733421
materialize=2733421
--- stats proactr h1s.s64k ---
peer=proactr
reqs=275958
seal_calls=551915
ssl_write_ok=551915
pt_bytes=18113541625
ct_bytes=18119612701
ct_pt_ratio=1.0003
```
