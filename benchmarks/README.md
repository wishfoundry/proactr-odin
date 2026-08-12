# Benchmarks

## Peers

| Peer | Stack |
|------|--------|
| **proactr** | this tree (io_uring on Linux · kqueue on Darwin) |
| **laytan** | `vendor/laytan/odin-http` |
| **ntex** | neon-uring (Linux) · tokio (Darwin) |
| **drogon** | `third_party/drogon` (Linux / epoll) |
| **go** | `comparisons/tfb/go` |

## Numbers

**[`TFB.md`](TFB.md)** — clear H1 size ladder + fortunes:

| Host | When | TSV |
|------|------|-----|
| **io_uring** bastion | 2026-08-11 | `comparisons/tfb/results/summary_20260811.tsv` |
| **kqueue** Darwin arm64 | 2026-08-12 | `comparisons/tfb/results/summary_kqueue_20260811.tsv` |

TLS/H2 (io_uring only, 2026-08-10): `comparisons/tls-h2/results/`.

```bash
# Linux
SERVERS="proactr laytan ntex drogon go" WORKERS=8 \
  TESTS="plaintext s4k s64k s1m s4m fortunes" \
  ./comparisons/tfb/run_peer_matrix.sh

# Darwin
SERVERS="proactr laytan ntex go" WORKERS=8 \
  TESTS="plaintext s4k s64k s1m s4m fortunes" \
  ./comparisons/tfb/run_peer_matrix.sh
```
