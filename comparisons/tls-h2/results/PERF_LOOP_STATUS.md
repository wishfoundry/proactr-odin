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

## Round 3 — H2 send/rearm cleanup (no kTLS)

| Stage | Result |
|-------|--------|
| Plan (coalesce heading) | **REJECT** — R2-adjacent, wrong cell for 0.73× H2 |
| Alt plan (send/rearm density) | **APPROVED** by critic |
| Impl | Collapse arm spray, empty flush fast-path, kqueue soft-CQ changelist flush |
| Measure (proactr+ntex) | h2 plain **−0.1%**; s4k **−2.3%**; some h1s bulk **−6–9%** |
| Gate | Need ≥+8% h2 plain — **FAIL** |
| Decision | **RESET** (not committed) |

**Learning:** arm_recv was already single-flight; remaining spray is cheap flag checks. Soft-CQ flush didn't move RPS. Small-H2 gap is not free “orchestration” — deeper (OpenSSL record setup + send density) without kTLS.

## Next levers still open (honest, **no kTLS**)

1. **Small H2:** residual first HPACK ownership into stream (still one clone); response path OpenSSL WPACKET; compare ntex connection reuse  
2. **H1 parse/maps** for h1s plaintext (0.75× drogon)  
3. **Bulk:** accept OpenSSL userspace AES+send ceiling vs drogon until different I/O architecture (not kTLS as product default)  
4. **Calibration:** bare OpenSSL encrypt+send microbench to bound headroom  
5. Do **not** re-do plain-split, dual-CT 256KiB, 1MiB window, or heading coalesce as main bets  

## Round 4 — TCP_NODELAY on accept (no kTLS)

| Stage | Result |
|-------|--------|
| Plan | Header-map tax **REJECT** as RPS bet; OpenSSL calib not product |
| Alt plan | **`TCP_NODELAY` on accept** — peer parity (ntex/drogon default) |
| Plan critic | **APPROVE_WITH_AMENDMENTS** — gate ≥+5% h1s or h2 plain |
| Impl | `net.set_option(client_fd, .TCP_Nodelay, true)` after accept |
| Measure | h1s plain **+2.6%**, h2 plain **+1.0%** — gate **FAIL** |
| h1s s1m ×3 | **2434–2472** vs R3 **2778** (−11–12%) — **regress** |
| Decision | **RESET** (not committed) |

**Learning:** On this Darwin loopback+h2load shape, Nagle off is **not free RPS**; bulk H1.s got worse. Peers may benefit differently (epoll/uring paths). Do not force NODELAY for matrix cosplay.

## Stop inventing small wins?

Per R4 plan critic: after NODELAY miss, optional OpenSSL calibration; **fresh sample** of current HPACK/send mix; only productize if a ≥10% CPU bucket is named.

## Next levers still open (honest, **no kTLS**)

1. Fresh post-HPACK **sample** on h2 plain / h1s plain (current residual stacks)  
2. Offline **OpenSSL encrypt+send** calibration for s1m ceiling  
3. H1 header `sanitize_key` hygiene (not as primary RPS bet)  
4. Accept residual bulk gap vs drogon without kTLS until architecture changes  

## Loop policy reminder
Gate with **h2load RPS** same harness; peers flat when claiming win; no drogon H2 fiction; **no kTLS** as the peer-fair fix.
