# Code Quality Critic — Round 4 (Plan A graft only)

**Bar:** WOW ≥ 9 only.  
**Subject:** Plan A R4 graft (`plan-a.md`) — B residual wins absorbed; spine remains A.  
**Scope:** Code quality only. **Not Plan B.** Judge whether the graft improved **ownership** and **close SM** without regressing R2/R3 CQ wins.  
**Baselines:** CQ A R2 **9.2** · R3 spot-check **9.35**. Prior residual (R3 CQ): stream free-order prose-scattered (minor); Exec_Op private zoo (minor). Wire-unit/gen Major was already closed at R3.

---

## Score: 9.5/10
## WOWED: yes

| Round | CQ score | WOWED | Δ |
|-------|---------:|:-----:|---|
| R2 | 9.2 | yes | — |
| R3 | 9.35 | yes | +0.15 (Seal_Unit+gen, four-field PC, Conn_Pt_Ring, firehose CI) |
| **R4** | **9.5** | **yes** | **+0.15** (normative dual-path close SM + product/social quality machine-guns; spine held) |

**Verdict one-liner:** Graft closed the last ownership/UAF residual that still separated A from B’s free-order rigor, without diluting A’s greener Phase-1 exit, must-alias PT, allocator table, or typed seal queue. This is freeze-grade host law, not documentation cosplay.

---

## What improved vs R3 A

### 1. Close SM is now first-class free-order law (ownership of death)

**R3 residual (minor):** stream free-order lived split across W2 + D2 + a thinner E.4; B’s §L was denser.

**R4 §E.4** is normative, implementer-not-invent, dual-path:

| Path | Quality force |
|------|----------------|
| **Stream RST / stream GOAWAY** | gen mark → abort plan cursor (W2) → Client_Gone once → **remove Seal_Units for `slot.gen`** → wait CQE if mid-socket-send → **return Conn_Pt_Ring slabs (`pt_hold`)** → free slot / gen++ |
| **Conn-level death** | Tls_Pipe Closing → for-each stream path → fail recv + wait sock send → engine shutdown → free CT[2]/rx_hold/all PT → clear tls → close fd |
| **Invariants** | never free CT/PT under outstanding send CQE; never resume Waiting_Flow into freed plan (gen); never free Session_State under pending timer CQEs |

That is the classic UAF class closed as **ordered free**, not as scattered laws. Stream death is no longer “prose adjacent to conn Closing.” `pt_hold` return and seal_q gen-remove are ownership operations implementers can review line-by-line.

### 2. Ownership graph remains complete end-to-end (no dilution)

R4 graft log explicitly **kept** A spine:

| Spine item | Still law? | Locus |
|------------|:----------:|-------|
| Stream_Slot sole exchange; Connection = pipe | **Yes** | §D.1–D.2; Phase 1 grep-clean |
| Conn_Pt_Ring **must** alias seal input (Law PT1) | **Yes** | §F.2; D23; anti dual-PT |
| Firehose CI fail if peak ≳ 4× HW | **Yes** | Phase 2 exit; D22 |
| Typed `Seal_Unit` + `seal_q` + `rr_cursor` + gen | **Yes** | §D.4; Law D4/F.7 |
| Allocator lifetime table | **Yes** | §D.3 (A’s R2 edge over B — retained) |
| W1 live windows / W2 plan abort / D1 duplex | **Yes** | §C.3–C.4; §J |
| Four-field public Plan_Context | **Yes** | §C.2; no ring/SQE leak |
| Exclusive framer `#raw_union` | **Yes** | §G |

**No regression** of R2 Fatals/Majors or R3 wire-unit closure. Graft added B packaging/physics density **beside** ownership law, not instead of it.

### 3. Social dual-API quality (review-forceable)

Not pure type law, but code quality in a multi-protocol freeze includes “what will rot in examples”:

- **E0.1–E0.8** hard Phase 0 merge blockers (docs-as-API, same-handler CI, Host_Pull / debug / sid bans).
- **NEVER** expanded: app Host_Pull, progressive `stream_*` second product, third intent rail.
- **M1–M6** product bar (M6 concurrent SSE) + Phase 4 eng ≠ Phase 5 product — prevents paper multiplex from becoming the de-facto architecture.
- **Steal vs own** (§A.4 / §G): cherry-pick facts; refuse forever vapor `server/` fork — dual-maint substrate is a quality death sentence; R4 freezes the refuse.
- **Session apply** private `framer.kind` switch (§H.4) — no product `Session_Wire` vtable dual.

These close culture-shaped duals that reintroduce dual write paths under deadline. Quality of *shipped* code, not just sketch elegance.

### 4. Pipe POD + close path completeness

Named constants table (§F.1) with peer-measured footnote (not package import) + close SM free-order gives implementers one place for *numbers* and one place for *death order*. R3 had numbers and Seal_Unit; R4 pairs them with B-grade free-order without adopting B’s softer “may alias” PT sin.

---

## Residual issues (R4)

### Fatal

**None.** Ownership dual-write, dual PT, dual Loop, public resume/stream-id, bare sock bool under TLS bulk, frozen plan windows as flow truth — all closed and not reopened by graft.

### Major

**None.** R2 CQ Major (wire unit identity under RST) stayed closed from R3. R3 CQ free-order scatter is closed by §E.4 density. No new Major introduced by PART I/II / matrix / M6 mass.

### Minor

1. **Private `Exec_Op_Kind` zoo still listed** (`Write_Slice` … `Commit_Unit`) despite fusion rule (**§F.5**). Correct teaching surface remains windows/inflight/`Commit_Unit`; list length still invites review theater of micro-ops. Prefer Produce / Seal / Submit role table in host docs; keep ops as internal enum, not narrative API. **Cosmetic / teaching — not a dual world.**

2. **`Host_Pull` still appears on private `Slot_Deferred`** (§F.4). App Contract NEVER + E0.6 are loud. Residual hazard is re-entry/blocking if a future PR “helps middleware” register pull. Review reject only — not a public rail. Keep as checklist line in PR0–PR4.

3. **Type sketch incompleteness** (`file_send_*: ...` ellipsis in Wire_Slot_State; Conn_Pt_Ring free-list as comment). Freeze law is clear; Phase 1 implementers must not invent a second ownership home in the ellipsis. Prefer one concrete cursor field set in PR2 sketch polish.

4. **Doc mass / dual reference surfaces.** W2 and D2 still correctly name abort rules; normative ordered list is §E.4. Acceptable redundancy for laws. Slight density cost vs a pure §L-only home — not ownership ambiguity. Do not rewrite ontology to “fix” length.

5. **Fairness weights open (documented).** Equal RR v1 + documented SSE-vs-bulk starvation until polish. Correct honesty; not a UAF. Phase 6 only.

6. **`Message_Proto` × `Multiplex` dual-label** (host-private). Not public dual; mild synonym pressure for implementers. Prefer framer.kind drives Multiplex fill (already said in C.1) — keep one derivation path in code review.

---

## Comparative note vs theoretical hybrid 9.5–9.6

Critics’ hybrid ceiling (COMPARISON / R2 CQ merge ask):

> **A spine** (Stream_Slot sole ownership, allocator §D.3, grep-clean Phase 1, must-alias PT, four-field PC, W1 purity, exclusive framer)  
> **+ B free-order close SM density**  
> **+ B matrix / M6 / E0 social machine-guns**  
> **+ no dual Loop / no paper-H2**

**Plan A R4 is that hybrid on A’s spine.** CQ score **9.5** lands at the **floor of the theoretical 9.5–9.6 band**.

| Hybrid ingredient | R4 status |
|-------------------|-----------|
| A ownership + allocator table | **Held** |
| A must-alias PT + 4× firehose CI | **Held** (stricter than B residual) |
| A Seal_Unit + gen + seal_q (R3) | **Held** |
| B §L free-order density | **Absorbed → §E.4** |
| B matrix / M6 / E0 / PART split | **Absorbed** |
| Zero private teaching residue (Exec_Op zoo, Host_Pull ghost) | **Not zero** — residual Minors |
| Zero doc-mass friction | **Not zero** — graft length |

**Why not 9.6?** The extra tenth is pure residual elimination (Exec_Op teaching surface compression + drop ellipsis in type sketch + optional Host_Pull rename to non-`pull` host-only fill). Not a redesign, not a Plan B respine. **9.6 would be polish PRs, not R5 ontology.**

**Why not below 9.5?** Free-order + gen-checked seal_q + pt_hold return + must-alias + allocator table + Phase 1 grep-clean is the full UAF-prevention stack elite multi-protocol hosts actually need. Graft improved the weak joint (stream death order) without trading away A’s stronger joints (PT ownership, dual-write exit, allocator discipline).

**Regression check vs R3 A:** **None** on Fatals/Majors/spine. Score Δ is pure residual close + social dual defense, not score inflation.

---

## Scorecard (code quality dimensions)

| Dimension | R3 A | R4 A | Note |
|-----------|-----:|-----:|------|
| Layer ownership L5→L1 | 9.4 | **9.5** | Held; close free-order completes death ownership |
| Dual-write / migration gate | 9.5 | **9.5** | Grep-clean Phase 1 held |
| Wire unit / gen / RST | 9.4 | **9.55** | §E.4 gen-remove + mid-send wait now normative |
| Allocator / lifetime | 9.5 | **9.5** | §D.3 held (B still lacked this as table) |
| Tls_Pipe / Seal_SM / PT1 | 9.5 | **9.5** | Must-alias + Seal_SM + dual HW held |
| Live windows / duplex | 9.5 | **9.5** | W1/W2/D1 held |
| Public surface purity | 9.4 | **9.5** | Four-field + E0/NEVER louder |
| Multiplex product honesty | 9.3 | **9.5** | M1–M6 + eng≠product phases |
| Private op teaching surface | 9.1 | **9.1** | Exec_Op zoo residual unchanged |
| **Overall CQ** | **9.35** | **9.5** | **WOWED** |

---

## Freeze recommendation (CQ only)

- **Ship Plan A R4 as the code-quality freeze spine.** Do not reopen ontology for residual Minors.
- **PR0–PR2 checklist (quality, not redesign):** E0.* · Response→slot only · grep-clean dual-write · §D.3 allocator discipline · §E.4 free-order unit tests (stream RST mid-seal_q + mid-socket-send).
- **Do not absorb B’s softer PT “may alias” or Response._conn sugar** — R4 correctly refused those.
- Optional polish toward 9.55–9.6: compress Exec_Op narrative; flesh Wire_Slot_State fields; keep Host_Pull host-private forever.

---

## Verdict summary

| | Plan A R4 |
|--|-----------|
| R2 Fatals/Majors still closed | **Yes** |
| R3 wire-unit Major still closed | **Yes** |
| R3 free-order scatter residual | **Closed** (§E.4 dual-path SM) |
| Spine diluted by graft? | **No** |
| New Fatals/Majors from graft? | **None** |
| Residual Major | **0** |
| Residual Minor | **~5** (Exec_Op zoo, Host_Pull ghost, sketch ellipsis, doc mass, fairness weights, proto/Multiplex label) |
| **Score** | **9.5/10** |
| **WOWED** | **yes** |
| vs theoretical hybrid 9.5–9.6 | **At floor of band**; 9.6 = polish only |

> **R4 graft improved ownership and close SM without regression.** Plan A is no longer “strong ownership with thinner stream death order” — it is **strong ownership with B-grade free-order**, plus A-strict PT admission and allocator table. **Stop redesigning. Implement Phase 0–1.**

*Critic: code quality R4 · Plan A graft only · bar WOW ≥9 · **WOWED yes · 9.5/10** · free-order closed · spine held · hybrid floor reached*
