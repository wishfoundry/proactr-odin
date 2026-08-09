# Author capability matrix

**What you may write *now*.** Phase numbers = product readiness for authors, not internal engineering milestones. Until a cell is ✅, do not market that combo; handlers still use the same API — listen options simply do not offer it yet.

Companion docs: [`APP_CONTRACT.md`](APP_CONTRACT.md), [`MIDDLEWARE_CONTRACT.md`](MIDDLEWARE_CONTRACT.md), [`PHASE0_E0.md`](PHASE0_E0.md).  
Ship honesty: [`IMPLEMENTATION_STATUS.md`](IMPLEMENTATION_STATUS.md).  
H2 product baseline (M1–M6): [`design/dual-tls-h2/H2_PRODUCT_BASELINE.md`](design/dual-tls-h2/H2_PRODUCT_BASELINE.md).  
Operator edges (not matrix flips): [`PRODUCTION_CHECKLIST.md`](PRODUCTION_CHECKLIST.md).

---

## Matrix

| Capability | Clear H1 | TLS H1 | TLS H2 |
|------------|:--------:|:------:|:------:|
| Oneshot cmds + `respond` | ✅ Phase 1 | ✅ **Phase 2** (HTTPS oneshot; OpenSSL dynlib; mem-BIO host) | ✅ **offline M1–M6** + eng curl — concurrent multi-slot oneshot (M1); ALPN `h2` |
| Large `body_file` / Static (same API; host windows) | ✅ Phase 1–2 | ⏳ Phase 2 — windowed seal path exists; bulk/live firehose not CI-gated | ⏳ Phase 5 — offline flow O(window) (M2/M5); live bulk firehose not CI-gated |
| **SSE** (`sse_start` / Effects) | ✅ today / Phase 1 | ✅ **Phase 2** — same Effects API over ciphered progressive stream | ✅ **offline M1–M6** + eng curl — multi-slot SSE (M6); RST → Client_Gone |
| **WS** (`ws_start`) | ✅ H1 | ✅ **Phase 2** — same Effects API over ciphered progressive stream | ⏳ later phase (not H2 until documented) |
| Concurrent unary on one connection | N/A (pipelining H1) | N/A | ✅ offline M1 (+ eng curl) — default `h2_serial_dispatch=false` |
| Concurrent SSE sessions on one connection | N/A | N/A | ✅ offline M6 (+ eng curl); live multi-stream bastion **optional** |
| “Supports HTTP/2” in README | — | — | ✅ allowed as **experimental** offline bar; not peer-matrix RPS; bastion multi-stream optional |

**TLS H1 note (PR5 + PR6):** HTTPS oneshot (PR5) and long-lived SSE/WS (PR6) share the
App Contract with clear H1 — `respond` / `sse_start` / `ws_start` / Effects; listen PEMs
only (no handler `#if`). Progressive path: plain frames in `resp_buf` →
`tls_host_stream_try_submit` (serial windowed `SSL_write` + `tls_ct_tx`). Hangup on
ciphered Open long-lived arms CT recv with single-flight ownership (`tls_ct_recv_inflight`)
→ `.Client_Gone`. Large-body product claims stay ⏳ until bulk firehose is proven on live
TLS wire. Clear H1 remains the default when PEMs are empty or OpenSSL cannot load.

**TLS H2 product bar (PR9):** ✅ means **offline M1–M6 unit gates + eng `curl --http2`**,
not live multi-stream bastion RPS. Fair RR on multi-pending / conn credit recovery (M3);
peak **on-wire** DATA O(window) (M5). Live multi-stream bastion is **optional** evidence —
do not publish peer-matrix H2 RPS from the offline bar alone. WS-on-H2 remains ⏳. See
[`H2_PRODUCT_BASELINE.md`](design/dual-tls-h2/H2_PRODUCT_BASELINE.md).

> **PR7 engine footnote (implementers only):** offline codec packages (`http2/`,
> `hpack/`, `huffman/`) remain the sans-I/O foundation. Product author claims follow
> the matrix cells above, not eng-only curl greenery. See [`H2_ENGINE.md`](H2_ENGINE.md).

---

## Honesty rules (README / release notes / examples)

1. **Do** say “supports HTTP/2” only with concurrent streams + SSE-on-H2 (M1–M6 offline bar met). Prefer “experimental / product concurrent + SSE” and note bastion RPS is future.
2. **Do not** imply WS works on H2 — still ⏳.
3. TLS and H2 are **listen options**, never handler options.
4. **Do not** claim peer-matrix or bastion multi-stream RPS unless measured and published.
5. **Do not** claim full “HTTPS production ready” for bulk large-body until that TLS H1/H2 cell is ✅ (oneshot + SSE/WS alone are not the whole column).
6. **Do not** treat PR7 offline engine tests alone as product H2 — product bar is M1–M6 (now green offline).

**Invariant for authors:** the handler sample has **zero** protocol `#if` and never touches stream ids. Same code under clear H1, TLS H1, and TLS H2 (for ✅ cells) when PEMs / ALPN are configured.
