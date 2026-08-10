# Critic: micro-opt loop (items 1,2,3,5,6)

**Stance:** adversarial. Correctness regressions = auto-reset. RPS keep only if ≥ **+2%** avg of 3 runs vs `MICRO_BASELINE.md`. Noise band ±2% → treat as no gain.

**Host:** Darwin · WORKERS=8 · h2load c50 D8 t4 · shared multi-kq  
**Baseline:** h1s plain 147885 · h1s s1m ~10112 · h2 plain 150056 · h2 s1m 8730

---

## Verdict: **CONDITIONAL KEEP** (partial)

| Item | Landed? | RPS | Critic decision |
|------|---------|-----|-----------------|
| **1 HPACK residual** | yes (static map, encode reserve) | h2 plain **−0.1%** | **RESET** — no gain; P0 already WOW |
| **2 H1 tiny materialize** | yes then **broke** responses (HTTP/0.9) | n/a | **RESET** — correctness fail |
| **3 CT peek-only** | yes (enforce peek, count fallback) | h1s s1m **+7%** (w/ dense+H2) | **KEEP** — law + bulk; RPS mixed with H2 keep |
| **5 H2 frame/flow** | yes (partial direct DATA, frame reserve, WU batch) | h2 s1m **+4.4%** | **KEEP** |
| **6 H1 parse/route** | yes (exact route, header parse) | h1s plain **−0.9%** | **RESET** — no gain |

---

## Final remeasure (after reset of 1,2,6)

3-run means:

| cell | baseline | post (kept 3+5+dense) | Δ |
|------|---------:|----------------------:|--:|
| h1s plain | 147885 | 146555 | **−0.9%** noise |
| h1s s1m | ~10112 | **10848** | **+7.3%** keep |
| h2 plain | 150056 | 149917 | **−0.1%** noise |
| h2 s1m | 8730 | **9111** | **+4.4%** keep |

Tests: `http` 169 · `http2` 59 · green after resets.

---

## What remains in tree (kept)

- Dense H1 flush + `tls_reactor_residual.odin` (Linux soft_cq law; pre-loop)
- CT **peek-only** product drain + accept fail if no peek
- H2 **frame/flow** micros (`frame.odin`, `flow.odin`, `connection.odin`, `h2_host.odin`)

## What was reset

- HPACK residual encode map / reserve
- H1 materialize in-place + format (broken)
- H1 exact-route / scanner / header sanitize micros

---

## Lies

- “HPACK residual will lift h2 plain” — measured flat after P0 FSM already removed the real cost.
- “Tiny materialize rewrite is safe” — shipped broken wire (HTTP/0.9); auto-reset correct.
- “Parse micros free plain win” — not visible at ±2% gate.

## Next ban

- More HPACK micro without h2 plain profile proof  
- Materialize rewrites without curl bodycheck in agent contract  
- Claiming AES as next without new sample under kept tree  

---

## Scoreboard

**Keep:** H2 bulk framing (~+4%) + bulk H1 (~+7% vs rough baseline; also dense/peek).  
**Reset:** 1, 2, 6.  
**Not WOW as a micro package overall** — selective keep only.
