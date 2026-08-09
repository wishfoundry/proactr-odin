# TLS/H2 peer matrix results

- **Host:** ranch-bastion · Linux 6.14.0-37-generic
- **When:** 2026-08-09T04:32Z
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
proactr  h2     plaintext  181061.47  ok      h2         0       0        0
proactr  h2     s4k        157958.53  ok      h2         0       0        0
proactr  h2     s64k       52443.80   ok      h2         0       0        0
proactr  h2     s1m        2919.00    ok      h2         0       0        0
proactr  h1s    plaintext  189145.80  ok      http/1.1   0       0        0
proactr  h1s    s4k        175842.93  ok      http/1.1   0       0        0
proactr  h1s    s64k       52128.73   ok      http/1.1   0       0        0
proactr  h1s    s1m        4680.93    ok      http/1.1   0       0        0
ntex     h2     plaintext  133033.13  ok      h2         0       0        0
ntex     h2     s4k        124270.53  ok      h2         0       0        0
ntex     h2     s64k       33639.67   ok      h2         0       0        0
ntex     h2     s1m        1151.73    ok      h2         0       0        0
ntex     h1s    plaintext  176266.27  ok      http/1.1   0       0        0
ntex     h1s    s4k        155217.80  ok      http/1.1   0       0        0
ntex     h1s    s64k       42407.20   ok      http/1.1   0       0        0
ntex     h1s    s1m        1814.87    ok      http/1.1   0       0        0
drogon   h2     plaintext  N/A        no_h2   http/1.1   0       0        0
drogon   h2     s4k        N/A        no_h2   http/1.1   0       0        0
drogon   h2     s64k       N/A        no_h2   http/1.1   0       0        0
drogon   h2     s1m        N/A        no_h2   http/1.1   0       0        0
drogon   h1s    plaintext  209671.67  ok                 0       0        0
drogon   h1s    s4k        184677.40  ok      http/1.1   0       0        0
drogon   h1s    s64k       48207.80   ok      http/1.1   0       0        0
drogon   h1s    s1m        4404.60    ok      http/1.1   0       0        0
go       h2     plaintext  91653.00   ok      h2         0       0        0
go       h2     s4k        88942.53   ok      h2         0       0        0
go       h2     s64k       34099.67   ok      h2         0       0        0
go       h2     s1m        3327.73    ok      h2         0       0        0
go       h1s    plaintext  166656.47  ok      http/1.1   0       0        0
go       h1s    s4k        104884.67  ok      http/1.1   0       0        0
go       h1s    s64k       45383.87   ok      http/1.1   0       0        0
go       h1s    s1m        4857.20    ok      http/1.1   0       0        0
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
reqs=2716079
seal_calls=2716179
ssl_write_ok=1
pt_bytes=181974228
ct_bytes=241915656
ct_pt_ratio=1.3294
h2_flush=2716178
h2_pt_bytes=181974126
ct_sends=2716381
materialize=1
--- stats proactr h2.s4k ---
peer=proactr
reqs=2369536
seal_calls=2369636
ssl_write_ok=1
pt_bytes=9833158952
ct_bytes=9885476434
ct_pt_ratio=1.0053
h2_flush=2369635
h2_pt_bytes=9833158850
ct_sends=2369838
materialize=1
--- stats proactr h2.s64k ---
peer=proactr
reqs=786818
seal_calls=786918
ssl_write_ok=1
pt_bytes=51622013091
ct_bytes=51708741873
ct_pt_ratio=1.0017
h2_flush=786917
h2_pt_bytes=51622012989
ct_sends=787120
materialize=1
--- stats proactr h2.s1m ---
peer=proactr
reqs=201
seal_calls=219514
ssl_write_ok=1
pt_bytes=46025637885
ct_bytes=46088557783
ct_pt_ratio=1.0014
h2_flush=219513
h2_pt_bytes=46025637783
ct_sends=219716
materialize=1
--- stats proactr h1s.plaintext ---
peer=proactr
reqs=2837243
seal_calls=2837243
ssl_write_ok=2837243
pt_bytes=320608448
ct_bytes=383213884
ct_pt_ratio=1.1953
h2_flush=0
h2_pt_bytes=0
ct_sends=2837445
materialize=2837243
--- stats proactr h1s.s4k ---
peer=proactr
reqs=2637700
seal_calls=2637700
ssl_write_ok=2637700
pt_bytes=11073060504
ct_bytes=11131275994
ct_pt_ratio=1.0053
h2_flush=0
h2_pt_bytes=0
ct_sends=2637902
materialize=2637700
--- stats proactr h1s.s64k ---
peer=proactr
reqs=1
seal_calls=1564001
ssl_write_ok=1564001
pt_bytes=51329698102
ct_bytes=51415904214
ct_pt_ratio=1.0017
```
