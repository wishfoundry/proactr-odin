# Handmade / Craft Design Critique — R2

**Critic posture:** Casey Muratori / data-oriented / Odin house style.  
**Bar:** WOW ≥ 9. Willing to grant if the craft bar is *actually* met — no participation trophies, no “ship it” curves.  
**Subject:** Plan A (R2) vs Plan B (r2) — multi-protocol (TLS + H2) high-level API for proactr.  
**Prior:** `critic-handmade-r1.md` (A 8.7 / No · B 6.9 / No).

**Question asked of every type and phase (unchanged):**  
Would a skilled engineer, alone at a whiteboard, invent *this* cut — or is it interface soup, vapor vocabulary with the serial numbers filed off, or dual-maint forever?

---

## Verdict headline

| Plan | Overall | WOWED | vs R1 |
|------|---------|-------|-------|
| **A** | **9.25 / 10** | **Yes** | 8.7 → 9.25; closed every R1 craft Fatal/Major that blocked WOW |
| **B** | **9.1 / 10** | **Yes** | 6.9 → 9.1; dual-maint FAIL flipped; interface joints killed; Slot/Pipe absorbed |

Both freezes now pass the handmade bar. A remains the cleaner *carved* freeze document. B is no longer a ported field manual with a dual-world type mistake — it is a real single-ontology design with measured pipe physics. Granting WOW to both is not grade inflation: R1 listed concrete kill conditions; both documents executed them.

---

## Plan A (R2) — TLS + HTTP/2 designed into planner + sessions

### R1 “What would WOW” checklist

| R1 demand | R2 status |
|-----------|-----------|
| Collapse `Plan_Context` denorms (`tls`, `cipher_blocks_zc`, `prefer_coalesce`, fat flow dump) | **Done** — §C.2 thin public; host-private `Plan_Host`; no public caps/proto/flow |
| Private POD numbers (PT/CT, inflight, high-water) | **Done** — §F.1: 64 KiB pull, ~4-record batch, CT×2, PT HW 256 KiB, RX_HOLD 32 KiB, sock send ∈ {0,1}, CT sealed ∈ {0,1,2} |
| Hard H2 always-arm-recv law | **Done** — Law D1 §J; anti-pattern table; T5 burst drain |
| Phase 2 ALPN `http/1.1` only | **Done** — §E.5; no negotiate-and-ignore |
| `Frame_Window` out of plan ops | **Done** — host automatic on framer progress |
| Keep Slot/Pipe cut; no Session_Wire / Provider product | **Kept** |
| mem-BIO one-way private sentence | **Done** — §E.1 |
| Dual-write Phase 1 hard exit | **Done** — §D.2 grep-clean; Response binds slot |

R1 predicted merge-target **9.2–9.4**. A alone now sits in that band.

### Rule scores

| # | Rule | Verdict | Note |
|---|------|---------|------|
| 1 | Data-oriented over interface-oriented | **PASS** | Ownership cake is data, not vtables. Orthogonal `Conn_Caps` bit_set; exclusive `H1_Framer \| H2_Engine` raw union (not Frame_State soup); `Stream_Slot[]` + gen; Tls_Pipe CT[2] as POD; live `Slot_Flow` re-read not interface callbacks. Cipher opacity is module boundary, not Provider sermon. |
| 2 | Explicit constraints, private mechanisms | **PASS** | App Contract freezes intent rails only. Thin `Plan_Context` is optional advanced read. Mechanisms (seal schedule, Wait_Flow park, Commit_Unit, mem-BIO) never mint body APIs or stream-id events. Hangup = `.Client_Gone` only. |
| 3 | No fake abstraction | **PASS** | R1 Partial is closed. Redundant truth fields gone. `max_write_unit` is one intentional coalesce (record/frame/policy), not a synonym cluster. Exclusive framer is a real cut. Fused `Commit_Unit` refuses micro-op taxonomy as public truth. Residual: public still carries staging hints (`output_ring_free`, `sqe_budget`, `max_iovecs`, `fixed_files`) — real for pure planner tables, slightly dashboard-ish, not rename-of-truth. Not enough to keep Partial. |
| 4 | One way for the common path | **PASS** | Same sample, three listens. H1 = N=1 same types. No public duals (`conn_caps`, `message_proto`, second hangup, `body_set_pull`, io.Stream). Multiplex serial only as labeled HOL debug — not default. Law S1: one submit_send owner. |
| 5 | Phase without dual-maintenance forever | **PASS** | App freeze → slot truth → TLS physics → H2 → polish. One host grown in place. No vapor package fork. Phase 2 ships write physics (not “CT pipeline Phase 4 forever”). |
| 6 | Platform honesty (TLS/H2 cost visible) | **PASS** | sendfile truth table; numbers as pipe POD; ALPN honesty; concurrent deferred N≥2 before H2 perf claims; free-order close; peak O(window) failure triggers. kTLS not smuggled as current ZC. |
| 7 | proactor-native | **PASS** | Arm only from CQE paths (T1). No public resume/poll. Effects timing host-owned. Socket send_inflight ∈ {0,1}; CT pipeline depth separate. Duplex exception under Multiplex documented as law, not smuggled readiness. |
| 8 | Handmade elegance | **PASS** | Intent / Constraints / Policy / Mechanism / **Slot** / **Pipe**. App Contract is the freeze spine. Laws S1, W1, W2, D1 are carveable whiteboard rules. Type sketch is implementable without inventing a second architecture. L5→L1 ASCII remains slightly ceremonial; the POD graph is the design — acceptable. |

### Overall Score: **9.25 / 10**

### WOWED: **Yes**

### Residual craft nits (not WOW blockers)

1. **Public Plan_Context still ~8 fields.** The lethal denorms are dead. What remains is mostly honest planner input. A harsher diet (A’s thin four fields matching B, plus maybe `max_write_unit` only) would be *more* elegant — optional polish, not a fail.

2. **Exec_Op enum still lists clear-path + fused ops.** Public contract correctly says “windows/inflight, not op laundry.” Private enum of 8 kinds is fine for clear H1 legacy; guard reviews against re-growing Write_Plain + Cipher_Seal + Frame_Data as three hot-path interpreter steps after fusion was promised.

3. **Layer diagram invitation.** Same R1 risk: ownership table is right; do not grow Adapter interfaces between L-numbers.

4. **Document density.** App Contract + A–R + critic response is long for a freeze. Craft of the *system* is WOW; craft of the *doc* could still trim.

### What still would push A toward 9.5+

- Public `Plan_Context` matching B’s four-field diet (or explicit “computed accessors only” for ring/sqe hints).  
- One-line normative: “hot path cursor advances by flush units; Exec_Op list is clear-H1 legacy + Commit_Unit/Wait_Flow only.”  
- Keep Slot/Pipe/App Contract exactly as written.

---

## Plan B (r2) — vapor-informed, single-slot, completion-native

### R1 “What would WOW” checklist

| R1 demand | R2 status |
|-----------|-----------|
| Drop wholesale vapor package fork; steal facts, own engine | **Done** — §G Steal vs own; “not forever dual-maint”; one tree |
| Replace `Conn_Proto` with caps + framing | **Done** — orthogonal `Conn_Caps`; no product Conn_Proto |
| Replace `Response._sid` with slot ownership + gen Session | **Done** — frame_id private on slot; Session.id = gen |
| Mem-BIO + windows + duplex law kept | **Kept / strengthened** — §L5 constants, Law O4/O5, M1–M5, §L free order |
| Effects only long-lived; pull host-private | **Done** — no public body_set_pull; Slot_Deferred private; io.Stream refused |
| Kill Session_Wire product | **Done** — private switch; no proc-table type |
| Provider under cipher only | **Done** — private L2; not north-star IOC |
| Types lead freeze; evidence is footnote | **Mostly done** — App Contract / Ontology first; §0 lessons remain long but no longer the type spine |

R1’s Rule 5 **FAIL** is gone. That alone moves B from “craft fail” to “contender.”

### Rule scores

| # | Rule | Verdict | Note |
|---|------|---------|------|
| 1 | Data-oriented over interface-oriented | **PASS** | Single `Stream_Slot` POD; fixed `pt` ring + high-water; `Cipher_State` CT[2] + seal counts; `Wire_Conn_State` fairness queue; caps bit_set. Provider/ssl as `rawptr` under cipher is *private data*, not a public vtable product. Residual OpenSSL-shaped field names (`ssl`, `provider`) are slightly less elegant than A’s opaque engine — still data, not interface soup. |
| 2 | Explicit constraints, private mechanisms | **PASS** | Thinnest public `Plan_Context` of the pair (four fields). Fat snap private. Deferred produce host-only. Never list is review-grade. Middleware may/must-not table is hard. |
| 3 | No fake abstraction | **PASS** | Session_Wire dead. Conn_Proto dead. Framer exclusive bag. Seal_SM transitions are real mechanism, not rename. **Minor scar:** `Slot_Deferred.Host_Pull` with `pull: proc(...)` is one private function-pointer ghost of vapor Body_Source — marked host-only, not app API. Acceptable under freeze; do not let it become public. |
| 4 | One way for the common path | **PASS** | Law O1–O2: one produce → seal → submit path; no fuse optionality. cmds \| effects only. H1 = N=1. Serial H2 only as labeled engineering milestone, never marketed default. M1–M5 before perf language. |
| 5 | Phase without dual-maintenance forever | **PASS** | R1 FAIL closed. Cherry-pick frame layouts/vectors/HPACK math; rewrite storage to slots; OWNERS one tree. Phases 0–1 structure before TLS; write windows on clear (P2) before cipher (P3). Not dual architecture. |
| 6 | Platform honesty | **PASS** | Still B’s crown. Numeric defaults, separate CT/PT high-water, BIO_RX_HOLD fixed overflow→close, duplex + rBIO burst, close free-order SM (§L), M1–M5 product gates, peak O(windows×slots). Best “cost is data” story. |
| 7 | proactor-native | **PASS** | Completions primary; demux/thread TLS non-goals; CQE-driven cipher drive; soft_cq tests only; Effects timing; gen check on CQE abort. `send_inflight: bool` alone **forbidden** — counts + Seal_SM required. |
| 8 | Handmade elegance | **PASS** | North star is Slot/Pipe in one sentence. Close free-order SM and Seal_SM are whiteboard-carvable. §0 vapor lessons remain archaeology-heavy for a freeze doc (still longer than ideal), but ontology and laws now lead. No longer “ported portfolio with proactr glue.” |

### Overall Score: **9.1 / 10**

### WOWED: **Yes**

### Residual craft nits (not WOW blockers)

1. **`ssl` / `provider` rawptr in the freeze type sketch.** Correct privacy; slightly vendor-shaped. Prefer A’s opaque `Conn_Cipher_Engine` naming in the freeze surface so implementers do not paste OpenSSL into host headers.

2. **Host_Pull proc in private deferred.** One seam. Keep it host-static-middleware only; never `body_set_pull` on Response.

3. **Evidence section length.** L1–L15 is excellent research; craft freeze docs still read better when lessons shrink to a short “physics provenance” appendix. Not a type fail.

4. **More phases (0–8) than A (0–4).** Honest engineering staging (clear bulk windows before TLS is smart). Slightly harder to hold as one mental model; not dual-maint.

### What still would push B toward 9.4+

- Opaque cipher engine name in the freeze sketch (drop public-looking `ssl:` field).  
- Collapse Host_Pull or gate it behind “host static only, never Response.”  
- Shorten §0 to one page of constants + steal/own table; keep laws and types as the spine.  
- Optionally absorb A’s Wire_Slot vs Wire_Conn naming split if it clarifies ownership further (B already has the meaning).

---

## Comparative note (R2)

| Dimension | Plan A | Plan B | Winner (craft bar) |
|-----------|--------|--------|--------------------|
| Core ownership cut | Stream_Slot / pipe; H1 = N=1; Wire_Conn vs Wire_Slot | Stream_Slot / pipe; H1 = N=1; wire_conn + pt ring | **Tie** (both carved; A slightly clearer wire split) |
| Constraint surface | Thin public (still ~8 fields) | Thinnest public (4 fields) | **B** (diet) |
| Mechanism privacy | Tls_Pipe SM + fused Commit_Unit; no SSL\* | Cipher_State + Seal_SM; Provider under module | **A** (opacity naming); **B** (seal SM detail) |
| One architecture forever | Phase in place; no fork | Cherry-pick facts; one owned engine | **Tie** (both pass Rule 5) |
| Platform cost honesty | Numbers + truth table + D3 concurrent bar | Numbers + free-order SM + M1–M5 + HW both PT/CT | **B** (slight) |
| Proactor purity | T1 arm-from-CQE; no resume | CQE drive; bool inflight alone forbidden | **Tie** |
| Invented vs ported | Thesis-first freeze | Thesis + physics footnotes; lessons still long | **A** |
| Close / free-order law | Free-order list in §E.4 | Full stream + conn death SM §L | **B** |
| App Contract as docs-as-API | Front-loaded, CI same-sample gate | Front-loaded ≤1 page; CI implied by phases | **A** (slightly tighter Phase 0 gate) |
| Handler identity | Zero protocol branch; debug-only escape | Zero protocol branch; Never list hard | **Tie** |

**Summary judgment**

- **Plan A** met every R1 craft WOW condition without importing B’s old interface joints. Slot/Pipe remains the handmade core; App Contract, Law W1/W2, Law D1, Tls_Pipe SM, and window POD close the gap that kept A at 8.7. **WOWED: Yes (9.25).**

- **Plan B** ceased to be dual-maint vapor adaptation. Single slot ontology, orthogonal caps, gen Session, one outbound law, private deferred, no Session_Wire — that is a real carve. Physics numbers and close SM remain best-in-pair. Residual scars (ssl rawptr shape, Host_Pull proc, long lessons) keep it a hair under A on elegance, not under the WOW bar. **WOWED: Yes (9.1).**

**If forced to ship one freeze under this critic’s rules (R2):**  
Either is freezeable. Prefer **Plan A as the architecture spine** if you want the single best *carved* document; prefer **Plan B’s §L free-order + Seal_SM transitions + four-field Plan_Context + M1–M5 gates** as mandatory patches into A if merging. Do **not** reintroduce Provider product surfaces, Session_Wire, Conn_Proto, public pull rail, or package fork.

**Merged theoretical ceiling (still valid):** **9.4–9.5** — A’s App Contract + Wire_Slot/Wire_Conn + opaque Tls_Pipe + B’s free-order SM + thinnest public context + M1–M5 wording + dual PT/CT high-water.

---

## Scoreboard (compact)

| Plan | R1 | R2 | R3 | R4 | R5 | R6 | R7 | R8 | Overall | WOWED |
|------|----|----|----|----|----|----|----|----|---------|-------|
| **A** | Pass | Pass | **Pass** | Pass | Pass | Pass | Pass | Pass | **9.25** | **Yes** |
| **B** | **Pass** | **Pass** | **Pass** | **Pass** | **Pass** | Pass | Pass | **Pass** | **9.1** | **Yes** |

R1 → R2 flips of note:

| Plan | Rule | R1 | R2 |
|------|------|----|----|
| A | 3 No fake abstraction | Partial | **Pass** |
| B | 1 Data-oriented | Partial | **Pass** |
| B | 2 Explicit constraints | Partial | **Pass** |
| B | 3 No fake abstraction | Partial | **Pass** |
| B | 4 One way | Partial | **Pass** |
| B | 5 Dual-maint forever | **Fail** | **Pass** |
| B | 8 Handmade elegance | Partial | **Pass** |

---

## R1 issues — explicit close (both)

### Plan A

| R1 issue | Closed? |
|----------|---------|
| Constraint field bloat | **Yes** — thin public; denorm bools removed |
| Mechanism without sizes | **Yes** — §F.1 POD numbers; Phase 2 ships them |
| Missing duplex law | **Yes** — Law D1 |
| ALPN mush Phase 2 | **Yes** — http/1.1 only |
| Frame_Window fuzzy op | **Yes** — host automatic |
| TLS default path sentence | **Yes** — mem-BIO only default |

### Plan B

| R1 issue | Closed? |
|----------|---------|
| Dual-maintenance strategy | **Yes** — steal facts, own engine |
| Interface soup | **Yes** — no Session_Wire product; Provider private |
| Response._sid | **Yes** — frame_id on slot only |
| Conn_Proto product enum | **Yes** — orthogonal caps |
| Body mode explosion | **Yes** — cmds \| effects; deferred private |
| v0 serial as product | **Yes** — M1–M5 gates |
| Evidence-as-spine | **Mostly** — types lead; §0 still long |
| Session_Wire fake abstraction | **Yes** |

---

*Critic: handmade / data-oriented / proactor house rules. Bar WOW ≥ 9. Both plans clear it in R2. No participation trophies — the types earned it.*
