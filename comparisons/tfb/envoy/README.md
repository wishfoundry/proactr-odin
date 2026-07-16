# Envoy peer (proxy overhead)

Not an app server. Proxies to a TFB upstream (default: ntex on **18081**).

```bash
# terminal A — upstream (io_uring ntex)
PORT=18081 WORKERS=8 DATABASE_PATH=/tmp/proactr-tfb.sqlite \
  ./ntex/target/release/ntex-tfb

# terminal B — Envoy (docker)
docker run --rm --network host \
  -v "$PWD/envoy.yaml:/etc/envoy/envoy.yaml:ro" \
  envoyproxy/envoy:v1.31-latest -c /etc/envoy/envoy.yaml

# bench port 18080 (Envoy listener)
```

Harness peer id: `envoy` (starts upstream + docker envoy automatically when Docker is available).
