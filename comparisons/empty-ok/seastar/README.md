# Seastar empty-ok peer

Seastar is heavy (toolchain, DPDK optional, many deps). The source submodule lives at
`third_party/seastar`.

## Plan

1. `WITH_HEAVY=1 ./scripts/fetch_third_party.sh`
2. Follow Seastar’s `README.md` to build the library.
3. Add a tiny `httpd` sample here that returns `OK` on `GET /`.

Until then, the harness skips Seastar when `SKIP_HEAVY=1` (default).
