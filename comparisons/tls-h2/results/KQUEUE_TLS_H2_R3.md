# TLS/H2 peer matrix results

- **Host:** Benjamins-MacBook-Pro.local · Darwin 25.5.0
- **When:** 2026-08-09T16:32Z
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
proactr  h2     plaintext  93745.00   ok      h2         0       0        0
proactr  h2     s4k        78865.80   ok      h2         0       0        0
proactr  h2     s64k       27921.07   ok      h2         0       0        0
proactr  h2     s1m        1783.40    ok      h2         0       0        0
proactr  h1s    plaintext  112981.93  ok      http/1.1   0       0        0
proactr  h1s    s4k        96423.87   ok      http/1.1   0       0        0
proactr  h1s    s64k       29566.53   ok      http/1.1   0       0        0
proactr  h1s    s1m        2778.33    ok      http/1.1   0       0        0
ntex     h2     plaintext  128197.27  ok      h2         0       0        0
ntex     h2     s4k        132529.47  ok      h2         0       0        0
ntex     h2     s64k       49094.27   ok      h2         0       0        0
ntex     h2     s1m        1121.80    ok      h2         0       0        0
ntex     h1s    plaintext  132578.53  ok      http/1.1   0       0        0
ntex     h1s    s4k        138991.47  ok      http/1.1   0       0        0
ntex     h1s    s64k       63417.67   ok      http/1.1   0       0        0
ntex     h1s    s1m        2076.20    ok      http/1.1   0       0        0
drogon   h2     plaintext  N/A        no_h2   http/1.1   0       0        0
drogon   h2     s4k        N/A        no_h2   http/1.1   0       0        0
drogon   h2     s64k       N/A        no_h2   http/1.1   0       0        0
drogon   h2     s1m        N/A        no_h2   http/1.1   0       0        0
drogon   h1s    plaintext  149750.40  ok      http/1.1   0       0        0
drogon   h1s    s4k        150610.47  ok      http/1.1   0       0        0
drogon   h1s    s64k       67145.20   ok      http/1.1   0       0        0
drogon   h1s    s1m        9232.93    ok      http/1.1   0       0        0
go       h2     plaintext  112121.87  ok      h2         0       0        0
go       h2     s4k        111925.27  ok      h2         0       0        0
go       h2     s64k       36681.60   ok      h2         0       0        0
go       h2     s1m        3036.33    ok      h2         0       0        0
go       h1s    plaintext  142107.60  ok      http/1.1   0       0        0
go       h1s    s4k        119783.33  ok      http/1.1   0       0        0
go       h1s    s64k       51724.07   ok      http/1.1   0       0        0
go       h1s    s1m        4692.80    ok      http/1.1   0       0        0
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
reqs=1406343
seal_calls=1406443
seals_per_req=1.000
ssl_write_ok=1
pt_bytes=47854130
ct_bytes=78983540
ct_pt_ratio=1.6505
h2_flush=1406442
h2_pt_bytes=47854028
ct_sends=1406645
materialize=1
--- stats proactr h2.s4k ---
peer=proactr
reqs=1183154
seal_calls=1183254
seals_per_req=1.000
ssl_write_ok=1
pt_bytes=4870671103
ct_bytes=4896890355
ct_pt_ratio=1.0054
h2_flush=1183253
h2_pt_bytes=4870671001
ct_sends=1183456
materialize=1
--- stats proactr h2.s64k ---
peer=proactr
reqs=418969
seal_calls=419069
seals_per_req=1.000
ssl_write_ok=1
pt_bytes=27471080814
ct_bytes=27517348380
ct_pt_ratio=1.0017
h2_flush=419068
h2_pt_bytes=27471080712
ct_sends=419271
materialize=1
--- stats proactr h2.s1m ---
peer=proactr
reqs=201
seal_calls=134193
seals_per_req=667.627
ssl_write_ok=1
pt_bytes=28128354722
ct_bytes=28166884162
ct_pt_ratio=1.0014
h2_flush=134192
h2_pt_bytes=28128354620
ct_sends=134395
materialize=1
--- stats proactr h1s.plaintext ---
peer=proactr
reqs=1694824
seal_calls=1694824
seals_per_req=1.000
ssl_write_ok=1694824
pt_bytes=191515101
ct_bytes=228989493
ct_pt_ratio=1.1957
h2_flush=0
h2_pt_bytes=0
ct_sends=1695026
materialize=1694824
--- stats proactr h1s.s4k ---
peer=proactr
reqs=1446437
seal_calls=1446437
seals_per_req=1.000
ssl_write_ok=1446437
pt_bytes=6072138430
ct_bytes=6104139226
ct_pt_ratio=1.0053
h2_flush=0
h2_pt_bytes=0
ct_sends=1446620
materialize=1446437
--- stats proactr h1s.s64k ---
peer=proactr
```
