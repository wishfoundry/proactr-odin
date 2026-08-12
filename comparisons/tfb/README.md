# TFB-style comparisons

**No JSON.** Routes:

| Path | Role |
|------|------|
| `GET /plaintext` | 13 B I/O ceiling |
| `GET /s/4k` … `/s/4m` | size ladder |
| `GET /fortunes` | SQLite + sort + HTML |

## Peers (published set)

| Peer | Backend (Linux) | Build |
|------|-----------------|--------|
| `proactr` | proactr / io_uring | odin (`proactr/`) |
| `laytan` | nbio / io_uring | odin (`laytan/`) |
| `ntex` | neon-uring | `cargo` (`ntex/`) |
| `drogon` | trantor / epoll | CMake (`drogon/build.sh`) |
| `go` | net/http | `go build` (`go/`) |

Published numbers: [`benchmarks/TFB.md`](../../benchmarks/TFB.md).

## Quick run

```bash
./schema/prepare.sh
# build peers as needed, then:
SERVERS="proactr laytan ntex drogon go" WORKERS=8 \
  TESTS="plaintext s4k s64k s1m s4m fortunes" \
  ./run_peer_matrix.sh
```

| Env | Default |
|-----|---------|
| `SERVERS` | see `run_peer_matrix.sh` |
| `TESTS` | plaintext ladder (+ fortunes if set) |
| `WORKERS` | 8 in peer matrix |
| `BENCH_C` / `BENCH_Z` | load tool concurrency / duration |
| `DATABASE_PATH` | `/tmp/proactr-tfb.sqlite` |

Fortunes app work differs by peer — see notes in `run_peer_matrix.sh`.
