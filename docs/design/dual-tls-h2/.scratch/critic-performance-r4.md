# Critic R4 — PERFORMANCE architecture (Plan A only)

**Bar:** WOW ≥ 9 vs elite peers (H2O pull/record discipline, ntex framing economy, vapor measured membio: window + cursor + CT double-buffer + duplex H2 recv).  
**Scope:** write pipelines, zero-copy honesty, TLS record batching, H2 flow / multiplex fairness, proactor CQE path, allocation/peak mem, HOL, sendfile/TLS truth, **product-bar honesty as performance risk** (paper-H2 is a perf-claim failure mode).  
**Method:** R3 residual grafts and “ideal merge” must be **verified closed in plan text**, not only in graft-log claims. Soft language does not close. Spine items that R3 ranked A-leading must **still be present undiluted**.  
**Inputs:** `plan-a.md` (**R4 graft**), `plan-a-summary.md`, `critic-performance-r3.md`, `COMPARISON.md`.  
**Out of scope for score:** Plan B as peer document (R4 is A-only; B residual *wins* are scored only as grafted into A).

---

## Score

| Plan | R1 | R2 | R3 | R4 | Δ R3→R4 | Verdict |
|------|---:|---:|---:|---:|--------:|---------|
| **A** | 6.4 | 8.8 | 9.25 | **9.50** | **+0.25** | **WOWED.** R3 ideal merge landed on A’s spine; product bar + eng/product H2 closed without diluting pipe law. |

**WOWED. Freeze-grade single document.** Performance architecture is no longer waiting on a dual-plan merge for product honesty.

---

## Verification — R3 “must still be present” (spine integrity)

R3 preferred freeze merge: **A’s Conn_Pt_Ring + Seal_Unit + 4× firehose CI + Commit_Unit** ∪ **B’s M1–M6 + capability-matrix honesty**. R4 claims that graft. Hard check:

| Spine / residual | R3 locus / demand | R4 locus | Present undiluted? |
|------------------|-------------------|----------|--------------------|
| **Conn_Pt_Ring must-alias** | Law PT1; D23; F.2 “must not soft” | §F.2: encrypt input **MUST alias**; “May alias” **FORBIDDEN**; diagram `MUST alias`; D23; spine line §0; Phase 2 exit | **Yes — stronger wording retained** |
| **Firehose CI ≳ 4× HW** | Phase 2 hard fail; D22 | Phase 2: “**fail CI if peak ≳ 4× high-water**”; D22; Q behavioral success; PR5; reminder R | **Yes — still hard CI, not culture** |
| **Seal_SM normative** | E.2 enum + T3 seal∥send; D21 | E.2 `Idle\|Sealing\|Send_Armed\|Send_And_Sealed` + `seal_n∈{0,1,2}`; T3; anti bare sock bool; D21 | **Yes — still state machine, not caption** |
| **Seal_Unit + seal_q + rr_cursor + gen** | D.4 types; Law D4 | D.4 full types; F.7; SEAL_Q_CAP=32 | **Yes** |
| **M6** concurrent SSE-on-H2 | R3 A residual; B edge | §J M6 row; product bar = M1–M6; Phase 5; matrix concurrent SSE; H.6 Phase 5 exit (M6); D16 | **Yes — named, gated, matrix-aligned** |
| **Eng vs product H2** | R3 B edge (Phase 5 eng-only vs product) | Phase 4 “engineering milestone only” + Forbidden README/matrix; Phase 5 product M1–M6; D11, D24; PR8 vs PR9; honesty rule 4 | **Yes — machine-gun social defense** |
| Dual HW 128/128 + CT[2] | F.1 | F.1 POD table; peer footnote not package import | **Yes** |
| Law W1 / D1 duplex | C.3, J | Unchanged hard law | **Yes** |
| Commit_Unit fusion | F.5 | F.5 + D19 | **Yes** |
| Allocator lifetime table | D.3 | D.3 retained | **Yes** |

**Spine integrity: PASS.** No dilution of A’s admission/CI/Seal edges. B’s product-bar residual wins are **in-law**, not appendix vibes.

---

## WOWED

### Plan A R4 — **WOWED (9.50)**

R3 left A at 9.25 with elite *pipe physics* and a thinner *product bar* than B (9.35). R4 does not reopen physics. It **completes the performance social contract** so “H2 perf” cannot ship as unary curl:

1. **Product bar = M1–M6 (closed R3 A residual / B edge)**  
   M6 is normative: ≥2 concurrent SSE/Effects sessions on one H2 conn; same `sse_start` callbacks; `.Client_Gone` on RST. Law D3 and D16 bind M6 into multiplex product meaning. Long-lived multiplex under PT/CT HW is part of “H2 ready,” not a later badge. **This is performance architecture:** it forces the fair seal schedule + duplex + peak O(HW) to be proven under concurrent long-lived produce, not only unary GET fan-out.

2. **Eng ≠ product H2 (closed R3 B edge)**  
   Phase 4 = labeled engineering (curl/h2spec; optional serial flag). **Forbidden:** README “supports HTTP/2,” App Contract H2 multiplex/SSE ✅, H2 perf claims. Phase 5 = M1–M6 + recorded baseline + matrix TLS H2 ✅. Capability matrix and PART I honesty rules make the split **author-visible time law**, not implementer folklore. Paper-H2 as a perf marketing path is structurally blocked.

3. **Spine retained at R3 hardness**  
   - **Conn_Pt_Ring must-alias** — single PT owner; dual full PT window is anti-pattern + redesign trigger.  
   - **Firehose CI** — peak ≳ 4× high-water **fails CI** at Phase 2 TLS bulk (and product gates reference hard evidence E1/D22).  
   - **Seal_SM + seal_n + CT[2] seal∥send** — bare `sock_send_inflight` alone under TLS bulk forbidden.  
   - **Typed fairness** — `Seal_Unit` + `seal_q` + `rr_cursor` + gen-checked dequeue.  
   - **Close SM §E.4** — free-order stream vs conn death; seal_q gen remove; never free CT/PT under CQE; never resume Waiting_Flow into freed plan (B operational density grafted without changing peak law).

4. **Operational density without package fork**  
   Named POD table (64 KiB pull, ~4-record batch, 128/128 dual HW, CT×2, 16 KiB rx hold) + peer-measured footnote as *physics*, not vapor `server/` import. Steal facts / own types is maintenance law with performance consequence (one owner of flow math under proactr slots).

Retained R2/R3 elite core: Law W1 live windows, D1 duplex + T5 burst, concurrent deferred before perf claims, mem-BIO-only, sendfile honesty, fused `Commit_Unit`, four-field public `Plan_Context`, Stream_Slot sole ownership, Law S1 single outbound path.

---

## Score reconciliation (R3 → R4)

| R3 residual / gap for A | R3 pts | R4 status | R4 pts |
|-------------------------|-------:|-----------|-------:|
| No named **M6** / thinner product bar vs B | −0.10 (implicit in A vs B gap) | M1–M6 checklist + matrix + Phase 5 + D16 | **0** |
| Eng Phase social cliff (unary marketed as H2) | −0.10 (B edge) | Phase 4 Forbidden + D24 + honesty rules + PR8/PR9 split | **0** |
| SSE vs bulk equal weight v1 | −0.10 | Unchanged; Phase 6 optional weights; documented accept | **−0.10** |
| H2 baseline “recorded,” not peer RPS floor | −0.10 | Phase 5 still **recorded** artifact; peak firehose CI remains hard | **−0.10** |
| Exec_Op laundry + Commit_Unit fusion discipline | −0.05 | Fusion rule retained; clear laundry ops remain for migration | **−0.05** |
| *R3 physics already closed* | 0 | must-alias, 4× CI, Seal_SM, dual HW, Seal_Unit — **verified present** | **0** |
| **Base** | 10 | | 10 |
| **Result** | **9.25** | | **9.50** |

*(Net +0.25: product-bar + eng/product honesty grafts; residual polish unchanged class.)*

---

## Fatal flaws (R4)

**None.**

R1 fatals (live windows, CT seal∥send, duplex) stayed closed.  
R2 near-fatal (optional evidence) stayed closed by hard 4× firehose CI.  
R3 product-bar / paper-H2 social cliff closed by M6 + eng≠product + matrix.  
Spine items R3 ranked A-leading were **not** softened in the graft.

---

## Major issues remaining (do not block WOW)

| # | Issue | Severity | Why it still matters |
|---|--------|----------|----------------------|
| M1 | **SSE vs bulk equal weight v1** | Low-Major | Documented starvation risk under concurrent SSE + large GET. Correct honesty; still a real h2load cliff until Phase 6 weights. Architecture accepts it; do not pretend solved. |
| M2 | **H2 RPS/ratio is “recorded,” not a peer floor** | Low-Major | Firehose **peak** detector is elite. Throughput regression floor remains culture + committed artifact. Architecture WOW does not require Actix-m4 number; long-term CI hygiene does. |
| M3 | **Private Exec_Op still lists clear laundry + fused ops** | Minor→Major edge | Fusion rule is right. Risk only if interpreter re-splits `Commit_Unit` into Write_Plain+Cipher_Seal+Frame on the hot path. Review reject, not redesign. |

---

## Minor issues

- `SEAL_Q_CAP=32` admits backpressure language; keep implementer law: park slot produce under full queue — **not silent drop** of `Seal_Unit`s (state once in executor notes).
- Seal_SM names (`Send_Armed` / `Send_And_Sealed`) differ from B’s `Seal_And_Send` vocabulary — equivalent depth; pick one string in code, not a second SM.
- Phase 5 “recorded baseline” should name the artifact path in the first product PR (not architecture gap).
- HPACK dyn table / stream caps remain production RAM open questions (N open Q), not bulk pipe shape.
- Close SM graft is dense and correct; soak test for gen-stale `Seal_Unit` after RST under CT inflight is the proof, not more prose.

---

## Axis scorecard (performance only, A R4)

| Axis | Grade | Note |
|------|:-----:|------|
| Bulk TLS pipeline realism | **9.6** | CT[2] + batch + seal∥send + dual HW + Seal_SM typed |
| PT admission ownership | **9.7** | Conn_Pt_Ring + PT1 + **must** alias; dual PT = fail |
| H2 duplex / rBIO | **9.5** | D1 + T5 burst hard law |
| Live flow re-window | **9.5** | W1 unit formula every produce/seal |
| Multiplex product bar | **9.5** | **M1–M6** + matrix + eng≠product (parity with former B edge) |
| Fairness typed schedule | **9.4** | Seal_Unit + gen + rr_cursor + SEAL_Q_CAP; equal RR v1 residual |
| Peak mem / anti-firehose | **9.6** | Dual HW + O(HW) claim + **4× CI fail** |
| Evidence exits | **9.4** | Peak hard; RPS recorded not floored |
| Zero-copy / sendfile honesty | **9.5** | Refuse lie under Ciphered/Multiplex |
| Proactor CQE identity | **9.5** | Arm-from-CQE; free-order close SM |
| Planner / Exec_Op fit | **9.3** | Commit_Unit + pure plan_body; laundry residual |
| Risk of paper H2 | **9.5** | Matrix + M6 + Phase 4 Forbidden + anti-patterns |

**Composite: 9.50 — WOWED.**

---

## Harsh one-liner

R3 said A was freeze-grade *pipe* and B was freeze-grade *product bar*. R4 put **M1–M6 + eng≠product H2 + capability matrix** on A **without** softening **must-alias PT, 4× firehose CI, or Seal_SM**. That is the ideal merge as one implementable document. Remaining sins are equal-weight honesty and a recorded (not floored) RPS artifact — polish, not architecture. **9.50 — WOWED. Ship A R4 as the performance law.**

---

## What would push higher (~9.6+)

Surgical only — not redesign:

| # | One-line graft |
|---|----------------|
| 1 | Phase 5: commit named baseline artifact + optional peer RPS floor after first soak (CI hygiene). |
| 2 | Phase 6 weights for interactive vs bulk (or Server_Opts deficit classes) once M6 green proves the cliff. |
| 3 | Executor note: `seal_q` full → park slot produce; never drop units. |
| 4 | Hot-path review rule: `Commit_Unit` must not re-split into three interpreter ops in TLS bulk. |

None of these reopen ontology or pipe POD.

---

## Close

| Round | A | Headline |
|-------|--:|----------|
| R1 | 6.4 | Control-plane thesis; data plane thin |
| R2 | 8.8 | Fatals closing; evidence/PT/fairness short of WOW |
| R3 | 9.25 | **WOWED** pipe + hard CI; product bar thinner than B (9.35) |
| **R4** | **9.50** | **WOWED.** B residual product honesty grafted; A spine undiluted |

**Freeze recommendation (performance):**  
Implement from **Plan A R4 only**. Do not maintain a parallel B physics story for performance law. Apps never see any of it — App Contract four fields, two intent rails, capability matrix ⏳/✅.

**WOWED: Plan A R4 — yes (9.50).**
