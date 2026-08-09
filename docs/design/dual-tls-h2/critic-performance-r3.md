# Critic R3 — PERFORMANCE architecture (final harsh re-review)

**Bar:** WOW ≥ 9 vs elite peers (H2O pull/record discipline, ntex framing economy, vapor measured membio: window + cursor + CT double-buffer + duplex H2 recv).  
**Scope:** write pipelines, zero-copy honesty, TLS record batching, H2 flow / multiplex fairness, proactor CQE path, allocation/peak mem, HOL, sendfile/TLS truth.  
**Method:** R2 “push to WOW” grafts and residual Majors must be **verified closed in plan text**, not only in critic-response tables. Soft language does not close.  
**Inputs:** `plan-a.md` (R3 / design freeze candidate), `plan-b.md` (r3), `critic-performance-r2.md`.

---

## Score

| Plan | R1 | R2 | R3 | Δ R2→R3 | Verdict |
|------|---:|---:|---:|--------:|---------|
| **A** | 6.4 | 8.8 | **9.25** | **+0.45** | **WOWED.** R2 residuals closed in law + types + hard CI. Data plane is freeze-grade. |
| **B** | 8.2 | 9.2 | **9.35** | **+0.15** | **WOWED (higher).** Physics retained; M6 + capability-matrix product bar hardens paper-H2 social cliff. Dual-PT residual remains the only physics nit. |

**Both clear WOW.** Prefer freeze merge: **A’s Conn_Pt_Ring + Seal_Unit + 4× firehose CI + Commit_Unit** ∪ **B’s M1–M6 + capability-matrix honesty + vapor L5 anchors**. Either alone is implementable elite pipe law.

---

## WOWED

### Plan A — **WOWED (9.25)**

R2 left A at 8.8 for four concrete gaps. R3 text closes them as **normative types and phase exits**, not vibes:

1. **First-class `Conn_Pt_Ring` (Law PT1)**  
   Connection owns fixed PT admission; produce stops at `PT_HIGH_WATER`; slots hold `pt_hold` counts, not growable multi‑MiB PT. Cipher encrypt input **aliases** ring views (D23) — dual full PT window is an anti-pattern. **R2 M1 closed.**

2. **Dual high-water (PT + CT = 128 KiB each)**  
   `PT_HIGH_WATER` stops produce; `CT_HIGH_WATER` + `ct_bytes_held` stop seal. Peak claimed as `O(PT_HW + CT_HW + slabs)`, not `O(body×N)`. HW numbers aligned with vapor/B (was 256/absent). **R2 M1 + align-HW closed.**

3. **`Seal_SM` is a state machine, not a caption**  
   `Idle | Sealing | Send_Armed | Send_And_Sealed` + `seal_n∈{0,1,2}` + T3 encrypt∥send while sock busy. Bare `sock_send_inflight: bool` alone under TLS bulk is **forbidden** (anti-pattern + D21). **R2 Seal_SM softness closed.**

4. **Fairness as type (`Seal_Unit` + `seal_q` + `rr_cursor`)**  
   Gen-checked dequeue; RR/deficit over slots; `SEAL_Q_CAP=32` admission backpressure. Law D4 / F.7 implementable — not “Phase 4 polish comment.” **R2 M3 closed.**

5. **Hard evidence exits (E1 / D22 — not optional culture)**  
   Phase 2: multi‑MiB HTTPS peak ≤ HW (+ε); **CI fails if peak ≳ 4× high-water** (firehose detector). Phase 3: M1–M5 green + recorded baseline + README forbid “H2 perf” until then. **R2 near-fatal evidence optional closed — A now leads on bulk-cliff CI hardness.**

Plus retained R2 wins: Law W1 live windows, D1 duplex + T5 burst, concurrent deferred before perf claims, mem-BIO-only, sendfile honesty, fused `Commit_Unit`, four-field public `Plan_Context`.

### Plan B — **WOWED (9.35)**

R2 already cleared WOW at 9.2. R3 does not reopen pipe physics (Seal_SM, O1–O5, dual HW, fixed pt ring, mem-BIO, duplex). It **raises the multiplex product bar** and **social defense**:

1. **M1–M6 before author “supports HTTP/2”**  
   M6 adds concurrent SSE/Effects on H2 slots to the product bar. Long-lived multiplex under PT/CT HW is part of “H2 ready,” not a later badge. Performance-relevant: prevents shipping unary-only framing as product while demos claim full H2.

2. **Capability matrix + Phase 5 forbidden product language**  
   Engineering `curl --http2` is explicitly **not** author-facing H2. CI/README honesty rules are machine-gun culture against R1 Fatal #1 regressing in practice. **R2 near-fatal social attack surface reduced.**

3. **E0.* ergonomics freeze** (examples/Host_Pull bans)  
   Not bulk AEAD law — but kills second intent rails and debug meters leaking into samples that would re-paper the data plane.

Retained elite core: L5 constants, Seal_SM + seal_n, O1–O4, fixed pt + dual HW pause pumps, duplex/rBIO, one outbound path, free-order close.

---

## Verification matrix — R2 “A must close for WOW”

| R2 demand for A ≥9 | Plan A R3 locus | Closed? |
|--------------------|-----------------|--------|
| Conn-level PT ring first-class | §D.1 graph `pt: Conn_Pt_Ring`; §F.2; Law PT1; type sketch | **Yes** |
| CT_HIGH_WATER named + dual HW | §F.1 PT/CT 128 KiB; T3 stop if CT_HW; `ct_bytes_held` | **Yes** |
| Seal_SM + seal∥send hard | §E.2–E.3; D21; anti-pattern bare sock bool | **Yes** |
| Seal_Unit + fairness cursor in types | §D.4 `Seal_Unit`, `seal_q_*`, `rr_cursor`; §F.7 Law D4 | **Yes** |
| Phase 2/3 bulk exits **required** | §K hard evidence; 4× firehose CI fail; M1–M5; E1; D22 | **Yes** |
| HW align or justify | 128/128 (was 256 PT; no CT_HW) | **Yes** |
| Single PT owner / no dual window | D23 alias; anti-pattern dual PT; Tls_Pipe encrypt aliases ring | **Yes (stronger than B)** |

| R2 residual for B | Plan B R3 status | Closed? |
|-------------------|------------------|--------|
| Dual PT: `Cipher_State.pt_win` + `Connection.pt` | Still declares `pt_win: [PULL_WINDOW]u8` with “may alias” | **Partial** — wording soft; not single-owner law |
| Peer ratio floor vs recorded | Still “ratios recorded” Phase 6 | **Open** (same class as A recorded baseline) |
| Phase 5 social cliff | Capability matrix + forbidden README language + M1–M6 | **Mostly closed** |
| Equal RR SSE vs bulk | Open Q; equal RR v1 | **Documented accept** (same as A Phase 4 weights) |
| proactr Exec_Op mapping | Still Produce/Seal/Submit table; less Commit_Unit-native | **Open minor** |

---

## Score reconciliation (R2 → R3)

### Plan A

| R2 deduction | R2 pts | R3 status | R3 pts |
|--------------|-------:|-----------|-------:|
| No first-class PT ring / no CT_HW | −0.25 | Conn_Pt_Ring + dual 128 KiB + PT1 + alias | **0** |
| Fairness law thinner than type | −0.15 | Seal_Unit + seal_q + rr_cursor + gen + SEAL_Q_CAP | **0** |
| Evidence optional / bastion soft | −0.40 | 4× firehose CI fail; M1–M5; recorded baseline; E1 | **0** |
| SSE vs bulk weights | −0.15 | Equal v1 documented; Phase 4 polish | **−0.10** |
| Exec_Op residual / dual-cursor | −0.05 | Commit_Unit fusion retained; clear legacy ops remain | **−0.05** |
| *New R3 residual:* peer ratio not numeric floor; M5 peak formula still needs multi-stream soak proof | — | Architecture closed; floor culture optional | **−0.10** |
| **Base** | 10 | | 10 |
| **Result** | **8.8** | | **9.25** |

### Plan B

| R2 deduction | R2 pts | R3 status | R3 pts |
|--------------|-------:|-----------|-------:|
| Multiplex / concurrent deferred residual | −0.10 | M1–M6 + matrix; Phase 5 no product claim hardened | **0** |
| Evidence recorded not floor | −0.25 | Unchanged “recorded”; no 4× CI fail number | **−0.20** |
| proactr wire / dual progress | −0.20 | Unchanged; O1–O2 still one path | **−0.15** |
| Dual PT views + equal RR | −0.15 | Dual PT **still soft**; RR open Q | **−0.15** |
| *R3 gain:* M6 long-lived multiplex in product bar; social Phase 5 machine-guns | — | Real product-bar completeness | **+0.05 net vs pure residual math** |
| **Base** | 10 | | 10 |
| **Result** | **9.2** | | **9.35** |

*(Net: B’s social/product hardening outweighs unchanged dual-PT nit enough to clear 9.3+; A’s physics graft is the larger absolute jump.)*

---

## Fatal flaws (R3)

### Plan A

**None.** R1 fatals (live windows, CT seal∥send, duplex) stayed closed. R2 near-fatal (optional evidence) is closed by hard CI + M1–M5 gates.

### Plan B

**None.** R1 fatals stayed closed. R2 near-fatal (Phase 5 social) is mitigated by capability matrix + forbidden README language + M6 product inclusion — residual is cultural, not a physics hole, and no longer elevates to near-fatal.

---

## Major issues remaining (neither blocks WOW)

### Plan A

| # | Issue | Severity | Why it still matters |
|---|--------|----------|----------------------|
| M1 | **SSE vs bulk equal weight v1** | Low-Major | Documented starvation risk under SSE+large GET. Correct honesty; still a real h2load cliff until Phase 4 weights. |
| M2 | **H2 baseline is “recorded,” not a peer floor** | Low-Major | Firehose **peak** detector is elite; RPS/ratio regression floor is still culture. Architecture WOW does not require Actix-m4 number; long-term CI hygiene does. |
| M3 | **Private Exec_Op still lists clear laundry + fused ops** | Minor→Major edge | Fusion rule is right. Risk only if interpreter re-splits Commit_Unit into Write_Plain+Cipher_Seal+Frame on the hot path. Review reject, not redesign. |

### Plan B

| # | Issue | Severity | Why it still matters |
|---|--------|----------|----------------------|
| M1 | **`Cipher_State.pt_win` + `Connection.pt` dual surface** | **Major residual** | “May alias” is implementer hope. If both allocate full windows under multiplex, peak mem and copy count regress vs membio ideal. **A’s D23 is stricter.** One-line freeze fix: encrypt input **must** alias `Connection.pt` views; drop silent second slab. |
| M2 | **No hard firehose CI fail threshold** | Low-Major | O(window) phase exits yes; A’s **fail if ≳4× HW** is sharper regression armor. |
| M3 | **Exec_Op / existing wire migration less spelled** | Low-Major | O1–O2 are correct. A’s Commit_Unit + plan_body tables reduce dual-progress anxiety during clear→cipher transition. |
| M4 | **Equal RR SSE vs bulk** | Low-Major | Same as A; open Q honesty. |

---

## Minor issues

### Plan A
- `SEAL_Q_CAP=32` is fine; document backpressure → slot park (not silent drop) under sustained multi-stream produce.
- Seal_SM state names differ from B (`Send_Armed` vs `Seal_And_Send`) — equivalent depth; pick one in merge.
- Phase 3 “SSE on slots” product bar is good; B’s M6 concurrent SSE≥2 is slightly sharper product language — A’s M1–M5 imply concurrency but do not name long-lived as M6.

### Plan B
- `sock_send_inflight: bool` remains **correct** for socket {0,1}; seal depth is `seal_n` — do not “fix.”
- `Host_Pull` private + E0.6 ban is the right social fix; keep examples dual-free forever.
- HPACK dyn table / stream caps remain production RAM open questions, not bulk pipe shape.

---

## Comparative (A vs B, performance only, R3)

| Axis | Winner | Note |
|------|--------|------|
| Bulk TLS pipeline realism | **Tie** (A edge on typed Seal_SM+ring in one graph) | Both CT[2]+batch+seal∥send+dual HW |
| PT admission ownership | **A** | Conn_Pt_Ring + PT1 + **must alias**; B “may alias” |
| H2 duplex / rBIO | **Tie** | Both hard law + burst |
| Live flow re-window | **Tie** (A W1 formula edge) | Both re-read every unit |
| Multiplex product bar | **B** | M1–**M6** + capability matrix; Phase 5 forbidden product language |
| Fairness typed schedule | **Tie** (A slight type edge) | Both Seal_Unit + RR; A gen+frame_id+SEAL_Q_CAP more complete |
| Peak mem / anti-firehose | **A** edge | Dual HW + 4× CI fail; B dual-PT residual |
| Evidence exits | **A** edge on peak; **B** edge on product honesty | A firehose detector; B matrix/M6/README ban |
| Zero-copy / sendfile honesty | **Tie** | Both refuse the lie |
| Proactor CQE identity | **Tie** | Arm-from-CQE both |
| Fit with proactr planner / Exec_Op | **A** | Commit_Unit + pure plan_body + Plan_Host split |
| Risk of paper H2 | **B** slightly lower social risk | Matrix + M6; A has M1–M5 + forbid language too |

### Ranking (perf architecture freeze)

1. **Plan B — 9.35 WOWED** — best single *product-bar* document (M1–M6 + matrix); fix dual PT to match A’s alias law for ~9.5.  
2. **Plan A — 9.25 WOWED** — best single *pipe physics + CI hardness* document; add M6-style concurrent SSE gate for parity.  
3. **Ideal merge (~9.5–9.6):**  
   A: `Conn_Pt_Ring`, Law PT1/D23 alias, Seal_Unit+gen, Seal_SM, 4× firehose CI, W1 unit formula, Commit_Unit, four-field Plan_Context  
   ∪ B: L5 vapor anchors, M1–M6, capability matrix, Phase 5 engineering-only language, free-order close §L, O1–O2 one-path sentence  
   ∪ equal-RR v1 documented; peer ratio floor later soak (optional for architecture freeze).

---

## Harsh one-liners

- **Plan A:** R2 said “almost WOW — optional bastion, soft PT ring, fairness vibes.” R3 shipped **Conn_Pt_Ring, dual 128 KiB HW, Seal_SM, typed Seal_Unit RR, and a 4× firehose CI kill switch.** That is not documentation cosplay; that is how elite stacks keep membio from rotting. **9.25 — WOWED.** Guard Commit_Unit fusion and Phase 4 weights; do not re-open public meters.
- **Plan B:** R2 already WOW’d the autopsy. R3 did the right thing: **did not touch** Seal_SM / O-laws / dual HW, and **did** make H2 product mean concurrent slots **and** SSE-on-slots under matrix honesty. Remaining sin: `pt_win` still looks like a second slab. One alias law and you own 9.5. **9.35 — WOWED (higher).**
- **Both:** Socket send ∈ {0,1} was never the win. The win is **seal depth 2 + dual HW admission + fair multi-slot produce + live flow re-read + recv always drainable + peak proven in CI.** Both documents now encode that sentence. Freeze either; implement the merge.

---

## What would push either higher (~9.5+)

### Surgical only (not redesign)

| Plan | One-line graft |
|------|----------------|
| **A** | Name **M6**: concurrent Effects/SSE ≥2 on one H2 conn before “supports HTTP/2”; keep 4× firehose CI. |
| **B** | **Must** alias cipher encrypt input to `Connection.pt` — delete or shrink `pt_win` to a view, not a second full window; optionally adopt A’s 4× peak CI fail. |
| **Both** | Optional soak: peer RPS floor as regression (architecture already WOW without it). Equal-weight starvation documented until interactive weights. |

---

## Close

| Round | A | B | Headline |
|-------|--:|--:|----------|
| R1 | 6.4 | 8.2 | Neither WOW; B data-plane baseline; A control-plane only |
| R2 | 8.8 | **9.2** | Fatals closed both sides; **B WOWED**; A evidence/PT/fairness short |
| **R3** | **9.25** | **9.35** | **Both WOWED.** A closed every R2 graft. B stayed WOW and rose on product-bar honesty. |

**Final performance freeze recommendation:**  
Ship **one pipe law document** built from A’s admission ring + Seal_Unit + hard firehose CI + planner fusion, and B’s M1–M6 + capability matrix + vapor-measured constant table. Do not maintain two parallel physics stories. Apps never see any of it — App Contract four fields and two intent rails only.

**WOWED: Plan A yes · Plan B yes.**
