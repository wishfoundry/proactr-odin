# Perf improvement loop — Round 1

## Target
Darwin TLS kqueue matrix — close small **h2** gap (R2: proactr 0.73× ntex plaintext).

## Plan
Eliminate second HPACK→Request string clone via deferred stream free + borrow.

## Critics
| Stage | Verdict |
|-------|---------|
| Plan | **APPROVE_WITH_AMENDMENTS** (must defer free; no scrap decode) |
| Impl | **PASS** (UAF-safe; not full WOW on client path) |

## Measure (proactr-only then full peer)

| Cell | R2 baseline | After borrow (solo) | Full R3 peer run |
|------|------------:|--------------------:|-----------------:|
| h2 plaintext | 93 347 | **95 155** (+1.9%) | 93 745 (~noise) |
| h2 s4k | 78 256 | **79 609** (+1.7%) | 78 866 |
| h2 s1m | 1 753 | 1 763 | 1 783 |
| vs ntex h2 plain | 0.73× | — | **0.73×** (128 k) |

## Decision
**Commit** `a80a0a1` — correctness win + directional small-H2 gain; not enough to change rank.

## Next target (Round 2)
Still far from parity on:
- h2 small/mid (send/recv/rearm + residual HPACK first clone)
- **h1s s1m 0.30× drogon** (largest absolute hole)
- h2 s1m 0.59× go

Round 2 proposal: **TLS H1 bulk path** (materialize/seal vs drogon) **or** **reduce per-response send/rearm tax** on small H2 — plan critic before code.
