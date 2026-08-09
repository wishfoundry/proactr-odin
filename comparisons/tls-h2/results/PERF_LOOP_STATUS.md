# PERF_LOOP status

## Current pin: **BASELINE_P5** (Plan R2 P5 complete)

See **`BASELINE_P5.md`** for the full same-session peer matrix, duty scrape, and CPU sample.

| Item | Value |
|------|--------|
| SHA | `c93ddb8` |
| Date | 2026-08-09 |
| Engine | `reactor-kqueue` (native wait ownership) |
| h1s s1m proactr / drogon | **0.30×** (2599 / 8612) |
| h1s s1m proactr / ntex | **1.30×** |
| h2 s1m proactr / ntex | **2.18×** |
| soft_cq_send (TLS bulk) | **0** |
| h1s s1m windows/turn | **~17** |

## Next

**Not a free-for-all.** One evidence-gated cut at a time against `BASELINE_P5.md` gates:

1. Bulk: seal 64 vs 128 KiB A/B **or** BIO/memmove reduction  
2. Tiny (separate): H1 materialize elimination on static bodies  
3. Tiny H2 (separate): plain vs ntex gap  

Do not reopen CLOSED_RPS_FLAGS without NEW LAW.

## Closed architecture work

P0–P5 Plan R2 done (native kqueue reactor wait + residual-first TLS send law).
