# Benchmarks

## Peers we publish

| Peer | Stack | Where |
|------|--------|--------|
| **proactr** | this tree | `comparisons/tfb`, `tls-h2` |
| **laytan** | vendored odin-http | `vendor/laytan` |
| **ntex** | Rust (crates.io) | `comparisons/*/ntex` |
| **drogon** | C++ (`third_party/drogon`) | `comparisons/*/drogon` |
| **go** | `net/http` | `comparisons/*/go` |

## Numbers

**[`TFB.md`](TFB.md)** — latest checked-in matrices:

| Suite | Date / source | Routes |
|-------|----------------|--------|
| Clear H1 size ladder | bastion R3 (`tfb/results/summary.tsv`) | plaintext … 1 MiB |
| Fortunes (partial) | `tfb/results/fortunes_fair_v2.tsv` | plaintext + fortunes |
| TLS H1 / H2 | 2026-08-10 (`tls-h2/results/`) | plaintext … 1 MiB |

Re-run before marketing claims; numbers drift with host noise and code.

```bash
./scripts/fetch_third_party.sh
./comparisons/tfb/schema/prepare.sh
SERVERS="proactr laytan ntex drogon" WORKERS=8 \
  TESTS="plaintext s4k s64k s1m" \
  ./comparisons/tfb/run_peer_matrix.sh
```

Empty-OK wiring canary only: `comparisons/empty-ok/`.
