# Plain text / HTML baselines (+ payload size ladder)

No JSON. Two goals:

1. **App-shaped work:** `/fortunes` (DB + sort + HTML escape)
2. **Payload size ladder:** fixed `text/plain` bodies so we can track RPS vs size

## Endpoints

| Path | Content-Type | Body size | Work |
|------|--------------|----------:|------|
| `GET /plaintext` | `text/plain` | 13 B | `Hello, World!` — framing ceiling |
| `GET /s/4k` | `text/plain` | 4 KiB | Fixed body (startup-filled buffer) |
| `GET /s/64k` | `text/plain` | 64 KiB | ″ |
| `GET /s/1m` | `text/plain` | 1 MiB | ″ |
| `GET /s/4m` | `text/plain` | 4 MiB | ″ |
| `GET /fortunes` | `text/html; charset=utf-8` | ~1–2 KiB | SQLite + sort + **escape** |

Size ladder bodies are **immutable after init** (filled with a printable pattern). That measures **send/copy path** under keep-alive, not app generation cost. Fortunes is the generation/escape test.

Exact sizes (bytes):

| Name | Bytes |
|------|------:|
| plaintext | 13 |
| s4k | 4096 |
| s64k | 65536 |
| s1m | 1048576 |
| s4m | 4194304 |

## Fortune rules

Unchanged: TE 12-row seed, runtime insert, sort by message, escape `& < > " '`.

### proactr SQLite modes

| Mode | Peer | DB access |
|------|------|-----------|
| **sync** | `proactr-sync` | Default: **one connection per I/O worker** (no global mutex). Set `FORTUNES_SYNC_SHARED=1` for ntex-style single conn + mutex |
| **async** | `proactr-async` | Thread pool (`DB_WORKERS`); one SQLite connection per pool thread; I/O worker only responds after the job completes |

Both modes apply the same connection PRAGMAs: `journal_mode=WAL`, `synchronous=NORMAL`, `temp_store=MEMORY`, `cache_size=-65536`, `mmap_size=256MiB`, `query_only=ON`, `busy_timeout=5s`, plus a **prepared** `SELECT` reused via `sqlite3_reset`.

Bastion matrix: `./run_fortunes_bastion.sh` (default `SERVERS="ntex proactr-sync proactr-async"`).

**Why async can still beat sync even with per-worker conns:** async runs query+HTML on *extra* pool threads while I/O workers keep accepting/recv/send. Sync does DB+HTML on the same threads that drive the ring — under pure `/fortunes` load that is mostly “same concurrency,” but under mixed traffic or high connection churn async keeps the ring hotter. The old large gap was mostly **one shared mutex**, not missing WAL (WAL was already on from `prepare.sh`).

## Peer classes

| Class | Peers | I/O |
|-------|-------|-----|
| **io_uring** | ntex (neon-uring), ntex-compio, compio, asio, laytan, proactr | Linux completion path |
| **epoll / other** | go, drogon | portable stacks (labeled) |
| **heavy / optional** | seastar, envoy | build or docker; see peer README |

Default `SERVERS` on Linux includes both uring and epoll app servers. Envoy/seastar opt-in via env.

## Fairness (CRITIC / peer matrix)

### Size ladder — fair claim OK

Same paths, same immutable body lengths (verified by `run_bench.sh` body-check after each peer starts). Same `WORKERS`, `BENCH_C`, `BENCH_Z`, `WARMUP_Z`, loadgen, host.

| Peer | Wire (size ladder) | I/O label |
|------|--------------------|-----------|
| **proactr** | **materialize** into `resp_buf` + one send (`plan_optimize=false`) | io_uring on Linux |
| **laytan** | odin-http respond_plain | nbio → io_uring on Linux |
| **ntex** | ntex body + neon-uring | io_uring |
| **drogon** | `setBody` + trantor | **epoll** (not uring) |

Do **not** report proactr as writev/sendfile unless `plan_optimize` / `prefer_gather` / `prefer_sendfile` is on and counters prove it. The optimize path is multi-buffer **sequential** sends, not kernel `writev`.

### Fortunes — not equal app work

| Peer | DB concurrency | Query / sort | Conn lifecycle |
|------|----------------|--------------|----------------|
| **proactr-sync** (default) | **per I/O worker** conn | prepared `ORDER BY message`, stream HTML into `body_reserve` | open once per worker |
| **proactr-sync** + `FORTUNES_SYNC_SHARED=1` | one conn + mutex | same stream | shared |
| **proactr-async** | pool (`DB_WORKERS`) | same stream off I/O threads | one conn per pool thread |
| **ntex** | one conn + `Mutex` | `SELECT *`, **app sort**, prepare every request | process lifetime |
| **drogon** | none | `SELECT *`, app sort | **open/prepare/close every request** (handicapped) |
| **laytan** | — | 501 | skipped in harness |

Same schema (12 TE rows + runtime insert). **Do not** treat fortunes RPS as a pure I/O framework comparison. For a fairer DB concurrency match vs ntex, run proactr with `FORTUNES_SYNC_SHARED=1`. Fixing drogon’s per-request open is a peer code change (not done by the matrix harness).

### Harness anti-cheat

- `FORCE_REBUILD=1` (peer matrix default): rebuild all peers `-o:speed` / `--release` / CMake Release
- Body-check fails the peer if size ladder bytes ≠ expected
- Warmup applied for oha **and** bombardier/wrk
- `BENCH_Z < 10s` prints a noise warning
