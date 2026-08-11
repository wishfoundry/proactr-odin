# third_party

Peer sources used for **benchmark builds** and occasional architecture reading.
Tracked as git submodules (shallow preferred).

| Directory | Upstream | Used by |
|-----------|----------|---------|
| `ntex/` | [ntex-rs/ntex](https://github.com/ntex-rs/ntex) | Reference; microservers pin crates.io `ntex` |
| `drogon/` | [drogonframework/drogon](https://github.com/drogonframework/drogon) | `comparisons/*/drogon` CMake builds |

Upstream baseline for Odin peers: `vendor/laytan/odin-http` (not under this tree).

Go peers live under `comparisons/*/go` (module path, no submodule).

## Fetch

```bash
./scripts/fetch_third_party.sh
# or:
git submodule update --init --depth 1 third_party/ntex third_party/drogon
git submodule update --init --depth 1 vendor/laytan/odin-http
```
