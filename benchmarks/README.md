# Benchmarks

## Peers

| Peer | Stack |
|------|--------|
| **proactr** | this tree (io_uring on Linux) |
| **laytan** | `vendor/laytan/odin-http` |
| **ntex** | crates.io neon-uring |
| **drogon** | `third_party/drogon` (epoll) |
| **go** | `comparisons/tfb/go` |

## Numbers

**[`TFB.md`](TFB.md)** — clear H1 size ladder + fortunes, **2026-08-11** bastion run  
(`comparisons/tfb/results/summary_20260811.tsv`).

TLS/H2 last pin: 2026-08-10 under `comparisons/tls-h2/results/`.

```bash
./scripts/fetch_third_party.sh
./comparisons/tfb/schema/prepare.sh
SERVERS="proactr laytan ntex drogon go" WORKERS=8 \
  TESTS="plaintext s4k s64k s1m s4m fortunes" \
  ./comparisons/tfb/run_peer_matrix.sh
```
