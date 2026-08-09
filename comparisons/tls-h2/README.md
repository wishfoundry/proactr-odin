# TLS / HTTP/2 peer matrix

**Goal:** measure **proactr TLS + H2** against **ntex, drogon, go** under comparable
conditions — same routes, body sizes, worker count, loadgen, host, and certs.

**Host of record:** ranch-bastion (Linux).

This is **not** `comparisons/tfb` (cleartext H1). Do not mix rankings.

---

## Fairness contract

| Control | Value |
|---------|--------|
| Workers | `WORKERS` (default **8**) |
| Listen | `0.0.0.0:$PORT` (default **18443**) |
| TLS | same self-signed cert/key under `certs/` |
| Loadgen | **h2load** `-c BENCH_C -D BENCH_Z -t 4` |
| Concurrency | `BENCH_C` (default **100**) |
| Duration | `BENCH_Z` seconds (default **15**) |
| Warmup | `WARMUP_Z` (default **3**) |
| Body checks | length **and** content prefix before load |
| H2 honesty | cell requires `Application protocol: h2` else **N/A** |
| Failures | nonzero failed/errored/timeout → **INVALID** |

### Protocols

| ID | Client | Measures |
|----|--------|----------|
| **h2** | h2load ALPN h2 | TLS + HTTP/2 oneshot |
| **h1s** | `h2load --h1` | TLS + HTTP/1.1 oneshot |

### Routes

| Test | Path | Body |
|------|------|------|
| plaintext | `/plaintext` | 13 B `Hello, World!` |
| s4k | `/s/4k` | 4096 B pattern |
| s64k | `/s/64k` | 65536 B pattern |
| s1m | `/s/1m` | 1048576 B pattern |

### Peers

| ID | Stack | TLS | H2 |
|----|--------|-----|-----|
| **proactr** | io_uring | OpenSSL mem-BIO | product ALPN h2 |
| **ntex** | neon-uring | OpenSSL | bind_openssl ALPN |
| **drogon** | trantor **epoll** | OpenSSL | primarily H1; h2 may be N/A |
| **go** | net/http | crypto/tls | automatic HTTP/2 |

### Instrumentation

All peers: `GET /_matrix/stats` after each cell (see `instrumentation.txt`).

- **proactr:** seal_calls, pt_bytes, ct_bytes, ct_pt_ratio, h2_flush, ct_sends, materialize (+ PHASE if built with `HTTP_PHASE_STATS`)
- **others:** reqs, bytes, tls/io labels

---

## Run

```bash
./comparisons/tls-h2/gen_certs.sh
SERVERS="proactr ntex drogon go" WORKERS=8 ./comparisons/tls-h2/run_matrix.sh

# ranch-bastion
./comparisons/tls-h2/run_on_bastion.sh
```

Outputs: `/tmp/proactr-tls-h2/` + `results/SUMMARY.md`, `summary.tsv`, `instrumentation.txt`.

Critic checklist: [`CRITIC.md`](CRITIC.md).
