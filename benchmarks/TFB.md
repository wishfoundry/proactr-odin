# TFB baselines

_TechEmpower Web Framework Benchmarks._

relative comparisons against:
· ntex (rust, proactor-style)
· drogon (c++, reactor-style)
· laytan (odin. reactor-style, upstream fork)
· proactr (odin. proactor-style, this project)
· go std lib (reactor-style)



| Field | Value |
|-------|--------|
| **Date** | 2026-07-25 |
| **Routes** | `/plaintext` (13 B), `/s/4k`, `/s/64k`, `/s/1m`, `/s/4m`, `/fortunes` |
| **Load** | `oha` · `c=100` · warm 3 s · steady **15 s** · localhost |
| **Workers** | `WORKERS=8` where the peer honors it |
| **DB** | SQLite `/tmp/proactr-tfb.sqlite` · TE 12-row Fortune seed · WAL |
| **Tooling** | `comparisons/tfb/run_bench.sh` |

No JSON. Size-ladder bodies are fixed pattern buffers (send path). Fortunes = SQLite SELECT + runtime row + sort/order + HTML escape.

### Peers

| Peer | I/O (Linux) | I/O (Darwin) | Notes |
|------|-------------|--------------|--------|
| **ntex** | neon-uring | tokio | Fortunes: **1 shared SQLite conn + mutex** |
| **drogon** | trantor / **epoll** | - | Not built for this kqueue pass |
| **laytan** | nbio / io_uring | nbio / kqueue | Fortunes still **501** |
| **proactr** | proactr / io_uring | proactr / kqueue | Fortunes: **1 conn per I/O worker**, stream into `body_reserve` |
| **go** | net/http (epoll) | net/http (kqueue) | modernc.org/sqlite |

---

## io_uring 

| | |
|--|--|
| **Host** | ranch-bastion · Linux 6.14.0-37-generic · x86_64 |

### RPS (Avg Reqs/sec)

| Peer | plaintext | 4 KiB | 64 KiB | 1 MiB | 4 MiB | fortunes |
|------|----------:|------:|-------:|------:|------:|---------:|
| **ntex** | **361 620** | 316 241 | 119 625 | 5 287 | 1 419 | 10 873 |
| **proactr** | 348 874 | **355 108** | **137 046** | 6 178 | 1 488 | **90 928** |
| **laytan** | 337 721 | 269 847 | 78 390 | 2 506 | 530 | n/a (501) |
| **go** | 235 168 | 190 889 | 121 127 | **9 340** | **2 539** | 8 963 |
| **drogon** | 293 037 | 57 634 | 17 215 | 1 317 | 316 | 8 341 |

All completed **200** cells: 100% 2xx (oha deadline aborts only).

---

## kqueue — Darwin (Apple M2 Pro)

| | |
|--|--|
| **Host** | Darwin arm64 · Apple M2 Pro · kernel 25.5.0 |

**drogon:** not run (no mac binary in this pass).

### RPS (Avg Reqs/sec)

| Peer | plaintext | 4 KiB | 64 KiB | 1 MiB | 4 MiB | fortunes |
|------|----------:|------:|-------:|------:|------:|---------:|
| **ntex** (tokio) | 96 047 | 93 703 | 64 365 | **8 984** | 1 541 | 68 576 |
| **proactr** | 131 464 | **125 688** | 56 213 | 5 587 | **1 732** | **65 387** |
| **laytan** | 115 837 | 112 721 | **68 150** | 8 203 | **1 719** | n/a (501) |
| **go** | **133 961** | 104 070 | 54 840 | 8 092 | 1 518 | 35 517 |


---

## Reproduce

```bash
# env needs rust and go
export PATH="$HOME/.cargo/bin:$HOME/go/bin:/usr/local/bin:$PATH"
#
cd comparisons/tfb

./schema/prepare.sh
#
rm -f proactr/tfb-proactr.bin laytan/tfb-laytan go/tfb-go
SERVERS="ntex proactr laytan go drogon" \
  TESTS="plaintext s4k s64k s1m s4m fortunes" \
  WORKERS=8 BENCH_C=100 BENCH_Z=15s REQUIRE_URING=1 \
  ./run_bench.sh

# Darwin (kqueue) — drogon optional
SERVERS="ntex proactr laytan go" \
  TESTS="plaintext s4k s64k s1m s4m fortunes" \
  WORKERS=8 BENCH_C=100 BENCH_Z=15s \
  ./run_bench.sh
```
