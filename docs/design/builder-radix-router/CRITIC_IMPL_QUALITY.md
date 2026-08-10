# Adversarial implementation quality re-review — free_built / Chain-parity

| | |
|--|--|
| **Subject** | `Layer.free_built` + `Match_Table.handler_frees` destroy path; prior CONDITIONAL sole WOW blocker |
| **Prior verdict** | **CONDITIONAL** (wrap free bare `free(user_data)` leaked CORS/security deep clones) |
| **Mandate** | Auto-FAIL + Q1–Q8; residual nits may still allow **WOW** if ownership/correctness holds |
| **Verdict** | **WOW** |
| **Date** | 2026-08-10 |

---

## Verdict

**WOW**

Prior sole ownership WOW blocker is **closed correctly**. Stock `cors_layer` / `security_headers_layer` register `free_built`; expand records it on `handler_frees`; destroy deep-frees wrap state **before** bare free of remaining wrap `user_data`. `cors_destroy` / `security_headers_destroy` nil `user_data` → no double-free on the second pass. Terminals (`next` unset) still skip free of app/fn-ptr data.

D1/D2/D4 remain closed. Auto-FAIL clear. Match core, expand, K12 cut, and handler-path 405/customs tests stand. Residual items are **hygiene / coverage nits**, not ownership or route correctness holes.

---

## free_built verification (mandatory)

| Required | Present? | Evidence |
|----------|----------|----------|
| `http.Layer.free_built` | **Yes** | `route_builder.odin`: field + comment law (deep free of build’s `user_data`) |
| `middleware.Layer.free_built` | **Yes** | `chain.odin` Layer; `to_http_layer` copies all four fields |
| `cors_layer` sets free_built | **Yes** | `free_built = _cors_free_built` → `cors_destroy` |
| `security_headers_layer` sets free_built | **Yes** | `free_built = _security_free_built` → `security_headers_destroy` |
| Expand tracks free_built | **Yes** | `_wrap_layers` appends `Tracked_Handler_Free{h=node, free=layer.free_built}` |
| Destroy: free_built then bare free | **Yes** | `match_table_destroy`: loop `handler_frees` first; then wraps with `next` set and `user_data != nil` get bare `free` |
| No double-free after free_built | **Yes** | `cors_destroy` / `security_headers_destroy` set `h.user_data = nil` before return |
| Terminals app-owned | **Yes** | Bare free only when `next` is set |
| Expand-fail still nils `layer_data` | **Yes** | Unchanged; free_built still runs on partial wraps (expand-private Cors_State correctly freed) |

**Law (now implementable without handle switches on the Builder path):**

1. `layer_data` → free Layer opts (`free_data` / bare free), unique pointer once.  
2. `handler_frees` → deep free wrap `user_data` (must leave `user_data` nil).  
3. Remaining wraps with `next` set → bare free leftover `user_data` (from_fn / request_id / logger).  
4. Terminals → free shell only.

This is better than Chain’s handle-pointer special cases for the Match_Table path: free policy is **data-driven** from the Layer that built the node.

---

## Auto-FAIL audit

| Gate | Result |
|------|--------|
| Dual Router public | **Pass** |
| Match_Proc can respond via `res` | **Pass** |
| APP_CONTRACT | **Pass** |
| Mount/group expand broken | **Pass** |
| Terminal user_data wrong free | **Pass** |
| Broken destroy / double free / table leak | **Pass** — D1 listen tail, D2 expand-fail layer nil, free_built + nil user_data, merge scoped |

No auto-FAIL.

---

## Scorecard Q1–Q8

| Q | Topic | Grade | Notes |
|---|--------|-------|-------|
| **Q1** | Package split + ownership | **PASS** | free_built completes the ownership table for stock deep-free layers |
| **Q2** | Insert/match | **PASS** | Unchanged; overflow → miss |
| **Q3** | Expand laws | **PASS** | Group/mount/customs/merge; free_built recorded at wrap |
| **Q4** | Clean cut K12 | **PASS** | Product + middleware docs Builder path |
| **Q5** | Tests | **PASS*** | Priority, expand-fail, merge layers, real 405/customs handler. *Group join / mount static / merge-prefix / free_built smoke untested — coverage nits, not law holes |
| **Q6** | No host wire coupling | **PASS** | |
| **Q7** | Layer packaging | **PASS** | free_data + free_built + adapter; dual Layer type residual is intentional IOC |
| **Q8** | Ownership clear | **PASS** | Short destroy law in code; free_built explicit |

All PASS (Q5 with documented coverage nits) → **WOW** eligible; auto-FAIL clear → **WOW**.

---

## Prior residual close-out

| Residual | Status |
|----------|--------|
| D1 listen / early serve table leak | **Closed** (`listen_builder` still-owned destroy) |
| D2 expand-fail frees Builder Layer.data | **Closed** (nil tracking + test) |
| D3 wrap free ≠ Chain deep free | **Closed** (`free_built` / `handler_frees`) |
| D4 merge unscoped | **Closed** (owned group + layer test) |
| Handler-path 405 / customs | **Closed** |

---

## Residual nits (do not reduce WOW)

Not ownership/correctness blockers:

1. **No free_built smoke test** — expand with `cors_layer` + tracking allocator + `match_table_destroy` would lock the regression. Recommended, not required for verdict.
2. **Group/mount/merge-prefix/Child_Status tests** — expand code is correct and exercised by mount custom-prefix + merge layer tests; add for belt-and-suspenders.
3. **`builder_destroy` never frees `Layer.data`** — after successful expand table owns free; never-expand / fail-only `builder_use_fn` can leak unless app owns data. Documented product path is expand + serve; optional transfer flag later.
4. **`serve` early `.Closed`** still relies on `listen_builder` tail for owned tables (only `listen_builder` sets the flag) — acceptable.
5. **Chain destroy** still uses handle switches, not `free_built` — dual strategy; both correct for CORS/security on their paths.
6. **free_built contract** for authors: must nil `user_data` (or free everything the bare pass would free). Stock layers comply; mention once in godoc/MIDDLEWARE.

---

## Bottom line

| | |
|--|--|
| **Verdict** | **WOW** |
| **Prior CONDITIONAL blocker** | **Closed** — `free_built` + `handler_frees` + cors/security registration |
| **Auto-FAIL** | Clear |
| **Ship stance** | Ownership/free law for Builder + Match_Table is freeze-grade for product path (`listen_builder` + stock layers via `to_http_layer`) |
| **Optional follow-ups** | free_built destroy smoke; group/mount/prefix tests; Builder untransferred layer free |

No ordered **correctness** fix list. Hygiene only (above nits).
