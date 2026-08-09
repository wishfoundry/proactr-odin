# Critic — SEMANTIC COMPRESSION (r2)

**Lens:** maximum power per concept · orthogonal vocabulary · no synonym types · no parallel worlds for H1 vs H2 · few true primitives that compose · App Contract thin  
**Bar:** WOW ≥ 9  
**Artifacts:** Plan A r2 (`plan-a.md`), Plan B r2 (`plan-b.md`)  
**Baseline:** `critic-semantic-r1.md` (A 8.4 / B 6.8; neither WOWED)

---

## Verdict (one line)

**Both plans closed the r1 disqualifiers.** Dual H1/H2 worlds are gone from B; A’s caps/context/Exec_Op inflation is largely cut; App Contracts are freeze-thin.  
**A ≈ 9.15 WOWED · B ≈ 9.05 WOWED.** Prefer **A’s ownership laws + Law W1 purity** with **B’s thinner public Plan_Context + Produce/Seal/Submit mechanism table** (not an Exec_Op museum). Neither is the pure 9.5 merge yet — residuals are *minors*, not ontology forks.

---

## 0. What changed since r1 (compression-relevant)

| r1 charge | Plan A r2 | Plan B r2 |
|-----------|-----------|-----------|
| Dual Loop vs H2_Stream_Slot | Already clean; hardened Phase 1 grep-clean dual-write | **Fixed:** single `Stream_Slot`; H1 = N=1 |
| Conn_Proto product worlds | N/A (never had) | **Killed** as architecture |
| Intent tri-rail / Body_Source | Already cmds\|effects; deferred host-only | **Fixed:** no public Body_Source; `Slot_Deferred` private |
| Response._sid / stream-id API | Already refused | **Fixed:** frame_id private; Session = gen |
| Plan_Context junk drawer | **Diet:** no tls/caps/flow/proto public | **Thinner still:** 4 public fields |
| Conn_Cap synonym cluster | **Ciphered · Multiplex · Sendfile · ZC** only | Same orthogonal four |
| Exec_Op zoo | **Fused `Commit_Unit`**; public = windows/inflight | **Better:** Produce/Seal/Submit table, not op enum |
| Flush multi-meaning | **§F.5 one flush-unit** | One flush-unit definition |
| Escape hatches (caps/proto app) | **Stripped** from freeze; debug only | **Never** in App Contract |
| App Contract page | **Frozen ≤1 page + CI same sample** | **Frozen ≤1 page** (arguably leaner) |
| Window physics / CT pipeline | **Absorbed** §F numbers; Phase 2 not deferred | Always had; now under single slot |
| Live vs frozen flow | **Law W1/W2** — no plan token bucket | **Law O4** — advisory snap, live re-read |
| Session_Wire product | Never productized | **Private switch**; no vtable product |
| Stream_Reset dual hangup | `.Client_Gone` only | `.Client_Gone` only |

**r1’s cardinal failure (B dual worlds) is closed. r1’s main A guilt (denorm caps/context) is closed.** This is a different review than r1.

---

## 1. Target primitive budget (unchanged bar)

| Role | Job | Public? |
|------|-----|---------|
| **Intent** | cmds \| effects — exactly two rails | Yes |
| **Constraints** | thin `Plan_Context` (stable meaning) | Yes, optional |
| **Policy** | pure `plan_body` | Host |
| **Mechanism** | produce → seal/frame → one submit | Private |
| **Slot** | sole exchange ownership | Host name; apps say “exchange” |
| **Pipe** | socket + cipher? + framer + one send schedule | Host |
| **Event** | unified `Session_Event` only | Yes |

**Test:** Does TLS or H2 invent a *peer* role, a *synonym type*, or a *second home* for slot/intent? If yes → fail. If only fills caps / private physics → pass.

---

## 2. Plan A r2 — concept inventory

| Name | Role | Necessary? | r2 note |
|------|------|------------|---------|
| `Response_Cmd` / body_* / respond | Intent (oneshot) | **Yes** | Sole unary rail |
| `Effects` / `Session_Event` | Intent + events | **Yes** | Hangup = Client_Gone only |
| `Plan_Context` (public) | Constraints | **Yes** | **Diet done** — no caps/flow/tls/proto |
| `Plan_Host` | Private planner input | **Yes** | Clean split from public |
| `Conn_Caps` (4 bits) | Orthogonal axes | **Yes private** | Synonym cluster **gone** |
| `Message_Proto` {H1,H2} | Slot framing label | **Borderline private** | Still dual-label with Multiplex (see m1) |
| `Stream_Slot` | Ownership unit | **Yes — core** | Sole storage; H1 N=1 |
| `Connection` | Pipe | **Yes** | No session/plan storage |
| `Session` (gen, `_slot`) | Public long-lived handle | **Yes** | ABA-correct |
| `Response` / `Request` | Exchange surfaces | **Yes** | Bind slot |
| `Body_Middleware` | Intent rewrite | **Yes** | Cmd-only card in App Contract |
| `Tls_Pipe` / `Conn_Cipher_Engine` | L2 cipher SM | **Yes private** | Normative SM; mem-BIO default |
| `Connection_Framer` exclusive union | L3 demux | **Yes private** | Not Frame_State god-object |
| `Wire_Conn_State` / `Wire_Slot_State` | Wire progress split | **Yes** | Conn vs slot real |
| `Slot_Flow` | Live H2 windows | **Yes when H2** | Authoritative; not in Plan_Context |
| `Exec_Op_Kind` | Private mechanism | **Role yes; set still fat** | Commit_Unit helps; clear laundry remains (m2) |
| Pipe POD constants | Bulk physics | **Yes private** | Absorbed from B lineage |
| App Contract / Middleware card | Freeze surface | **Yes** | **Thin enough for freeze** |
| L1–L5 layers | Pedagogy | Doc only | Fine |
| Six meta concepts (A.3) | Thesis | **Yes** | Product of the plan |

**Load-bearing public concepts:** Intent · Exchange · Backpressure · (optional thin Plan_Context).  
**Load-bearing implementer concepts:** Slot · Pipe · Framer · Cipher · Wire_Conn · live flow.  
**Named types in freeze talk:** ~16; **~9–10 load-bearing** — down from r1’s ~22 with synonym bloat.

### Plan A r2 — scorecard

| Axis | r1 | r2 | Note |
|------|----|----|------|
| Primitive budget | 9 | **9.3** | App Contract locks two rails |
| Orthogonal vocabulary | 7 | **9.0** | Four caps; Plan_Context diet |
| No parallel H1/H2 worlds | 9.5 | **9.7** | Phase 1 dual-write exit hard |
| No synonym types | 6.5 | **8.7** | Residual Message_Proto / Multiplex (m1) |
| Mechanism privacy | 9 | **9.2** | Fused Commit_Unit; SSL\* sealed |
| Composability TLS×H2 | 9 | **9.4** | Same sample CI gate |
| App Contract thin | — | **9.1** | ≤1 page; phase honesty table |
| Phase honesty | 9 | **9.3** | Physics in Phase 2; multiplex bar Phase 3 |
| **Overall compression** | **8.4** | **9.15** | **WOWED** |

**WOWED?** **Yes (≥9).** Thesis was already ≥9; type sketch no longer drags below the bar.

### Plan A r2 — what still WOW’s (and what newly does)

1. **Stream_Slot sole ownership; Connection = pipe; H1 = degenerate N=1** — still the compression cut.  
2. **App Contract as docs-as-API** with CI: same handler clear / TLS H1 / H2 — makes the invariant *testable*, not sermon.  
3. **Law W1** — live windows never frozen as plan token bucket. Stronger semantic hygiene than “advisory snap fields that look live.”  
4. **Two intent rails only**; hangup one event; Writable unifies buffer + flow.  
5. **Orthogonal Conn_Caps** (r1 fix landed).  
6. **Exclusive framer raw union** — one personality, not kitchen-sink Frame_State.  
7. **Write physics absorbed without public knobs** — windows stay pipe POD.  
8. **Round-1 response matrix** maps every Fatal/Major to a section — compression of *process* (no silent reopen).

### Plan A r2 — residual issues (harsh minors)

#### m1. `Message_Proto` + `Multiplex` still dual-label framing (private)

Slot needs a framing kind. Conn has `Multiplex ∈ caps`. Having both is honest engineering (caps = capability; proto = which exclusive framer bag). Compression nit: document **one primary** — e.g. framer.kind is truth; Multiplex is derived bit for planner tables; Message_Proto is alias of framer.kind, not a third authority. Not a freeze blocker.

#### m2. Exec_Op still a clear-path laundry list

```
Write_Slice, Writev, Sendfile, Copy_Into, Patch_CL,
Flush, Wait_Flow, Produce_Window, Commit_Unit
```

Fusion rule for Commit_Unit is correct. Residual: public *teaching* still risks “learn the op zoo.” Prefer B-shaped **role table** (Produce / Seal / Submit / Wait_Flow / Flush unit) with clear H1 ops as *instances of Produce/Submit under !Ciphered*, not peer conceptual families. **Minor** — private only.

#### m3. Public Plan_Context still 8 fields — “thin” but not skeletal

```
sendfile_ok, zero_copy_send, fixed_files, preferred_copy_budget,
max_iovecs, max_write_unit, output_ring_free, sqe_budget
```

Semantic keepers: `sendfile_ok`, `max_write_unit`, budgets.  
Staging-ish: `output_ring_free`, `sqe_budget`, `max_iovecs` — useful for advanced middleware sizing, not required for the App invariant. Compression culture: **correctness-optional staging hints belong in `http/debug` or a second advanced struct**, not peer to `sendfile_ok` in the freeze surface. B’s 4-field public is tighter. **Minor.**

#### m4. Pedagogic triple statement

App Contract three words · A.3 six concepts · §R reminder — same thesis thrice. Fine for a freeze doc; not type inflation. Ignore for score; note for doc edit.

#### m5. Naming micro-synonyms

`H2_Framer` vs `H2_Engine` (A.2 vs G); `Conn_Cipher_Engine` vs engine inside `Tls_Pipe`. Pick one private name per bag. Nit.

**No Fatals. No Majors.** r1 I1–I7 closed.

---

## 3. Plan B r2 — concept inventory

| Name | Role | Necessary? | r2 note |
|------|------|------------|---------|
| `Response_Cmd` / body_* | Intent (unary) | **Yes** | Sole unary |
| `Effects` / sse_start | Intent (long-lived) | **Yes** | Effects only; io.Stream refused |
| `Plan_Context` (4 fields) | Constraints public | **Yes** | **Thinnest public surface of either plan** |
| `Host_Plan_Snap` | Private constraints+windows | **Yes** | Residual advisory windows (mB1) |
| `Conn_Caps` (4 bits) | Orthogonal axes | **Yes private** | Same good cut as A |
| `Stream_Slot` | Ownership unit | **Yes — core** | **Dual world closed** |
| `Connection` | Pipe | **Yes** | slots + framer + cipher + wire + pt ring |
| `Session` (gen) | Public handle | **Yes** | No sid |
| `Slot_Deferred` | Host deferred produce | **Yes private** | Host_Pull risk (mB2) |
| `Framer_State` exclusive | L3 | **Yes private** | Sans-I/O; good |
| `Cipher_State` | L2 mem-BIO SM | **Yes private** | Seal SM real; ssl rawptr (mB3) |
| `Wire_Conn_State` / Seal_Unit | Outbound schedule | **Yes** | Fairness explicit |
| `Pt_Window_Ring` | Pipe PT staging | **Yes private** | Conn-owned; differs from A’s slot views |
| Produce / Seal / Submit / Wait / Flush | Mechanism roles | **Yes — best compression** | Better than Exec_Op enum |
| Seal_SM | CT pipeline states | **Yes private** | Compresses inflight truth |
| App Contract / Middleware | Freeze surface | **Yes** | ≤1 page; hard may/must-not |
| Vapor L1–L15 | Evidence catalog | **Doc only** | Still large mass (mB4) |
| M1–M5 multiplex gates | Product meaning of H2 | **Yes as phase law** | Compression of “what H2 means” |
| Close free-order SM | Teardown law | **Yes** | Prevents dual free paths |

**Load-bearing public:** same four as A, with *smaller* Plan_Context.  
**Named design objects:** ~18; parallel homes **removed**. r1’s ~25+ with dual Loop is gone.

### Plan B r2 — scorecard

| Axis | r1 | r2 | Note |
|------|----|----|------|
| Primitive budget | 5.5 | **9.2** | Slot+Pipe+two rails locked |
| Orthogonal vocabulary | 5 | **9.0** | Caps not Conn_Proto worlds |
| No parallel H1/H2 worlds | 3.5 | **9.5** | **Cardinal r1 fail closed** |
| No synonym types | 6 | **8.6** | Host_Plan_Snap windows dual-ish (mB1) |
| Mechanism privacy | 8 | **9.3** | Produce/Seal/Submit; no Session_Wire product |
| Composability TLS×H2 | 6 | **9.2** | Constraint+slot, not forked bags |
| App Contract thin | — | **9.4** | Four-field Plan_Context; hard NEVER list |
| Phase honesty | 8 | **9.1** | M1–M5 before perf claims |
| Evidence discipline | 9.5 | **9.0** | Lessons kept; types lead freeze |
| **Overall compression** | **6.8** | **9.05** | **WOWED** |

**WOWED?** **Yes (≥9).** r1 said “not a compressed ontology.” r2 is one.

### Plan B r2 — what WOW’s (r2)

1. **Single Stream_Slot for all protocols** — the r1 disqualifier inverted.  
2. **App Contract is the thinnest freeze page** of the pair; Plan_Context four fields only.  
3. **Mechanism as five roles, not nine enum kinds** — maximum power per name.  
4. **Law O1–O5** — one outbound path, no fuse optionality, PT high-water, live windows, seal-while-send.  
5. **M1–M5** — multiplex is *product meaning*, not framing badge.  
6. **Private Slot_Deferred** keeps completion bulk without a public third rail.  
7. **Cherry-pick facts / one owned engine** — process compression (no dual-maint vapor package).  
8. **Close free-order SM** — one teardown ontology.

### Plan B r2 — residual issues (harsh minors)

#### mB1. `Host_Plan_Snap` still *names* stream/conn windows

Law O4 says advisory + live re-read. Correct. Compression nit: putting `stream_window` / `conn_window` on the snap type invites “plan owns windows” habits in code review. A’s Law W1 is cleaner: **live only on slot/conn; plan never carries window fields as authority.** Prefer Host_Plan_Snap without window fields (or name them `window_hint_at_plan` and never read after first unit). **Minor.**

#### mB2. `Slot_Deferred.Host_Pull` is a latent third rail

Private, host-registered only — good. Risk: demos and “advanced middleware” start exposing pull. Freeze language should say **Host_Pull is internal to Static/File/host helpers only; never Response API**. One sentence already mostly there; keep it reject-checklist loud. **Minor.**

#### mB3. Cipher sketch exposes `ssl` / `provider` rawptrs

A uses opaque `Conn_Cipher_Engine`. B’s freeze sketch shows SSL* shapes. Module-private is fine; freeze type sketch should prefer **opaque engine** so PR review never normalizes SSL* upstairs. Opacity score: A slightly better. **Minor.**

#### mB4. Document mass: L1–L15 still a vapor museum *section*

Marked as evidence; types lead. Compression of *reader attention*: long L* lists re-expand vapor nouns before Slot/Pipe stick. r2 improved (“types lead the freeze”); still the heaviest section. Prefer one-page “evidence appendix” pointer, not spine. **Doc issue, not ontology.**

#### mB5. PT ownership model differs from A (not a dual *world*, a dual *sketch*)

B: `Connection.pt` ring as sole framed PT staging.  
A: slot-local views + PT high-water across slots.  
Both can implement Law O1/S1. Freezing both sketches invites two PT homes in PRs. Pick one for implementers. **Coordination minor**, not synonym failure.

#### mB6. `want_recv` / `want_send` inside Cipher_State

OpenSSL WANT_* mapping is real. Naming echoes readiness product. Prefer phase + inflight counts only in public-to-implementers sketches (B’s Seal_SM already does the important work). Nit.

**No Fatals. No Majors.** r1 J1–J9 closed.

---

## 4. Dual worlds? Synonyms? App Contract thin?

### Dual worlds (H1 vs H2)

| Check | A r2 | B r2 |
|-------|------|------|
| One slot type | **Yes** | **Yes** |
| H1 = N=1 same types | **Yes** | **Yes** |
| No Loop-vs-H2_Stream_Slot | **Yes** | **Yes** (fixed) |
| No Conn_Proto product enum | **Yes** | **Yes** (fixed) |
| Effects API protocol-blind | **Yes** | **Yes** |
| Framer exclusive one bag | **Yes** | **Yes** |

**Both pass.** r1’s disqualifier is dead.

### Synonym / denorm scan

| Cluster | A r2 | B r2 |
|---------|------|------|
| Cap synonym (Alpn/Flow/Record) | **Gone** | **Gone** |
| Plan_Context bool aliases (tls/h2/…) | **Gone** | **Gone** |
| Caps × Message_Proto dual label | **Mild residual (m1)** | Caps only; framer.kind |
| Live window × plan window | **Clean (W1)** | **Mild residual (mB1)** |
| Body rails (cmds/pull/live) | **Two rails** | **Two rails** (+ private Host_Pull) |
| Hangup dual events | **One** | **One** |
| Session_Wire product + switch | N/A | **Private switch only** |
| Exec_Op zoo vs role table | **Still list-ish (m2)** | **Role table wins** |

### App Contract thin?

| Criterion | A | B |
|-----------|---|-----|
| ≤1 page freeze surface | **Yes** | **Yes** |
| Two intent rails only | **Yes** | **Yes** |
| Plan_Context optional for correctness | **Yes** | **Yes** |
| NEVER list (SSL, sid, resume, …) | **Yes** | **Yes** |
| Public Plan_Context field count | **8** | **4** (tighter) |
| Middleware hard may/must-not | **Yes** | **Yes** |
| Phase honesty (WS, admission, HOL) | **Stronger table** | Present (WS, soft 503) |
| CI same sample three listens | **Explicit gate** | Implied by invariant |

**Both thin enough to freeze.** B wins field-count; A wins phase-honesty CI specificity.

---

## 5. Comparative (r2)

| Dimension | Plan A r2 | Plan B r2 | Winner (compression) |
|-----------|-----------|-----------|----------------------|
| Core ontology | Slot+Pipe+Intent+Constraints | Same | **Tie** |
| Parallel H1/H2 worlds | Refused | Refused (fixed) | **Tie** |
| Public Plan_Context diet | Thin (8) | **Thinnest (4)** | **B** |
| Live window authority | **Law W1 purest** | O4 good; snap fields mild | **A** |
| Mechanism vocabulary | Commit_Unit + clear laundry | **Produce/Seal/Submit** | **B** |
| Caps algebra | Orthogonal 4 | Orthogonal 4 | **Tie** |
| Cipher opacity in sketch | Opaque engine | ssl rawptr visible | **A** |
| App Contract freeze page | Excellent + CI | Excellent + thinner PC | **Tie → slight B PC / A CI** |
| Bulk physics | Absorbed normative | Native normative | **Tie** |
| Multiplex product bar | D3 N≥2 | M1–M5 explicit | **Tie → B slightly louder** |
| Evidence vs ontology | Ontology-first | Evidence appendix heavy | **A** |
| Dual-write / Phase 1 | Grep-clean hard exit | Same intent | **Tie** |
| Residual third-rail risk | Low | Host_Pull latent | **A** |
| Close free-order | Free-order list | Full SM §L | **B** (law completeness) |

### Head-to-head on the bar

| | A r2 | B r2 |
|--|------|------|
| **Compression score** | **9.15** | **9.05** |
| **WOWED (≥9)?** | **Yes** | **Yes** |
| **r1 → r2 delta** | +0.75 | **+2.25** (largest climb) |
| **After residual minis only** | ~9.35 | ~9.25 |
| **If frozen as written** | **Ship** | **Ship** (either; align PT home + thin PC) |

---

## 6. What would still hit 9.5 (merge of residuals — not a third plan)

Both already clear 9. Remaining to 9.5 is **one page of alignment**, not redesign:

1. **Public Plan_Context = B’s four fields** (`sendfile_ok`, `preferred_copy_budget`, `max_write_unit`, `zero_copy_send`). Staging ring/sqe → host/debug only (A m3).  
2. **Live windows = A’s Law W1** — no window fields on plan snap (B mB1).  
3. **Mechanism teaching = B’s Produce/Seal/Submit/Wait/Flush-unit** — keep clear Writev/Sendfile as Produce/Submit instances under !Ciphered (A m2).  
4. **Cipher opacity = A’s opaque engine** in freeze sketches (B mB3).  
5. **One PT home** — pick conn `pt` ring *or* slot views + conn high-water; document once (mB5).  
6. **Host_Pull** — reject checklist: never Response API (B mB2).  
7. **Message_Proto** — alias of framer.kind; Multiplex derived (A m1).

**That merge is ~9.45–9.5.** Either plan can absorb the other plan’s residual in PR0–PR1 without ontology change.

---

## 7. Scores summary

| Plan | r1 | r2 | WOWED | One-line judgment |
|------|----|----|-------|-------------------|
| **A** | 8.4 | **9.15** | **Yes** | Thesis always right; denorm/caps/escape hatches closed; residual Exec_Op list + slightly fat public PC |
| **B** | 6.8 | **9.05** | **Yes** | Dual-world cardinal fail inverted; thinnest App PC + best mechanism roles; residual Host_Plan_Snap windows + Host_Pull + doc mass |
| **A∩B residual merge** | 9.2–9.5 | **~9.45** | **Yes** | A laws + B thin PC + B role table + A W1 purity |

---

## 8. Freeze recommendation (compression-only, r2)

1. **Freeze either plan’s App Contract** — both meet thin + two rails + NEVER list. Prefer **B’s Plan_Context field set** + **A’s CI same-sample + phase honesty table**.  
2. **Freeze ownership laws:** Stream_Slot sole exchange; Connection pipe-only; H1 = N=1; no dual-write after Phase 1. **Both already say this.**  
3. **Freeze Law W1/O4 as A’s stronger form:** live windows only on slot/conn; plan never freezes flow tokens.  
4. **Freeze mechanism as roles** (Produce / Seal / Submit / Wait_Flow / one flush unit), not as a public or semi-public Exec_Op zoo.  
5. **Do not freeze:** Host_Pull as any app surface; Message_Proto as app API; staging fields as required Plan_Context peers; ssl* in non-module docs.  
6. **Pick one PT staging ownership** before Phase 2 bulk PRs.  
7. **r1 freeze “do not freeze B dual Loop” is obsolete** — B r2 is single-slot. Treat B as a first-class freeze candidate, not a physics donor only.

---

## 9. Final cut

> **Count concepts.** Both r2 plans count **six implementer primitives** and **three app words** (Intent · Exchange · Backpressure).  
> **Orthogonal?** Caps are four real axes. Public Plan_Context is diet (B thinner).  
> **Synonyms?** r1 clusters dead; residuals are private dual-labels and advisory window fields.  
> **Parallel H1/H2 worlds?** **Neither designs them.**  
> **App Contract thin?** **Both.** B wins field count; A wins CI gate specificity.  
> **WOW bar ≥9:** **Both clear.** A edges overall (**9.15 vs 9.05**) on W1 purity and opaque cipher sketch; B wins the climb and the mechanism role table.

**Harsh ranking for this critic (r2):** **A ≳ B** on pure compression hygiene; **B ≳ A** on public surface minimalism and mechanism vocabulary. **Both shippable.** **Ship A∩B residual merge in PR0 if you want 9.5 without a third thesis.**

**r1 line is retired:** “A skeleton + B blood” → **r2 line:** “Either skeleton is one world; steal the other’s residual minis.”
