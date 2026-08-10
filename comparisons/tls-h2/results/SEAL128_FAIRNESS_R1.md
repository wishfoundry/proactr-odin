# Seal 128 KiB + fairness WRITE re-arm R1

**Date:** 2026-08-10  
**Stack:** CT peek drain (`3195a8b`) + `REACTOR_SEAL_WINDOW=128KiB` + fairness continue re-arm  
**Rejected this round:** level-triggered WRITE (tiny RPS regression / complexity; oneshot re-arm kept)

## Changes

| Item | Detail |
|------|--------|
| Seal trunk | 64 → **128 KiB** (`reactor_law.odin`) |
| Fairness | 16 windows × 128 KiB = 2 MiB; on hit **oneshot WRITE** → `reactor_tls_flush` |
| WRITE model | Still **EV_ONESHOT** + re-arm (drogon *re-entry* shape without level thrash) |

## Matrix (WORKERS=8, c50, D10)

| Cell | BASELINE_P5 | CT_PEEK | **This** | vs P5 |
|------|------------:|--------:|---------:|------:|
| h1s s1m | 2599 | 2669 | **2873** | **+10.5%** |
| h1s plain | 111730 | 112986 | **113605** | +1.7% |
| h2 s1m | 2216 | 2228 | **2373** | +7.1% |
| drogon h1s s1m | 8612 | 8206 | 7823 | (peer noise) |
| proactr/drogon s1m | 0.30× | 0.33× | **0.37×** | |

All 0 fail. `soft_cq_send=0`. h1s s1m: **~9 seals/req**, **~9 windows/turn**.

**+15% gate vs BASELINE_P5:** not met (+10.5%). Keep; document ceiling progress L0 0.30 → **0.37×**.

## Next convergence (still open)

1. Level WRITE again only with careful idle disable + tiny guard  
2. Dual-wait merge (soft_cq + kevent)  
3. Tiny materialize elimination (separate track)  
4. Further AES/send density (OpenSSL link mode offline A/B)
