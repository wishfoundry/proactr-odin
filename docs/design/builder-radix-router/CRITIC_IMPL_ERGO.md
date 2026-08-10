# Critic: Implementation Ergonomics — Builder + segment router (re-review)

**Verdict: WOW**

**Date:** 2026-08-10  
**Scope:** Implemented product face vs DESIGN R4 + chi/axum bar. Prior verdict was **CONDITIONAL**.  
**Method:** Re-read `examples/empty_ok`, `route_builder` (merge + `listen_builder`), `MIDDLEWARE.md`, `STATIC.md`, `route_test` merge/use tests; grepped product `http/`, `examples/`, `comparisons/` for dual-path symbols.

Prior CONDITIONAL blockers are cleared. No auto-FAIL. All E1–E8 **PASS**. Residual polish only — not gates.

---

## Prior CONDITIONAL blockers — disposition

| # | Blocker (prior review) | Status | Evidence |
|---|------------------------|--------|----------|
| 1 | Product middleware/static docs still teach deleted `Router` / `route_get` | **Fixed** | `http/middleware/**`: zero `Router` / `route_get` / `router_init`. `MIDDLEWARE.md` quick start is Builder + `to_http_layer` + `listen_builder`. `STATIC.md` uses `builder_get` + `{*path}`. |
| 2 | Groups / use / composition unshown to authors | **Fixed enough** | `MIDDLEWARE.md` documents `builder_use` + commented `builder_group_begin` scoped MW; stock attach path explicit. Mount/use/merge covered in `route_test`. No separate `examples/builder_groups` binary — not required once product docs teach the face without dead APIs. |
| 3 | `builder_merge` dropped layer scope over routes | **Fixed** | `builder_merge` always creates owned child; routes/customs/layers land on `sub`. `test_builder_merge_preserves_scoped_layers` asserts MW + route both fire via ctx. |

---

## Auto-FAIL checklist

| Trigger | Hit? | Evidence |
|---------|------|----------|
| Dual public `Router` + `Builder` | **No** | `http/**/*.odin` and `examples/**`: zero old symbols. `routing.odin` = URL+query only. |
| Hello world worse than design face | **No** | `empty_ok`: `builder_init` → `builder_get_fn` ×2 → `listen_builder` → `builder_error_format`. |
| Named `param()` missing | **No** | `route_params.odin` + tests. |
| Regex product path | **No** | Parse rejects `:` constraints; no Lua match in product `http`. |
| `listen_builder` / structured `build_err` missing | **No** | Dual return; expand fail skips listen; table owned + destroyed on listen fail path. |
| APP_CONTRACT broken | **No** | Routing only; oneshot/Effects demos unchanged. |

---

## Scorecard (E1–E8)

| Gate | Result | Evidence |
|------|--------|----------|
| **E1** Product hello ≤ design empty_ok | **PASS** | [`examples/empty_ok/main.odin`](../../../examples/empty_ok/main.odin) matches DESIGN §2. Same face: `https_demo`, `comparisons/empty-ok/proactr`, `tfb/proactr`, `tls-h2/proactr`, `plan/server`. Env PORT/WORKERS is host ceremony. |
| **E2** Groups / mount / use without closures-only | **PASS** | `builder_group_begin` primary; `builder_group` sugar; `builder_mount`; `builder_use` / `builder_use_fn`. Merge scopes layers correctly. Docs show stock MW attach. |
| **E3** Named `param()` | **PASS** | `param` / `param_decoded`; walk fills keys; unit test. |
| **E4** `Match_Proc` classify-only | **PASS** | `proc(req) -> bool`; trie → customs (prefix gate) → 405 → 404; ctx bag only. |
| **E5** `req_ctx_*` string helpers | **PASS** | set/get string + ptr; overflow false; tests deposit. Match clears params only. |
| **E6** Zero dual path | **PASS** | Product code + examples clean. Peer `comparisons/*/laytan` and vendor laytan correctly keep old API. |
| **E7** `builder_error_format` on expand fail | **PASS** | Structured `Builder_Error`; empty_ok formats `build_err`. |
| **E8** Examples / comparisons / product teaching | **PASS** | Proactr call sites on Builder. Middleware/static docs product face only. |

---

## What the product face is (facts)

```text
builder_init → builder_get_fn / group_begin / use(to_http_layer(...)) / mount
            → listen_builder(err, build_err)
            → Server owns Match_Table
```

- Segment dialect only: static / `{name}` / `{*path}`  
- Named params + request ctx bag  
- Fail-at-build conflicts with structured diag  
- No second public router

Approaches chi for Odin: multi-statement, no fluent chain, no typed extractors — as designed. Not overclaimed.

---

## Residual polish (not WOW blockers)

1. **`to_http_layer` tax** — stock layers return `middleware.Layer`; Builder wants `http.Layer`. Documented. Optional: `*_layer` return `http.Layer` directly (IMPL_NOTES residual).  
2. **`builder_error_format` ownership** — allocates; examples rarely free. Error path only.  
3. **No runnable groups demo binary** — docs + tests suffice for the gate; optional `examples/` sketch still nice.  
4. **Stale IMPL_NOTES line** — still claims middleware docs mention `Router`; false after fix. Update when convenient.  
5. **No CI grep** for reintroducing `route_get` — optional lock on E6.

---

## Lies / overclaims

- None material on the product path after this pass.  
- Do not claim axum extractors / fluent APIs. Residual gap table in DESIGN still honest.  
- “Single path” is true for product **code and stock docs**; design history and peer comparisons still mention old Router by design.

---

## Bottom line

| | |
|--|--|
| **Verdict** | **WOW** |
| **Why** | Prior CONDITIONAL trio (docs, composition teaching, merge layer scope) fixed; E1–E8 all PASS; no auto-FAIL. |
| **Ship** | Product Builder face is the ergonomics bar for R4. Residual polish is optional, not gate work. |
