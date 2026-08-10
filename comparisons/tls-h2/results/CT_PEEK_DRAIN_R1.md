# CT peek drain R1 — wBIO zero-copy (drogon sendTLSData shape)

**Date:** 2026-08-09  
**Base:** `BASELINE_P5.md` · parent architecture `c93ddb8`  
**Change:** `reactor_drain_wbio` prefers `BIO_get_mem_data` peek → `send` → residual copy only on partial → `BIO_reset`. Falls back to `BIO_read` if peek unsupported.

## Law

- Residual-first preserved (R-ORDER): partial send copies **remainder only** into `dual_ct.tx` residual, then resets wBIO.
- Full window: **no** CT slab copy; `BIO_reset` after send.
- `soft_cq_send_completes` still **0**. Multi-window seal unchanged (64 KiB).

## Matrix (WORKERS=8, c50, D10 — same class as baseline)

| Cell | Baseline RPS | This RPS | Δ |
|------|-------------:|---------:|--:|
| h1s s1m | 2599 | **2669** | **+2.7%** |
| h1s plain | 111730 | 112986 | +1.1% |
| h2 s1m | 2216 | 2228 | +0.5% |
| drogon h1s s1m (same session) | 8612 | 8206 | (peer noise) |
| proactr/drogon h1s s1m | 0.30× | **0.33×** | |

All cells 0 fail. soft_cq=0. h1s s1m windows/turn ≈ 17.

**Gate +15% s1m:** **not met.** Honest architecture land; modest RPS.

## CPU sample (h1s s1m top-of-stack)

| Symbol | Baseline | After peek |
|--------|---------:|-----------:|
| `_platform_memmove` | 1241 | **728** (−41%) |
| AES-GCM kernel | 1857 | 1628 |
| `__sendto` | 2862 | 3288 |

Memmove tax down; more samples in useful send. AES still large — next bulk lever still seal-window A/B or further path density.

## Files

- `tls_server/provider.odin` — `bio_peek_out` / `bio_reset_out`
- `tls_server/provider_openssl_dynlib.odin` — `BIO_ctrl` (INFO/RESET)
- `http/tls_reactor_flush.odin` — `reactor_drain_wbio` peek path
