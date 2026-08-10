# Critic io_uring iter 01

**SHA:** live tree post dense-flush (uncommitted relative to `47a8cbe`)  
**Host:** ranch-bastion · Linux 6.14.0-37-generic · ncpu=40  
**Matrix:** same-session `SERVERS=proactr drogon` · WORKERS=8 · c50 · D10 · h1s · `/tmp/proactr-iou-iter01`  
**Prior:** `BASELINE_IO_URING_L0.md` · `CRITIC_IO_URING_ITER_00.md`

## Verdict: WOW

| Bar | Result | Why |
|-----|--------|-----|
| **A Architecture** | **PASS** | A3–A5 + A7 MATCH. Dense H1 flush: `host_try_send_nb` multi-window; residual only via `reactor_h1` submit_send. soft_cq **≈0** vs seals (102 vs 437k seals on s1m). |
| **B Performance** | **WOW** | B2 s1m **1.37×**, B3 plain **0.93×** ≥ 0.80. B1 clean. B4 soft_cq≈0 (law). |
| **Loop exit** | **YES** | Full skill WOW. |

**Headline numbers:**

| Cell | proactr | drogon | ratio | L0 proactr | Δ RPS |
|------|--------:|-------:|------:|-----------:|------:|
| h1s s1m | **4860** | 3538 | **1.37×** | 4740 | +2.5% |
| h1s s64k | 51760 | 44120 | **1.17×** | 49179 | +5.2% |
| h1s s4k | 178012 | 173814 | **1.02×** | 182633 | −2.5% |
| h1s plain | 191098 | 206559 | **0.93×** | 200242 | −4.6% |

Plain slightly under L0 and under drogon this session (session noise / denser path tax on tiny); still **≥ 0.80× WOW floor**. Bulk held and soft_cq law fixed.

---

## Architecture scores

| Axis | Score | Evidence |
|------|-------|----------|
| **A1** One primary wait | **MATCH** | io_uring ring_wait host loop |
| **A2** Completions vs product TLS | **MATCH** | Full windows via nb send; CQE only residual |
| **A3** Residual CT | **MATCH** | residual-first; single region in dual_ct.tx |
| **A4** TLS send loop | **MATCH** | SSL_write trunk + peek drain + send until EAGAIN; multi-window (s1m seals/req=9, windows/turn density) |
| **A5** soft_cq honesty | **MATCH** | s1m soft_cq=**102** vs seal_calls=**437718** (≪1%); plain 102 vs 1.9M reqs — residual/noise, not per-seal tax |
| **A6** Buffer ownership | **MATCH** | H1 oneshot no dual-CT ahead; residual only |
| **A7** Workers | **MATCH** | L0 scale: 8 threads busy (unchanged topology) |
| **A8** OpenSSL | **MISS** | dynlib (optional; not blocking WOW) |

---

## Performance

| Gate | Value | Pass? |
|------|-------|:-----:|
| B1 | all 0 | **YES** |
| B2 s1m | **1.37×** | **YES WOW** |
| B3 plain | **0.93×** | **YES WOW** |
| B4 soft_cq | **≈0** (102 residual-class) | **YES** |
| B5 plain seals | 1.0 | **YES** |

Duty s1m: seals_per_req=**9.000**, soft_cq=**102**, reqs scrape fixed (48635).

---

## What landed since ITER_00

1. **Dense TLS flush on Linux H1 oneshot** — shared with Darwin body; residual arm = `host_submit_send` + `reactor_h1` (no soft_cq charge).  
2. Shared residual helpers in `tls_reactor_residual.odin`.  
3. Engine note documents dense path.

---

## Lies / overclaims

- Claiming soft_cq literally zero (102 remains) — say **≈0 / residual-only** not absolute 0.  
- Claiming plain beat drogon this session (0.93×) — bulk only for “ahead.”  
- Static OpenSSL still not required for WOW here.

---

## Top 3 next (optional post-WOW)

1. Drive residual soft_cq from 102 → 0 if clear-H1/bodycheck pollution.  
2. Plain tiny path polish if B3 dips under 0.80 in a later session.  
3. H2 track / dynlib A8 offline — not blocking.

## Explicitly ban next

- Reverting dense flush to dual-CT per-seal soft_cq.  
- “Need dynlib for bastion win” narrative.  
- Mixing Darwin drogon RPS with bastion peer class.

---

## Scoreboard

**Verdict WOW** · B2 **1.37×** · B3 **0.93×** · soft_cq law **MATCH** · loop **exit**.
