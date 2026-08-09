# Implementation critic — shortcuts vs Plan A R4 PR plan (r1)

**Posture:** harsh. No credit for types that do not own the hot path. No credit for freezes that do not fail CI.  
**Bar:** WOW ≥ 9 **only if** honesty is complete: scope is clearly **Phase 0–1 + POD**, not marketed as TLS/H2 done, and Phase 0 gates that the plan called *hard fail* are not paper.  
**Subject:** live tree under `http/` + author docs (`docs/APP_CONTRACT.md`, `CAPABILITY_MATRIX.md`, `PHASE0_E0.md`, `README.md`) vs `docs/design/dual-tls-h2/plan-a.md` **PR0–PR10**, with focus on PR0–PR4 (what should already be honest structure).  
**Not in scope:** redesign of Plan A ontology; peer benches; “will fix later” as a grade.

---

## Verdict

| Axis | Score | Note |
|------|------:|------|
| **PR0–PR4 plan fidelity** | **6.4 / 10** | Real structure work (docs, four-field PC, session-on-slot, pure pipe POD + tests). Incomplete dual-write kill. CI freeze not wired. |
| **Honesty of status docs** | **5.8 / 10** | README is safe (scaffold). `PHASE0_E0.md` overclaims “Phase 1 structure (landed): PR1–PR4” and “Stream_Slot sole exchange.” No `IMPLEMENTATION_STATUS`. |
| **Marketing / H2 paper risk** | **8.5 / 10** | No README “supports HTTP/2.” Matrix keeps H2 concurrent/SSE as Phase 5. Residual: matrix “what you may write *now*” without a ship-status doc. |
| **Overall (implementation honesty)** | **6.2 / 10** | |

### WOWED: **No**

**One-line:** Useful skeleton of PR1/PR3/PR4 pure laws and partial PR2, sold slightly past itself by Phase 0 exit language and “sole exchange / PR1–PR4 landed” wording while **E0.4 is missing**, **E0.5–E0.7 are paper**, **Response still lives in `Loop`**, and **pipe bags do not drive the wire**.

WOW is withheld until honesty is complete (fixes below) — not until TLS is green.

---

## Mandate checks (user-specified)

### 1. PR0 E0.4 same-handler CI — **MISSING**

| Plan | Reality |
|------|---------|
| E0.4: CI runs **same handler sample** under clear H1; zero protocol `#if`; no stream ids. PR0 gate = **E0.1–E0.8**. | `docs/PHASE0_E0.md` status: **“Planned — CI job not wired yet.”** |
| Hard fail CI if missing (PART I freeze table). | **No** `.github/workflows` (or equivalent) in-repo. No automated job that builds/runs `examples/empty_ok` (or a designated same-handler sample) as a freeze gate. |

`examples/empty_ok/main.odin` is a clean clear-H1 sample (no `#if`, no sid, no debug import). That is **artifact half** of E0.4. Without CI it is not a freeze.

**Verdict:** E0.4 **done as culture/docs only; missing as CI.** Phase 0 is **not exited**.

---

### 2. E0.5–E0.7 example bans — **PAPER**

| Gate | Plan | Reality |
|------|------|---------|
| **E0.5** | No `examples/` import of `http/debug` / caps / proto introspection | Ban text in PHASE0 + APP_CONTRACT. **No CI grep.** Status: Planned. Current examples do not violate. |
| **E0.6** | No sample/godoc/middleware helper registers Host_Pull / pull from app | Documented NEVER. **No CI grep.** No Host_Pull type in tree yet (latent risk still). |
| **E0.7** | No example sets/prints stream id / `Response._sid` | Documented. **No CI grep.** No `_sid` field found (good). |

Plan language: freeze is theater if examples reintroduce duals; **hard fail CI**. Current enforcement = human review hope.

**Verdict:** Bans are **social paper**, not merge blockers. Clean examples today do not redeem missing enforcement.

---

### 3. PR2: Response still in Loop — **SHORTCUT vs plan**

Plan **§D.1–D.2 / Phase 1 / PR2**:

- `Stream_Slot` is **sole** exchange storage: **req, res, wire_slot, plan cursor, session**.
- `Connection` = **pipe only** (socket, tls, framer, pt, wire_conn, slab header).
- Response binds **`_slot`**; dual-write of session/wire/plan **grep-clean forbidden** at Phase 1 exit.
- Gate: **H1 identical**.

**What landed:**

| Field / path | Plan home | Actual home | Grade |
|--------------|-----------|-------------|-------|
| Session + session_pad | slot | `conn.slot.session*` | **OK** (partial PR2) |
| Progressive stream markers | slot wire | `conn.slot.stream_*` | **OK** (moved markers, not full wire_slot) |
| Gen for Session.id | slot.gen | `stream_slot_bump_gen` | **OK** |
| **Request** | slot | **`conn.loop.req`** | **Shortcut** |
| **Response** | slot | **`conn.loop.res`** | **Shortcut** |
| Plan cursor / exec / file region | `Wire_Slot_State` on slot | **`conn.wire` (`Wire_State`)** | **Shortcut** (pipe still owns exchange wire) |
| Response bind | `_slot` only; conn via `slot.conn` | **`_slot` + `_conn` sugar**; hot path still thrives on `_conn` / `loop.res` | **Soft / residual dual** |

Evidence (structure):

```odin
// http/server.odin — Loop still owns exchange surfaces
Loop :: struct {
	conn: ^Connection,
	req:  Request,
	res:  Response,
}

// http/slot.odin — slot is session + progressive markers, NOT req/res/plan
Stream_Slot :: struct {
	gen: u32,
	conn: ^Connection,
	session: ^Session_State,
	// ... stream_open / stream_sent / pin ...
	// no req, no res, no Wire_Slot_State plan cursor
}
```

`response_init` binds both:

```odin
r._slot = &c.slot
r._conn = c
```

`clean_request_loop` still resets **`conn.loop.res`**. Session attach correctly uses **`conn.slot.session`**.

**Verdict:** PR2 is a **façade half-move** (session/stream → slot; Response pointer dual-bind), **not** Stream_Slot sole ownership. Claiming “Stream_Slot sole exchange” in PHASE0 is **false under Plan A’s own §D definition**.

This is the largest structural shortcut in the claimed PR1–PR4 “landed” set.

---

### 4. PR4: pipe bags not on hot path — **honest POD if labeled; theater if “landed physics”**

Plan **PR4**: `Tls_Pipe` + `Seal_SM` + `Conn_Pt_Ring` POD (must-alias) + close SM; gate = **unit tests**. Phase 2 (PR5) is when HTTPS wire + seal∥send + firehose CI land.

**What landed (code comments match reality):**

- `http/pipe.odin`: pure types + admission/`seal_q` helpers; **no OpenSSL, no ring, no wire hot path**.
- `Conn_Pt_Ring`: admitted + high_water only; **“fixed slab free-list — later PR.”**
- `Tls_Pipe`: SM fields + counters; **no cipher engine**.
- `Wire_Conn_State.seal_q`: pure queue; **not** `host_submit_*`.
- Clear path still **`Wire_State` on Connection** (`wire.odin` ~773 LOC hot path vs `pipe.odin` 247 LOC pure).
- Connection embeds bags and **init on alloc/reset** (`conn_slab.odin`); tests assert layout + pure laws (`pipe_test.odin`).
- Explicit comment on Connection:

```text
// Plan A pipe bags (POD; not yet driving clear-H1 wire path — Phase 2+)
// Clear-H1 path still drives Wire_State
```

**Dual-bag residual:** live outbound owner = `conn.wire` (`Wire_State`); planned Law S1 bag = `conn.wire_conn`. Until wire routes through `Wire_Conn_State`, **two schedule bags** exist. Acceptable temporary **only** if status docs say “POD + pure tests, not wire physics.”

**Close SM:** Plan PR4 lists close SM. Tree has `seal_q_remove_gen` (stream-RST free-order for the **queue POD**) and existing connection `close_pending` / `close_on_io` for clear H1. Full §E.4 stream-vs-conn free-order SM under seal/socket dual-inflight is **not** a complete unit-test suite matching plan free-order table.

**Verdict:**

- As **PR4 POD foundation**: **PASS** if honesty says POD + pure helpers only.  
- As **“Phase 1 structure landed including pipe physics”**: **THEATER**.  
- Must-alias Law PT1 is **documented intent**, not enforced by a seal path (there is no seal path).

---

### 5. CAPABILITY_MATRIX honesty vs README claims

| Surface | Claims | Honesty grade |
|---------|--------|---------------|
| **README** | Scaffold / greenfield; host intentional stubs; **no** HTTP/2 or TLS product claim | **Good** |
| **CAPABILITY_MATRIX** | Author calendar: Clear H1 ✅ Phase 1; TLS H1/H2 phase-gated; honesty rules forbid paper-H2 | **Mostly good as calendar** |
| **ARCHITECTURE.md** | Still lists “HTTP/2 / HTTP/3” under near-term non-goals | **Honest product state**; slightly stale vs design track (ok if not “we abandoned the plan”) |
| **PHASE0_E0** | E0.4–E0.7 Planned (honest); **“Phase 1 structure (landed): PR1–PR4 … Stream_Slot sole exchange”** | **Overclaim** |
| **APP_CONTRACT / MIDDLEWARE** | Thin public story; no seal SM in app surface | **Good** (E0.1–E0.2) |
| **RESPONSE_COMMAND_PLANNER** | Separate “Phase 0–5” for **planner wire evolution** (materialize → writev → sendfile → stream) | **Naming collision** with dual-tls Phase 0–5 product readiness — confuses “done” |

Matrix header: *“What you may write *now*”*. Clear H1 ✅ is fair if the clear-H1 API is product-usable. Without `IMPLEMENTATION_STATUS`, a reader can confuse **phase calendar** with **repo ship milestone** (especially after PHASE0 says PR1–PR4 landed).

**No Fatal marketing lie** (no “supports HTTP/2”). Residual honesty failure is **internal status inflation**, not external H2 marketing.

---

### 6. Missing IMPLEMENTATION_STATUS / PHASE0 accuracy

| Artifact | Status |
|----------|--------|
| `docs/IMPLEMENTATION_STATUS.md` | **Missing** |
| `docs/PHASE0_E0.md` | Exists; partial truth table for E0.*; **inflates** Phase 1 / PR1–PR4 |
| Design plan PR map (PR0–PR10) | Spec only; not mirrored as live checklist with pass/fail |

**PHASE0 accuracy failures:**

1. Implies Phase 0 is in force while E0.4–E0.7 are Planned — plan said **merge blocker / hard fail CI**. Correct phrasing: **Phase 0 incomplete; docs half landed.**
2. “Stream_Slot sole exchange” — false under §D (Response/Request/wire still not slot-owned).
3. “PR1–PR4 landed” without distinguishing:
   - PR1: largely real (four-field `Plan_Context`, `Plan_Host`, `Conn_Caps`, tests).
   - PR2: **partial** (session/stream; not Response/plan/wire_slot).
   - PR3 / E0.8: real (`plan_test` E0.8 cases).
   - PR4: **POD + pure tests**, not wire.

---

## PR0–PR4 scorecard (harsh)

| PR | Plan gate | Landed? | Shortcut grade |
|----|-----------|---------|----------------|
| **PR0** | E0.1–E0.8 hard | E0.1–E0.3 docs **yes**; E0.8 tests **yes**; **E0.4 no CI**; **E0.5–E0.7 paper** | **Fail exit** |
| **PR1** | Four-field PC; Plan_Host; Conn_Caps | **Yes** (types + tests + plan_context public four) | **Pass** |
| **PR2** | Slot N=1; Response→slot; grep-clean dual-write; gen Session | **Partial**: gen + session on slot; Loop still holds req/res; wire on Connection; `_conn` sugar | **Major shortcut** |
| **PR3** | plan_body tables / E0.8 | **Yes** | **Pass** |
| **PR4** | Tls_Pipe + Seal_SM + Conn_Pt_Ring POD; close SM; unit tests | **POD + pure helpers + tests yes**; hot path **no**; close SM incomplete vs §E.4 | **Pass only as labeled POD** |

**PR5–PR10:** not claimed in code as product. Correct to leave unclaimed. Do not grade as done.

---

## Additional duals / residual debt (not full PR fails, still honesty)

1. **Progressive `stream_*` still first-class** (`response_begin_stream` / write / flush / end) while App Contract says it is not a second long-lived product. SSE Effects path exists; stream path remains teachable dual.
2. **`Wire_State` vs `Wire_Conn_State`**: dual outbound bags until Phase 2 fuses Law S1 into one owner.
3. **Phase number collision** between `RESPONSE_COMMAND_PLANNER.md` (wire experiment phases) and dual-tls product phases.
4. **No Host_Pull type yet** — E0.6 is vacuous until someone adds the ghost; still need CI ban before demos invent it.

---

## Unclaimed / missing work (explicit list)

### Phase 0 (must close before any TLS/H2 author marketing)

- [ ] **E0.4 CI job**: build + run same-handler sample (clear H1 now); assert zero protocol `#if` / no sid in sample sources.
- [ ] **E0.5–E0.7 CI greps** (or equivalent hard-fail script in CI): `examples/` + public godoc samples — ban `http/debug`, Host_Pull/pull registration helpers, stream-id/`_sid` prints.
- [ ] Mark Phase 0 **incomplete** until the above are green (not “Planned” next to a landed Phase 1 claim).

### PR2 finish (Phase 1 exit under Plan A)

- [ ] Move **Request + Response** storage into `Stream_Slot` (or prove equivalent sole ownership with **no** `Loop.res` / `Loop.req`).
- [ ] Move plan cursor / file region / progressive wire fields into **slot `Wire_Slot_State`** (or document intentional temporary exception with kill date) — today `conn.wire` is exchange-shaped.
- [ ] Grep-clean dual-write / dual-home: no session on Connection; no “loop is the real exchange.”
- [ ] Kill or strictly private-migrate **`Response._conn` sugar** (prefer `response_conn` → `slot.conn` only; hot path must not require independent `_conn` ownership story).
- [ ] Update PHASE0 / status: sole exchange is **true only after** the above.

### PR4 honesty / Phase 2 boundary

- [ ] Keep pipe bags labeled **POD / pure / not wire** until PR5 hooks seal∥send.
- [ ] Do not claim Law PT1 / S1 / Seal_SM **enforced** until one submit path and PT views alias.
- [ ] Close SM free-order unit tests aligned to §E.4 (stream RST mid-`seal_q` + mid-socket-send ownership) when dual-inflight exists.

### Status docs

- [ ] Add **`docs/IMPLEMENTATION_STATUS.md`**: PR0–PR10 table with **pass / partial / missing**, hot-path vs pure, and “author marketing allowed?” column.
- [ ] Fix **PHASE0_E0** overclaims (sole exchange; PR1–PR4 landed as block).
- [ ] Disambiguate planner “Phase N” vs dual-tls “Phase N” in author-facing links (one sentence each doc).

### Not missing-as-failure-for-this-review (correctly unclaimed)

- TLS handshake / mem-BIO / HTTPS H1 wire (PR5)
- Firehose CI peak ≳ 4× HW (PR5)
- H2 engine / ALPN h2 / multiplex / M1–M6 (PR7–PR9)
- Soft 503 / GOAWAY polish (PR10)
- README “supports HTTP/2”

---

## Required honesty fixes for WOW

WOW ≥ 9 on **this** critic is an **honesty bar**, not a TLS bar. Implement **all** of:

1. **Truthful scope line** (README Status + PHASE0 + new IMPLEMENTATION_STATUS, same words):  
   > Clear HTTP/1.1 host + planner + SSE/WS Effects. **Plan A Phase 0 incomplete (E0.4–E0.7 not CI-enforced). Phase 1 slot ownership partial (session/stream on slot; Response/Request still `Loop`). Pipe bags are POD + pure unit tests only — not TLS wire, not HTTP/2.**

2. **Retract** “Stream_Slot sole exchange” and “PR1–PR4 landed” as a single green block until PR2 exit criteria match §D.2.

3. **Wire E0.4** CI for clear-H1 same-handler sample (minimum). Document TLS/H2 jobs as “when phase lands.”

4. **Wire E0.5–E0.7** as hard-fail greps in the same CI (or fail the freeze claim).

5. **CAPABILITY_MATRIX**: keep calendar; add one line: *not a substitute for IMPLEMENTATION_STATUS; ✅ means product readiness target, not “this PR merged.”* Or point matrix “now” cells only at clear H1 and leave TLS/H2 as ⏳ until those phases actually ship (matrix already uses phase labels — the bug is missing ship-status sibling).

6. **PR4 comments stay** in code; status docs must **not** imply seal path or must-alias enforcement.

After (1)–(6), if the tree still has Loop-owned Response, score can rise on **honesty** (WOW possible as “honest Phase 0.x + POD”) while **plan fidelity** remains partial until PR2 finishes.  
**WOW is still No** if (1)–(4) are skipped even if more types land.

---

## Scorecard vs “would a skilled engineer alone invent this cut?”

| Cut | Inventable? | Ship state |
|-----|-------------|------------|
| Four-field `Plan_Context` + private `Plan_Host` | Yes | Landed |
| Session gen on slot; hangup `.Client_Gone` | Yes | Landed |
| Pure PT admit / seal_q gen-check | Yes | Landed as pure law |
| Response dual-bound to slot **and** Loop home | No — migration scar | **Present** |
| Second wire bag zeroed every conn, never read on send | No — freeze theater if called done | **Present** |
| Freeze docs without freeze CI | No — plan already rejected this | **Present** |

---

## Bottom line

| Question | Answer |
|----------|--------|
| Is this TLS/H2 done? | **No** — correctly unclaimed in README. |
| Is Phase 0 exited? | **No** — E0.4 missing; E0.5–E0.7 paper. |
| Is Phase 1 exited under Plan A §D? | **No** — Response still in Loop; wire still connection-owned. |
| Is PR4 honest POD? | **Yes in code comments**; **no** if PHASE0 “landed PR1–PR4 / sole exchange” is the public story. |
| WOWED? | **No** (6.2 overall). Honesty incomplete. |
| Path to WOW on this critic | Status truth + CI freezes + retract sole-exchange claim; finish PR2 for plan-fidelity WOW later. |

**Do not market dual-tls-h2 progress as “structure done.”** Market: **docs freeze half-landed, planner diet real, session-on-slot real, pipe POD pure-tested, exchange ownership migration incomplete, zero TLS wire.**
