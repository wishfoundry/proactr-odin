# Scratch — semantic compression inventory (Plan A R4 only)

**Purpose:** raw concept count for `critic-semantic-r4.md`. Not a freeze doc.  
**Artifact:** `plan-a.md` (R4 graft · ~1231 lines · ~8935 words)

---

## Load-bearing public (apps must learn)

| # | Concept | Notes |
|---|---------|-------|
| 1 | Intent = cmds \| effects | exactly two rails |
| 2 | Exchange (slot privately) | request/response or session |
| 3 | Backpressure = `.Writable`; death = `.Client_Gone` | one hangup |
| 4 | thin Plan_Context (optional) | four fields only |

**Public types:** Response_Cmd / body_* / respond · Effects / Session_Event · Session (gen) · Plan_Context · middleware rewrite of cmds only.

---

## Load-bearing implementer (host ontology)

| # | Concept | Role |
|---|---------|------|
| 1 | Stream_Slot | sole exchange ownership |
| 2 | Connection (pipe) | socket + tls? + framer + pt + wire_conn + slots header |
| 3 | Tls_Pipe + Seal_SM | L2 cipher; CT×2; arm-from-CQE |
| 4 | Conn_Pt_Ring + PT1 must-alias | sole bulk PT admission |
| 5 | Seal_Unit + seal_q + rr_cursor + gen | fairness + ABA |
| 6 | live Slot_Flow / Law W1 | never frozen as plan bucket |
| 7 | exclusive framer (H1 \| H2) | not Frame_State god-object |
| 8 | Wire_Conn / Wire_Slot split | S1 single outbound |

**Caps:** Conn_Caps 4 orthogonal bits. **Policy:** pure plan_body. **Mechanism:** produce → frame/seal → one submit.

---

## Named types in freeze (inventory)

| Name | Necessary? | Class |
|------|------------|-------|
| Plan_Context (4) | Yes public | constraints |
| Plan_Host | Yes private | host meters |
| Conn_Caps / Conn_Cap | Yes private | orthogonal axes |
| Message_Proto {H1,H2} | Borderline | dual-label w/ Multiplex / framer.kind |
| Stream_Slot | Yes core | ownership |
| Connection | Yes core | pipe |
| Session + gen | Yes public handle | ABA |
| Request / Response | Yes | exchange surfaces |
| Slot_Flow | Yes when H2 | live windows |
| Seal_Unit | Yes | fairness unit |
| Wire_Conn_State / Wire_Slot_State | Yes | wire split |
| Conn_Pt_Ring | Yes | PT admission |
| Tls_Pipe / Tls_Phase / Seal_SM | Yes private | L2 SM |
| Conn_Cipher_Engine | Yes opaque | no SSL* escape |
| Connection_Framer / H1_Framer / H2_Engine | Yes exclusive | L3 |
| Slot_Deferred (private Host_Pull) | Yes private | deferred produce |
| Exec_Op_Kind | Role yes; set fat | residual laundry |
| Pipe POD constants | Yes private | physics numbers |
| Server_Opts | Admin not handler | knobs |

**Count:** ~18–20 named design objects; **~8–10 load-bearing**. Unchanged order vs r2/r3 — **no new runtime type from graft**.

---

## R4 graft items — type vs apparatus

| Graft | New type? | Inflation? | Compression effect |
|-------|-----------|------------|--------------------|
| PART I / PART II | No | Doc structure | **Compresses reader ontology** — authors never load Slot/Pipe/Seal |
| Capability matrix ⏳/✅ | No | Calendar-as-data | **Compresses readiness fuzz** into one table |
| E0.1–E0.8 | No | Freeze gates | **Compresses dual-API social reentry** |
| README honesty rules | No | Marketing law | Collapses paper-H2 / early-SSE lies |
| M6 + product bar M1–M6 | No | Phase law | **Folds SSE-on-H2 into product meaning** (not second package) |
| Eng Phase 4 ≠ product Phase 5 | No | Honesty | Separates curl green from H2 product |
| Close SM §E.4 | Steps not types | Operational density | **One free-order ontology** (stream vs conn) |
| Steal vs own §A.4 | Process | Boundary | **Compresses dual-maint vapor fork** |
| Session framer.kind switch | No product type | Explicit refuse Session_Wire | Prevents vtable dual |
| Host_Pull NEVER / third rail | Ban | Social + contract | Closes latent third intent rail |
| Soft-503 host note | No | Footgun clarity | Keeps admission out of app API |
| Peer POD footnote | No | Evidence | Numbers without package import |

**Verdict raw:** graft is **apparatus + honesty**, not synonym types. Net **compress**.

---

## Residual dual-labels / synonyms (pre-existing + tiny graft scars)

| Item | Severity | Note |
|------|----------|------|
| Message_Proto × Multiplex × framer.kind | minor | three names for framing truth; pick primary |
| Exec_Op laundry vs Produce/Seal/Submit roles | minor | private teaching surface still zoo-shaped |
| BIO_RX_HOLD_MAX ≡ RX_HOLD_CAP | nit | **explicit synonym** in POD table — drop alias row |
| H2_Engine vs H2_Framer naming | nit | pick one |
| Conn_Cipher_Engine vs Tls_Pipe.engine | nit | one bag |
| Thesis ×3–4 (three words · A.3 six · R · spine) | doc | not type inflation |
| Matrix · M1–M6 · Phase K | doc | three readiness calendars; different audiences OK |

---

## What closed since r2 semantic

| r2 residual | R3/R4 status |
|-------------|--------------|
| m3 fat 8-field Plan_Context | **Closed** R3 — four fields |
| m1 Message_Proto dual-label | **Open** minor |
| m2 Exec_Op laundry | **Open** minor |
| m4 pedagogic triple | **Worse slightly** (matrix+M6+PART + R) — still doc-only |
| m5 micro-names | **Open** nit; + BIO_RX alias |

R3 spotcheck A semantic: **9.3**. R4 graft target: hold or slight lift on phase honesty / reader cut.

---

## Score draft (pre-write)

| Axis | r2 | r3 spot | r4 draft |
|------|----|---------|----------|
| Primitive budget | 9.3 | ~9.4 | **9.4** |
| Orthogonal vocab | 9.0 | ~9.1 | **9.15** |
| No parallel H1/H2 | 9.7 | 9.7 | **9.7** |
| No synonym types | 8.7 | 8.7 | **8.75** (BIO_RX nit; Host_Pull ban helps third rail) |
| Mechanism privacy | 9.2 | 9.25 | **9.3** |
| Composability TLS×H2 | 9.4 | 9.4 | **9.45** (M6 same API) |
| App Contract thin | 9.1 | 9.3 | **9.4** (PART stop + matrix + E0) |
| Phase honesty | 9.3 | 9.35 | **9.5** (M6 + eng≠product + honesty rules) |
| **Overall** | **9.15** | **9.3** | **~9.35–9.4** |

**WOWED draft:** Yes ≥9. Graft **compressed**, did not bloat type ontology.
