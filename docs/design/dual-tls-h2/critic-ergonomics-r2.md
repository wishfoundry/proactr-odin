# Critic R2 — USER ERGONOMICS (public API for authors & app developers)

**Lens:** few concepts · zero footguns on the common path · progressive disclosure · delightful defaults  
**Bar:** WOW ≥ 9. Fair but harsh. Dual APIs and surface fat are not “implementation detail.”  
**Plans:** A (`plan-a.md` R2) · B (`plan-b.md` r2)  
**Prior:** `critic-ergonomics-r1.md` (A 8.0 · B 6.5 · not WOWED)  
**Focus this round:** App Contract · dual-API kills · hangup unity · pull/stream duals · escape hatches · residual Plan_Context / phase honesty

---

## Score

| Plan | R1 | R2 | Δ | Notes |
|------|---:|---:|---|-------|
| **A** | 8.0 | **8.8** | +0.8 | Closed every R1 Fatal and almost every Major. Residual public mechanism fields on `Plan_Context` keep it under 9. |
| **B** | 6.5 | **8.6** | +2.1 | Dual-API poisons excised; App Contract real; Plan_Context thinner than A. Phase ordering still makes long-lived H2 feel late. |
| **Synthesis (A surface + B private physics, ring/sqe off public)** | — | **9.1** | — | Would clear WOW if shipped as the freeze, not as a future hope. |

**Primary score for the multi-protocol API freeze as written (A as intentional public story):** **8.8**

---

## WOWED

**No.**

Both plans are now *competent freezes* of a good app surface. Neither is WOW. The common path is still “today’s clear H1, plus a promise it still works” — not *shorter*, not *sweeter*, not *impossible to misuse*. R1 Fatals are gone; residual progressive-disclosure leaks and phase storytelling keep both below 9.

A WOW pass would:

1. Land the App Contract as the *only* public story authors ever see first.  
2. Strip **every** ring/SQE/staging knob off public `Plan_Context`.  
3. Prove the invariant with CI that fails on protocol-branching samples **before** TLS ships.  
4. Make multiplex and SSE-on-H2 part of the *first* marketed H2, not a later badge.

Until then: excellent design cleanup, not WOW product.

---

## R1 → R2 scorecard (did they close what ergonomics demanded?)

### Fatal (R1)

| R1 Fatal | A R2 | B R2 | Verdict |
|----------|------|------|---------|
| **No ≤1-page App Contract** (docs-as-API fake freeze) | **Closed.** App Contract frozen at top; Phase 0 `APP_CONTRACT.md` + CI same sample; three-word mental model; hangup law; middleware card; phase-visible honesty table. | **Closed.** App Contract ≤1 page; ONESHOT / LONG-LIVED / ADVANCED / NEVER; middleware hard table; same invariant sentence. | **Both pass.** This was the ergonomics ship-blocker. Both treat it as first-class product, not epilogue. |
| **B: `Response._sid` / stream id on public Response** | N/A (already clean) | **Closed.** `frame_id` private on slot; Response binds slot; Session.id = gen only. Anti-pattern #6. | **B pass.** R1 poison pill removed. |
| **B: optional `Stream_Reset` beside `.Client_Gone`** | Already unified | **Closed.** Explicit: hangup always `.Client_Gone`; codes → metrics/logs only; anti-pattern #11. | **B pass.** Hangup unity restored. |

### Major (R1) — dual APIs & surface discipline

| R1 Major | A R2 | B R2 | Verdict |
|----------|------|------|---------|
| **A: fat `Plan_Context` (tls/caps/windows/coalesce duals)** | **Mostly closed.** Diet: removed `tls`, raw `caps`, `cipher_blocks_zc`, `prefer_coalesce`, frame/flow windows, `proto`. Host rest in private `Plan_Host`. | **Closed harder.** Public: only `sendfile_ok`, `preferred_copy_budget`, `max_write_unit`, `zero_copy_send` — matches R1 WOW diet almost exactly. | **B wins on thinness.** A still overshares (see Issues). |
| **A: escape hatches (`response_message_proto` / `conn_caps`)** | **Closed.** Not app API; debug package only; App Contract “Never”; D18; B.2 table. | **Closed.** NEVER list: Conn_Proto / Message_Proto / caps in handler branches. | **Both pass.** |
| **B: dual unary body (`body_set_pull` parallel fields)** | Already avoided; F.3 host windowing only | **Closed.** Unary = cmds only; `Slot_Deferred` host-private; Host_Pull “not `body_set_pull` on Response.” | **Both pass.** Mechanism demoted correctly. |
| **B: Body_Source / vapor three modes as product vocabulary** | N/A | **Closed.** Not a public type; L6 hybrid: cmds + host windowing + Effects. | **B pass.** |
| **B: `io.Stream` SSE dual** | Already refused in freeze | **Closed.** Refused in freeze; anti-pattern #12; Phase 7 effects only. | **Both pass.** |
| **Session attach language (slot vs stream id)** | Slot-only (§D.6) | Slot + gen; “never attach to stream id in docs” | **Both pass.** Vocabulary aligned. |
| **B middleware under-specified** | Strong card already | **Closed.** Hard may/must-not table; File stays File. | **Both pass.** A still slightly richer (phase notes). |
| **B Plan_Context high-water / pull_window public** | Windows private | **Closed.** Intentionally absent; private `Host_Plan_Snap`. | **B pass.** |
| **B H2 v0 silent serialize** | Concurrent N≥2 before H2 perf (D3/J) | M1–M5 gates; serial only as labeled milestone, not marketed default | **Both pass** with different honesty styles; A more aggressive product bar. |
| **Conn_Proto product enum vs orthogonal caps** | Orthogonal private caps | Caps private; no Conn_Proto product worlds | **Both pass.** |

### R1 “What would WOW” checklist

| WOW item | A | B |
|----------|----|----|
| Frozen app surface (oneshot / stream / advanced / never) | Yes | Yes |
| Plan_Context diet (sendfile_ok, budget, max_write_unit, zc) | **Partial** — still ships ring/sqe/fixed_files/max_iovecs | **Yes** |
| No dual hangup / long-lived / unary | Yes | Yes |
| Middleware contract card | Yes | Yes |
| Three app concepts (Intent / Exchange / Backpressure) | Explicit | Explicit |
| Phase 0 docs + CI same sample | Explicit exit | Explicit exit (policy tables; sample CI less shouted) |
| Delightful defaults (TLS/H2 listen-only; SSE early; multiplex real) | Strong | Weaker on SSE-on-H2 timing (Phase 7) |
| Synthesis A surface + B physics | Absorbed physics; ontology stays A | Absorbed A ontology; physics lead narrative |

**Net:** R1’s dual-API and App-Contract demands are **substantially closed by both**. The remaining gap is polish + progressive disclosure purity + when “the app story” becomes true on the wire — not another round of ontology surgery.

---

## Strengths (R2)

### Plan A — still the public-story champion

1. **App Contract is the product.** Opens the plan. Same sample, three listens. Hangup law, middleware card, phase-visible honesty (WS, admission, multiplex) in one place. Authors can stop reading after §App Contract and still be safe.
2. **Dual-API kill list is review-ready.** B.2 table: no `conn_caps`/`message_proto`, no stream id on Session, no second hangup, no public pull, no `io.Stream`, no fat Plan_Context dump. Reviewers can reject without philosophy.
3. **Effects surface frozen and protocol-blind.** Same `(sess, ev, user) → Effects`; `.Client_Gone` / `.Writable` only. H1↔H2 mapping table (H) is the right teaching artifact for framework authors without leaking to app enums.
4. **Middleware remains a contract, not a vibe.** Cmd rewrite only; thin plan_context; File demotion by planner. Range/Gzip/Static stay one model.
5. **Mental model load controlled.** Apps: Request, Response, Session, Effects. Slot/Pipe implementer-only. Three words: Intent / Exchange / Backpressure.
6. **Phase honesty as ergonomics.** Multiplex concurrency and soft 503 are not silent footguns if the contract says so. CI same-handler under clear/TLS/H2 is the real freeze test.
7. **Escape hatches demoted correctly.** Caps/proto are host-private fill; public never needs them for correctness.

### Plan B — the dual-poison recovery

1. **R1 Fatals actually deleted.** No `_sid`, no `Stream_Reset`, no public pull rail, no `io.Stream` in freeze. That is the difference between “vapor field manual with an API sketch” and “freeze candidate.”
2. **Thinnest honest public `Plan_Context`.** Four fields. Matches the R1 WOW diet. No ring free, no SQE budget, no flow windows, no caps bitset on the app struct. Progressive disclosure is real here.
3. **App Contract + Middleware Contract are crisp.** Text-block ONESHOT/LONG-LIVED/ADVANCED/NEVER is copy-paste tutorial material. Middleware may/must-not is greppable.
4. **Unary intent compression held.** Large bodies remain Static/Bytes/File; windowing is host `Slot_Deferred`. Authors are not taught a third body system.
5. **Hangup and backpressure unified.** TCP / TLS alert / H2 RST / stream GOAWAY → `.Client_Gone`. Buffer HW or window reopen → `.Writable`. Same as A; no optional second enum.
6. **Multiplex marketed only after M1–M5.** Serial H2 as labeled engineering milestone is better ergonomics than silent HOL default. Authors who read the plan know “curl --http2 green ≠ multiplex product.”
7. **Gen-stable Session.** Public handle = generation; stream id never the story. Aligns with A’s ABA discipline.

### Shared (both R2)

- Invariant sentence: correct on clear H1 ⇒ correct on HTTPS and HTTP/2.  
- Two intent rails only: commands | effects.  
- No public resume/poll/SSL*/body-modes-as-mechanisms.  
- Stream_Slot sole exchange; Connection is pipe.  
- Live windows are host law, not handler API.  
- WS honestly H1(/TLS) until a later phase.

---

## Issues

### Fatal

*(None remaining at R1’s bar. Dual-API ship-blockers are closed.)*

If a new Fatal must be named for **harsh** WOW bar only:

1. **Neither plan has actually landed the App Contract as a repo artifact with CI.**  
   Design text promises Phase 0. Ergonomics freezes are false until `docs/APP_CONTRACT.md` exists and a sample handler runs under three listens without `#if`. That is process, not ontology — but user ergonomics *is* the shipped docs. **Not a design Fatal; treat as Phase 0 exit hard-gate, not a re-architecture trigger.**

### Major

1. **Plan A: public `Plan_Context` still includes mechanism staging knobs.**  
   R2 diet removed the worst duals (`tls`, caps, flow windows, `prefer_coalesce`). Still public:

   | Field | Ergonomics problem |
   |-------|-------------------|
   | `output_ring_free` | Ring is L1. Handlers “optimizing” for free slots re-teach proactor. |
   | `sqe_budget` | SQE is proactr substrate. Same footgun class as caps escape hatches. |
   | `max_iovecs` | Executor shape; rarely a *semantic* app constraint. |
   | `fixed_files` | Niche; fine for advanced middleware, noisy on the default public struct. |

   R1 WOW diet was four semantic fields. A ships **eight**. The common path is still fine *if nobody opens the struct* — but the struct is the advanced API, and advanced authors *will* open it.  
   **Law:** if correctness never requires it, it is not on the public struct in v1. Put ring/SQE under host-private snap or `http/debug`.  
   **Score impact:** this is the single largest reason A is 8.8 not 9.1.

2. **Plan B: long-lived on H2 is Phase 7 — late for the marketed invariant.**  
   App Contract says Effects are the long-lived story and “correct on H2.” Implementation phases put TLS H1 cipher at 3, H2 unary at 5, multiplex bar at 6, **Effects on TLS H1 + H2 at 7**.  
   Risk: early “H2 ready” language without SSE/session parity trains two ecosystems (unary-H2 packages vs session-H2 packages) or forces authors to keep H1 for streaming.  
   A folds sessions into Phase 3 exit more tightly. B should either promote Effects-on-slots into the multiplex product bar (M-gates) or state in App Contract: “SSE/WS on H2: Phase 7; until then H1(/TLS) only” with the same honesty as WS.  
   **Phase-visible honesty missing for sessions-on-H2** (WS is covered; SSE-on-H2 is not as explicit).

3. **Plan B: narrative still teaches implementers first.**  
   §0 vapor lessons, Provider, mem-BIO, seal SM dominate page weight before the App Contract is internalized by a casual reader who opens the wrong section. Contract is *present* and good; **discoverability** for app authors is weaker than A (contract at top, physics later).  
   Harsh: a freeze candidate for *user* ergonomics should not require skimming cipher state machines to find `sse_start`. Structure of the doc is part of the product.

4. **Both: “Host_Pull” / deferred produce must never appear in app docs.**  
   B’s private `Slot_Deferred` includes a `pull` proc (“host-registered only”). A has deferred fill cursor on `Wire_Slot_State`. Correct privately.  
   **Footgun:** one blog post or example that shows `pull` and the dual body API is back by social means. Freeze must say: **no sample, no godoc, no middleware helper** that registers pull from app code. Host/static middleware internals only. A’s “no third public intent rail” is clearer law wording; B should copy that sentence into App Contract NEVER.

5. **Both: multiplex honesty still easy to market away.**  
   A requires concurrent deferred N≥2 before H2 perf claims. B requires M1–M5 before perf language; allows serial milestone.  
   Remaining ergonomics risk is **operator/docs**, not types: “supports HTTP/2” in README without “multiplex concurrent streams: yes.” Demand an App Contract or README capability line, not only implementer gates. Silent serialize is a dual *behavior* even when types are pure.

### Minor

1. **A’s six meta-concepts** still risk tutorial creep if implementer vocabulary leaks. Contract says apps never say Slot/Pipe — enforce in doc review, not only plan text.
2. **A `Plan_Context` vs B:** B omits `fixed_files` / `max_iovecs` / ring / sqe. Prefer B’s public shape; keep A’s private `Plan_Host` richness.
3. **B `Cipher_State` type sketch still names `ssl: rawptr`.** Private module only — fine. Ensure no re-export in public package tree (same SSL\* leak class as R1).
4. **Admission:** A documents assert→soft 503 Phase 4. B soft 503 in Phase 8. Load-test footgun for app authors until then — note in App Contract as temporary host behavior, not app API.
5. **WS asymmetry** documented by both — good. Keep one sentence in APP_CONTRACT forever so protocol-blind WS is not assumed.
6. **A CI story is stronger** (“same handler sample under clear / TLS H1 / H2”). B should promote the same sample to Phase 0/PR0 exit, not only policy table tests.
7. **Progressive `stream_*` residual language:** neither R2 plan re-opens public progressive stream duals as primary; confirm existing proactr progressive APIs (if any) are folded under the same effects-or-cmds law or explicitly deprecated in App Contract. Silence is a minor documentation hole.
8. **Debug package temptation:** both allow debug introspection of caps/proto. Name it `http/debug` and **do not** import it from examples in `examples/`. One import in a popular sample reopens escape hatches.

---

## Dual-API audit (explicit)

| Temptation | A R2 | B R2 | Pass? |
|------------|------|------|-------|
| Second hangup event | `.Client_Gone` only | `.Client_Gone` only | **Both** |
| Stream id on Response/Session | Never; gen only | Never; gen only | **Both** |
| Public caps / Message_Proto / Conn_Proto | Debug-only / host-private | NEVER list | **Both** |
| `body_set_pull` parallel unary | Host windowing only | Host `Slot_Deferred` only | **Both** |
| `io.Stream` long-lived | Refuse in freeze | Refuse in freeze | **Both** |
| Public resume / poll | Never | Never | **Both** |
| Body modes = writev/sendfile/SSL_write | Never | Never | **Both** |
| Fat Plan_Context as strategy façade | **Partial fail** (ring/sqe) | Pass (thin) | **B** |
| Silent H2 serial as “H2” | Rejected as default | Labeled milestone only | **Both (A stricter)** |
| Effects vs live flush dual | Effects frozen | Effects only; no vapor live | **Both** |

**Hangup unity:** closed.  
**Pull/stream duals:** closed as *public* APIs.  
**Escape hatches:** closed as *app* APIs.  
**Remaining dual class:** public executor knobs (A) and late behavioral readiness (B phases).

---

## Comparative note (ergonomics)

| Dimension | Plan A R2 | Plan B R2 | Winner |
|-----------|-----------|-----------|--------|
| App Contract placement & completeness | Top; honesty table; CI sample | Clear; slightly leaner; physics-heavy neighbors | **A** |
| Dual-API kill completeness | Excellent; ring/sqe residual | Excellent; thinner context | **B (surface purity)** |
| Hangup unity | Law | Law | **Tie** |
| Pull / stream duals | Host-only windowing | Host-only deferred | **Tie** |
| Escape hatches | Explicit B.2 + Never | Explicit NEVER | **Tie** |
| Plan_Context progressive disclosure | Good diet, not great | R1 WOW diet | **B** |
| Middleware author UX | Card + §I | Hard table | **A (slight)** |
| Phase honesty for app-visible capability | WS, admission, multiplex concurrency | M-gates; SSE-on-H2 late | **A** |
| Mental model load (apps) | Lowest if docs stay at contract | Low if they never read §0–C | **A** |
| Framework author (host) clarity | Strong ontology | Stronger executable physics | **B (not app score)** |
| Docs-as-API readiness | Best stated exits | Strong contracts; weaker sample-CI shout | **A** |
| Risk of social dual reintroduction | Debug package | Host_Pull in samples | **Slight A** |

**Verdict:**  
Both R2 plans are **freeze-worthy for user ergonomics** in a way R1 B was not. **A remains the preferred public freeze** for narrative, phase honesty, and contract placement. **B’s public `Plan_Context` is the preferred shape** and should be absorbed into A (drop `output_ring_free`, `sqe_budget` from public; demote `max_iovecs` / `fixed_files` or keep only if middleware truly needs them as *semantic* constraints).

Shipping A as written is an **8.8** product surface — close enough that the next edit is a diet, not a redesign. Shipping B as written is an **8.6** product surface with a cleaner advanced struct and a worse “when is the invariant true for SSE on H2?” story.

---

## What would WOW now (≥9) — residual only

R1’s big list is largely done. Remaining for ≥9:

### 1. Plan_Context public shape (ship B’s diet)

```odin
Plan_Context :: struct {
    sendfile_ok:           bool,
    preferred_copy_budget: u32,
    max_write_unit:        u32,  // 0 = ignore
    zero_copy_send:        bool,
}
// optional v1.1 if middleware proves need:
// fixed_files, max_iovecs — still not ring/sqe
```

Everything else: `Plan_Host` / `Host_Plan_Snap` only.

### 2. App Contract one-liners that must stay forever

- Hangup: **only** `.Client_Gone`.  
- Unary bytes: **only** body cmds; host may window; **no** app pull API.  
- Long-lived: **only** Effects; **no** `io.Stream`.  
- Identity: Session **gen**, never stream id.  
- Caps/proto: **not** handler API.  
- Capability honesty: WS H1 until phase X; H2 multiplex concurrent N≥2 before “H2 perf”; SSE on H2 from phase Y (name it).

### 3. Phase 0 is the ergonomics merge gate

- [ ] `docs/APP_CONTRACT.md` ≤1 page (no Exec_Op, no seal SM)  
- [ ] `docs/MIDDLEWARE_CONTRACT.md` reject checklist  
- [ ] CI: same handler under clear H1 / TLS H1 / H2  
- [ ] No example imports `http/debug` for caps/proto  
- [ ] No sample registers Host_Pull from app code  

### 4. Delight defaults (product, not types)

- TLS and H2 are listen options.  
- First marketed H2 includes concurrent slots **and** session/SSE on slots, or capability lines say otherwise.  
- Large `body_file` / Static: same API; TLS cost is performance, not a new author concept.

### 5. Synthesis freeze line

| Public (ship) | Private (steal) |
|---------------|-----------------|
| A’s App Contract placement + phase honesty + middleware card + hangup/effects laws | B’s window numbers, seal SM, mem-BIO, duplex law, fixed pt/rx caps |
| **B’s four-field `Plan_Context`** | A’s Stream_Slot / pipe ontology (both already agree) |

**Do not reopen:** `_sid`, `Stream_Reset`, public pull, `io.Stream`, public caps/proto.

---

## Ruthless one-liners

- **A:** The App Contract is finally a product. Stop advertising the ring free count as a “constraint.”  
- **B:** You deleted the unforgivable duals. Now stop hiding the app story behind vapor anatomy, and say when SSE-on-H2 is true.  
- **Both:** Dual APIs are dead on paper. WOW dies in examples, debug imports, and README “supports H2” lies — police those or the freeze is theater.  
- **Score truth:** R1 demanded surgery; R2 delivered it. R3 should be a **diet and a docs landing**, not another ontology rewrite.

---

## Close-out vs R1 Fatals/Majors

| Plan | R1 Fatals open | R1 Majors open | New Majors |
|------|----------------|----------------|------------|
| **A** | 0 | ~0.5 (Plan_Context residual fat) | ring/sqe on public context |
| **B** | 0 | 0 on dual-API list | SSE-on-H2 phase lag; narrative load |

**WOWED:** No.  
**Ship-as-freeze for ergonomics?** Yes, with A’s contract + B’s Plan_Context diet + Phase 0 docs/CI hard gate.  
**Primary freeze score:** **8.8 (A)** · secondary **8.6 (B)** · synthesis path **9.1**.

---

*Critic: user ergonomics R2 · dual-tls-h2 · bar WOW ≥9 · not WOWED · duals mostly dead · surface almost thin enough*
