# Critic R3 — USER ERGONOMICS (final re-review)

**Lens:** few concepts · zero footguns on the common path · progressive disclosure · delightful defaults · honesty in time  
**Bar:** WOW ≥ 9 only. Willing to grant WOW when R2 residuals are closed.  
**Plans:** A (`plan-a.md` R2 / status Round-3) · B (`plan-b.md` r3)  
**Prior:** `critic-ergonomics-r2.md` (A 8.8 · B 8.6 · not WOWED)  
**Focus this round:** Plan_Context public diet · App Contract sole story · phase capability honesty (SSE H2) · dual-API kills · docs/CI freeze

---

## Score

| Plan | R1 | R2 | R3 | Δ R2→R3 | Notes |
|------|---:|---:|---:|---------|-------|
| **A** | 8.0 | 8.8 | **9.2** | +0.4 | Four-field `Plan_Context`; App Contract sole public story; SSE-on-H2 in first marketed H2 (Phase 3); Phase 0 docs/CI freeze. Residual is craft polish, not dual APIs. |
| **B** | 6.5 | 8.6 | **9.3** | +0.7 | PART I front-matter; author capability matrix ⏳/✅; M6 SSE-on-H2 at product bar; E0.1–E0.8 hard freeze; Host_Pull ban in contract + examples. Slight edge on author-time honesty UX. |
| **Synthesis** (A contract placement + phase-exit tightness · B matrix + E0 gates · shared four-field context) | — | 9.1 | **9.5** | +0.4 | Ideal freeze package if merged as one doc set. |

**Primary score for the multi-protocol API freeze as written:**  
- Prefer **B’s author-facing freeze package** (Part I + matrix + E0) if picking one narrative.  
- Prefer **A’s App Contract density** (hangup / middleware / phase table in one page) if picking one contract page.  
- Either plan alone is **WOW-eligible**. Ship either; do not re-open ontology.

---

## WOWED

| Plan | WOWED | Why |
|------|:-----:|-----|
| **A** | **Yes** | R2’s single largest A demerit (ring/SQE/`max_iovecs`/`fixed_files` on public `Plan_Context`) is gone. App Contract is the only public story; Phase 0 freezes docs-as-API; first marketed H2 includes sessions on slots; dual-API kill list remains greppable. Common path is “today’s clear H1 sample, three listens, no `#if`.” That is delightful progressive disclosure. |
| **B** | **Yes** | R2’s B demerits (SSE-on-H2 lag, implementer-first narrative, soft Phase 0, Host_Pull social dual, README H2 lies) are surgically closed without reopening dual hangup / pull / stream-id / fat context. Capability matrix turns phase honesty into something authors can *use*, not only implementers can *assert*. |
| **Both as a pair** | **Yes** | R3 is the diet + docs landing R2 asked for. No further ergonomics redesign is justified. Remaining issues are merge discipline and example police. |

**WOW bar met.** Further rounds should enforce the freeze in tree (`APP_CONTRACT.md`, CI samples, example bans) — not rewrite types.

---

## R2 → R3 residual scorecard

### What R2 required for ≥9

| Residual (R2) | A R3 | B R3 | Verdict |
|---------------|------|------|---------|
| **1. Plan_Context public diet** — only `sendfile_ok`, `preferred_copy_budget`, `max_write_unit`, `zero_copy_send` | **Closed.** §C.2 four fields; host meters in private `Plan_Host`; D2/D18; type sketch matches. Explicitly removed `output_ring_free`, `sqe_budget`, `max_iovecs`, `fixed_files`. | **Already closed at R2; held.** Part I + B.3 still exactly four fields; Host_Plan_Snap private; D5/D17. | **Both pass.** A absorbed B’s thin shape — the R2 synthesis ask. |
| **2. App Contract sole story** — authors never taught Exec_Op / Tls_Pipe / seal SM | **Closed.** Contract opens plan; “only public story”; implementer epics banned from tutorials/`examples`/README how-to; Phase 0 exit: APP_CONTRACT is *copy of this section only*. | **Closed harder on discoverability.** PART I first; “authors stop after App Contract + capability matrix”; PART II labeled host law. | **Both pass.** B slightly better document productization; A slightly denser one-page contract. |
| **3. Phase capability honesty (SSE H2)** | **Closed.** Phase-visible honesty: “first marketed H2 **includes** sessions on slots (Phase 3 exit), not a later badge”; Phase 3 exit requires same App Contract CI samples including SSE; WS Phase 4+ explicit. | **Closed.** Capability matrix: SSE TLS H2 ⏳ until Phase 6; M6 = concurrent SSE on H2; Phase 5 forbidden README “supports HTTP/2”; honesty rules 1–4. | **Both pass** with different honesty styles (see Comparative). |
| **4. Dual-API kills** — hangup, pull, stream id, io.Stream, caps, resume | **Held.** B.2 table + NEVER list + anti-patterns. No public pull; no second hangup; no `_sid`; no io.Stream; caps/proto debug-only. | **Held + social ban.** NEVER list + E0.5–E0.7 example bans + Host_Pull “no third public intent rail.” | **Both pass.** B stronger on *social* dual reintroduction. |
| **5. Docs / CI freeze** — Phase 0 hard gate | **Closed.** Phase 0 exit checklist: APP_CONTRACT ≤1 page, MIDDLEWARE_CONTRACT, CI same sample clear/TLS/H2 fails on protocol branches, no `http/debug` in examples, no pull registration samples, host design not required README reading. | **Closed as numbered gates.** E0.1–E0.8 merge blockers including CAPABILITY_MATRIX, CI sample, Host_Pull ban, sid ban, plan tables. | **Both pass.** B’s numbered E0.* is more reviewable; A’s three-listen CI shout is stronger wording. |

### R1 Fatals / Majors (still closed?)

| Item | A | B |
|------|---|---|
| No App Contract | Closed (R2) · sole story (R3) | Closed (R2) · Part I (R3) |
| `_sid` / Stream_Reset / public pull / io.Stream | Never | Never |
| Fat Plan_Context / escape caps | Four fields only | Four fields only |
| Middleware contract | Card + §I | Hard table |
| Hangup / Writable unity | Law | Law |

**No R1 Fatal reopened. No R2 Major reopened.**

---

## Strengths (R3)

### Plan A — public story + first marketed H2 means sessions

1. **App Contract is the freeze product.** Top of document, three-word mental model (Intent / Exchange / Backpressure), hangup law, middleware card, phase-visible honesty, Phase 0 docs-as-API exit. Authors who stop after that section are safe.
2. **Plan_Context diet complete.** Four semantic fields only. Ring free, SQE budget, iovecs, fixed_files are host-private. Progressive disclosure no longer lies about “advanced constraints.”
3. **SSE-on-H2 is product, not a later badge.** Phase 3 exit folds sessions + same App Contract CI on H2. Matches the invariant sentence without training a unary-H2-only ecosystem.
4. **Dual-API reject table remains elite.** B.2 + Never + anti-patterns give reviewers greppable laws (no second hangup, no public pull, no stream id, no io.Stream, no ring meters).
5. **CI story is the real freeze test.** Same handler under clear / TLS H1 / H2; fails on protocol-branching samples. That is user ergonomics as process, not only prose.
6. **Escape hatches stay demoted.** Caps/proto fill Plan_Context privately; debug only; correctness never requires opening advanced surface.
7. **Mental model load controlled.** Apps: Request, Response, Session, Effects. Slot/Pipe stay out of tutorials by law.

### Plan B — author-time honesty as a product feature

1. **PART I / PART II split is the right book for two audiences.** “App authors stop here” is progressive disclosure of the *document*, not only the type system.
2. **Author capability matrix is WOW-grade UX.** Clear H1 / TLS H1 / TLS H2 × oneshot / large body / SSE / WS / concurrent / marketing line — with ⏳/✅ and phase numbers. Turns “correct on H2” from slogan into a calendar authors can trust.
3. **M6 makes long-lived part of H2 product meaning.** Concurrent SSE sessions on one conn + same callbacks + Client_Gone on RST before any author-facing “supports HTTP/2.” Closes R2’s Phase-7 lag without a second session package.
4. **E0.1–E0.8 is a merge-blocker freeze, not culture.** Includes CAPABILITY_MATRIX, same-handler CI, example bans for debug / Host_Pull / sid. Dual-API social ban is explicit.
5. **Phase 5 engineering vs Phase 6 product** is excellent honesty. `curl --http2` green is not “H2 ready.” README rules 1–4 police the last dual that pure types cannot kill: marketing language.
6. **Host_Pull never becomes social dual.** NEVER list + “no third public intent rail” + E0.6. Unary remains cmds only.
7. **Temporary host behavior (assert admission until soft 503)** is named in the App Contract — load-test footgun is not a silent app API change.
8. **Four-field Plan_Context held** while private snap stays rich for implementers.

### Shared (both R3)

- Invariant: correct on clear H1 ⇒ correct on HTTPS / HTTP/2 **for offered capabilities**.  
- Two intent rails only: commands | effects.  
- Hangup = `.Client_Gone` only; backpressure = `.Writable` only.  
- No public resume / poll / SSL\* / body-modes-as-mechanisms / stream ids.  
- Stream_Slot sole exchange; Connection is pipe.  
- Live windows host law; public Plan_Context is not a flow token bucket.  
- WS honestly H1(/TLS) until a named later phase.  
- Multiplex / “H2 perf” gated (A: M1–M5; B: M1–M6 including SSE).  
- Examples must not import `http/debug` or register app pull.

---

## Issues

### Fatal

**None.** Dual-API ship-blockers stay dead. Plan_Context fat is dead. App Contract is sole public story. Phase honesty for SSE-on-H2 is explicit in both.

### Major

**None that block WOW or freeze.** Residual risks are operational (landing docs, policing examples/README), not design shape.

If harsh process bar must name one **Major-class process** item (not design redesign):

1. **Neither plan is the repo artifact yet.**  
   Ergonomics freezes are true when `docs/APP_CONTRACT.md`, middleware contract, capability honesty, and same-handler CI exist. Both plans make that Phase 0 / E0 exit — correctly.  
   **Do not re-score design for this.** Treat as PR0 merge blocker for *implementation*, already specified.

### Minor

1. **A lacks a standalone author capability matrix artifact.**  
   Phase-visible honesty table is good; B’s ✅/⏳ matrix is easier for README and release notes. **Absorb B’s matrix into A’s Phase 0** (or keep A’s table and add CAPABILITY_MATRIX.md). Score impact already reflected: B +0.1 on author UX.

2. **B’s `Host_Pull` still appears in implementer type sketches.**  
   Private and banned from app surface — fine. Residual social risk if a tutorial author copies the struct. E0.6 + NEVER mitigate; keep Host_Pull out of any public godoc path forever.

3. **A’s implementer vocabulary (Slot / Pipe / Exec_Op / Tls_Pipe) still lives in the same long doc.**  
   Contract forbids leaking into tutorials; doc structure is less hard-split than B’s PART I/II. Enforce in doc review. Not a type issue.

4. **Phase numbering mental load (B: 0–8; A: 0–4).**  
   A’s fewer product phases are easier for implementers; B’s matrix compensates for authors. Prefer matrix over renumbering.

5. **Admission assert → soft 503 timing differs** (A Phase 4 polish; B Phase 7). Both now call temporary host behavior out in App Contract. Keep one sentence in shipped APP_CONTRACT forever.

6. **Debug package temptation remains.** Both ban examples importing `http/debug`. CI lint on `examples/` imports is the real close.

7. **Progressive `stream_*` residual.** Both now say: not a second long-lived product; SSE/WS = Effects only. Confirm existing proactr progressive APIs are deprecated or folded in APP_CONTRACT when PR0 lands (wording is present; tree work remains).

8. **B `Cipher_State` sketch still shows `ssl: rawptr`.** Module-private only — OK if the public package tree never re-exports. Same class as R1 SSL\* leak if packaging is sloppy.

---

## Dual-API audit (explicit)

| Temptation | A R3 | B R3 | Pass? |
|------------|------|------|-------|
| Second hangup event | `.Client_Gone` only | `.Client_Gone` only | **Both** |
| Stream id on Response/Session | Never; gen only | Never; gen only | **Both** |
| Public caps / Message_Proto / Conn_Proto | Host-private / debug | NEVER + E0.5 | **Both** |
| `body_set_pull` / app Host_Pull | Host windowing; NEVER pull from app | NEVER + E0.6 + no third rail | **Both (B social ban sharper)** |
| `io.Stream` long-lived | Refuse in freeze | Refuse in freeze | **Both** |
| Public resume / poll | Never | Never | **Both** |
| Body modes = writev/sendfile/SSL_write | Never | Never | **Both** |
| Fat Plan_Context (ring/SQE/iovecs) | **Four fields only** | **Four fields only** | **Both** |
| Silent H2 serial as “H2” | M1–M5 before perf/language | Phase 5 eng only; M1–M6 before README | **Both (B marketing rules sharper)** |
| SSE-on-H2 as later dual product | Phase 3 product exit includes sessions | M6 + matrix ⏳ until Phase 6 | **Both (honest; different schedule)** |
| Progressive `stream_*` second long-lived path | Not third product; Effects for long-lived | Explicit in App Contract | **Both** |
| Docs teaching Exec_Op/Tls_Pipe as handler API | Forbidden | PART I stop line | **Both** |

**Hangup unity:** closed.  
**Pull/stream duals:** closed public + sample ban.  
**Escape hatches:** closed app-facing.  
**Plan_Context dual class:** closed.  
**Marketing dual (“supports H2” without multiplex/SSE):** policed by both; B’s matrix + Phase 5 forbid is the sharper author tool.

---

## Comparative note (ergonomics)

| Dimension | Plan A R3 | Plan B R3 | Winner |
|-----------|-----------|-----------|--------|
| App Contract as sole story | Opens plan; dense one-pager | PART I; authors stop after matrix | **Tie (A denser page · B better book)** |
| Plan_Context progressive disclosure | Four fields (R3 diet complete) | Four fields (held) | **Tie** |
| Dual-API kill completeness | Excellent tables | Excellent + E0 social bans | **B slight** |
| Hangup / Writable unity | Law | Law | **Tie** |
| Pull / stream duals | Host-only; NEVER | Host-only; NEVER + E0.6 | **B slight** |
| Escape hatches | B.2 + Never | NEVER + example CI bans | **Tie** |
| SSE-on-H2 phase honesty | First marketed H2 includes sessions (Phase 3) | Matrix ⏳ → Phase 6 + M6 | **A earlier parity · B clearer calendar** |
| Multiplex marketing honesty | M1–M5 + no H2 perf early | Phase 5 forbid + M1–M6 + README rules | **B slight** |
| Docs/CI freeze gates | Phase 0 checklist + three-listen CI | E0.1–E0.8 numbered merge blockers | **B slight (reviewability) · A slight (three-listen shout)** |
| Author discoverability | Contract first; long implementer body after | Hard PART I stop | **B** |
| Mental model load (apps) | Lowest if docs stay at contract | Lowest if they stop at Part I | **Tie** |
| Capability matrix | Phase honesty table (good) | Full ⏳/✅ matrix (excellent) | **B** |
| Implementer physics proximity | Strong ontology in same doc | Strong; after author stop line | **A for one-file density · B for audience split** |

**Verdict:**  
Both R3 plans **WOW**. **B edges overall author ergonomics** (matrix + PART I + E0 social freeze + marketing rules). **A remains the densest single App Contract page** and ships session parity on the first marketed H2 sooner (Phase 3 vs B Phase 6). That is a product schedule preference, not a dual-API failure — both are honest.

**Synthesis still best freeze package:**

| Ship public | Ship private (unchanged agreement) |
|-------------|-------------------------------------|
| A’s contract density (hangup, middleware card, three words) + B’s capability matrix + E0-style example bans | Shared: four-field Plan_Context, Stream_Slot, seal SM, mem-BIO, live windows, M-gates |
| A’s “first marketed H2 includes SSE on slots” *or* B’s matrix ⏳ until M6 — pick one schedule and put it in APP_CONTRACT | |

**Do not reopen:** `_sid`, `Stream_Reset`, public pull, `io.Stream`, public caps/proto, ring/SQE on Plan_Context, dual Loop/H2 worlds.

---

## What WOW already is (no further design work)

R2’s residual list is **done**:

1. ✅ Public Plan_Context = four fields (both).  
2. ✅ App Contract sole public story (both; B PART I / A top contract).  
3. ✅ SSE-on-H2 honesty (A Phase 3 product exit · B M6 + matrix).  
4. ✅ Dual-API kills held + sample bans.  
5. ✅ Phase 0 / E0 docs+CI freeze as hard gate.

### Remaining for *shipping* WOW (implementation PR0 — not R4 redesign)

- [ ] Land `docs/APP_CONTRACT.md` ≤1 page (no Exec_Op, no seal SM, no Provider).  
- [ ] Land `docs/MIDDLEWARE_CONTRACT.md`.  
- [ ] Land capability honesty (A table and/or B matrix).  
- [ ] CI: same handler sample; fail on protocol `#if` / stream-id samples.  
- [ ] Lint: `examples/` no `http/debug`, no Host_Pull registration, no sid.  
- [ ] README: TLS/H2 are listen options; no “supports HTTP/2” before multiplex (+ SSE per chosen schedule).

---

## Ruthless one-liners

- **A:** You finally stopped selling ring free as a “constraint.” The App Contract is the product. Ship it.  
- **B:** You put authors first and put SSE-on-H2 on a calendar they can read. The matrix is the WOW.  
- **Both:** Dual APIs are dead on paper *and* on the social attack surface (examples). WOW is granted; lose it only by lying in README or teaching pull from app code.  
- **Score truth:** R1 demanded surgery; R2 delivered dual-API kills; R3 delivered diet + honesty + freeze gates. **Stop redesigning. Start Phase 0.**

---

## Close-out vs prior rounds

| Plan | R1 Fatals open | R2 Majors open | R3 Majors open | Score | WOWED |
|------|----------------|----------------|----------------|------:|:-----:|
| **A** | 0 | Plan_Context residual fat | **0** | **9.2** | **Yes** |
| **B** | 0 | SSE-on-H2 lag; narrative load; soft Phase 0 | **0** | **9.3** | **Yes** |
| **Synthesis** | — | — | **0** | **9.5** | **Yes** |

**Ship-as-freeze for user ergonomics?** **Yes — either plan; prefer synthesis for docs packaging.**  
**Primary freeze scores:** **A 9.2 · B 9.3 · synthesis 9.5.**  
**Further ergonomics critic rounds:** not justified unless PR0 artifacts violate the freeze (example duals, fat Plan_Context regression, README H2 lies).

---

*Critic: user ergonomics R3 final · dual-tls-h2 · bar WOW ≥9 · **WOWED yes both** · Plan_Context diet closed · App Contract sole story · SSE H2 honest · duals dead · docs/CI freeze hard · stop redesigning*
