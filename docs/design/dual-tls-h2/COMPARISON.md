# Dual design comparison — Plan A vs Plan B (TLS + HTTP/2 high-level API)

**Run ID:** `4e65dac9`  
**Status:** Both plans WOW’d at R3; **Plan A R4** grafts all B residual wins and re-scored higher.  
**Bar:** code quality · user ergonomics · performance · semantic compression · handmade craft (WOW ≥ 9).

---

## Process

| Round | Plan A | Plan B | Critics |
|-------|--------|--------|---------|
| Write | Conversation thesis (G1–G5, Plan_Context, effect sessions) | Vapor deep-dive then proactr adaptation | — |
| R1 | Strong ontology, weak pipe | Strong pipe, dual H1/H2 worlds | **Neither WOW** |
| R2 | Grafted Tls_Pipe / windows / duplex | Single Stream_Slot; killed duals | Most axes WOW; ergo lag |
| R3 | 4-field context; Conn_Pt_Ring; Seal_Unit; hard CI | Capability matrix; M6 SSE-on-H2; PART I/II | **All axes WOW** |
| **R4** | **Graft all B residuals into A; re-critic A only** | (frozen as evidence / field manual) | **A hybrid at ~9.46 mean** |

---

## Plan A R4 scoreboard (post-graft)

| Axis | A R3 | **A R4** | Δ | WOWED |
|------|-----:|---------:|--:|:-----:|
| Code quality | 9.35 | **9.5** | +0.15 | Yes |
| User ergonomics | 9.2 | **9.45** | +0.25 | Yes |
| Performance | 9.25 | **9.50** | +0.25 | Yes |
| Semantic compression | 9.3 | **9.38** | +0.08 | Yes |
| Handmade craft | 9.35 | **9.45** | +0.10 | Yes |
| **Mean** | **~9.29** | **~9.46** | **+0.17** | **Yes all** |

Graft absorbed: PART I/II, capability matrix, E0.1–E0.8, README honesty, M6 + eng≠product H2, close free-order SM, L5 POD footnote, steal-vs-own, private `framer.kind` apply, expanded NEVER/anti-patterns.  
Spine retained: Stream_Slot, must-alias Conn_Pt_Ring, 4× firehose CI, Seal_Unit, four-field Plan_Context, allocator table, W1/W2/D1.

Critics: theoretical hybrid was **9.5–9.6**; R4 sits at the **floor of that band**. Remaining gap is polish (Exec_Op narrative, synonym rows), not redesign.

---

## Final scoreboard (R3 — pre-graft)

| Axis | Plan A | Plan B | Edge |
|------|-------:|-------:|------|
| Code quality | 9.35 | 9.15 | **A** (allocator table, greener dual-write exit) |
| User ergonomics | 9.2 | 9.3 | **B** (matrix, PART I stop, E0 social bans) |
| Performance | 9.25 | 9.35 | **B** (product bar M1–M6); A firehose CI hardness |
| Semantic compression | 9.3 | 9.15 | **A** (W1 live-window purity) |
| Handmade craft | 9.35 | 9.2 | **A** |
| **Mean** | **~9.29** | **~9.23** | **A ≈ B** (within noise) |

Both are implementable freeze candidates. Difference is **which residual you prefer to polish in PR0**, not which ontology wins.

---

## What both plans now agree on (converged core)

After critics forced the merge bar into each lineage:

1. **App Contract only public story** — `body_*` / `respond` / `sse_start` + Effects; hangup = `.Client_Gone`; no public stream ids, SSL, resume, io.Stream SSE dual, or app pull rail.
2. **Four-field `Plan_Context`** — `sendfile_ok`, `zero_copy_send`, `preferred_copy_budget`, `max_write_unit`.
3. **`Stream_Slot` sole ownership** — H1 = N=1; H2 = N; Connection is pipe (cipher + framer + outbound).
4. **Tls_Pipe + mem-BIO + Seal_SM** — arm-from-CQE; CT[2] seal∥send; dual high-water; no demux product mode; no fuse optionality.
5. **Live flow windows on slot/conn** — planner does not freeze a token bucket as truth.
6. **H2 duplex law** — never starve recv while DATA/flow or CT inflight.
7. **Evidence before “H2 perf”** — concurrent deferred + multiplex gates (M1–M5/M6).
8. **Phase structure before toys** — slot façade before TLS before multiplex product claim.

R1 line “A skeleton + B blood” is now **both documents**. Lineage still differs in *origin story and residual emphasis*.

---

## Where they still differ

| Dimension | Plan A (conversation) | Plan B (vapor-informed) |
|-----------|----------------------|-------------------------|
| **Origin authority** | proactr G1–G5 / planner purity | vapor measured scars (HOST, VAPOR_PROGRAM, nbio_tls) |
| **Doc structure** | Single narrative laws W1/W2/D1/PT1 | PART I authors / PART II implementers + vapor lessons §0 |
| **SSE-on-H2 product gate** | First marketed H2 (Phase 3) includes sessions | Explicit ⏳ until Phase 6 + **M6** |
| **Fairness typing** | First-class `Seal_Unit` + `seal_q` + gen | Present; slightly softer seal-q story |
| **PT ownership** | **Must** alias conn ring (anti dual-PT) | “May alias” residual |
| **Firehose CI** | Hard Phase 2 fail if peak ≳ 4× HW | Strong windows; less absolute CI wording |
| **Vapor package strategy** | No import; invent under proactr | Cherry-pick sans-I/O engine / facts; refuse forever fork |
| **Allocator table** | Explicit multi-lifetime table | Weaker residual vs A |
| **Tone** | “Laws” language | “Lessons + product bar” language |

---

## Which is better?

### Verdict: **Plan A is the better freeze spine; Plan B is the better operational field manual.**

**Ship Plan A as the architectural north star** for proactr-odin, with a short **mandatory graft** of Plan B’s non-negotiable residuals:

| Graft from B into A (PR0) | Why |
|---------------------------|-----|
| Author **capability matrix** + README honesty rules | Ergonomics WOW edge; prevents paper-H2 social cliff |
| **M6** concurrent SSE-on-H2 in product bar | Same API earlier is not enough; product readiness is honesty |
| Free-order close SM §L wording if tighter than A | Close path quality |
| L5-style constant table citation (peer-measured footnotes) | Performance culture without importing vapor packages |
| E0-style example bans (Host_Pull / debug / sid) | Social dual-API prevention |

**Do not ship pure Plan B as spine** if the house rule is handmade compression: B still carries more lesson mass and slightly softer PT alias / allocator documentation, even after structural duals were killed.

**Do not ship pure Plan A without the graft** if the house rule is product honesty under multiplex: B’s matrix and M6 are what stopped the “invariant true everywhere” ergonomics failure mode.

### Why A edges overall

1. **Lineage fidelity** — The conversation thesis (command planner, semantics≠transport, effect sessions, proactor identity) is *proactr’s* differentiator versus vapor. A never abandoned that center; B arrived there under critic fire.
2. **Craft scores** — Handmade + semantic + code quality still prefer A’s law density and greener Phase 1 dual-write exit.
3. **Pipe admission** — Conn_Pt_Ring must-alias + 4× HW CI is the stricter bulk admission story.

### Why B is not “worse”

1. **Performance product bar** slightly higher (M1–M6, social phase 5 engineering-only).
2. **Ergonomics packaging** slightly higher (PART I/II, matrix, E0).
3. **Vapor evidence** is how the shared pipe physics were *discovered*; A now contains those physics but B remains the audit trail for *why* numbers exist.

If forced to pick **one document to implement from without merge**, pick **A after a half-day graft of B’s matrix/M6/E0**. If forced to pick **one document to hand a TLS implementer on day one**, give **B’s PART II + A’s App Contract**.

### Hybrid ceiling → **delivered as Plan A R4**

Critics’ theoretical merge was **~9.5–9.6**. **Plan A R4 is that hybrid** (mean **~9.46**, all axes WOW).

> **Freeze `docs/design/dual-tls-h2/plan-a.md` (R4) as the architectural north star.**  
> Keep `plan-b.md` as vapor evidence / audit trail only — not a second freeze.  
> **Never open demux or dual Loop/H1 worlds.**

---

## Recommendation for next work

1. **PR0 (docs only):** land `APP_CONTRACT.md` + capability matrix + MIDDLEWARE + E0 CI from Plan A R4 PART I.
2. **PR1:** Stream_Slot N=1 façade (Response binds slot; dual-write grep-clean).
3. **PR2:** Tls_Pipe mem-BIO + Conn_Pt_Ring + Seal_SM + firehose CI.
4. **PR3+:** H2 engine sans-I/O → eng unary (no README H2) → **M1–M6 product** before any perf marketing.

Do **not** start with H2 framing or vapor `server/` import.

---

## Artifact paths

| Artifact | Path |
|----------|------|
| Plan A | `docs/design/dual-tls-h2/plan-a.md` |
| Plan B | `docs/design/dual-tls-h2/plan-b.md` |
| Summaries | `plan-a-summary.md`, `plan-b-summary.md` |
| R3 critiques | `critic-ergonomics-r3.md`, `critic-performance-r3.md`, `critic-spotcheck-r3.md` |
| R2 trail | `critic-*-r2.md` |
