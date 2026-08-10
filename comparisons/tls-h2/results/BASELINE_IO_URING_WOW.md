# Baseline — io_uring WOW (dense H1 flush)

| Field | Value |
|-------|--------|
| **Date** | 2026-08-10T15:01Z |
| **Prior L0** | `BASELINE_IO_URING_L0.md` (SHA `47a8cbe`) |
| **Host** | ranch-bastion · Linux 6.14 · WORKERS=8 · c50 · D10 · h1s |
| **Change** | Dense TLS flush (Linux H1 oneshot): nb send multi-window; residual `reactor_h1` only |
| **Critic** | `CRITIC_IO_URING_ITER_01.md` → **WOW** |

## RPS (same session)

| peer | plain | s4k | s64k | s1m |
|------|------:|----:|-----:|----:|
| proactr | 191098 | 178012 | 51760 | **4860** |
| drogon | 206559 | 173814 | 44120 | 3538 |
| ratio | **0.93×** | 1.02× | 1.17× | **1.37×** |

## Duty s1m

soft_cq_send_completes=**102** (≈0 vs 437k seals) · seals_per_req=**9.0** · 0 errors

## vs L0

| Cell | L0 | WOW | note |
|------|---:|----:|------|
| s1m | 4740 | 4860 | held bulk + law |
| plain | 200242 | 191098 | slight dip; still WOW B3 |
| soft_cq s1m | ~237k | **102** | law fixed |
