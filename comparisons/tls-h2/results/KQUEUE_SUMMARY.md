# TLS/H2 peer matrix results

- **Host:** Benjamins-MacBook-Pro.local · Darwin 25.5.0
- **When:** 2026-08-09T13:40Z
- **WORKERS=8** · **BENCH_C=100** · **BENCH_Z=15s** · **WARMUP_Z=3s**
- **Loadgen:** h2load -c 100 -D 15 -t 4 · SSL_CERT_FILE=matrix cert
- **Protocols:** h2 h1s (h2 = ALPN h2 required; h1s = TLS HTTP/1.1)
- **Peers requested:** proactr ntex drogon go
- **Peers built:**  proactr ntex drogon go

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
proactr  h2     plaintext  61844.60   ok      h2         0       0        0
proactr  h2     s4k        64475.67   ok      h2         0       0        0
proactr  h2     s64k       25116.00   ok      h2         0       0        0
proactr  h2     s1m        1744.67    ok      h2         0       0        0
proactr  h1s    plaintext  114932.67  ok      http/1.1   0       0        0
proactr  h1s    s4k        99567.93   ok      http/1.1   0       0        0
proactr  h1s    s64k       29225.60   ok      http/1.1   0       0        0
proactr  h1s    s1m        2726.13    ok      http/1.1   0       0        0
ntex     h2     plaintext  128037.87  ok      h2         0       0        0
ntex     h2     s4k        131066.33  ok      h2         0       0        0
ntex     h2     s64k       47385.87   ok      h2         0       0        0
ntex     h2     s1m        1094.13    ok      h2         0       0        0
ntex     h1s    plaintext  136888.87  ok      http/1.1   0       0        0
ntex     h1s    s4k        138722.20  ok      http/1.1   0       0        0
ntex     h1s    s64k       61712.53   ok      http/1.1   0       0        0
ntex     h1s    s1m        2016.93    ok      http/1.1   0       0        0
drogon   h2     plaintext  N/A        no_h2   http/1.1   0       0        0
drogon   h2     s4k        N/A        no_h2   http/1.1   0       0        0
drogon   h2     s64k       N/A        no_h2   http/1.1   0       0        0
drogon   h2     s1m        N/A        no_h2   http/1.1   0       0        0
drogon   h1s    plaintext  151384.60  ok      http/1.1   0       0        0
drogon   h1s    s4k        152587.13  ok      http/1.1   0       0        0
drogon   h1s    s64k       67282.33   ok      http/1.1   0       0        0
drogon   h1s    s1m        8989.27    ok      http/1.1   0       0        0
go       h2     plaintext  113020.53  ok      h2         0       0        0
go       h2     s4k        111848.00  ok      h2         0       0        0
go       h2     s64k       37731.87   ok      h2         0       0        0
go       h2     s1m        3140.13    ok      h2         0       0        0
go       h1s    plaintext  144147.07  ok      http/1.1   0       0        0
go       h1s    s4k        121110.93  ok      http/1.1   0       0        0
go       h1s    s64k       52752.20   ok      http/1.1   0       0        0
go       h1s    s1m        4762.80    ok      http/1.1   0       0        0
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
reqs=927840
seal_calls=927940
ssl_write_ok=1
pt_bytes=62162215
ct_bytes=82764559
ct_pt_ratio=1.3314
h2_flush=927939
h2_pt_bytes=62162113
ct_sends=928142
materialize=1
--- stats proactr h2.s4k ---
peer=proactr
reqs=967302
seal_calls=967402
ssl_write_ok=1
pt_bytes=4013887852
ct_bytes=4035358360
ct_pt_ratio=1.0053
h2_flush=967401
h2_pt_bytes=4013887750
ct_sends=967604
materialize=1
--- stats proactr h2.s64k ---
peer=proactr
reqs=376891
seal_calls=376991
ssl_write_ok=1
pt_bytes=24723833132
ct_bytes=24765472118
ct_pt_ratio=1.0017
h2_flush=376990
h2_pt_bytes=24723833030
ct_sends=377193
materialize=1
--- stats proactr h2.s1m ---
peer=proactr
reqs=201
seal_calls=131286
ssl_write_ok=1
pt_bytes=27519093032
ct_bytes=27556790938
ct_pt_ratio=1.0014
h2_flush=131285
h2_pt_bytes=27519092930
ct_sends=131488
materialize=1
--- stats proactr h1s.plaintext ---
peer=proactr
reqs=1724084
seal_calls=1724084
ssl_write_ok=1724084
pt_bytes=194821481
ct_bytes=232939593
ct_pt_ratio=1.1957
h2_flush=0
h2_pt_bytes=0
ct_sends=1724286
materialize=1724084
--- stats proactr h1s.s4k ---
peer=proactr
reqs=1493597
seal_calls=1493597
ssl_write_ok=1493597
pt_bytes=6270116110
ct_bytes=6303152514
ct_pt_ratio=1.0053
h2_flush=0
h2_pt_bytes=0
ct_sends=1493776
materialize=1493597
--- stats proactr h1s.s64k ---
peer=proactr
reqs=1
seal_calls=876965
ssl_write_ok=876965
pt_bytes=28781520100
ct_bytes=28829941406
ct_pt_ratio=1.0017
```
