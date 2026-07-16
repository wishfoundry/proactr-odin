# Envoy peer

Envoy is used as a **production L7 proxy baseline**, not a raw app server.

Typical setup:

1. Fetch: `WITH_HEAVY=1 ./scripts/fetch_third_party.sh`
2. Build Envoy (or use a release binary).
3. Point `envoy.yaml` at a static cluster (e.g. ntex or proactr empty-ok on an upstream port).
4. Bench the Envoy listener port to measure proxy overhead floor.

Config stub: `envoy.yaml` (static admin + listener + cluster placeholders).
