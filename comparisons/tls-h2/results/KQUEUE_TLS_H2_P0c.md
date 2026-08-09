# TLS/H2 peer matrix results

- **Host:** Benjamins-MacBook-Pro.local · Darwin 25.5.0
- **When:** 2026-08-09T19:25Z
- **WORKERS=8** · **BENCH_C=100** · **BENCH_Z=10s** · **WARMUP_Z=2s**
- **Loadgen:** h2load -c 100 -D 10 -t 4 · SSL_CERT_FILE=matrix cert
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
proactr  h2     plaintext  94807.10   ok      h2         0       0        0
proactr  h2     s4k        81837.80   ok      h2         0       0        0
proactr  h2     s1m        2509.20    ok      h2         0       0        0
proactr  h1s    plaintext  118981.50  ok      http/1.1   0       0        0
proactr  h1s    s4k        103037.70  ok      http/1.1   0       0        0
proactr  h1s    s1m        2772.30    ok      http/1.1   0       0        0
ntex     h2     plaintext  125784.30  ok      h2         0       0        0
ntex     h2     s4k        128527.90  ok      h2         0       0        0
ntex     h2     s1m        1112.20    ok      h2         0       0        0
ntex     h1s    plaintext  135705.90  ok      http/1.1   0       0        0
ntex     h1s    s4k        139469.40  ok      http/1.1   0       0        0
ntex     h1s    s1m        2041.70    ok      http/1.1   0       0        0
drogon   h2     plaintext  N/A        no_h2   http/1.1   0       0        0
drogon   h2     s4k        N/A        no_h2   http/1.1   0       0        0
drogon   h2     s1m        N/A        no_h2   http/1.1   0       0        0
drogon   h1s    plaintext  150911.40  ok      http/1.1   0       0        0
drogon   h1s    s4k        150907.70  ok      http/1.1   0       0        0
drogon   h1s    s1m        9215.50    ok      http/1.1   0       0        0
go       h2     plaintext  112206.60  ok      h2         0       0        0
go       h2     s4k        112265.60  ok      h2         0       0        0
go       h2     s1m        3251.90    ok      h2         0       0        0
go       h1s    plaintext  143768.60  ok      http/1.1   0       0        0
go       h1s    s4k        120381.20  ok      http/1.1   0       0        0
go       h1s    s1m        4801.90    ok      http/1.1   0       0        0
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
WARN drogon h2 s1m negotiated 'http/1.1' not h2 → N/A
```

## Instrumentation (excerpt)
```
--- stats proactr h2.plaintext ---
peer=proactr
reqs=1896386
seal_calls=948343
seals_per_req=0.500
ssl_write_ok=1
pt_bytes=32267230
ct_bytes=53318440
ct_pt_ratio=1.6524
h2_flush=948342
h2_pt_bytes=32267128
ct_sends=948545
materialize=1
--- stats proactr h2.s4k ---
peer=proactr
reqs=1636998
seal_calls=818649
seals_per_req=0.500
ssl_write_ok=1
pt_bytes=3369580818
ct_bytes=3387778760
ct_pt_ratio=1.0054
h2_flush=818648
h2_pt_bytes=3369580716
ct_sends=818851
materialize=1
--- stats proactr h2.s1m ---
peer=proactr
reqs=50312
seal_calls=125697
seals_per_req=2.498
ssl_write_ok=1
pt_bytes=26334566481
ct_bytes=26370652139
ct_pt_ratio=1.0014
h2_flush=125696
h2_pt_bytes=26334566379
ct_sends=125899
materialize=1
--- stats proactr h1s.plaintext ---
peer=proactr
reqs=1189915
seal_calls=1189915
seals_per_req=1.000
ssl_write_ok=1189915
pt_bytes=134460384
ct_bytes=160826778
ct_pt_ratio=1.1961
h2_flush=0
h2_pt_bytes=0
ct_sends=1190117
materialize=1189915
--- stats proactr h1s.s4k ---
peer=proactr
reqs=1030459
seal_calls=1030459
seals_per_req=1.000
ssl_write_ok=1030459
pt_bytes=4325862786
ct_bytes=4348713022
ct_pt_ratio=1.0053
h2_flush=0
h2_pt_bytes=0
ct_sends=1030644
materialize=1030459
--- stats proactr h1s.s1m ---
peer=proactr
reqs=1
seal_calls=138784
seals_per_req=138784.000
ssl_write_ok=138784
pt_bytes=29103521707
ct_bytes=29143372619
ct_pt_ratio=1.0014
h2_flush=0
h2_pt_bytes=0
ct_sends=138936
materialize=1
--- stats proactr final ---
peer=proactr
```
