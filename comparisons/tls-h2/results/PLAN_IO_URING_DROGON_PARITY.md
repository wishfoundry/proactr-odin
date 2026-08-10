# Plan: io_uring TLS bulk parity (lessons from Darwin kqueue)

**Status:** ready to execute  
**Host for baselines:** `ranch-bastion` (Linux, io_uring product path)  
**Peer:** same-session drogon (and optionally ntex) via `comparisons/tls-h2`  
**Goal:** harsh-critic **WOW** on Linux — architecture bar + performance bar (h1s s1m ≥ **0.90×** drogon, plain ≥ **0.80×**), duty honest (`soft_cq_send=0` on bulk or explicit NEW LAW).

**Do not** copy the kqueue reactor onto Linux. Transfer **laws and measurement**, implement density in **proactor** terms.

---

## 0. Lessons from Darwin (what transfers)

| Lesson | Transfer to io_uring? | Linux form |
|--------|----------------------|------------|
| Measure who is busy (workers × CPU) | **Yes** | Per-worker CQ activity / `ps`/perf; c=1 vs c=50 scale |
| Same-session peer + duty honesty | **Yes** | Matrix + path_metrics; no “architecture win” without RPS |
| Multi-window TLS without CQE between seals | **Yes** | Dense flush: seal+drain until SQ full / would-block; minimize soft send CQE tax |
| Residual-first CT order | **Yes** | Single residual region; residual before next SSL_write |
| Peek/drain wBIO (no full CT copy every time) | **Yes** | Already partly on Darwin; ensure Linux drain matches |
| Close only waits real in-flight ops | **Yes** | RECV/SEND SQE outstanding — not permanent “interest” flags |
| c=1 density ≠ multi-conn scale | **Yes** | Always ladder c=1/8/50 after changes |
| Ban Darwin REUSEPORT multi-bind | **No** | Linux REUSEPORT is usually fine; measure, don’t copy ban |
| Level R/W kevent model | **No** | Proactor: multishot/linked ops / continuous re-arm, not level flags |
| Dynlib/fn-cache first | **No** | Only after workers busy and multi-window law holds |

**Linux product path today (contrast):**  
`tls_host_flush_response` on non-Darwin uses **dual-CT** (`tls_dual_ct_try_ahead`, seal → `host_submit_send` → CQE). Darwin oneshot H1 uses `reactor_tls_flush` (until-EAGAIN, soft_cq=0). The io_uring fight is **proactor density**, not multi-kq accept cosplay.

---

## 1. Principles (frozen)

1. **Baseline first.** No implementer PR claims “better” without `BASELINE_IO_URING_L0` on bastion.  
2. **One change → remeasure → critic.** No batch of 5 “improvements” without intermediate matrix.  
3. **Two independent bars** (same as Darwin critic): Architecture (proactor-honest) + Performance (RPS). Both must PASS for interim; both **WOW** to stop.  
4. **APP_CONTRACT frozen.** No CLOSED_RPS_FLAGS reopen without written **NEW LAW**.  
5. **kTLS is not a fair fix** for this peer matrix.  
6. Temporary RPS regression OK if law-honest and next top-3 is named.  
7. Do not claim “converged” under 0.50× s1m; do not claim “parity” under 0.90× s1m + 0.80× plain.

### CLOSED_RPS_FLAGS (carry forward unless NEW LAW)

Dual_Ct N>2 as RPS flag, dense soft-CQ that fakes multi-window, TCP_NODELAY as fair fix, 1 MiB seal as flag, kTLS-as-fair, reopening floor-0 plain-split without evidence.

---

## 2. Host & harness

| Item | Value |
|------|--------|
| Bastion | `ranch-bastion.local` (reachable; odin + h2load present) |
| Sync | `comparisons/tls-h2/run_on_bastion.sh` (or equivalent rsync + remote matrix) |
| Matrix | `SERVERS="proactr drogon"` (add ntex when ranking peers) |
| Load | `WORKERS=8 BENCH_C=50 BENCH_Z=10 WARMUP_Z=3` (match Darwin session when comparing ratios) |
| Protocols | Start **h1s only** for bulk parity loop; h2 is a later track |
| Artifacts | `comparisons/tls-h2/results/BASELINE_IO_URING_L0.md` + `bastion_*` copies + per-iter critic files |

**Scale probe (mandatory each baseline / after scale-related PR):**

```bash
# On bastion, proactr only, after bodycheck
for c in 1 4 8 16 50; do
  h2load -c $c -D 5 -t 4 --h1 https://127.0.0.1:PORT/s/1m
done
# Expect: RPS rises with c until ~cores; flat c=1..50 ⇒ worker/accept serial bug (Darwin lesson)
```

Under c=50 load: confirm **multiple** worker threads busy (not 1/N).

---

## 3. Critic skill (Linux variant)

### 3.1 Create / extend skill

**Path:** `.grok/skills/proactr-io-uring-parity-critic/SKILL.md`  
(Or extend `proactr-drogon-parity-critic` with a **Linux section** — prefer **new skill** so Darwin and Linux axes stay distinct.)

### Bar A — Architecture (io_uring / proactor honesty)

| Axis | PASS when |
|------|-----------|
| **A1** One primary wait per worker | One blocking wait path dominating (io_uring enter/wait); no dual *blocking* soft+uring loops |
| **A2** Completions vs product TLS | Document: product bulk does not require CQE between every seal window |
| **A3** Residual CT | Single residual region; residual-first before next SSL_write |
| **A4** TLS send loop | SSL_write trunk + peek/drain + send until backpressure; multi-window per “turn” |
| **A5** soft_cq_send honesty | `soft_cq_send_completes≈0` on h1s s1m **or** NEW LAW + measured necessity |
| **A6** Buffer ownership | No dual residual; dual-CT ahead only if measured and residual-order safe |
| **A7** Thread model | N workers, conn pinned; **all workers load-bearing under c=50** |
| **A8** OpenSSL | Dynlib called out as MISS (not required for WOW if B2/B3 pass) |

**Architecture PASS:** ≤1 MISS among A1–A7; **A3–A5 and A7** must be MATCH.

### Bar B — Performance (same as Darwin)

| Gate | PASS | WOW |
|------|------|-----|
| B1 errors | all 0 | all 0 |
| B2 h1s s1m proactr/drogon | ≥ **0.50×** | ≥ **0.90×** |
| B3 h1s plain | ≥ **0.65×** | ≥ **0.80×** |
| B4 soft_cq bulk | = 0 (or NEW LAW) | same |
| B5 plain seals/req | not fake 2 | same |

**Loop exit:** Verdict **WOW** = Architecture PASS + Performance WOW.

### Critic outputs

`comparisons/tls-h2/results/CRITIC_IO_URING_ITER_NN.md` — same template as Darwin critic (verdict, A/B tables, lies, top 3, ban list).

---

## 4. Phases

### Phase 0 — Baseline L0 (no code changes)

**Owner:** orchestrator (or baseline agent, read-write only for results files).

1. Sync tree to bastion (`run_on_bastion.sh` or rsync).  
2. Build clean proactr + drogon on bastion.  
3. Run:

```bash
SERVERS="proactr drogon" WORKERS=8 BENCH_C=50 BENCH_Z=10 WARMUP_Z=3 \
  PROTOCOLS=h1s LOGDIR=/tmp/proactr-iou-l0 ./run_matrix.sh
```

4. Scale ladder c=1..50 on proactr `/s/1m`.  
5. Under load: note worker CPU distribution (e.g. `ps -L` / `pidstat -t`).  
6. Scrape instrumentation: soft_cq, seals/req, windows/turn, materialize.  
7. Write **`BASELINE_IO_URING_L0.md`**:

| Field | Content |
|-------|---------|
| SHA, uname, ncpu | required |
| RPS matrix | proactr + drogon h1s ladder |
| Ratios | proactr/drogon per cell |
| Scale table | c → RPS |
| Worker busy? | yes/no + evidence |
| Duty | soft_cq, seals/req, windows/turn |
| Honesty label | L0 / L1 / … |

8. **Critic ITER_00** (baseline only): score A/B; **must FAIL** if B2 &lt; 0.50 or A7 MISS (one worker). Name top 3 for Phase 1.

**Gate to Phase 1:** L0 artifact committed or pinned under `results/`; critic ITER_00 on disk.

---

### Phase 1 — Diagnose (read-only agents)

**Agents (parallel, read-only / explore):**

| Agent | Task |
|-------|------|
| **scale-auditor** | Explain c-scale curve + worker busyness vs Darwin pin bug; is REUSEPORT OK on Linux? |
| **path-auditor** | Trace Linux H1 TLS: `tls_host_flush_response` → dual-CT → `host_submit_send` → CQE; count soft CQEs per seal |
| **duty-auditor** | Map path_metrics to law; soft_cq_send on s1m; seals/req; materialize |
| **critic ITER_00** | Already from Phase 0; refresh if path-auditor finds lie |

**Deliverable:** short `DIAGNOSE_IO_URING_L0.md` — single “headline miss” (e.g. soft CQE per seal, dual-CT thrash, accept imbalance, AES density).

**Gate:** one ordered top-3 for implementers; no more than one “density” item until scale is healthy.

---

### Phase 2 — Implementation loop (until WOW)

Each iteration **N**:

```
┌─────────────────────────────────────────────────────────┐
│ 1. Critic ITER_(N-1) top-3 (or DIAGNOSE if N=1)         │
│ 2. Implementer agent: ONE primary change + tests        │
│ 3. Check agent: build + odin test http (bastion)        │
│ 4. Matrix agent: same-session proactr+drogon h1s        │
│ 5. Scale probe if change touches accept/workers         │
│ 6. Harsh critic ITER_N (correctness + quality + perf)   │
│ 7. If not WOW → loop with new top-3                     │
└─────────────────────────────────────────────────────────┘
```

#### Suggested implementation track (reorder only if critic forces)

| Priority | Workstream | Why (Darwin lesson) | Likely files |
|----------|------------|---------------------|--------------|
| **P0** | Multi-worker utilization | If L0 shows 1 hot worker | `server_io_uring.odin`, accept path, REUSEPORT verify |
| **P1** | Dense TLS flush on Linux | Multi-window without CQE between seals | `tls_oneshot.odin`, `tls_dual_ct.odin`, `wire.odin`, maybe Linux-only dense drain |
| **P2** | Residual-first + peek drain on Linux | Match Darwin/drogon CT path | `tls_host.odin` drain, dual_ct residual |
| **P3** | Dual-CT ahead: measure or kill on bulk | Dual-CT may tax more than help | `tls_dual_ct.odin`, oneshot flush |
| **P4** | Soft harvest / wait merge | A1 dual wait tax | host loop in `server.odin` / proactr wait |
| **P5** | OpenSSL density (static/fn) | Only after P0–P2 | `tls_server/*` — **last**, not first |

**Explicit non-goals early:** kqueue reactor port; level kevent flags on Linux; dynlib A/B as first PR.

#### Implementer agent contract

- Read `BASELINE_IO_URING_L0.md` + latest critic.  
- Implement **one** top-3 item (or tightly coupled pair with one remeasure).  
- Preserve APP_CONTRACT; no CLOSED flag reopen.  
- `odin test http` green on bastion.  
- Do not claim WOW; leave that to critic.

#### Critic agent contract (every iter)

- Skill: `proactr-io-uring-parity-critic`.  
- Inputs: live SHA, matrix summary + instrumentation, scale table if available, touched files.  
- Output: `CRITIC_IO_URING_ITER_NN.md`.  
- Score correctness (B1, residual order, no UAF), quality (no density theater, no triple paths), performance (B2/B3).  
- Auto-FAIL cheerleading under 0.50× s1m.  
- Top 3 ordered by expected ×drogon impact.

#### Quality critic (optional every 2 iters)

Reuse strict code-review skill: no file bloat, no triple OpenSSL paths, backend stays `server_io_uring` not OS soup.

---

### Phase 3 — WOW exit & pin

When critic returns **WOW**:

1. Pin `BASELINE_IO_URING_WOW.md` (or `L_FINAL`) with matrix + duty + SHA.  
2. Update `summary.tsv` / bastion copies under `results/` with historical L0 rows (like Darwin pre-shared-listen).  
3. Commit with message that cites B2/B3 ratios and soft_cq.  
4. Optional: h2 track as separate plan (do not block WOW on h1s).

---

## 5. Agent roster (orchestration)

| Role | Type | When |
|------|------|------|
| **orchestrator** | human or main session | Runs loop, bastion sync, stops on WOW |
| **baseline-runner** | general-purpose + execute | Phase 0 matrix + scale + write L0 |
| **diagnose-*** | explore / read-only | Phase 1 audits |
| **implementer** | general-purpose all | Phase 2 code |
| **verify** | check-work style | build + tests |
| **matrix-runner** | execute | same-session proactr drogon |
| **parity-critic** | general-purpose r/w | CRITIC_IO_URING_ITER_NN |
| **quality-critic** | code-review skill | every 2 iters or on large diffs |

**Loop control:** max **N=12** iters then stop for human review (avoid infinite density thrash). If B2 flat for 3 iters after P0 healthy, force path-auditor re-open (wrong diagnosis).

---

## 6. Success criteria (WOW checklist)

- [ ] Same-session bastion matrix proactr + drogon, h1s ladder, 0 errors  
- [ ] B2 h1s s1m ≥ **0.90×** drogon  
- [ ] B3 h1s plain ≥ **0.80×** drogon  
- [ ] B4 soft_cq_send = 0 on bulk (or NEW LAW document)  
- [ ] A7: multi-worker busy under c=50 (not single-thread bulk)  
- [ ] A3–A5 MATCH (residual-first, multi-window law, CQE honesty)  
- [ ] Critic file says **WOW** without banned language  
- [ ] L0 historical numbers recorded next to final matrix  

---

## 7. First commands (Phase 0 kickoff)

```bash
# From laptop
cd comparisons/tls-h2
SERVERS="proactr drogon" WORKERS=8 BENCH_C=50 BENCH_Z=10 WARMUP_Z=3 \
  PROTOCOLS=h1s ./run_on_bastion.sh

# Then on bastion (or via ssh): scale ladder + worker CPU sample
# Write results/BASELINE_IO_URING_L0.md from remote SUMMARY + instrumentation
# Spawn critic ITER_00 against L0
```

After L0 critic top-3 lands, spawn **implementer** on item #1 only.

---

## 8. Risks

| Risk | Mitigation |
|------|------------|
| Bastion load noise | Same-session peers; don’t cherry-pick best of 5 |
| Dual-CT still “correct” but slow | Measure soft_cq + seals/turn; prefer dense flush over dual slab cosplay |
| Porting kqueue reactor to Linux | **Out of scope** — proactor density only |
| Scope creep (H2, static OpenSSL) | H2 after h1s WOW; static only if critic A8 + B still fail after density |
| Accepting 0.5× as “done” | Skill WOW requires 0.90× — interim PASS is not exit |

---

## 9. Document map

| Artifact | Path |
|----------|------|
| This plan | `comparisons/tls-h2/results/PLAN_IO_URING_DROGON_PARITY.md` |
| L0 baseline | `comparisons/tls-h2/results/BASELINE_IO_URING_L0.md` (create in Phase 0) |
| Critics | `CRITIC_IO_URING_ITER_NN.md` |
| Darwin reference | `CRITIC_DROGON_ITER_04.md`, `BASELINE_P5.md` |
| Skill | `.grok/skills/proactr-io-uring-parity-critic/SKILL.md` (create before ITER_00) |
| Bastion harness | `comparisons/tls-h2/run_on_bastion.sh` |

---

## 10. Immediate next step

1. Author **io_uring parity critic skill** (copy Darwin skill, swap axes to proactor + A7 worker busyness).  
2. Run **Phase 0** on bastion → `BASELINE_IO_URING_L0.md`.  
3. Critic **ITER_00** → top 3.  
4. Enter Phase 2 loop with agents until **WOW**.
