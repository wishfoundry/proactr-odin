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
| `ac570cb` | H2 oneshot borrow + H2-only dense CT; HPACK free-size | **h2 s1m +41%**; P0-2 plain gate FAIL |

## Current scoreboard vs best peer (P0c matrix)

| Cell | proactr | best | ratio | status |
|------|--------:|-----:|------:|--------|
| h2 plaintext | 94.8k | ntex 126k | **0.75×** | gap |
| h2 s4k | 81.8k | ntex 129k | **0.64×** | gap |
| h2 s64k | *(R3)* 27.9k | ntex 49k | **0.57×** | gap (not remeasured) |
| h2 s1m | **2.51k** | go 3.25k | **0.77×** | improved (was 0.59×) |
| h1s plaintext | 119k | drogon 151k | **0.79×** | gap |
| h1s s4k | 103k | drogon 151k | **0.68×** | gap |
| h1s s64k | *(R3)* 30k | drogon 67k | **0.44×** | gap (not remeasured) |
| h1s s1m | 2.77k | drogon 9.2k | **0.30×** | **largest hole** (unchanged) |
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

## Competitor hot-path audit (2026-08-09)

Full report: [`COMPETITOR_HOTPATH_AUDIT.md`](COMPETITOR_HOTPATH_AUDIT.md)  
Agents: ntex · drogon · go · vapor-http (`~/Projects/odin-http`) → summary critic.

**Consensus P0 (do not re-do NODELAY / 1 MiB / rearm):**

| Rank | Item | Peers | Target | P0c result |
|-----:|------|-------|--------|------------|
| 1 | Seal-until-EAGAIN multi-window | drogon + vapor | h1s s1m **0.30×** | H1 dense **FAIL** (+2%, plain −4%) → **reset**; H2-only dense **kept** (s1m win) |
| 2 | HPACK `decode_string` single-alloc | ntex + profile | h2 plain ≥+8% | shipped as free-size micro; RPS **+1% FAIL** gate |
| 3 | H2 oneshot borrowed body | go + ntex | h2 s4k/s1m ≥+8% | **PASS** (s1m **+41%** with H2 dense) |

## Round 5 — competitor P0 loop (agents + harsh critics)

| Stage | Result |
|-------|--------|
| Audit agents | ntex / drogon / go / vapor → ranked backlog |
| P0-1 H1 dense | seal-until-EAGAIN on oneshot; critic **REJECT** (no tests); measure gate **FAIL** |
| P0-1 H2-only dense | `h2_host_flush_out` multi-window NB send (max 8); H1 classic dual-CT |
| P0-2 HPACK | shrink+transfer Huffman; gate **FAIL** RPS |
| P0-3 H2 body | skip materialize + direct frame when windows fit |
| Combined measure | h2 s1m **1783→2509 (+41%)**; h2 plain +1%; h1s s1m flat |
| Final critic | **COMMIT_WITH_AMENDMENTS** (honest story; not WOW; not audit-complete) |
| Decision | **commit** H2 bulk path + HPACK free-size; H1 dense stays dead |

Artifacts: [`KQUEUE_TLS_H2_P0c.md`](KQUEUE_TLS_H2_P0c.md), `summary_P0c.tsv`.

**Not claimed:** H1 RPS wins · peer parity · P0-1/P0-2 complete · kTLS.

## Round 6 — H2 windowed frame (RESET)

| Stage | Result |
|-------|--------|
| Pre-flight sample h2 s1m | Busy: **memmove ≈ AES ≈ sendto**; `_append_elems` residual ~8%; memmove mostly **OpenSSL WPACKET + mem BIO** (not h2_out growth alone) |
| Plan critic | APPROVE_WITH_AMENDMENTS: windowed frame-into-dense-seal; gate h2 s1m ≥+10%; H1 density family **closed** |
| Impl | Frame DATA in ≤256 KiB body windows + flush; small-body pre-reserve |
| First matrix | h2 s1m **2727** vs P0c **2509** (+8.7%) soft-band; plain/s4k flat |
| 3× remeasure (10s, warm) | **2462 / 2500 / 2524** ≈ P0c — **noise, not real** |
| Chunk-size “fix” | Worse (2569 / more flush turns) |
| Decision | **RESET** (not committed) |

**Learning:** residual H2 bulk tax after P0c is **OpenSSL mem-BIO + WPACKET + AES + send**, not frame-buffer growth. Windowed encode is not a ≥10% RPS lever on this host. Do not re-run as RPS bet.

## Next levers still open (honest, **no kTLS**)

1. **h1s s1m 0.30× drogon** — H1 density family **closed** for this loop; I/O-law / OpenSSL ceiling until new theory  
2. **h2 plain 0.75× ntex** — sample: sendto+recv+frame/map (HPACK not dominant); need ≥10% named leaf  
3. **h2 s1m vs go (~0.77×)** — mem-BIO + pure-Go AES gap; product RPS micro on frame path **exhausted** for now  
4. Offline OpenSSL encrypt+send-until-EAGAIN microbench vs drogon (calibration, not matrix win)  
5. Optional: custom wBIO → dual-CT (kill mem_read/write copies) — real eng, not a free flag  
6. Do **not** re-run: H1 dense, windowed frame, HPACK free-size as RPS, NODELAY, 1 MiB seal  

## Loop policy reminder
Gate with **h2load RPS** same harness; peers flat when claiming win; no drogon H2 fiction; **no kTLS** as the peer-fair fix. **3× remeasure soft-band claims.**
