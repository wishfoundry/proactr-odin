# Harsh critic — are the kqueue benchmarks testing what they should?

**Role:** adversarial bench honesty (coverage · fairness · staleness · claim fit)  
**Artifacts:** `KQUEUE_TLS_H2.md`, `kqueue_summary.tsv`, `KQUEUE_TLS_PROFILE.md`, `KQUEUE_PROFILE_MATRIX.md` (cleartext TFB), `run_matrix.sh`  
**Date of this critique:** 2026-08-09  
**Matrix run under review:** 2026-08-09T13:40Z (TLS) · 2026-08-05 (cleartext profile)

---

## Verdict: **PASS_WITH_RESERVATIONS** (for the narrow claim) · **FAIL** (if claimed broader)

| Claim you might make | Allowed by these benches? |
|----------------------|---------------------------|
| “proactr TLS+H2 runs on Darwin kqueue and completes fail-closed cells” | **YES** |
| “On this Mac, relative rank vs ntex(tokio)/go/drogon on oneshot TLS size ladder” | **YES** (with labels) |
| “proactr kqueue is slower than io_uring by 0.34×” | **NO** — different host/silicon; ratio is anecdote |
| “proactr vs ntex-uring on kqueue” | **NO** — ntex is **tokio** on Darwin |
| “Current tree after HPACK FSM/encoder fixes” | **NO** — TLS matrix **pre-dates** HPACK modernization |
| “kqueue *event path* is the bottleneck” | **NO** — not isolated; OpenSSL + HPACK + mem-BIO dominate samples |
| “Full kqueue product matrix (cleartext + TLS + file + multi-stream)” | **NO** — split/stale/incomplete |

**One line:** The TLS matrix is a **fair-enough oneshot peer load on a laptop**; it is **not** a kqueue microbench, not a post-HPACK scoreboard, and not cross-host uring comparison.

---

## Scorecard — “are we testing what we should?”

| # | Question | Result | Notes |
|---|----------|--------|-------|
| Q1 | Same host, certs, routes, C/D/W for all peers? | **PASS** | harness enforces |
| Q2 | Body len + prefix verified? | **PASS** | H1.s + H2 when ALPN h2 |
| Q3 | H2 requires Application protocol h2? | **PASS** | drogon correctly N/A |
| Q4 | Fail-closed on failed/timeout/unparseable? | **PASS** | INVALID path present |
| Q5 | Backend labels honest for Darwin? | **MIXED** | SUMMARY fixed; **ntex process banner still says neon-uring** |
| Q6 | Peers match intended I/O class? | **PARTIAL** | proactr=kqueue OK; ntex≠uring; go≠worker model; drogon H1-only |
| Q7 | Loadgen not the silent winner? | **UNKNOWN** | `-c100 -t4` may cap ~150k class cells (drogon/go plaintext) |
| Q8 | Isolates kqueue vs other Darwin demux? | **FAIL** | only one host path; no control experiment |
| Q9 | Isolates OpenSSL vs kqueue wait? | **PARTIAL** | profile helps; matrix RPS alone does not |
| Q10 | Multi-stream / SSE / warm HPACK / CONTINUATION? | **FAIL** | oneshot size ladder only; `/sse` unused in TESTS |
| Q11 | Numbers match current code? | **FAIL** | TLS matrix before Huffman FSM + encoder table |
| Q12 | Cleartext kqueue TFB still valid product story? | **PARTIAL** | older oha matrix; sendfile win OK; not TLS evidence |
| Q13 | Instrumentation trustworthy as RPS sibling? | **FAIL** bulk | `path_reqs` undercount multi-chunk (h1s s64k `reqs=1`) |
| Q14 | Laptop vs bastion noise controlled? | **FAIL** | thermal, background, power; single run |
| Q15 | Bastion ratio used only as context? | **PASS** in write-up | doc warns; still easy to mis-quote |

---

## What the TLS kqueue matrix **actually** tests

```
localhost · TLS 1.3 · h2load -c100 -D15 -t4 · WORKERS=8
routes: /plaintext, /s/4k, /s/64k, /s/1m
protocols: ALPN h2  |  h2load --h1 (TLS HTTP/1.1)
pattern: one request → one response body (oneshot), keep-alive churn
```

That is the right experiment for:

- “Does our **product TLS stack** work on Darwin?”
- “How do we rank against **realistic peers we can build on Mac**?”
- “Is dual-CT / seal path alive?” (with instrumentation caveats)

That is the **wrong** experiment for:

- “How good is **kqueue** as a demultiplexer?” (need cleartext or synthetic event load, or A/B backends)
- “Did **HPACK P0** fix the 0.48× ntex gap?” (need **re-run** after HPACK)
- “io_uring vs kqueue absolute” (need same box or stop quoting ratios as fact)

---

## Critical honesty failures

### C1 — ntex self-label still lies on Darwin (**IMPORTANT**)

`ntex/src/main.rs` always prints:

```text
io=neon-uring
```

Cargo selects **tokio** on non-Linux. SUMMARY.md was fixed; the **running peer log was not**. Anyone grepping server logs will re-poison ranks.  
**Required:** banner `io=tokio` when `cfg(not(linux))`.

### C2 — Scoreboard is **stale** vs HPACK work (**CRITICAL** for current claims)

| Event | When |
|-------|------|
| KQUEUE TLS matrix | ~13:40Z Aug 9 |
| Huffman FSM + encoder + ownership | hours later |

Publishing “proactr 0.48× ntex on h2 plaintext” as **current** product truth is **false advertising** until rebench. Profile that blamed linear Huffman is also pre-FSM.

### C3 — “kqueue” in the title oversells the independent variable (**IMPORTANT**)

Measured system =

`kqueue host + OpenSSL mem-BIO + HPACK + dual-CT + app handlers + h2load`

You cannot attribute the ntex gap to kqueue alone. Sample stacks put **HPACK / send / AES** on top, not `kevent` exclusive.  
**Label:** “Darwin TLS peer matrix (proactr uses kqueue)” — not “kqueue performance matrix.”

### C4 — Peer class inequality (documented but still misread) (**IMPORTANT**)

| Peer | What matrix measures | What people hear |
|------|----------------------|------------------|
| proactr | kqueue proactor + mem-BIO OpenSSL | “kqueue” |
| ntex | **tokio** + OpenSSL | “ntex-uring” if careless |
| go | net/http + crypto/tls · GOMAXPROCS | “same workers” |
| drogon | trantor kqueue · **no H2** | “four-peer H2” if careless |

Harness labels are mostly honest. **Marketing is the risk**, not the TSV.

### C5 — Loadgen / machine class (**IMPORTANT**)

- Single consumer laptop (M2 Pro), not bastion; no repeated runs / median.
- `h2load -t 4` fixed; may leave cores idle or become client-bound at high RPS.
- No check that h2load CPU &lt; 100% of a core cluster when crowning drogon ~150k.
- No power-adapter / thermal note.

Without that, **rank order** is still useful; **absolute RPS** is soft.

### C6 — Instrumentation not ground truth for bulk (**IMPORTANT**)

`path_reqs` undercounts multi-window responses (`h1s s64k reqs=1` while seals ~877k). Doc admits h2load is truth — good. Using seals/req from scrape without h2load denom is still a footgun in later write-ups.

### C7 — Missing tests that product care about on kqueue (**IMPORTANT**)

Not in `TESTS` / protocols:

| Missing | Why it matters on Darwin |
|---------|---------------------------|
| Cleartext H1/H2 alongside TLS in same report | Separates kqueue from OpenSSL |
| Multi-stream H2 (many streams / connection) | kqueue rearm + H2 fairness |
| SSE / progressive under TLS | stream dual-CT path |
| Post-warm encoder table (many GETs same conn) | new HPackEncoder path unmeasured |
| File / sendfile under TLS? | N/A usually; cleartext file was separate |
| Rebench after HPACK | current code |

Cleartext `KQUEUE_PROFILE_MATRIX.md` covers tiny/file/sse with oha — **different loadgen, older, incomplete peer set (no go/drogon)**. Not a substitute for TLS matrix and not fresher than TLS.

### C8 — Bastion cross-ratio is seductive junk science if quoted hard (**CRITICAL** if abused)

`kqueue/uring ≈ 0.34×` on h2 plaintext mixes:

- Apple Silicon vs bastion CPU  
- kqueue vs io_uring  
- possibly different OpenSSL builds  
- thermal / single-run noise  

Write-up correctly marks “context only.” **Any slide that shows one ratio without that caveat fails honesty.**

---

## What we **should** be testing (recommended matrix)

### Tier A — keep (current TLS matrix) after **re-run**
Same harness post-HPACK, fix ntex banner, 3× runs median, document h2load CPU.

**Answers:** product TLS rank on Darwin today.

### Tier B — add to isolate kqueue vs crypto
| Cell | Purpose |
|------|---------|
| Cleartext H1 plaintext/s64k same peers | kqueue/app without TLS |
| TLS H1 vs H2 plaintext only | HPACK/H2 tax |
| `INSTRUMENT=1` PHASE + path_metrics with fixed reqs | where time goes |

### Tier C — product gaps not “kqueue” but still Darwin
| Cell | Purpose |
|------|---------|
| h2 multi-stream (h2load `-m` / multi) | stream scheduler |
| SSE long-lived | progressive / dual-CT stream |
| Connection reuse warm HPACK (encode table) | new encoder |

### Tier D — do **not** claim without bastion-class host
Absolute cross-OS ratios; “kqueue is X% of uring.”

---

## Fake-bench checklist (TLS kqueue run)

| # | Check | Status |
|---|--------|--------|
| C1 ntex peer TLS | PASS (builds; wrong io label) |
| C2 drogon peer TLS | PASS H1; h2 N/A honest |
| C3 go peer TLS H1+H2 | PASS |
| C4 same routes/certs/W | PASS |
| C5 h2 ALPN required | PASS |
| C6 fail-closed | PASS |
| C7 body prefix | PASS |
| C8 backend labels SUMMARY | PASS (ntex log FAIL) |
| C9 no cleartext mixed into TLS table | PASS |
| C10 instrumentation | PARTIAL (bulk reqs wrong) |
| C11 drogon h2 not claimed win | PASS |
| C12 worker model labels | PASS in notes |
| **C13 numbers match HEAD** | **FAIL** (pre-HPACK) |
| **C14 isolates claimed factor (kqueue)** | **FAIL** |

---

## Residual excuses (ranked)

1. **Re-run TLS matrix on current tree** (HPACK + encoder) before any rank claim.  
2. **Fix ntex Darwin banner** (`tokio` not `neon-uring`).  
3. **Rename narrative** to “Darwin TLS peer matrix”; demote “kqueue” to mechanism footnote.  
4. **Median of ≥3 runs**; note thermal; optional raise `-t` with cores.  
5. **Prove loadgen headroom** (h2load CPU) on top cells.  
6. **Fix `path_reqs`** or stop scraping it for bulk seals/req.  
7. **Add Tier B cleartext** cells if the question is kqueue vs crypto.  
8. **Never hard-quote bastion ratio** as kqueue penalty.

---

## Top 3 actions (truthfulness first)

1. **Rebench** `SERVERS="proactr ntex drogon go"` TLS matrix after HPACK; replace `KQUEUE_TLS_H2.md` with dated R2.  
2. **Honesty patch:** ntex `io=` banner by OS; SUMMARY already OK.  
3. **Claim discipline:** publish only relative Darwin ranks + “pre/post HPACK” tag; kill cross-host absolute ratios in headlines.

---

## Bottom line

**We are testing the right thing for “TLS product on Mac vs peers we can run.”**  
**We are not testing a pure kqueue benchmark, not a current-code scoreboard, and not io_uring parity.**

Until rebench + label fix + claim hygiene:  
**PASS_WITH_RESERVATIONS** on the 13:40Z matrix as historical;  
**FAIL** any statement that treats it as “kqueue performance” or “post-HPACK truth.”
