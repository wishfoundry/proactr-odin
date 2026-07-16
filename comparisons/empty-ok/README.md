# empty-ok comparison

Minimal ceiling: `GET /` → `200` + small body (`OK` / equivalent).

## Peers

| ID | Dir | Stack |
|----|-----|--------|
| `proactr` | `proactr/` | this tree (scaffold until host lives) |
| `laytan` | `laytan/` | vendored laytan/odin-http nbio |
| `ntex` | `ntex/` | third_party/ntex via crates.io pin |
| `compio` | `compio/` | third_party/compio / crates.io |
| `drogon` | `drogon/` | third_party/drogon |
| `asio` | `asio/` | third_party/asio (Boost.Asio) |
| `seastar` | `seastar/` | third_party/seastar (optional, heavy) |
| `envoy` | `envoy/` | third_party/envoy as reverse proxy (optional) |

## Run

```bash
# After peers build:
./run_bench.sh

SERVERS="ntex drogon laytan" PORT=18080 ./run_bench.sh
SKIP_HEAVY=1 ./run_bench.sh   # skip seastar + envoy
```

Requires `oha` or `wrk` on `PATH`.
