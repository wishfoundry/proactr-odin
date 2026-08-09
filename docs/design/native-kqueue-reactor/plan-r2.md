# Plan R2: Native kqueue reactor host (Darwin) — frozen for implement

**Status:** Phase 0 **FROZEN** — multi-critic WOW (2026-08-09 consolidation)  
**Supersedes:** `plan-r1.md`  
**Date:** 2026-08-09  
**START_IMPLEMENT:** yes (P0 first; no behavior change until inventory exit)  

**One sentence:** On Darwin, delete proactor-emulation for HTTP sockets and run a **native kqueue reactor** send law (encrypt→write until EAGAIN, single residual CT). Linux keeps true io_uring proactor. **APP_CONTRACT unchanged.**

---

## 0. Problem

```text
Today: host assumes CQE boundaries → proactr.submit_send → kqueue façade soft-CQ / EVFILT
Want:  Darwin host kevent → do work (including multi SSL_write + write until EAGAIN)
       Linux host stays submit → CQE (unchanged)
```

Failed under **façade proactor law** (closed; do not reopen as flags): H1 dense, Dual_Ct N=4, BIO peek package, windowed H2 frame, NODELAY, 1 MiB seal, heading coalesce, soft-CQ rearm spray, HPACK free-size-as-RPS.

**R7 vs this plan (non-cosplay diff):**

| Axis | R7 trifecta (RESET) | This plan (Darwin reactor) |
|------|---------------------|----------------------------|
| Soft-CQ between full CT windows | yes / promote path | **forbidden** |
| Host send model | submit → CQE → promote | **sync drain in kevent turn** |
| CT depth | Dual_Ct N=4 | **single residual buffer** |
| Measured first | RPS | **duty cycle, then RPS confirm** |
| Engine | same façade | **readiness-native host** |

If implementers reintroduce dual-CT promote soup or soft-CQ between full windows, that is **R7 costume** → auto-REJECT.

---

## 1. Decisions (closed — not open questions)

| # | Decision |
|---|----------|
| **D1** | **No `Host_Io` vtable.** Compile-time: `server_loop_proactor.odin` (Linux) vs `server_loop_reactor.odin` (Darwin). Shared protocol never calls `proactr.submit_*` for sockets after cutover; thin internal procs in engine files only. |
| **D2** | **No Phase 1 “extract for extract’s sake.”** Inventory (P0) then Darwin reactor vertical slice. Linux code path stays as-is until shared call sites need a one-line thin wrapper — no portable engine framework PR. |
| **D3** | **Reactor TLS bulk = single residual CT buffer** (drogon `writeBuffer_` shape). Dual-CT **Linux proactor only**. No “optional dual-CT on Darwin.” |
| **D4** | **Vertical spine:** TLS H1 oneshot (plain → s4k → s1m bulk). Cleartext-only multi-week epic: **rejected**. |
| **D5** | **Timers:** stay on proactr software timers / soft_cq through cutover. Reactor `wait` **merges** I/O + due timers (one wait). No second timer heap in P2–P5. |
| **D6** | **Darwin-only** through ship gates. FreeBSD/OpenBSD only if free `#+build` share; no BSD matrix claim. |
| **D7** | **One I/O owner per worker.** No H1-reactor + H2-façade hybrid on the same process. Until H2 is on reactor, Darwin either all-façade **or** all-reactor for product HTTP sockets; matrix labels must not lie. |
| **D8** | **SSL_write trunk A/B under reactor law:** start **64 KiB** (drogon), then 128/256 only if duty-cycle shows setup tax. Do not freeze 256 without trial. |
| **D9** | **Fairness cap (fixed):** first of **2 MiB plain** or **8 SSL_write windows** per kevent turn per conn; re-arm WRITE if more pending. |
| **D10** | **No runtime `IO_ENGINE` enum** for product. `when ODIN_OS` only. Optional debug force-flag later, not R2. |

---

## 2. Non-goals

- Change APP_CONTRACT / examples app story / middleware public API  
- Expose kqueue, readiness, engine choice to handlers  
- Delete Linux io_uring proactor  
- kTLS / leave OpenSSL as required  
- Drogon 9k parity as success  
- Permanent façade + reactor dual on Darwin  
- Reopen CLOSED_RPS_FLAGS without NEW LAW (below)  

### CLOSED_RPS_FLAGS

```text
H1_dense | DualCt_Ngt2 | BIO_peek_package | windowed_H2_frame
NODELAY | 1MiB_seal | heading_coalesce | softCQ_rearm_spray | HPACK_freesize_as_RPS

Reopen only if NEW LAW:
  (a) no soft completion between multi-window seal+drain on Darwin reactor path
  (b) host does not require CQE promote for consecutive SSL_write windows
  (c) duty-cycle gates land before any RPS claim
```

---

## 3. Public API freeze (ergonomics laws)

### Unchanged

- Oneshot: `body_*` → `respond`  
- Long-lived: Effects; events Start | Timer | External | Client_Gone | Idle_Timeout | **Writable**  
- Advanced: `plan_context` **exactly four fields**, engine-**invariant** meaning  

### Examples / tutorials / app godoc NEVER (reject PR)

1. `kqueue`, `kevent`, `EVFILT_*`, io_uring, CQ/SQ, soft-CQ, dual-CT, seal window, `Host_Io`  
2. readiness, “arm write”, re-arm as app concept  
3. `proactr.submit_*`, `Ring`, `ring_wait`, `ring_backend_name` in handler code  
4. `io_engine`, `when ODIN_OS` / engine `#if` in handlers or middleware  
5. Existing APP_CONTRACT NEVER (SSL*, stream ids, pull, resume/poll, …)  
6. Links from `examples/` into this design track  

### Session event meaning (behavior contract)

- **Writable** = host will accept more effects (backpressure relief), **not** “socket POLLOUT vocabulary.”  
- Trigger may be CQE full, sync full, or residual drain complete — **same predicate:** `want_writable && host can accept more body && no send residual for that channel`.  
- Dense loop: **at most one** Writable per backpressure episode after turn goes idle.  
- Timer / Idle_Timeout / hangup **only Client_Gone** unchanged across timer backend.  

### Doc firewall

- Dual host I/O = implementer design track (like dual-tls-h2).  
- APP_CONTRACT remains sole app story.  
- ARCHITECTURE “Writing handlers” does **not** grow kqueue curriculum.  
- `io_engine` on `/_matrix/stats` = operator only, never examples.  

### Middleware law

If middleware branches on OS, TLS mechanism, or `io_engine`, the plan **failed**.

### Compliance gate (every Darwin-touching PR)

- Grep ban list on `examples/**` + public middleware docs  
- Same handler sources for matrix cells on both OSes  

---

## 4. Target architecture

```text
APP_CONTRACT
    │
    ├─ Linux:  uring proactor host (existing law: dual-CT + CQE)
    └─ Darwin: kqueue reactor host (new law: until-EAGAIN + single residual)
         shared: parse, route, H2, HPACK, planner, sessions, OpenSSL setup, buffers
         not shared: worker wait/dispatch + TLS/clear bulk send path
```

**Hot path shape (Darwin TLS bulk — one screen):**

```text
reactor_tls_flush(conn):
  for until fairness cap:
    if ct_residual_len > 0:
      n = write(fd, residual); advance; if EAGAIN: arm WRITE; return
      continue   // no SSL_write while residual > 0  (drogon gate)
    if plain_remaining == 0: finish_response; return
    SSL_write(plain_window)           // start 64KiB
    drain wBIO → write(fd) until empty or EAGAIN
    if EAGAIN: stash residual CT; arm WRITE; return
    advance plain cursor
  if more work: arm WRITE  // fairness preempt
// NO soft_cq. NO promote_hold. NO dual_ct_try_ahead.
```

**Unified complete helper:** `host_on_send_delivered(conn)` shared by proactor CQE Full and reactor sync Full. Partial never enters it.

---

## 5. Correctness invariants (normative)

### R-ORDER (TLS)

1. At most one sealed CT region non-empty among {wBIO-to-send, residual buffer, pending_send suffix}.  
2. `SSL_write(N+1)` forbidden until seal N has zero residual (wBIO drained or residual stashed as the single region).  
3. Single residual buffer on Darwin; dual-CT ahead-seal **Linux only**.  

### R-SEND

| Result | Action |
|--------|--------|
| Full window CT on wire | `kind=None`; call `host_on_send_delivered` inline |
| Partial / EAGAIN | `pending_send` remainder; arm WRITE; no delivered side effects |
| Hard error | fail closed (`_wire_fail` class) |

### R-CLOSE

1. Deferred close ⇔ wire residual **or** CT read interest **or** other registered socket interest — **not** “CQE must exist.”  
2. Close request + !deferred → close immediately (sync complete path).  
3. Never free residual buffer while WRITE interest still references it.  

### R-DUPLEX (Phase 2+, not postponed)

1. WANT_READ from SSL during bulk → arm READ before return.  
2. Readable events process even if WRITE also armed.  
3. Fairness cap is write budget only; read not gated on finishing bulk window.  

### R-WRIT

See §3 session Writable predicate.  

### R-OWNER

One kevent wait per Darwin worker for product sockets. proactr kqueue **must not** also arm HTTP socket filters after reactor cutover.

---

## 6. Phases (agent-sized)

### P0 — Freeze (docs)

- This plan R2 + ARCHITECTURE implementer note (firewall)  
- Call-site inventory of every `proactr.submit_*` from `http/`  
- File map (below)  
- Pin baseline: matrix command, cells, machine class, git SHA  
- Land duty-cycle counter **stubs** on façade path for baseline scrape  
- Offline OpenSSL encrypt+send-until-EAGAIN microbench note (ceiling ladder)  

**Exit:** inventory merged; decisions locked; no behavior change.

### P1 — Inventory + thin internal procs only (optional micro)

**Not** Host_Io framework. If needed: rename-only wrappers still calling façade on Darwin / uring on Linux — only to keep call sites listed. Prefer skip and jump to P2 if inventory shows clear cut points.

**Exit:** Linux matrix flat ±3% if any shared edit.

### P2 — Darwin reactor: TLS H1 oneshot plain (+ s4k)

- New: `http/server_loop_reactor.odin` (+build darwin)  
- New: `http/io_reactor_kqueue.odin` — wait, accept, read, write, residual CT  
- TLS H1: single residual; flush shape as §4 (windows may still be small)  
- Merged wait: kevent + proactr timer due  
- **No** HTTP `submit_send` on this path  
- Correctness tests T1–T6, T8–T9, T11–T12 (subset) green  

**Exit:**

- `io_engine=reactor-kqueue` honest for H1 cells  
- 0 failed/timeout on h1s plain (and s4k)  
- RPS ≥ baseline −10% on plain (guard)  
- Examples ban grep clean  

### P3 — Darwin reactor bulk law (h1s s1m) + metrics

- Full until-EAGAIN loop; residual gate (no SSL_write while residual > 0)  
- Trunk A/B: **64 KiB first**  
- Fairness D9  
- Duplex R-DUPLEX smoke  
- Duty counters live vs façade baseline  

**Primary gates (3× remeasure; duty first):**

| Metric | Gate vs façade baseline |
|--------|-------------------------|
| `seal_windows_per_kevent_turn` p50 on h1s s1m | **↑ ≥ 2×** |
| `soft_cq_send_complete_per_MiB` (must be 0 on reactor H1) | **= 0** |
| `eagain_arms_per_MiB` | **↓ ≥ 30%** |
| `plain_bytes_sealed_per_wall_ms` | **↑** |
| AES wall duty (sample or SSL_write timer / wall) | **↑ or flat with goodput ↑** |
| h1s s1m RPS | **≥ +15%** only as **confirmation** after duty gates |
| h1s plain | ≥ −3% |
| drogon same session | report ratio (parity **not** required) |

**Phase done without +15% RPS:** if duty gates hit hard but RPS +8–14%, **document AES/send ceiling**, do **not** reopen Dual_Ct N or density flags. Architecture may still ship for honesty if correctness green and soft_cq/MiB → 0.

**Claim ship (+15%):** only with duty + RPS + 3×.

### P4 — H2 on same reactor send law

- Port H2 flush to residual + until-EAGAIN (no façade)  
- Entire Darwin HTTP sockets on reactor (D7)  

**Exit:** h2 plain/s1m ≥ −3% vs pre-P4; 0 errors; no `submit_send` from H2 path.

### P5 — Delete façade socket path

- Darwin: no `proactr.submit_send/recv/accept` from `http/` (CI grep)  
- proactr kqueue socket submit: remove or compile-fail if linked from http  
- Timers remain in proactr  
- Soak + fairness  

**Exit:** grep gate; soak; IMPLEMENTATION_STATUS updated.

---

## 7. File map (expected)

| File | Role |
|------|------|
| `http/server_loop_reactor.odin` | Darwin worker: kevent dispatch |
| `http/io_reactor_kqueue.odin` | arm R/W, residual CT write, accept |
| `http/tls_reactor_flush.odin` | §4 bulk/plain flush (Darwin) |
| `http/tls_oneshot.odin` | dispatch to reactor flush vs proactor dual-CT |
| `http/wire.odin` | shared buffer helpers; proactor submit stays Linux |
| `http/server.odin` | select loop file by OS |
| `proactr/platform_kqueue.odin` | shrink: timers only post-P5; socket path dead |
| `comparisons/tls-h2/...` | matrix `io_engine` label |

Shared unchanged in intent: `http2/*`, `hpack/*`, planner, scanner, session event kinds, OpenSSL provider (may add BIO helpers later — not required for P2–P3).

---

## 8. Correctness tests (phase exits)

| ID | Test | Phase |
|----|------|-------|
| T1 | Residual CT + no SSL_write until residual empty | P2/P3 |
| T2 | Partial write → WRITE → resume; plain not advanced early | P2/P3 |
| T3 | Sync full CT → next seal/clean without CQE | P2/P3 |
| T4 | close during Partial_Armed | P2 |
| T5 | close after sync Full | P2 |
| T6 | WANT_READ mid-seal → arm READ → resume | P3 |
| T7 | H2 WINDOW_UPDATE during large DATA | P4 |
| T8 | Writable: multi-window full sync → 1 event | P2/P3 |
| T9 | Writable: EAGAIN path → 1 event | P2 |
| T10 | Fairness: large + small conns | P3 |
| T11 | Buffer free only after residual empty | P2 |
| T12 | Peer RST mid-bulk fail closed | P2 |
| T13 | Darwin build: no HTTP submit_send | P3/P5 |
| T14 | Stream plain progress without CQE (if stream on reactor) | later |
| T15 | HS multi-flight under reactor | P2 |

RPS claim only after T1–T6, T8–T9, T11–T13 green for that phase.

---

## 9. Ceiling ladder (honesty)

```text
L0 today:          ~0.30× drogon h1s s1m
L1 reactor law OK: ~0.35–0.45×  (+15–50% RPS)   ← honest P3 win band
L2 path refine:    ~0.45–0.60×                 ← evidence-gated later
L3 drogon parity:  ~1.0×                       ← NOT this plan
```

Banned language: “closing on drogon” at &lt;0.5×; “less AES” as a win.

---

## 10. Drogon comparison (law only)

| Drogon | This plan Darwin |
|--------|------------------|
| multi SSL_write(64k) + write until residual | same structure |
| residual gates sealing | R-ORDER / residual-first |
| level-trigger writable re-entry | EVFILT_WRITE re-entry |
| body double-copy | keep our borrow advantage |
| one EventLoop thread affinity | one worker ring/loop affinity |

---

## 11. Casey principles (binding)

1. Two OS loops, not a framework of engines.  
2. Hot path one screen (§4).  
3. Delete façade (P5), no dual forever.  
4. No speculative Host_Io product.  
5. Measure law (duty) before RPS victory.  

---

## 12. Success / WOW bar

### Plan WOW (this document)

Critics accept:

1. Decisions D1–D10 locked  
2. App/examples freeze enforceable  
3. R7 non-cosplay table  
4. Phases agent-sized with machine gates  
5. Correctness invariants + tests  
6. Duty-primary performance science  

### Implementation WOW (later)

1. soft_cq send completes / MiB → **0** on Darwin H1  
2. Duty gates + optional +15% RPS confirm  
3. Zero matrix errors  
4. No APP_CONTRACT leak  
5. Grep: façade socket path dead  

---

## 13. Implementation order for agents

1. P0 docs + inventory + baseline metrics on façade  
2. P2 reactor loop + TLS H1 plain/s4k  
3. Impl critic  
4. P3 bulk + 64KiB A/B + full gates  
5. Impl critic + **3× matrix**  
6. P4 H2 only if P3 claim or architecture-only ship decided  
7. P5 delete façade  

**Do not start P4/P5 before P3 correctness + duty instrumentation.**

---

## 14. Implementer footnotes (critic residual — non-blocking)

1. **One residual on Darwin:** map `pending_send` / residual CT / wBIO-to-send to a **single** residual region on the reactor path (do not keep two parallel remainder buffers).  
2. **kevent turn order:** due timers → readable → writable (deterministic).  
3. **Handshake:** multi-flight HS under reactor obeys residual-first / no soft-CQ between seal windows (same flush law after Complete).  
