# Plan B (r3) summary — ergonomics honesty + structural WOW retained

**Full design:** [`plan-b.md`](./plan-b.md)

## Thesis (5)

1. **One `Stream_Slot` owns every exchange** — H1 = N=1, H2 = N.
2. **One outbound law** — pipe/cipher only submits; Seal_SM + CT[2]; no fuse optionality.
3. **App Contract is the product** — PART I first; cmds \| effects; four-field `Plan_Context`; capability matrix ⏳/✅.
4. **Vapor physics stay private** — mem-BIO, windows, duplex, Provider under cipher.
5. **H2 product = M1–M6** — concurrent slots **and** SSE-on-H2 before README “supports HTTP/2”; Phase 5 is engineering only.

## Ergonomics deltas (r2 → r3)

| Change | Why |
|--------|-----|
| **Author capability matrix** (clear / TLS H1 / TLS H2 × oneshot / SSE / WS / multiplex) | Phase honesty like WS; no silent “invariant true everywhere” |
| **SSE-on-H2 → Phase 6 / M6** (was Phase 7 afterthought) | Same `sse_start` API; product readiness with multiplex bar |
| **Phase 0 E0.1–E0.8 hard gate** | docs + same-handler CI + ban Host_Pull / http/debug / sid in examples |
| **PART I / PART II doc split** | Authors stop after contract + matrix; physics not the front door |
| **NEVER: third intent rail / stream_* as second long-lived** | Social dual-API kill |
| **Temporary soft-503 note in App Contract** | Load-test footgun named |
| **Four-field Plan_Context unchanged** | Keep r2 surface purity win |

**Unchanged (structural WOW):** Stream_Slot, Seal_SM, O1–O5, free-order close, mem-BIO, vapor lessons, gen ABA, no fuse, Conn_Caps private.

## Phase map (author-visible)

| Phase | Author meaning |
|-------|----------------|
| 0 | Contracts + CI sample + example bans |
| 1–2 | Clear H1 slot + bulk windows |
| 3 | TLS H1 oneshot + SSE ✅ |
| 5 | H2 unary **engineering only** (no product claim) |
| 6 | H2 product: M1–M6 + SSE-on-H2 ✅ + README H2 OK |
| 7–8 | Soft 503, multi-worker, soak |

## R2→r3 one-liner

> Structure already WOW’d; r3 makes **when** the invariant is true for SSE/H2 as crisp as the API itself — and freezes examples so duals cannot return socially.
