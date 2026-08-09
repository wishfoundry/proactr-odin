> **SCOREBOARD (fair):** four peers · INSTRUMENT=0 (no PHASE) · fail-closed h2load · WORKERS=8 c=100 z=15s · ranch-bastion
> Critic: R1 PASS → R2 PASS (`results/CRITIC_R2.md`). R1 instrumented copy: `BASTION_TLS_H2_R1_INSTRUMENTED.md`.

# TLS/H2 peer matrix results

- **Host:** ranch-bastion · Linux 6.14.0-37-generic
- **When:** 2026-08-09T02:23Z
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
peer     proto  test       rps        status  app_proto                                                            failed  errored  timeout
proactr  h2     plaintext  179258.40  ok      h2                                                                   0       0        0
proactr  h2     s4k        153512.93  ok      h2                                                                   0       0        0
proactr  h2     s64k       5852.13    ok      h2                                                                   0       0        0
proactr  h2     s1m        976.20     ok      h2                                                                   0       0        0
proactr  h1s    plaintext  207490.53  ok      http/1.1                                                             0       0        0
proactr  h1s    s4k        187296.53  ok      http/1.1                                                             0       0        0
proactr  h1s    s64k       10631.67   ok      http/1.1                                                             0       0        0
proactr  h1s    s1m        3806.87    ok      http/1.1                                                             0       0        0
ntex     h2     plaintext  130448.00  ok      h2                                                                   0       0        0
ntex     h2     s4k        125035.73  ok      h2                                                                   0       0        0
ntex     h2     s64k       35112.27   ok      h2                                                                   0       0        0
ntex     h2     s1m        1149.33    ok      h2                                                                   0       0        0
ntex     h1s    plaintext  189181.67  ok      http/1.1                                                             0       0        0
ntex     h1s    s4k        153007.00  ok      http/1.1                                                             0       0        0
ntex     h1s    s64k       42255.13   ok      http/1.1                                                             0       0        0
ntex     h1s    s1m        1818.00    ok      http/1.1                                                             0       0        0
drogon   h2     plaintext  N/A        no_h2   http/1.1                                                             0       0        0
drogon   h2     s4k        N/A        no_h2   No protocol negotiated. Fallback behaviour may be activatedhttp/1.1  0       0        0
drogon   h2     s64k       N/A        no_h2   http/1.1                                                             0       0        0
drogon   h2     s1m        N/A        no_h2   http/1.1                                                             0       0        0
drogon   h1s    plaintext  212696.73  ok      http/1.1                                                             0       0        0
drogon   h1s    s4k        183889.20  ok      http/1.1                                                             0       0        0
drogon   h1s    s64k       49215.47   ok      http/1.1                                                             0       0        0
drogon   h1s    s1m        4538.00    ok      http/1.1                                                             0       0        0
go       h2     plaintext  91108.47   ok      h2                                                                   0       0        0
go       h2     s4k        87482.93   ok      h2                                                                   0       0        0
go       h2     s64k       32141.40   ok      h2                                                                   0       0        0
go       h2     s1m        3403.20    ok      h2                                                                   0       0        0
go       h1s    plaintext  168796.53  ok      http/1.1                                                             0       0        0
go       h1s    s4k        101964.80  ok      http/1.1                                                             0       0        0
go       h1s    s64k       45576.33   ok      http/1.1                                                             0       0        0
go       h1s    s1m        4699.47    ok      http/1.1                                                             0       0        0
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
WARN drogon h2 s4k negotiated 'No protocol negotiated. Fallback behaviour may be activatedhttp/1.1' not h2 → N/A
WARN drogon h2 s64k negotiated 'http/1.1' not h2 → N/A
WARN drogon h2 s1m negotiated 'http/1.1' not h2 → N/A
```

## Instrumentation (excerpt)
```
--- stats proactr h2.plaintext ---
peer=proactr
reqs=2689133
seal_calls=2689133
ssl_write_ok=1
pt_bytes=180162146
ct_bytes=239323072
ct_pt_ratio=1.3284
h2_flush=2689132
h2_pt_bytes=180162044
ct_sends=2689133
materialize=1
--- stats proactr h2.s4k ---
peer=proactr
reqs=2302957
seal_calls=2302957
ssl_write_ok=1
pt_bytes=9556441102
ct_bytes=9607106156
ct_pt_ratio=1.0053
h2_flush=2302956
h2_pt_bytes=9556441000
ct_sends=2302957
materialize=1
--- stats proactr h2.s64k ---
peer=proactr
reqs=88082
seal_calls=175963
ssl_write_ok=1
pt_bytes=5766491279
ct_bytes=5768429083
ct_pt_ratio=1.0003
h2_flush=175962
h2_pt_bytes=5766491177
ct_sends=175963
materialize=1
--- stats proactr h2.s1m ---
peer=proactr
reqs=14879
seal_calls=249899
ssl_write_ok=1
pt_bytes=15411389460
ct_bytes=15411716798
ct_pt_ratio=1.0000
h2_flush=249898
h2_pt_bytes=15411389358
ct_sends=249899
materialize=1
--- stats proactr h1s.plaintext ---
peer=proactr
reqs=3112416
seal_calls=3112416
ssl_write_ok=3112416
pt_bytes=351702997
ct_bytes=420176149
ct_pt_ratio=1.1947
h2_flush=0
h2_pt_bytes=0
ct_sends=3112416
materialize=3112416
--- stats proactr h1s.s4k ---
peer=proactr
reqs=2809505
seal_calls=2809505
ssl_write_ok=2809505
pt_bytes=11794297894
ct_bytes=11856107004
ct_pt_ratio=1.0052
h2_flush=0
h2_pt_bytes=0
ct_sends=2809505
materialize=2809505
--- stats proactr h1s.s64k ---
peer=proactr
reqs=159556
seal_calls=319111
ssl_write_ok=319111
pt_bytes=10473030747
ct_bytes=10476540979
ct_pt_ratio=1.0003
```
