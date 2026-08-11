# TFB-style baselines

Last published peer matrix for plaintext size ladder + fortunes.

| Field | Value |
|-------|--------|
| **Date** | 2026-07-25 |
| **Routes** | `/plaintext` (13 B), `/s/4k`, `/s/64k`, `/s/1m`, `/s/4m`, `/fortunes` |
| **Load** | `oha` · `c=100` · warm 3 s · steady **15 s** · localhost |
| **Workers** | `WORKERS=8` where the peer honors it |
| **DB** | SQLite · TE 12-row Fortune seed · WAL |
| **Harness** | `comparisons/tfb/run_bench.sh` / `run_peer_matrix.sh` |

No JSON. Size-ladder bodies are fixed buffers. Fortunes = SELECT + sort + HTML escape.

### Peers in this table

| Peer | I/O (Linux) | Notes |
|------|-------------|--------|
| **ntex** | neon-uring | crates.io `ntex` |
| **proactr** | proactr / io_uring | this project |
| **laytan** | nbio / io_uring | `vendor/laytan/odin-http` |
| **go** | net/http | `comparisons/tfb/go` |
| **drogon** | trantor / epoll | `third_party/drogon` |

---

## io_uring (Linux bastion)

**Host:** ranch-bastion · Linux 6.14 · x86_64

### RPS (avg requests/sec)

| Peer | plaintext | 4 KiB | 64 KiB | 1 MiB | 4 MiB | fortunes |
|------|----------:|------:|-------:|------:|------:|---------:|
| **ntex** | **361 620** | 316 241 | 119 625 | 5 287 | 1 419 | 10 873 |
| **proactr** | 348 874 | **355 108** | **137 046** | 6 178 | 1 488 | **90 928** |
| **laytan** | 337 721 | 269 847 | 78 390 | 2 506 | 530 | n/a |
| **go** | 235 168 | 190 889 | 121 127 | **9 340** | **2 539** | 8 963 |
| **drogon** | 293 037 | 57 634 | 17 215 | 1 317 | 316 | 8 341 |

---

## kqueue (Apple M2 Pro)

**Host:** Darwin arm64 · kernel 25.5.0 · **drogon not run**

### RPS (avg requests/sec)

| Peer | plaintext | 4 KiB | 64 KiB | 1 MiB | 4 MiB | fortunes |
|------|----------:|------:|-------:|------:|------:|---------:|
| **ntex** (tokio) | 96 047 | 93 703 | 64 365 | **8 984** | 1 541 | 68 576 |
| **proactr** | 131 464 | **125 688** | 56 213 | 5 587 | **1 732** | **65 387** |
| **laytan** | 115 837 | 112 721 | **68 150** | 8 203 | **1 719** | n/a |
| **go** | **133 961** | 104 070 | 54 840 | 8 092 | 1 518 | 35 517 |

---

## Reproduce

```bash
./scripts/fetch_third_party.sh
./comparisons/tfb/schema/prepare.sh

# ntex (Rust)
(cd comparisons/tfb/ntex && cargo build --release)

# drogon (needs cmake + OpenSSL; see comparisons/tfb/drogon/build.sh)
./comparisons/tfb/drogon/build.sh

# go
(cd comparisons/tfb/go && go build -o tfb-go .)

# proactr / laytan
# (odin build paths in comparisons/tfb/run_bench.sh)

SERVERS="proactr laytan ntex drogon go" WORKERS=8 \
  TESTS="plaintext s4k s64k s1m s4m fortunes" \
  ./comparisons/tfb/run_peer_matrix.sh
```

Requires `oha` (or bombardier/wrk) on `PATH`.
