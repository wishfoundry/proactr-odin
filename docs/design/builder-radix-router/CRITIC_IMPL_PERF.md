# Adversarial implementation performance critic — Builder / segment trie / Match_Table (R2)

| | |
|--|--|
| **Lens** | Implemented hot path only — no design cheerleading |
| **Prior** | CONDITIONAL (`CRITIC_IMPL_PERF.md` R1): always-on 404 `log.infof`, 405 double walk, silent param overflow, thin e2e tests |
| **Inputs** | `http/route_trie.odin`, `http/route_match.odin`, `http/route_params.odin`, `http/route_builder.odin`, `http/route_test.odin`, `http/server.odin`, DESIGN.md LAW MATCH-ALLOC |
| **Verdict** | **WOW** |

---

## Verdict (one line)

**WOW** — Prior CONDITIONAL blockers are closed in code. Product match is segment-trie O(depth), MATCH-ALLOC on hit (tracked), params overflow → miss, single-pass 405 Allow, no miss log, wrap-at-build leaves, Server-owned table, no match mutex. Auto-FAIL clean. P1–P8 PASS.

---

## Prior CONDITIONAL → R2 closure

| R1 blocker | Status | Evidence |
|------------|:------:|----------|
| **F1** Always-on 404 `log.infof` | **Closed** | 404 is status handler only — `route_match.odin:224-226`. **No** `log.` / `core:log` in `route_match.odin` |
| **F3** 405 double multi-method walk | **Closed** | Single `_collect_allow_methods` — `route_match.odin:210-252` |
| **F4** Param overflow → truncated hit | **Closed** | Every `_params_push` checked; false → miss — `route_trie.odin:419-421`, `451-452`, `465-466`, `474-475`, `489-490` |
| **F5** P8 thin (no e2e handler) | **Closed enough** | `test_match_table_handler_405_allow`, `test_match_table_handler_customs_before_405`, merge e2e via `match_table_handler` — `route_test.odin:349-481` + prior MATCH-ALLOC / priority / catch-all |

---

## Auto-FAIL audit

| Kill condition | Triggered? | Evidence |
|----------------|:----------:|----------|
| Linear O(n routes) product match | **No** | `segment_walk` per-method segment trie + static bsearch — `route_trie.odin:401-502`, `_static_lookup` `372-386` |
| Heap/temp on **happy-path** match | **No** | Hit: normalize subslice → `params.n=0` → walk → leaf call — `route_match.odin:182-193`. `test_match_alloc_path_slices` asserts 0 tracking growth — `route_test.odin:184-214` |
| Match mutex / mutable trie on match | **No** | No lock in handle/walk. Expand freezes roots, clears `_build_roots` — `route_builder.odin:401-407`. Server destroy after workers join — `server.odin:417-419` |
| Regex on hot path | **No** | Parse rejects `:` constraints — `route_trie.odin:164-169` |
| Middleware rebuilt per request | **No** | `_wrap_layers` at expand only — `route_builder.odin:527-552` |

**Auto-FAIL clean.**

---

## P1–P8 scorecard

| # | Requirement | Grade | Evidence |
|---|-------------|:-----:|----------|
| **P1** | Segment trie O(depth) | **PASS** | Static > param > catch-all (`route_trie.odin:443-496`); cost O(depth · log F), not O(routes) |
| **P2** | Zero/fixed-stack param capture | **PASS** | Fixed `Path_Params` (`route_params.odin:10-17`); path slices; overflow → miss; tracking test 0 alloc + `raw_data` identity |
| **P3** | Fixed ctx bag max | **PASS** | `MAX_CTX_ENTRIES :: 16`; overflow false; match clears **params only** (`route_match.odin:183-185`) |
| **P4** | Immutable multi-worker share | **PASS** | `listen_builder` → Server owns table (`route_builder.odin:577-581`); match reads `roots`/`customs` only; destroy post-join |
| **P5** | Expand freezes; no live grow on match | **PASS** | Customs → frozen `[]` (`route_builder.odin:391-395`); nodes via `_freeze_node`; match never appends ownership tracks |
| **P6** | Customs after miss; empty free | **PASS** | Order trie → customs → 405 → 404 (`route_match.odin:187-226`); empty slice free; prefix gate before `Match_Proc` |
| **P7** | No oneshot tax lock | **PASS** | No lock; hit never runs customs/405; 404 no log; Allow alloc **only** on confirmed 405 |
| **P8** | Load-relevant match correctness tests | **PASS** | Priority, catch-all, slash conflict, MATCH-ALLOC, mount gate, e2e 405 Allow, e2e customs-before-405, merge+wrap e2e |

**All P1–P8 PASS → WOW.**

---

## Hit / miss cost model (as implemented)

| Path | Work | Routing heap/temp |
|------|------|-------------------|
| **Hit** | subslice normalize; `params.n=0`; `segment_walk`; leaf `Handler` copy + call | **0** |
| **Miss → custom** | walk miss; O(C) prefix + Match_Proc | empty C free; Match_Proc author-owned |
| **Miss → 405** | walk miss; empty customs; **one** `|Method|` probe via `_collect_allow_methods`; `strings.join` + `headers_set` for Allow | Allow path only (law-allowed) |
| **Miss → 404** | walk miss; customs; single probe `has_other=false`; default 404 handler | **0** for routing (no log) |

---

## Verified laws (spot checks)

### LAW MATCH-ALLOC
- Normalize: end-index only — `route_trie.odin:52-57`
- Walk: indices + path slices; no `make` — `401-502`
- Param push stack-fixed; failure is miss — `389-397`, all call sites check `bool`
- `route_pattern` = interned leaf pointer — `route_match.odin:190`
- Allow materializes only after `has_other` — `210-218`

### Wrap-at-build
- Expand: `leaf_h := _wrap_layers(layers[:], r.handler, table)` — `route_builder.odin:461`
- Reverse apply, `layers[0]` outermost — `527-552`
- Runtime match never rebuilds onion

### Single-pass 405
```210:252:http/route_match.odin
	// 3) 405 if path exists under another method — single walk builds Allow.
	parts, n, has_other := _collect_allow_methods(table, path, method)
	if has_other {
		if n > 0 {
			allow := strings.join(parts[:n], ", ", context.temp_allocator)
			// ...
		}
		// method_na ...
	}
// _collect_allow_methods: one for m in Method { segment_walk_exists; parts; has_other }
```

### Params overflow → miss
```465:467:http/route_trie.odin
			if !_params_push(params, node.param_name, seg) {
				return {}, false
			}
```

---

## Non-blocking polish (not reopening WOW)

These are residual micro-opts / type hygiene. **Not blockers.**

1. **`headers_set(&res.headers, "allow", allow)`** still sanitizes a lowercase literal via builder (`route_match.odin:216`). Confirmed-405 is allowed to allocate for Allow value; `headers_set_unsafe` would drop redundant key sanitize only.
2. **`Match_Table` destroy tracks remain `[dynamic]`** (`route_match.odin:30-33`). Match never grows them; freeze law for hot fields (`roots`, `customs`) is met. Type-level freeze of ownership lists is polish vs DESIGN §14 purity.
3. **`segment_walk_exists`** reuses full `segment_walk` + stack `Path_Params` (`route_trie.odin:505-509`). Stack-only; optional exists-only walk is micro.
4. **B1–B9 microbenches** still not product CI (IMPL_NOTES). P8 satisfied by correctness + MATCH-ALLOC tests; benches remain nice-to-have.
5. No dedicated unit for `//` miss or 17-param overflow — walk code paths are clear; tests optional.

---

## Score summary

| Gate | Result |
|------|--------|
| Auto-FAIL | **Clean** |
| P1–P8 | **All PASS** |
| Prior CONDITIONAL F1/F3/F4/F5 | **Closed** |
| **Verdict** | **WOW** |

---

## File index

| Path | Role |
|------|------|
| `/Users/bngreer/Projects/proactr-odin/http/route_trie.odin` | `segment_walk`, overflow-miss, static bsearch |
| `/Users/bngreer/Projects/proactr-odin/http/route_match.odin` | handle order, single-pass 405, no 404 log |
| `/Users/bngreer/Projects/proactr-odin/http/route_params.odin` | fixed bags |
| `/Users/bngreer/Projects/proactr-odin/http/route_builder.odin` | expand freeze, wrap-at-build, `listen_builder` |
| `/Users/bngreer/Projects/proactr-odin/http/route_test.odin` | MATCH-ALLOC + e2e 405/customs |
| `/Users/bngreer/Projects/proactr-odin/http/server.odin` | table ownership / post-join destroy |
