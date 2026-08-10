# Critic: User Ergonomics — Builder/Router

**Verdict: WOW**

R3 closes the three CONDITIONAL blockers without regressing prior E-gates. Product face is implementable and chi-shaped for Odin; residual peer gaps stay honest. Performance out of scope (already WOW — not re-opened).

## Scorecard

| Gate | PASS/FAIL | Evidence (section quote or gap) |
|------|-----------|---------------------------------|
| **E1** Hello world ≤ ~10 lines feel | **PASS** | §2: `builder_init` → `builder_get_fn` × N → `listen_builder`; no author `Match_Table`/expand. K16/K26. Approaches chi (new → register → listen). |
| **E2** Groups + mount + compose | **PASS** | `builder_group_begin` primary; mount/merge frozen; callback sugar demoted + Odin capture limit documented. |
| **E3** Named `{id}` + `param()` | **PASS** | Product patterns + `param`/`param_decoded`; positional only on legacy Router. |
| **E4** Match_Proc power-only + classify law | **PASS** | Classify-only, ctx-only, after method-trie miss; prefix gate via `Custom_Entry.prefix` + `path_under_mount` (K19, Odin-safe). |
| **E5** Request context bag ergonomic | **PASS** | `req_ctx_set_string`/`get_string`; overflow false; middleware deposit example; match clears params only (K18). |
| **E6** Migration doesn’t strand apps | **PASS** | Legacy coexistence; PR5 product face; soft deprec. |
| **E7** Build-time conflicts author-friendly | **PASS** | `Builder_Error` struct + `builder_error_format`; **`listen_builder` → `(proactr.Error, Builder_Error)`** (K25); §2 shows caller `fmt` of `build_err` — no log-scrape-only. |
| **E8** Honest chi/axum/ntex residual gaps | **PASS** | Comparison table: no extractors/State/fluent; hello-world row cites `listen_builder` + `builder_get_fn`. |

### Prior CONDITIONAL blockers — verified fixed

| # | Blocker | R3 evidence |
|---|---------|-------------|
| 1 | `listen_builder` structured error to caller | §2 frozen contract + API sketch: `-> (err, build_err: Builder_Error)`; expand fail returns `(.None, build_err)`; “no log-only”; K25; example prints `builder_error_format(build_err)` |
| 2 | Hello-world uses `builder_get_fn` | §2 product face uses `builder_get_fn` only; K26; residual-gap table + PR5 aligned |
| 3 | Hygiene naming + appendix | Single kind `Child_Status_Override` (enum, expand prose, conflict matrix); Appendix A complete wrap loop + chain_wrap reference |

### Auto-FAIL checklist

| Trigger | Hit? |
|---------|------|
| Bootstrap more ceremony than chi/axum (expand tax) | **No** |
| Named params missing / primarily positional | No |
| Scoped MW only global | No |
| Regex/Lua product path | No |
| Match_Proc required for CRUD | No |
| APP_CONTRACT violated | No |
| Examples/docs not product face | No |
| API sketches incomplete | No |
| Silent first-wins product routes | No |

## Top issues (ordered)

None blocking WOW. Residual (optional polish, not gates):

1. **`builder_group_end` still tree-only** — **minor** — tree lists optional `group_end`; API sketch omits it; begin-registers-child is enough. Implement begin-as-primary; skip end unless stack-style is needed.
2. **`post_fn` / method_fn family** — **minor** — “v1 requires at least get_fn”; other methods still `handler()` until added. Acceptable for hello-world; CRUD authors may want parity later.
3. **Dual Router period** — **minor** — documented residual; PR5/PR6 soft deprec handles it.

## What would make this WOW (if not already)

Already **WOW**. Optional only:

- Ship `builder_*_fn` for all method verbs in same PR as expand (parity).
- PR5 empty_ok must literally match §2 (including `build_err` print) — already gated.

## Lies / overclaims

- **None material in R3.** Prior overclaim (“err carries structured diag” vs log-only signature) is gone: §2, §13, API sketch, and K25 agree.
- Residual gap table still correctly refuses axum extractors / fluent / typed State — not overclaim.
- Does not claim zero ceremony vs Go/Rust; claims collapse of expand/table tax + `handler()` tax on product face — accurate.

---

**Bottom line:** CONDITIONAL cleared. All E1–E8 PASS; no auto-FAIL. Ship this design as the ergonomics product face for Builder/Router.
