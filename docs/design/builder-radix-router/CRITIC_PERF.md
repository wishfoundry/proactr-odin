# Adversarial performance re-review — Builder + segment trie + Match_Proc (R2)

| | |
|--|--|
| **Lens** | Match hot path · build expand · multi-worker immutable share · oneshot / empty_ok / TLS plaintext tax |
| **Bar** | chi / httprouter / gin flat leaves — O(segments), zero heap on hit, no post-listen mutation, no mutex |
| **Prior** | CONDITIONAL (`grok-review-perf-011a423a.md` R1): soft walk alloc, vapor benches, expand handwave, soft customs, oneshot tax, dynamic table fields |
| **Inputs** | R2 design `grok-design-doc-011a423a.md` (status: Draft R2), `grok-design-summary-011a423a.md` |
| **Method** | **Verify claims in doc text** — LAW MATCH-ALLOC, B1–B9, frozen slices, customs hardness, oneshot tax, sorted static edges. Soft “prefer” does not count. |
| **Verdict** | **WOW** |

---

## Verdict (one line)

**WOW** — R2 closed every R1 WOW blocker as **normative law** (K17–K24 + §10/§14/§15 + Performance targets). Product match is segment-trie O(depth), zero-alloc by law, wrap-at-build, frozen multi-worker share, concrete B1–B9, expand asymptotics, customs cost hardness. No auto-FAIL. Residual nits do not reopen P1–P8.

---

## Claim verification (writer vs doc)

| Writer claim | Present as normative? | Locus | Status |
|--------------|:---------------------:|-------|--------|
| **LAW MATCH-ALLOC** | **Yes** | §10 (full bullet law); K17; Performance §; goals #4; mermaid hot path | **Closed** |
| **Index walk / path views / normalize = subslice** | **Yes** | MATCH-ALLOC bullets; trailing slash §7; segment_walk “index-based” | **Closed** |
| **B1–B9 microbench plan** | **Yes** | Performance targets table + happy-path 0-temp assert; PR2/PR6 gates | **Closed** |
| **Frozen slices (no live `[dynamic]` hot fields)** | **Yes** | §14 `Match_Table` sketch; expand Forbidden; K5 | **Closed** |
| **Customs hardness** | **Yes** | empty free; warn C>8; power escape; K24; §11; Performance | **Closed** |
| **Oneshot / static tax closure** | **Yes** | Performance table: `n=0` only, params-only clear, 405 cost, interned `route_pattern`, Builder-only benches; K18; Appendix C | **Closed** |
| **Sorted static edges, no hashmap on match** | **Yes** | §8 layout; “v1 static edges… No hashmap”; K23; insert bsearch | **Closed** |
| Expand asymptotics | **Yes** | §15 `O(R·S + E log F)` + Forbidden deferred work / match locks | **Closed** (was R1 P5 gap) |

**No claim is marketing-only.** Each is greppable law or a freeze table.

---

## Scorecard P1–P8

| # | Requirement | R1 | R2 | Verdict |
|---|-------------|:--:|:--:|---------|
| **P1** | Segment trie per method; static > param > catch-all; O(segments) | 9 | **9.5** | **PASS** — insert + segment_walk normative; no path compression v1 named; priority tests mandatory |
| **P2** | Zero / fixed-stack param capture; path slices | 6.5 | **9.5** | **PASS** — MATCH-ALLOC + fixed `Path_Params` + no `param_set` / no customs writes to params |
| **P3** | Ctx bag fixed slots / arena; documented max | 8.5 | **9** | **PASS** — MAX 16; overflow false; string helpers; match never clears ctx |
| **P4** | Immutable post-build; multi-worker share; no match mutex | 8 | **9.5** | **PASS** — frozen slices; ownership table; K5; B9 share smoke |
| **P5** | Expand cost documented; fail-fast conflicts | 5.5 | **9** | **PASS** — §15 asymptotics + Forbidden; structured `Builder_Error`; conflict matrices |
| **P6** | Match_Proc after miss; cost called out | 6 | **9** | **PASS** — after method-trie miss (before 405); empty free; warn C>8; not second router |
| **P7** | No regression tax static-only / oneshot | 6 | **9** | **PASS** — tax table closed; hit path: index walk + params.n=0 + leaf; no customs/405 on hit; product benches exclude Lua |
| **P8** | Concrete microbench plan (counts, methods) | 3 | **9** | **PASS** — B1–B9 with topologies, methods, ops, acceptance shape |

**All P1–P8 PASS.** Overall design perf score (harsh): **~9.2 / 10 → WOW**

---

## Auto-FAIL audit (R2)

| Kill condition | Triggered? | Evidence |
|----------------|:----------:|----------|
| Match still O(n routes) as product default | **No** | Segment trie product; Lua legacy only; PR5 product face = `listen_builder` |
| Unbounded per-request heap for params/ctx on happy path | **No** | Fixed arrays; MATCH-ALLOC forbids match core `make` |
| Trie mutated after listen / not shareable RO | **No** | Expand once; frozen slices; workers share table; no match mutex |
| Regex engine on hot path | **No** | Product patterns only; customs author-owned |
| Middleware re-walked/rebuilt per request | **No** | Wrap-at-build; Appendix A = chain_wrap |
| Unavoidable alloc/lock on match vs oneshot RPS | **No** | 0 heap hit/miss for routing; Allow alloc only confirmed 405; no locks |
| Unbounded customs **without** cost docs | **No** | O(C) after miss; empty free; warn C>8; K24 |

**Auto-FAIL clean.**

---

## R1 → R2 residual closure

| R1 blocker | R2 close | Adequate? |
|------------|----------|-----------|
| **F1 MATCH-ALLOC law** | Full §10 law + K17 + tests in PR2 gate | **Yes** |
| **F2 vapor microbench** | B1–B9 table + 0-temp happy path + PR2/PR6 | **Yes** |
| **F3 expand cost handwave** | §15 formula + Forbidden list + freeze slices | **Yes** |
| **F4 soft customs** | Empty free; CUSTOMS_WARN=8; power-escape docs; K24 | **Yes** |
| **F5 oneshot tax** | Explicit tax table; clear laws; interned pattern; Builder benches | **Yes** |
| **M2 hashmap on match** | Forbidden; sorted arrays only K23 | **Yes** |
| **M3 handler_nodes dynamic** | `[]^Handler` frozen §14 | **Yes** |

No R1 Fatal/Major reopened.

---

## What still WOW’s (and what newly does)

### Architecture (held + hardened)

1. **Product default is segment priority tree**, not linear Lua — correct kill of `routes_try` + `find_aux` + temp captures baseline.
2. **Static > param > catch-all** with fail-at-build conflicts (dual param names, slash twins, etc.) — chi/httprouter-shaped, not first-wins soup.
3. **Wrap-at-build leaves** — multi-worker immutable share without group re-entry.
4. **MATCH-ALLOC is law, not aspiration** — index walk, memcmp against interned keys, subslice normalize, path views into `req.url.path`, optional `route_pattern` = interned leaf pointer only.
5. **Match_Table freeze** — public hot fields are slices; ownership until workers stop; Server owns under `listen_builder`.
6. **Expand cost bounded on paper** — `O(R·S + E log F)`; no first-request amortize; no match locks.
7. **B1–B9 is implementable CI/bench work**, not “N routes someday.”
8. **Oneshot path discipline** — hit never runs customs or 405 probe; empty customs is free miss tail; product benches ban legacy Lua.

### Semantic ordering note (perf-neutral)

R2 places **customs before 405** (method-agnostic / `route_all` class). Hit path unchanged. Miss path: O(C) then optional O(|Method|·depth). Cost lawed; not a WOW regressor. Product multi-method remains `builder_route`.

### Match clear law (correct for outer Chain)

Match clears **params only**; ctx reset only at exchange boundary. Prevents wiping outer middleware deposits when table is nested under a host Chain — also avoids needless full-bag wipe on every request beyond `params.n = 0`.

---

## Residual nits (not WOW blockers)

These are implementer/review discipline items, not design holes.

1. **Request POD size** — fixed `Path_Params` + `Request_Ctx` enlarge `Request` vs today’s thin `url_params` slice. Honest fixed cost for named params + bag; reset is `n=0` only. Not heap; not match-path work. Document size delta in PR1 (already gated). Do not invent out-of-line maps “to slim Request” without reopening alloc laws.

2. **B1 “small constant” vs bare Handler** — qualitative until measured. B2–B4 acceptance (“beats Lua at ≥32”, “0 temp”, “O(depth) not O(N)”) is hard enough for design freeze. Record platform numbers when PR2 lands; do not block design on ns folklore.

3. **Customs warn only (not hard cap)** — correct for power escape; O(C) remains author-owned after C>8. If abuse appears in the wild, escalate docs — not a design FAIL.

4. **405 multi-root walks** — ≤ O(|Method|·depth) with fixed Method enum. Optional later: multi-method bitset trie (Alt D). v1 is acceptable and cost-bounded.

5. **Prefix gate on mounted customs** — expand wraps Match_Proc with prefix check. That is O(prefix) string compare per custom on miss — still O(C), still after trie miss. Fine; do not put gates on hit path.

6. **No path compression v1** — slightly more nodes/cache pressure than patricia; explicit freeze. Correct for simplicity; revisit only if B3/B5 show node fan-out pain.

---

## Multi-worker / oneshot interaction

Host model (REUSEPORT workers, shared root `Handler`, shared TLS ctx) aligns with:

- one expanded table under Server (`listen_builder`) or app-owned expand;
- read-only share, zero per-worker trie copy (B9);
- no mutex on match (expand Forbidden + K5).

Empty_ok / TLS plaintext: product path is `listen_builder` + static leaves → segment walk depth 1–2, MATCH-ALLOC, precomposed leaf (identity if no layers). **No unavoidable lock or heap.** That is the high-RPS bar.

---

## What would re-open CONDITIONAL or FAIL

| Regression | Result |
|------------|--------|
| Implement match with segment `make([]string)` / temp keys | FAIL (MATCH-ALLOC) |
| Ship Builder façade still linear-scanning routes | FAIL (product default) |
| Grow ctx/params on heap when full | FAIL (P2/P3) |
| Mutate trie / append customs after listen | FAIL (P4) |
| Nested group matchers as primary MW model | FAIL (middleware re-walk) |
| Drop B1–B9 from PR2/PR6 gates | CONDITIONAL (P8 softens) |
| Product perf claims on legacy Lua Router | CONDITIONAL (P7 social) |

None of these appear in R2 text.

---

## Final verdict

# **WOW**

R1 CONDITIONAL was correct for the draft that preferred zero-alloc and sketched “N static routes.” **R2 is freeze-grade routing performance law** for a chi/httprouter-class design:

- **P1–P8 all PASS**
- **Auto-FAIL clean**
- Writer claims **verified in document**, not assumed

Further work is **implementation under PR1–PR6 gates** (MATCH-ALLOC tests, B2–B4 early, full B1–B9, product examples on `listen_builder`). Do not re-open ontology for residual POD size or B1 ns folklore.

---

*Critic: adversarial HTTP routing performance R2 · prior CONDITIONAL · bar chi/httprouter/gin · multi-worker immutable share · oneshot alloc discipline · **verdict WOW***
