# empty-ok comparison

Minimal ceiling: `GET /` → `200` + body `OK`. Wiring / worker-fairness canary —
**not** the product numbers (use `comparisons/tfb`).

## Peers

| Peer | Workers | Stack |
|------|---------|--------|
| **proactr** | `WORKERS` | this tree |
| **laytan** | `WORKERS` | `vendor/laytan/odin-http` |
| **ntex** | `WORKERS` | crates.io ntex |
| **drogon** | `WORKERS` | `third_party/drogon` |

Default harness: `SERVERS="ntex drogon laytan proactr"`.

## Run

```bash
./run_bench.sh
SERVERS="ntex laytan proactr" WORKERS=8 PORT=18080 ./run_bench.sh
WORKERS=1 SERVERS="proactr laytan" ./run_bench.sh
```

Requires `bombardier`, `oha`, or `wrk` on `PATH`.
