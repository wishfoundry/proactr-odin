# R4 Builder + segment trie — implementation notes

**Date:** 2026-08-10  
**Status:** Landed (single path; linear Lua Router deleted)

## Files created

| File | Role |
|------|------|
| `http/route_params.odin` | `Path_Params`, `Request_Ctx`, `param` / `req_ctx_*`, clear helpers |
| `http/route_trie.odin` | Pattern parse, segment trie build/freeze, `segment_walk`, `path_under_mount`, normalize |
| `http/route_match.odin` | `Match_Table`, `Match_Proc`, customs, 404/405, `match_table_handler` / destroy |
| `http/route_builder.odin` | `http.Layer`, `Builder` APIs, expand, wrap-at-build, `listen_builder` |
| `http/route_test.odin` | Unit tests (priority, catch-all, slash, conflict, customs, mount gate, MATCH-ALLOC) |

## Files changed

| File | Change |
|------|--------|
| `http/request.odin` | `url_params` → `params` + `ctx` + `route_pattern`; `request_init` zeroes `n` / pattern |
| `http/routing.odin` | **Deleted** `Router` / `route_*` / `router_handler` / `core:text/match`; URL+query only |
| `http/server.odin` | `match_table` + `match_table_owned`; destroy after workers join |
| `http/middleware/chain.odin` | `to_http_layer` adapter |
| `http/middleware/static.odin` | Comment example → Builder pattern |
| `examples/empty_ok/main.odin` | `listen_builder` + `builder_get_fn` |
| `examples/https_demo/main.odin` | same |
| `comparisons/empty-ok/proactr/main.odin` | same |
| `comparisons/tfb/proactr/main.odin` | same |
| `comparisons/tls-h2/proactr/main.odin` | same (PEMs on opts) |
| `comparisons/plan/server/main.odin` | same (extra proactr caller) |

## Hard laws honored

1. Linear Lua Router fully deleted from product `http/` (vendor laytan untouched).
2. Product path: `builder_init` → routes → `listen_builder` → Server-owned `Match_Table`.
3. Patterns: static / `{name}` / `{*name}` only.
4. `Match_Proc :: proc(req) -> bool` — classify + ctx bag only.
5. **LAW MATCH-ALLOC:** match walk uses path indices/slices; `params.n=0` at match entry; never clear `ctx`.
6. Customs after method-trie miss, before 405; `Custom_Entry.prefix` + `path_under_mount`.
7. `listen_builder` → `(err: proactr.Error, build_err: Builder_Error)`.
8. `http.Layer` re-homed; middleware adapts via `to_http_layer`.
9. Wrap-at-build (`chain_wrap` order: `layers[0]` outermost).

## Verify

```bash
odin build examples/empty_ok -out:/tmp/empty_ok.bin -o:none
odin test http   # includes route_test; all green
```

## Residual / follow-ups

- Layer `data` ownership: after successful expand, `Match_Table` owns free; `builder_destroy` does not free layer data (avoids double-free).
- Optional: stock middleware `*_layer` returning `http.Layer` directly.
- Docs (`README`, `middleware/MIDDLEWARE.md`) still mention old `Router` in places — PR5 docs cleanup.
- Microbenches B1–B9 not landed in this cut.
