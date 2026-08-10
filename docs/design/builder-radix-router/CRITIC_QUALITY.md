# Adversarial quality / implementability re-review — Builder + segment trie + Match_Proc (R3)

| | |
|--|--|
| **Subject** | `grok-design-doc-011a423a.md` Draft **R3** |
| **Prior verdict** | CONDITIONAL (R2 sole residual: `wrap_match_prefix` / Odin-unimplementable Match_Proc wrap) |
| **Mandate** | Verify mount-gate fix only; same Q1–Q8 + auto-FAIL; no cheerleading |
| **Verdict** | **WOW** |

---

## Verdict

**WOW**

R2 residual is **closed in the design text**, not hand-waved. Mount customs are Odin-native data + a pure predicate in the match loop. No auto-FAIL gate trips. Q1–Q8 all PASS. Performance laws (MATCH-ALLOC, frozen slices, customs-before-405 order, B1–B9) unchanged and still ship-grade.

**Remaining blockers:** none for design freeze / implement start.

---

## R2 residual verification (mandatory)

| Required | Present? | Evidence |
|----------|----------|----------|
| `Custom_Entry.prefix` set at expand | **Yes** | Expand loop: `gate = "" if prefix == "/" else prefix`; `append_custom_build(..., prefix = intern(gate))` — author `match` pointer unchanged |
| Match loop gates with `path_under_mount` **before** `Match_Proc` | **Yes** | Order law step 5: `if e.prefix != "" && e.prefix != "/": if !path_under_mount(...): continue` then `e.match(req)` |
| No `wrap_match_prefix` factory | **Yes** | Explicit: “no wrap_match_prefix factory and no synthetic Match_Proc”; grep: factory deleted; K19 rewritten |
| Not raw `has_prefix` (`/api` ↛ `/apiv2`) | **Yes** | Normative `path_under_mount`: equality **or** `path[:len(prefix)] == prefix && path[len(prefix)] == '/'`; FORBIDDEN raw `strings.has_prefix`; test matrix: mount `/api` always-true custom → `/apiv2` gate miss → 404; `/v1` vs `/v1x` |

**Implementability:** `Match_Proc` stays `proc(req) -> bool`. Prefix is a string field on `Custom_Entry` — same pattern as `Layer.data` (explicit state, no closures). This is the correct Odin cut.

**K19** matches the mechanism (data + loop gate, not wrapped proc).

**PR3 gate** requires prefix tests including `/api` vs `/apiv2`. Good.

---

## Auto-FAIL audit

| Gate | Result |
|------|--------|
| God type (host wire + router + MW runtime) | **Pass** — `Match_Table` / Builder / bag split; Server owns table under `listen_builder` as lifetime only |
| Violates APP_CONTRACT / MIDDLEWARE_CONTRACT | **Pass** — frozen; Match_Proc classify/ctx only; framework 404/405 may `respond` |
| PR plan non-incremental / PR1 unshippable alone | **Pass** — bag + host `n=0` checklist first |
| Dual SoT forever, no deprecation path | **Pass** — soft deprec + PR5 product-story gate (`listen_builder` face) |
| Odin-hostile (closures / Rust extractors) | **Pass** — mount gate no longer requires capture; `group_begin` primary; no typed extractors claimed |
| Underspec structures (cannot insert without guessing) | **Pass** — § insert + segment walk + no compression v1 |
| Match_Proc can respond without law | **Pass** — no `res`; no Effects; no `Path_Params` writes |
| Missing tests: conflicts, priority, 405, mount layers | **Pass** — matrices include priority, 405×custom, HEAD, conflicts, mount+prefix, bag |

No auto-FAIL.

---

## Scorecard Q1–Q8

| Q | Topic | Score | Grade |
|---|--------|-------|-------|
| **Q1** | Package split + ownership | **9.0** | **PASS** |
| **Q2** | Trie insert/match algorithm | **9.0** | **PASS** |
| **Q3** | Expand (prefix, layers, mount) unambiguous + implementable | **9.0** | **PASS** |
| **Q4** | Migration; old Router coexist; examples path | **8.5** | **PASS** |
| **Q5** | PR plan ordered, reviewable, deps correct | **8.5** | **PASS** |
| **Q6** | Error/conflict diagnostics | **9.0** | **PASS** |
| **Q7** | Alternatives considered honestly | **9.0** | **PASS** |
| **Q8** | No hidden host coupling; pure app-layer | **8.5** | **PASS** |

All PASS → **WOW** eligible; auto-FAIL clear → **WOW**.

### Brief Q notes

- **Q1:** Builder / `Match_Table`+`Segment_Node` / Request bag; `http.Layer` re-home; ownership table (terminal `user_data` app-owned).  
- **Q2:** Normative insert; static > param > catch-all; MATCH-ALLOC; 405 probe O(|Method|×depth).  
- **Q3:** Expand visit order, merge, root-only 404/405, chain_wrap layer order, **and** mount customs via `Custom_Entry.prefix` + `path_under_mount` — implementable without guessing.  
- **Q4:** Coexist; `route_all` → `builder_route` or Match_Proc (customs before 405); PR5 forces product face.  
- **Q5:** PR1 bag → PR2 trie → PR3 expand+`listen_builder(err,build_err)`+prefix gate → polish/docs/benches.  
- **Q6:** Structured `Builder_Error` + format; diag field tests.  
- **Q7:** A–G including rejected 405-before-customs and expand-as-hello-world.  
- **Q8:** Host checklist for `n=0` only; match clears params not ctx; no wire types in match engine.

---

## Non-blockers (do not reduce WOW)

These are implementer hygiene / polish, not design holes:

1. Parse reject if pattern param count > `MAX_PATH_PARAMS` (safe default if omitted: walk stops or assert in debug).  
2. Dual `middleware.Layer` vs `http.Layer` during Chain migration — adapters already sketched.  
3. Soft deprecation timeline for Lua `route_*` stays soft — PR5 is the real cultural gate.  
4. `join_normalize` for prefixes without leading `/` — follow existing “normalize once” intent in expand; not a new ambiguity class.

No second residual on the R2-F1 class.

---

## Contract / perf freeze (regression check)

| Law | R3 |
|-----|-----|
| MATCH-ALLOC (0 heap/temp match core) | Intact |
| Customs before 405 | Intact |
| Match clears params only | Intact |
| APP_CONTRACT | Intact |
| Fail-at-build product conflicts | Intact |
| B1–B9 acceptance shape | Intact |

No regression from R2 perf WOW.

---

## Bottom line

| | |
|--|--|
| **Verdict** | **WOW** |
| **R2 sole residual** | **CLOSED** — `Custom_Entry.prefix` + segment-aware `path_under_mount` in match loop; no `wrap_match_prefix` |
| **Remaining design blockers** | **None** |
| **Implement** | PR1–PR6 per plan; PR3 must ship prefix tests (`/api` vs `/apiv2`, `/v1` vs `/v1x`) as merge gate |

Design is freeze-grade for Builder + segment trie + Match_Proc. Further bikeshed on extractors/fluent APIs is out of scope and already rejected honestly.
