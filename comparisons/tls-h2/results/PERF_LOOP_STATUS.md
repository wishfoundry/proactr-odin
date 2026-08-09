# Performance improvement loop status (Darwin kqueue TLS)

**Goal:** comparable or better than peers on all matrix cells.  
**Host:** M2 Pro laptop · single-run noise ± few %.

## Commits this loop

| Commit | Change | Measure |
|--------|--------|---------|
| `e052c24` | HPACK FSM + encoder (prior) | R2: h2 plain **+51%** |
| `a80a0a1` | H2 header borrow (no 2nd clone) | R3: **~0–2%** (noise / modest) |
| `9d80eef` | R3 matrix artifacts | — |
| *(reverted)* | 1 MiB seal + heading coalesce | **h1s s1m −6%**, plaintext −10% → **reset** |

## Current scoreboard vs best peer (R3 full matrix)

| Cell | proactr | best | ratio | status |
|------|--------:|-----:|------:|--------|
| h2 plaintext | 93.7k | ntex 128k | **0.73×** | gap |
| h2 s4k | 78.9k | ntex 133k | **0.59×** | gap |
| h2 s64k | 27.9k | ntex 49k | **0.57×** | gap |
| h2 s1m | 1.78k | go 3.0k | **0.59×** | gap (beats ntex) |
| h1s plaintext | 113k | drogon 150k | **0.75×** | gap |
| h1s s4k | 96k | drogon 151k | **0.64×** | gap |
| h1s s64k | 30k | drogon 67k | **0.44×** | gap |
| h1s s1m | 2.8k | drogon 9.2k | **0.30×** | **largest hole** |
| drogon h2 | — | N/A | — | not a peer |

Cleartext kqueue profile matrix (older): proactr ahead on tiny/file sendfile; behind ntex on assembled.

## Round log

### Round 1 — H2 header borrow
- **Plan critic:** APPROVE_WITH_AMENDMENTS  
- **Impl critic:** PASS  
- **Measure:** small H2 +1–2% solo; full matrix noise  
- **Decision:** **commit** (`a80a0a1`)

### Round 2 — 1 MiB seal + heading/body coalesce  
- **Plan critic:** REJECT menu; approve only this A/B with ≥15% h1s s1m gate  
- **Impl:** window 1 MiB + coalesce  
- **Measure:** h1s s1m **2608** vs baseline **2778** (−6%); h1s plain regression  
- **Decision:** **reset** (not committed)

## Next levers still open (honest)

1. **OpenSSL/send density ceiling** on bulk H1 — bare crypto calibration before more planner work  
2. **Small H2:** remaining after HPACK is mostly **send/recv/rearm** (not second clone)  
3. **H1 parse/maps** for h1s plaintext  
4. **kTLS** (long pole) if AES+send stays ~90% of bulk samples  
5. Do **not** re-implement plain-split / dual-CT (already live)

## Loop policy reminder
Gate with **h2load RPS** same harness; peers flat when claiming win; no drogon H2 fiction.
