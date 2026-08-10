# Design summary — Builder + segment trie + Match_Proc (R4)

**Full doc:** [`DESIGN.md`](DESIGN.md)  
**Status:** Draft R4 — **single path; no dual router**

## Outcomes

- **One product path only:** `builder_init` → **`builder_get_fn`** → **`listen_builder` → `(err, build_err)`**. No second router.
- **Clean cut (K12):** linear Lua `Router` / `route_*` / `router_handler` / `url_params` are **deleted** when the new stack lands — not soft-deprecated, not dual-API on `main`.
- **Product patterns only:** static / `{name}` / `{*name}`; no regex; Match_Proc for path-shape power.
- **LAW MATCH-ALLOC** (do not regress): 0 heap/temp match core; fixed params/ctx; sorted static edges.
- **Match_Proc:** classify-only; ctx bag only; after method-trie miss, **before 405**; mount gate = `Custom_Entry.prefix` + `path_under_mount` in the match loop.
- **Scoped MW wrap-at-build**; `http.Layer` in `http`; Odin `group_begin`.
- **PR3 = cutover:** Builder + migrate every in-tree caller + delete old types in one landable change set.
- APP_CONTRACT frozen; open questions none blocking.

## Explicitly banned

- Dual `Router` + `Builder` public APIs
- Soft-deprecation period that leaves dead code on `main`
- Keeping `url_params` “for legacy”
- Teaching `router_init` as a migration box in product docs
