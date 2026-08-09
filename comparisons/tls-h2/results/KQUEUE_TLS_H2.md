# Darwin / kqueue TLS·H2 peer matrix

**First measured numbers for proactr TLS on kqueue.** Prior docs only had Linux/io_uring bastion results.

| Field | Value |
|-------|--------|
| Host | Benjamins-MacBook-Pro.local · Darwin 25.5.0 · arm64 (M2 Pro, Mac14,9) |
| Cores / RAM | 12 · 32 GiB |
| When | 2026-08-09T13:40Z |
| Load | `h2load -c 100 -D 15 -t 4` · same self-signed certs · WORKERS=8 |
| Peers built | proactr · ntex · drogon · go (all four) |
| Fail-closed | body len+prefix OK; h2 requires ALPN `h2`; failed/errored/timeout → INVALID |
| Artifacts | `kqueue_summary.tsv`, `KQUEUE_SUMMARY.md`, `kqueue_instrumentation.txt`, `kqueue_host.txt` |

## Honest backend labels (Darwin)

| Peer | I/O | TLS | H2 |
|------|-----|-----|-----|
| **proactr** | **kqueue** (not io_uring) | OpenSSL mem-BIO dynlib (Homebrew openssl@3) | ALPN h2 product path |
| **ntex** | **tokio** (not neon-uring — Linux-only in this crate) | OpenSSL via ntex-tls | ALPN h2 via `bind_openssl` |
| **drogon** | trantor **kqueue** | OpenSSL | H1 only → h2 cells **N/A** |
| **go** | net/http **kqueue** | crypto/tls | automatic HTTP/2 |

Do **not** treat this matrix as “proactr vs ntex-uring.” On Darwin, ntex is a tokio OpenSSL peer. Cross-host absolute RPS is not comparable to bastion (different silicon/kernel). Relative rank **within** a host is the useful signal.

## RPS matrix (Darwin)

```
peer     proto  test       rps        status
proactr  h2     plaintext  61844.60   ok
proactr  h2     s4k        64475.67   ok
proactr  h2     s64k       25116.00   ok
proactr  h2     s1m         1744.67   ok
proactr  h1s    plaintext 114932.67   ok
proactr  h1s    s4k        99567.93   ok
proactr  h1s    s64k       29225.60   ok
proactr  h1s    s1m         2726.13   ok
ntex     h2     plaintext 128037.87   ok
ntex     h2     s4k       131066.33   ok
ntex     h2     s64k       47385.87   ok
ntex     h2     s1m         1094.13   ok
ntex     h1s    plaintext 136888.87   ok
ntex     h1s    s4k       138722.20   ok
ntex     h1s    s64k       61712.53   ok
ntex     h1s    s1m         2016.93   ok
drogon   h2     *          N/A        no_h2
drogon   h1s    plaintext 151384.60   ok
drogon   h1s    s4k       152587.13   ok
drogon   h1s    s64k       67282.33   ok
drogon   h1s    s1m         8989.27   ok
go       h2     plaintext 113020.53   ok
go       h2     s4k       111848.00   ok
go       h2     s64k       37731.87   ok
go       h2     s1m         3140.13   ok
go       h1s    plaintext 144147.07   ok
go       h1s    s4k       121110.93   ok
go       h1s    s64k       52752.20   ok
go       h1s    s1m         4762.80   ok
```

## Rank (Darwin only)

### HTTP/2 TLS (true H2 peers: proactr, ntex, go)

| Cell | 1st | 2nd | 3rd | proactr vs best |
|------|-----|-----|-----|-----------------|
| plaintext | ntex 128k | go 113k | **proactr 62k** | **0.48×** ntex |
| s4k | ntex 131k | go 112k | **proactr 64k** | **0.49×** ntex |
| s64k | ntex 47k | go 38k | **proactr 25k** | **0.53×** ntex |
| s1m | **go 3.1k** | **proactr 1.7k** | ntex 1.1k | **0.56×** go · **1.59×** ntex |

### TLS HTTP/1.1 (all four)

| Cell | 1st | 2nd | 3rd | 4th | proactr vs best |
|------|-----|-----|-----|-----|-----------------|
| plaintext | drogon 151k | go 144k | ntex 137k | **proactr 115k** | **0.76×** |
| s4k | drogon 153k | ntex 139k | go 121k | **proactr 100k** | **0.65×** |
| s64k | drogon 67k | ntex 62k | go 53k | **proactr 29k** | **0.43×** |
| s1m | drogon 9.0k | go 4.8k | **proactr 2.7k** | ntex 2.0k | **0.30×** drogon |

**Takeaway:** On this Mac, proactr’s kqueue TLS path is **correct** (ALPN h2, zero failed/timeout cells) but **not peer-competitive** on small/mid H2 or bulk H1.s. Only clear win is **h2 s1m vs ntex** (still behind go).

## vs Linux bastion (context only — not same host)

Same harness, same WORKERS/C/D, dual-CT stack. Bastion = ranch-bastion Linux io_uring (`BASTION_TLS_H2_RERANK.md`).

| Cell | proactr bastion (io_uring) | proactr Darwin (kqueue) | ratio kqueue/uring |
|------|---------------------------:|------------------------:|-------------------:|
| h2 plaintext | 181061 | 61845 | **0.34×** |
| h2 s4k | 157959 | 64476 | **0.41×** |
| h2 s64k | 52444 | 25116 | **0.48×** |
| h2 s1m | 2919 | 1745 | **0.60×** |
| h1s plaintext | 189146 | 114933 | **0.61×** |
| h1s s64k | 52129 | 29226 | **0.56×** |
| h1s s1m | 4681 | 2726 | **0.58×** |

Bastion relative rank was **proactr first on H2 small/mid** (vs ntex-uring + go). Darwin relative rank flips: **ntex/go ahead on H2 small/mid**. That is a real backend-class gap signal (kqueue host + same mem-BIO seal path), not just “Mac is slower.”

## Instrumentation notes (proactr)

From `kqueue_instrumentation.txt`:

- H2 cells: `ssl_write_ok=1` with high `seal_calls`/`h2_flush`/`ct_sends` — dual-CT / flush path engaged.
- H1.s oneshot: `ssl_write_ok ≈ reqs` materialize path.
- H1.s s64k scrape shows `reqs=1` while `seal_calls≈877k` — **path_metrics reset/scrape quirk under long seal windows**, not zero traffic (h2load reported ~29k rps succeeded). Treat per-cell RPS from h2load as ground truth; stats counters need care for multi-chunk TLS responses.

## Harness fixes applied for Darwin

1. **`kill_port`:** BSD has no `xargs -r`; macOS `fuser` is not Linux fuser → **lsof-first on Darwin**.
2. **Bash 3.2 + `set -u`:** empty `"${array[@]}"` is unbound → h2load flags as scalar (`--h1` or omit).
3. **Backend labels:** SUMMARY prints kqueue/tokio on Darwin; proactr banner `io=kqueue` via `ODIN_OS`.

## Verdict

| Claim | Result |
|-------|--------|
| proactr TLS+H2 works on Darwin kqueue | **PASS** (all h2 cells ok, body-check H1+H2) |
| Four-peer fair matrix runnable locally | **PASS** (drogon h2 still N/A by product) |
| proactr is peer-competitive on kqueue TLS | **FAIL** for H2 small/mid and H1.s bulk; partial for h2 s1m vs ntex only |
| Numbers previously unknown | **Closed** — this file is the first published kqueue TLS matrix |

## Next (not done here)

1. Profile kqueue TLS host (recv/rearm, dual-CT seal window, mem-BIO copies) — absolute gap vs bastion is large; relative gap vs tokio ntex is the sharper product question.
2. Do not publish “kqueue wins TLS” marketing; publish this table.
3. Optional: instrument `reqs` scrape for multi-chunk H1.s so s64k/s1m stats match h2load.

## Reproduce

```bash
# needs: odin, go, rustc, cmake, h2load (brew install nghttp2), Homebrew openssl@3
cd comparisons/tls-h2
export OPENSSL_DIR="$(brew --prefix openssl@3)"
export PKG_CONFIG_PATH="$OPENSSL_DIR/lib/pkgconfig"
export LOGDIR=/tmp/proactr-tls-h2-kqueue WORKERS=8 BENCH_C=100 BENCH_Z=15
export SERVERS="proactr ntex drogon go"
./run_matrix.sh
# → $LOGDIR/SUMMARY.md · results/KQUEUE_*.md after copy
```
