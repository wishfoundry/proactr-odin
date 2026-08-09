# Critic R2 — PERFORMANCE architecture (harsh re-review)

**Bar:** WOW ≥ 9 vs elite peers (H2O pull/record discipline, ntex framing economy, vapor measured membio: window + cursor + CT double-buffer + duplex H2 recv).  
**Scope:** write pipelines, zero-copy honesty, TLS record batching, H2 flow / multiplex fairness, proactor CQE path, allocation/peak mem, HOL, sendfile/TLS truth.  
**Method:** R1 fatals/majors must be **verified closed in the R2 text**, not claimed in a “critic response” table. Smoke language and optional evidence do not count as closed.  
**Inputs:** `plan-a.md` (R2), `plan-b.md` (r2), `critic-performance-r1.md`.

---

## Score

| Plan | R1 | R2 | Δ | Verdict |
|------|---:|---:|--:|---------|
| **A** | 6.4 | **8.8** | +2.4 | Fatals closed; data plane is now real. Still short of WOW on evidence gates + PT-ring first-class ownership. |
| **B** | 8.2 | **9.2** | +1.0 | **WOWED.** Write contract + Seal_SM + M1–M5 + dual high-water + duplex/live flow are freeze-grade. Residual: peer-ratio hardness, dual PT views, SSE-vs-bulk weights. |

**WOW claimed by B only.** A is an implementable elite control+pipe design if evidence exits harden; freeze-as-is prefers B’s data-plane law text, or a one-page merge of A’s planner fusion + B’s M1–M5/evidence.

---

## WOWED

### Plan B — **WOWED (9.2)**

This is the first document of the pair that a bulk implementer can build without reinventing vapor’s 2026 autopsy:

1. **Normative write pipe (C.1) with measured constants (L5)**  
   `PULL_WINDOW=64KiB`, `TLS_RECORD_BATCH_TARGET≈4 records`, `CT_SLOTS=2`, `PT_HIGH_WATER=128KiB`, `CT_HIGH_WATER=128KiB`, `SEAL_INFLIGHT∈{0,1,2}`, `SOCKET_SEND_INFLIGHT_MAX=1`, fixed `BIO_RX_HOLD_MAX=16KiB`. Not slogans — POD + laws.

2. **Seal-while-send is a state machine, not a diagram caption (O5)**  
   `Seal_SM` + `seal_n∈{0,1,2}` + explicit “encrypt may start on free CT while other CT is in sock send.” Anti-pattern: bare `send_inflight: bool` without CT[2]/SM under TLS bulk. **R1 Fatal #2 closed for real.**

3. **Multiplex is product-gated, not folklore (D.1 M1–M5)**  
   Concurrent unary ≥2, concurrent deferred bodies ≥2, fair seal RR/deficit, duplex+rBIO under multi-stream load, peak PT/CT O(windows×slots_armed). Phase 5 serial is **labeled milestone / no perf claim**; Phase 6 is the only “H2 perf” door. **R1 Fatal #1 closed.**

4. **Live windows (O4) + fixed PT ring with high-water that pauses pumps (O3)**  
   Plan snap advisory; re-read every seal unit; park `Waiting_Flow`; abort cursor on RST. `Connection.pt` fixed slots — not growable framed PT waiting for TLS. **R1 Fatal #3 (`out_pt` soft bound) closed.**

5. **Duplex + rBIO burst as reject criteria (L8, drive loop, anti-pattern 5)**  
   Recv stays armed under send/CT/flow-0; progress → burst `SSL_read` until WANT_* / BURST. Reliability × throughput under h2load-class load.

6. **One outbound path (O1–O2)** — framer never `submit_send`; no fuse optionality between adapter and tests.

### Plan A — strong; not WOW

A absorbed the R1 graft and is no longer “control plane only”:

- **Law W1/W2** live windows on `slot.flow` / conn; unit formula re-reads every produce/seal; plan is not a frozen token bucket. **R1 A-Fatal #1 closed.**
- **Tls_Pipe CT[2] + `ct_sealed∈{0,1,2}` + T3 seal∥send in Phase 2** (not polish). **R1 A-Fatal #2 closed.**
- **Law D1 duplex + T5 burst drain + anti-pattern table.** **R1 A-Fatal #3 closed.**
- **Law D3 / App Contract:** concurrent unary + concurrent deferred N≥2 before any H2 perf claim; HOL only as labeled debug.
- **Numbers:** `PULL_WINDOW 64KiB`, `TLS_RECORD_BATCH ~4`, `CT_SLOTS 2`, `PT_HIGH_WATER 256KiB`, `RX_HOLD_CAP 32KiB`.
- **Fused `Commit_Unit`**, deferred large bodies without public pull rail, mem-BIO-only default, sendfile honesty table.

WOW fails on residual **evidence softness** (bastion “optional”), **PT staging not elevated to a conn-level fixed ring with CT high-water**, and slightly less concrete seal/fairness types than B’s `Seal_SM` / `Wire_Conn` / M1–M5 table. Score 8.8 = elite-adjacent, freeze-ready for API+structure, not the best sole data-plane freeze.

---

## Verification matrix (R1 must-close items)

| Requirement | Plan A R2 | Plan B R2 | Closed? |
|-------------|-----------|-----------|---------|
| **Live windows** — executor re-reads every unit; plan not authority | Law W1/W2; `Slot_Flow`; unit = min(…, live_stream_win, live_conn_win); Wait_Flow re-read | Law O4; Host_Plan_Snap advisory; Waiting_Flow; abort cursor | **Both closed** |
| **CT double-buffer / seal∥send** | `ct[2]`, `ct_sealed` 0..2, T3, F.1, Phase 2 | Seal_SM, `ct[2]`, `seal_n` 0..2, forbid bare bool, Phase 3 | **Both closed** (B more SM-hard) |
| **H2 duplex recv** never unarm for send/CT/flow-0 | Law D1, T5 burst, anti-pattern, H1 ME exception | L8 law, drive burst, AP#5, M4 gate | **Both closed** |
| **Concurrent deferred before H2 perf** | App Contract + Law D3 + Phase 3 exit + PR9 | M1–M5 + Phase 5 no claim + Phase 6 exit + AP#8 | **Both closed** (B clearer product bar) |
| **High-water / O(window) peak** | PT_HIGH_WATER 256KiB; peak O(windows×slots); forbid firehose | PT+CT HW 128KiB; fixed `pt` ring; HW pauses pumps | **Both closed** (B dual HW + ring stronger) |
| Record batch ~4×16KiB | TLS_RECORD_BATCH ~4 | TLS_RECORD_BATCH_TARGET ≈4 records | **Both closed** |
| mem-BIO default / CQE arm-next | E.1 + T1 | F / Cipher drive | **Both closed** |
| sendfile/TLS honesty | C.5 / D8 | B.4 | **Both closed** |
| Fair seal schedule | Law D4; Phase 3 | Wire_Conn RR; M3; Phase 6 | **Both closed** (B more typed) |
| Evidence ≠ curl smoke | Metrics Phase 2; bastion **optional** Phase 4 | m1/m4 O(window) phase exits; Phase 6 ratios **recorded** | **B stronger; A soft** |

---

## Score reconciliation (R1 → R2)

### Plan A

| R1 deduction | R1 pts | R2 status | R2 pts |
|--------------|-------:|-----------|-------:|
| Missing/weak CT encrypt∥send | −1.2 | CT[2] + T3 seal∥send Phase 2 | **0** |
| Firehose / peak-mem risk | −0.8 | Deferred produce + PT_HW 256KiB; PT not conn-ring first-class | **−0.25** |
| H2 recv hold / rBIO | −1.0 | Law D1 + T5 | **0** |
| Live flow re-window | −0.8 | Law W1/W2 normative | **0** |
| Multiplex fairness / concurrent deferred | −0.6 | D3/D4 + Phase 3; fairness more law than type | **−0.15** |
| Record batch discipline | −0.4 | ~4-record batch | **0** |
| Evidence-gated exits | −0.5 | Metrics yes; bastion “optional” | **−0.40** |
| Integration with proactr wire | −0.3 | Strong (Commit_Unit, plan_body, slots) | **−0.05** |
| *New R2 residual:* CT high-water not named; Effects vs bulk weights thin | — | | **−0.15** |
| **Base** | 10 | | 10 |
| **Result** | **6.4** | | **8.8** |

### Plan B

| R1 deduction | R1 pts | R2 status | R2 pts |
|--------------|-------:|-----------|-------:|
| CT encrypt∥send contradiction | −0.4 | Seal_SM + seal_n; bare bool forbidden | **0** |
| Firehose / `out_pt` soft | −0.3 | Fixed pt ring + PT/CT HW pauses pumps | **0** |
| Live flow | −0.4 | Law O4 | **0** |
| Multiplex / concurrent deferred | −0.8 | M1–M5 hard; Phase 5 serial no claim | **−0.10** |
| Evidence-gated exits | −0.4 | Bulk O(window) exits; Phase 6 ratios recorded (not peer floor) | **−0.25** |
| Integration proactr wire / dual progress | −0.4 | One path O1–O2; still less Exec_Op-native than A | **−0.20** |
| *New R2 residual:* Cipher `pt_win` + Connection `pt` dual views; equal RR only for SSE vs bulk | — | | **−0.15** |
| **Base** | 10 | | 10 |
| **Result** | **8.2** | | **9.2** |

---

## Fatal flaws (R2)

### Plan A

**None remaining at Fatal severity** for the R1 set.

**Near-fatal residual (Major elevating risk if implementers are sloppy):**

1. **Evidence is still optional culture, not a gate.**  
   Phase 4: “Bastion ratios vs named peer (**optional** evidence, not API).” R1 WOW item #7 required measurable exits: HTTPS H1 m1/m4 peak O(window); H2 multi-stream large without stall; ratios recorded. Metrics on seal/ct/pt_hw hits help Phase 2, but without a non-optional bulk exit, marketing can still call Phase 3 “H2 ready” on curated h2spec + concurrent tests that never prove O(window) under load. Not a physics hole — a **discipline hole** that re-paperizes perf.

### Plan B

**None remaining at Fatal severity** for the R1 set.

**Near-fatal residual:**

1. **Phase 5 serial milestone remains a social attack surface.**  
   Text is correct (“no H2 perf claim yet”; M1–M5 before badge). Organizations ship “HTTP/2 support” at first curl --http2 green. Mitigated by explicit anti-pattern #8 and Phase 6 language — keep CI badges / README forbidden words until M1–M5 green, or this residual becomes R1 Fatal #1 again in practice.

---

## Major issues (R2 remaining)

### Plan A

| # | Issue | Why it matters |
|---|--------|----------------|
| M1 | **No first-class conn PT ring + no CT_HIGH_WATER constant** | Peak mem is claimed O(window×slots), but PT is “slot-local view or staging slab.” Under N concurrent deferred, without a single admission point (`pt_admitted` helps but is less crisp than B’s ring + dual HW), implementers can reintroduce per-slot growable staging. Fixed CT[2] bounds ciphertext; plaintext admission is the firehose vector. |
| M2 | **Bastion/ratio exits optional** | See near-fatal. Smoke + concurrent unit tests ≠ vapor m4 bar. |
| M3 | **Fairness / Seal_Unit typing thinner than law text** | Law D4 + Wire_Conn comment (“queue… RR/deficit”) is correct intent; B’s `Seal_Unit` + `rr` cursor is more implementable and reviewable. Risk: fairness becomes “best effort later.” |
| M4 | **SSE + large GET starvation under equal schedule not addressed** | Fair RR is necessary; interactive vs bulk weights left open (B open Q same). Not a ship-stopper for v1; still a real h2load+SSE cliff. |
| M5 | **Exec_Op still a small zoo** (`Produce_Window`, `Wait_Flow`, `Commit_Unit`, legacy clear ops) | Fusion rule helps; public contract correctly says windows/inflight. Residual copy-hop / dual-cursor risk if clear H1 path and Ciphered path diverge in the interpreter. Lower severity than R1 M4. |

### Plan B

| # | Issue | Why it matters |
|---|--------|----------------|
| M1 | **Dual PT surfaces: `Connection.pt` ring + `Cipher_State.pt_win`** | Comment says encrypt input “may alias pt ring” — good if true. If both allocate full windows, peak mem and copy count regress vs membio ideal. Freeze should say **alias or single owner**, not two silent buffers. |
| M2 | **Peer ratio is “recorded,” not a floor** | Better than A’s optional bastion; still weaker than vapor’s numeric Actix/m4 culture. Architecture is WOW; **regression bar** is not fully elite until CI fails on bulk cliff. |
| M3 | **proactr Exec_Op / existing wire integration less spelled** | One path O1–O2 is right. Existing clear H1 `Write_Slice`/`Writev`/`Sendfile` remain; Ciphered/Multiplex switch to produce→seal→submit. Migration risk: two mental models during Phase 2–3 if not one executor cursor. A is stronger here. |
| M4 | **Equal RR v1 for SSE vs bulk** (open Q) | Correct default honesty; document that interactive starvation is accepted until weights exist. |
| M5 | **`Host_Pull` private deferred** | Correctly not public API. Needs review reject if it leaks as handler-facing pull — else second intent rail returns through the host door. |

---

## Minor issues

### Plan A
- `PT_HIGH_WATER` 256KiB vs B’s 128KiB — preference, not wrong; document interaction with multi-slot admission.
- `RX_HOLD_CAP` 32KiB vs B 16KiB — both bounded; pick one in merge.
- Server_Opts `h2_serialize_bodies` HOL debug — good; ensure it cannot be default in any “perf” example.
- Phase order structure→TLS→H2 still right; Phase 2 now carries real physics (R1 minor “learn bulk late” largely fixed).

### Plan B
- `Wire_Conn_State.sock_send_inflight: bool` is **correct** for socket {0,1}; do not “fix” it back to a counter without need — seal depth is `seal_n`.
- Effects on H2 only Phase 7 — after multiplex bar — correct sequencing; temporary gap if someone demos SSE-H2 before Phase 6.
- HPACK/ cap open questions are production RAM, not bulk path shape.

---

## Comparative (A vs B, performance only, R2)

| Axis | Winner | Note |
|------|--------|------|
| Bulk TLS pipeline realism | **B** (edge) | Both have CT[2]+batch+seal∥send; B Seal_SM + CT_HW + fixed pt ring |
| H2 duplex / rBIO | **Tie** | Both hard law + burst |
| Live flow re-window | **Tie** (A wording edge) | W1 unit formula is textbook; O4 equivalent |
| Multiplex product bar | **B** | M1–M5 table is the best freeze artifact in either doc |
| Fairness typed schedule | **B** | Seal_Unit + rr vs A comment-law |
| Peak mem / anti-firehose | **B** | Dual HW + pt ring ownership |
| Evidence exits | **B** | Recorded ratios + O(window) phase exits vs optional bastion |
| Zero-copy / sendfile honesty | **Tie** | Both refuse the lie |
| Proactor CQE identity | **Tie** | Both arm-from-CQE; B more vapor-anchored loop text |
| Fit with proactr planner / Exec_Op | **A** | Thin Plan_Context + fused Commit_Unit + pure plan_body tables |
| Slot ownership / H1=N=1 | **Tie** | Both single Stream_Slot world now |
| Risk of paper H2 | **A lower social risk on API; B lower physics risk** | B’s Phase 5 is the remaining social cliff; A’s optional evidence is the remaining physics-proof cliff |

### Ranking (perf architecture freeze)

1. **Plan B** — freeze data-plane laws as written; **WOWED at 9.2**.  
2. **Plan A** — freeze App Contract / slot / planner fusion; graft B’s M1–M5 checklist + dual high-water + mandatory bulk exits to push ≥9.  
3. **Ideal one-pager merge (would clear ~9.4–9.5):**  
   A’s Stream_Slot + Law W1 formula + thin Plan_Context + Commit_Unit  
   ∪ B’s L5 constants (pick one HW set), Seal_SM, Connection.pt ring, M1–M5, O1–O2, Phase bulk exits with recorded peer ratios  
   ∪ CI forbid “H2 perf” until M1–M5 green.

---

## Harsh one-liners

- **Plan A:** You finally built the pipe you sketched in R1. Live windows, CT×2, duplex, concurrent deferred — **real**. Then you whispered “bastion optional” and left PT as “slot-local or staging.” Elite stacks do not optionalize proof or half-specify the admission ring. **8.8 — almost WOW, not WOW.**
- **Plan B:** R1 said you left multiplex exit ramps and `sending:bool` to rot the autopsy. R2 nailed Seal_SM, M1–M5, fixed pt+HW, live O4, duplex. This is vapor physics under proactr ontology without dual H1/H2 worlds. **9.2 — WOWED.** Guard Phase 5 with cultural machine-guns (badges/CI), alias cipher PT to the conn ring, and harden ratio floors when you care about regressions.
- **Both:** Socket `send_inflight∈{0,1}` remains correct. The win is **seal depth 2 + recv always drainable + fair multi-slot produce + O(window) peak proven**. Do not re-confuse those four with “one TCP write at a time.”

---

## What would push A to WOW (≥9)

Non-optional, short graft:

1. **Conn-level `Pt_Window_Ring` (or equivalent) + CT_HIGH_WATER** (even if CT is only 2 fixed slots, name admission: stop seal enqueue when sealed CT backlog / pt admitted hits HW).  
2. **Phase 2/3 exit:** m1/m4 peak PT/CT = O(window) **required**; Phase 3/H2 exit: multi-stream large body without stall **required**; ratios vs named peer **recorded** (not optional).  
3. **Wire_Conn `Seal_Unit` + fairness cursor** in the type sketch (not only Law D4 prose).  
4. Align HW numbers with B/vapor or justify 256KiB PT in one line (multi-slot headroom vs 128).

## What would push B higher (~9.5)

1. Single-owner PT: cipher encrypt view **aliases** `Connection.pt` only — no second silent slab.  
2. CI/README: “H2” badge / perf language blocked until M1–M5.  
3. One sentence mapping produce→seal→submit onto existing clear Exec_Op path (kill dual-progress anxiety).  
4. Optional later: peer ratio floor in soak (vapor-style), SSE-vs-bulk weight note.

---

## Close

R1’s verdict was correct: **neither** was WOW; B was the data-plane baseline; A needed a bulk graft.  

R2: **both** closed the three R1 fatals on each side (live windows, CT seal∥send, duplex, concurrent deferred, high-water numbers are present and phase-gated).  

**Plan B clears the WOW bar (9.2).** Plan A is a serious 8.8 with a cleaner planner/API spine — freeze it for control plane, not as the sole bulk contract. Prefer implementing **B’s pipe laws + A’s slot/planner diet**, or freeze B and import A’s App Contract CI / Commit_Unit fusion without diluting M1–M5.
