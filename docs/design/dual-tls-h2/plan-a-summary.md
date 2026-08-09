# Plan A (R4 graft) Summary — proactr multi-protocol API

**Full design:** `plan-a.md`  
**Status:** R4 graft — B residual wins absorbed; spine remains A  
**Lineage:** G1–G5 · semantics≠transport · effect sessions · proactor identity

---

## Thesis (5)

1. **PART I App Contract + capability matrix is the only public story** — oneshot + Effects; hangup = `.Client_Gone`; E0.1–E0.8 freeze gates; authors stop after Part I; README honesty forbids paper-H2 and early SSE-on-H2.
2. **Four-field Plan_Context only** — `sendfile_ok`, `zero_copy_send`, `preferred_copy_budget`, `max_write_unit`; ring/SQE/iovecs host-private; no third intent rail / no app Host_Pull.
3. **Slot owns exchange; Connection is pipe** — Phase 1 hard exit; first-class **Conn_Pt_Ring must-alias** seal input; typed **Seal_Unit** + `seal_q` + `rr_cursor` + gen; allocator lifetime table.
4. **Tls_Pipe + Seal_SM + close SM** — mem-BIO; arm-from-CQE; CT[2] seal∥send; dual PT+CT high-water 128KiB; stream-vs-conn free-order; firehose CI fails if peak ≳ 4× HW.
5. **Product bar = M1–M6** — eng H2 unary (Phase 4) ≠ author-facing H2; product multiplex + concurrent SSE (M6) only at Phase 5; steal facts / own types; private framer.kind switch (no Session_Wire product).

---

## R4 deltas (from R3)

### Ergonomics packaging (from B)

| Change | Detail |
|--------|--------|
| PART I / PART II | Authors stop after contract + matrix; implementer physics after |
| Capability matrix | Clear / TLS H1 / TLS H2 × oneshot / large / SSE / WS / concurrent — ⏳/✅ as product readiness |
| E0.1–E0.8 | Hard Phase 0 merge blockers (docs + same-handler CI + example bans) |
| README honesty | No “supports HTTP/2” without concurrent streams; no early SSE-on-H2; listen options; curl≠product |
| NEVER expanded | Host_Pull from app; progressive stream_* second product; third intent rail |
| Soft 503 note | Temporary host admission assert until polish — not app API |

### Product honesty (from B)

| Change | Detail |
|--------|--------|
| **M6** | ≥2 concurrent SSE sessions on one H2 conn; same callbacks; Client_Gone on RST |
| Product bar | **M1–M6** (was M1–M5) |
| Eng vs product H2 | Phase 4 unary eng (README H2 **forbidden**); Phase 5 product multiplex+SSE |

### Operational density (from B)

| Change | Detail |
|--------|--------|
| Close SM §E.4 | Stream RST path vs conn death; seal_q gen remove; never free CT/PT on inflight CQE; never resume Waiting_Flow into freed plan |
| Pipe POD footnote | Named constants + optional peer-measured note (not package import) |
| Steal vs own | Cherry-pick frame/HPACK facts; refuse forever vapor server fork |
| Session apply | Private switch on `framer.kind` — not Session_Wire vtable product |

### Kept A spine (not diluted)

Conn_Pt_Ring **must** alias · firehose CI ≳4× HW · Seal_Unit+seal_q+rr_cursor+gen · allocator table · W1/W2/D1/PT1 · G1–G5 voice · four-field Plan_Context · Stream_Slot sole ownership · no dual Loop worlds

---

## Public vs private

| Public (PART I) | Private (PART II) |
|-----------------|-------------------|
| 4-field `Plan_Context` | `Plan_Host` meters, `Conn_Caps`, `Message_Proto` |
| Response, Session+gen, Effects | `Stream_Slot`, `Conn_Pt_Ring`, `Seal_Unit`, `Tls_Pipe`/`Seal_SM` |
| App Contract + capability matrix | M1–M6, Exec_Op, pipe POD, close SM |
| README honesty / E0 gates | Steal-vs-own engine port |

---

## Phases (evidence-gated; eng ≠ product for H2)

| Phase | Gate |
|-------|------|
| 0 | E0.1–E0.8 + App docs + matrix + sample CI |
| 1 | Slot N=1; dual-write gone; Clear H1 ✅ |
| 2 | TLS + PT ring must-alias + Seal_SM; **peak ≤~4× HW CI**; TLS H1 ✅ |
| 3 | H2 engine cherry-pick (sans host); unit vectors |
| 4 | H2 unary **engineering only** — curl green; **no** README H2 |
| 5 | **M1–M6** product multiplex + SSE-on-H2; recorded baseline; matrix H2 ✅ |
| 6 | Soft 503, GOAWAY, optional weights, multi-worker |

---

## Graft log (one line)

B’s matrix/M6/E0/PART split/close-SM/steal-own/session-switch/honesty → grafted; A’s must-alias PT, 4× firehose CI, Seal_Unit typing, allocator table, and conversation laws retained.
