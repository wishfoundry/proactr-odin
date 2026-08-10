BASELINE_DARWIN 2026-08-10T16:03Z
# Micro-opt baseline (pre 1/2/3/5/6 loop)

**Host:** Darwin local · WORKERS=8 · h2load c50 D8 t4 · shared multi-kq

| proto | path | RPS |
|-------|------|----:|
| h1s | plaintext | **147885** |
| h1s | s1m | **~10112** (80898 req / 8s) |
| h2 | plaintext | **150056** |
| h2 | s1m | **8730** |

Note: HPACK P0 (FSM Huffman, ring table, dynamic encoder) already landed per CRITIC_HPACK_R2 WOW. Loop targets residual micros.

## Post-loop (after keep/reset) — 3-run avg

| proto | path | baseline | post | Δ | action |
|-------|------|---------:|-----:|--:|--------|
| h1s | plaintext | 147885 | 146555 | −0.9% | noise |
| h1s | s1m | ~10112 | **10848** | **+7.3%** | keep (dense/peek + noise band) |
| h2 | plaintext | 150056 | 149917 | −0.1% | noise |
| h2 | s1m | 8730 | **9111** | **+4.4%** | keep H2 frame micros |

**Reset (no gain or broken):** HPACK residual, H1 materialize (HTTP/0.9 bug), H1 parse/route.  
**Kept:** H2 frame/flow, CT peek-only enforce, dense TLS residual (prior).  
See `CRITIC_MICRO_LOOP_01.md`.
