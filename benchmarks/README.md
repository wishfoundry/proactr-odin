# Benchmarks

Published numbers: [`TFB.md`](TFB.md).

Peers: proactr · laytan · ntex · drogon · go.

```bash
SERVERS="proactr laytan ntex drogon go" WORKERS=8 \
  TESTS="plaintext s4k s64k s1m s4m fortunes" \
  ./comparisons/tfb/run_peer_matrix.sh
```
