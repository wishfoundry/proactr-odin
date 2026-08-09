# TLS/H2 peer matrix results

- **Host:** Benjamins-MacBook-Pro.local · Darwin 25.5.0
- **When:** 2026-08-09T15:09Z
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
proactr  h2     plaintext  93346.80   ok      h2         0       0        0
proactr  h2     s4k        78256.33   ok      h2         0       0        0
proactr  h2     s64k       27588.13   ok      h2         0       0        0
proactr  h2     s1m        1752.80    ok      h2         0       0        0
proactr  h1s    plaintext  116035.40  ok      http/1.1   0       0        0
proactr  h1s    s4k        99221.60   ok      http/1.1   0       0        0
proactr  h1s    s64k       29245.13   ok      http/1.1   0       0        0
proactr  h1s    s1m        2753.00    ok      http/1.1   0       0        0
ntex     h2     plaintext  127276.20  ok      h2         0       0        0
ntex     h2     s4k        130201.87  ok      h2         0       0        0
ntex     h2     s64k       47622.47   ok      h2         0       0        0
ntex     h2     s1m        1089.67    ok      h2         0       0        0
ntex     h1s    plaintext  136117.67  ok      http/1.1   0       0        0
ntex     h1s    s4k        138624.60  ok      http/1.1   0       0        0
ntex     h1s    s64k       58675.87   ok      http/1.1   0       0        0
ntex     h1s    s1m        2011.20    ok      http/1.1   0       0        0
drogon   h2     plaintext  N/A        no_h2   http/1.1   0       0        0
drogon   h2     s4k        N/A        no_h2   http/1.1   0       0        0
drogon   h2     s64k       N/A        no_h2   http/1.1   0       0        0
drogon   h2     s1m        N/A        no_h2   http/1.1   0       0        0
drogon   h1s    plaintext  152412.33  ok      http/1.1   0       0        0
drogon   h1s    s4k        153816.60  ok      http/1.1   0       0        0
drogon   h1s    s64k       69724.53   ok      http/1.1   0       0        0
drogon   h1s    s1m        8923.07    ok      http/1.1   0       0        0
go       h2     plaintext  112936.67  ok      h2         0       0        0
go       h2     s4k        111749.33  ok      h2         0       0        0
go       h2     s64k       38278.80   ok      h2         0       0        0
go       h2     s1m        2989.73    ok      h2         0       0        0
go       h1s    plaintext  145066.27  ok      http/1.1   0       0        0
go       h1s    s4k        121342.00  ok      http/1.1   0       0        0
go       h1s    s64k       52535.27   ok      http/1.1   0       0        0
go       h1s    s1m        4913.27    ok      http/1.1   0       0        0
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
reqs=1400388
seal_calls=1400488
seals_per_req=1.000
ssl_write_ok=1
pt_bytes=47652660
ct_bytes=78651060
ct_pt_ratio=1.6505
h2_flush=1400487
h2_pt_bytes=47652558
ct_sends=1400690
materialize=1
--- stats proactr h2.s4k ---
peer=proactr
reqs=1174025
seal_calls=1174125
seals_per_req=1.000
ssl_write_ok=1
pt_bytes=4833087210
ct_bytes=4859105624
ct_pt_ratio=1.0054
h2_flush=1174124
h2_pt_bytes=4833087108
ct_sends=1174327
materialize=1
--- stats proactr h2.s64k ---
peer=proactr
reqs=413963
seal_calls=414063
seals_per_req=1.000
ssl_write_ok=1
pt_bytes=27142767310
ct_bytes=27188484216
ct_pt_ratio=1.0017
h2_flush=414062
h2_pt_bytes=27142767208
ct_sends=414265
materialize=1
--- stats proactr h2.s1m ---
peer=proactr
reqs=201
seal_calls=131808
seals_per_req=655.761
ssl_write_ok=1
pt_bytes=27623195624
ct_bytes=27661037014
ct_pt_ratio=1.0014
h2_flush=131807
h2_pt_bytes=27623195522
ct_sends=132010
materialize=1
--- stats proactr h1s.plaintext ---
peer=proactr
reqs=1740630
seal_calls=1740630
seals_per_req=1.000
ssl_write_ok=1740630
pt_bytes=196691179
ct_bytes=235173303
ct_pt_ratio=1.1956
h2_flush=0
h2_pt_bytes=0
ct_sends=1740832
materialize=1740630
--- stats proactr h1s.s4k ---
peer=proactr
reqs=1488403
seal_calls=1488403
seals_per_req=1.000
ssl_write_ok=1488403
pt_bytes=6248311698
ct_bytes=6281234790
ct_pt_ratio=1.0053
h2_flush=0
h2_pt_bytes=0
ct_sends=1488584
materialize=1488403
--- stats proactr h1s.s64k ---
peer=proactr
```
