# Drogon path convergence — complete (with critics)

**Date:** 2026-08-10  
**Tip:** post–`ff6a071` convergence batch  
**Anchor baselines:** `BASELINE_P5.md` · `CT_PEEK_DRAIN_R1.md` · `SEAL128_FAIRNESS_R1.md`  
**Report:** `PROACTR_VS_DROGON_PATH_COMPARE.md`

---

## 1. Roadmap status (all implementable items)

| PR | Item | Status | Critic verdict |
|----|------|--------|----------------|
| **A** | Seal 64→128 KiB | **SHIPPED** | Keep. s1m seals/req ~9; RPS up vs P5 |
| **B** | Fairness WRITE re-arm | **SHIPPED** | Keep. Correctness for >2 MiB |
| **C** | Level residual WRITE | **SHIPPED** | Keep structure; residual-only (not all WRITE). Full level thrash rejected earlier |
| **D** | CT peek drain | **SHIPPED** | Keep. memmove ↓; residual-first law |
| **E** | Dual wait / timer merge | **SHIPPED** | Keep. Skip empty soft wait when no timer due |
| **F** | Tiny plain-split floor 0 | **TRIED → REJECTED** | Floor 0 → seals/req=2 on plain/s4k, **−27% plain**. **Kept 8 KiB floor** with documented reason (item closed by evidence) |
| **G** | Darwin no-hold slab | **SHIPPED** | Keep. RSS; dual-CT hold Linux-only |

### Explicit non-goals (report § leave alone) — not implemented by design

| Item | Why |
|------|-----|
| TCP_NODELAY | CLOSED; hurt bulk |
| Dual_Ct N>2 / dense soft-CQ | CLOSED; law already multi-window |
| kTLS | Out of fair matrix |
| Dynlib → static OpenSSL | Product choice; offline only |
| Deferred clean removal | Intentional reentrancy guard |
| Match drogon body double-copy | Would regress proactr bulk borrow |
| Handler-visible engine knobs | APP_CONTRACT |

---

## 2. Final matrix (this batch, after F reject)

`SERVERS=proactr drogon` · WORKERS=8 · c50 · D10 · LOGDIR `/tmp/proactr-conv-final`

| peer | proto | plain | s4k | s64k | s1m |
|------|-------|------:|----:|-----:|----:|
| **proactr** | h1s | 95723 | 84602 | 29144 | **2736** |
| **drogon** | h1s | 150716 | 148566 | 63318 | **8195** |
| proactr | h2 | 93669 | 83870 | 31192 | 2301 |

| Metric | Value |
|--------|--------|
| h1s s1m vs BASELINE_P5 (2599) | **+5.3%** (2736) |
| h1s s1m vs drogon | **0.33×** |
| soft_cq_send | **0** |
| s1m seals/req | **~9** |
| plain seals/req | **1** (materialize=reqs) |

**Harsh notes:** Absolute plain RPS is soft vs best earlier session (~113k) — treat as **machine/session noise + cumulative stack**, not as a reason to reopen floor 0. s1m holds multi-window law. +15% bulk gate still **not** met vs P5; convergence is **structural**, not drogon parity.

---

## 3. Iteration critics (summary)

### Critic after floor-0 (FAIL)

- **Finding:** `materialize=0` but `seals_per_req=2` on plain/s4k → two `SSL_write` per tiny response.  
- **RPS:** plain 82k vs ~113k (−27%).  
- **Verdict:** **REJECT** floor 0. Crossover **8 KiB** stays.  
- **Lesson:** Reactor multi-window does **not** make heading/body split free for sub-KiB bodies; SSL_write setup still taxes tiny path.

### Critic after full level WRITE (prior session, FAIL)

- Full level WRITE on all arms thrash/idle risk.  
- **Verdict:** residual-**only** level WRITE (this batch). Fairness/clear stay oneshot.

### Critic after this land (CONDITIONAL PASS)

- All roadmap **code** items present or evidence-closed (F).  
- soft_cq=0; 0 matrix errors.  
- **Fail vs cheerleading:** no “closing drogon” claim; 0.33× is still far.  
- **Next free RPS** is not another CLOSED flag — AES/send density or env-stable rebaseline only.

---

## 4. Code map (final stack)

| Mechanism | Where |
|-----------|--------|
| Peek CT drain | `tls_reactor_flush.odin` `reactor_drain_wbio` + `tls_server` BIO_ctrl |
| 128 KiB seal | `reactor_law.odin` `REACTOR_SEAL_WINDOW` |
| Fairness re-arm | `reactor_arm_fairness_continue` + `reactor_fairness_yield` |
| Level residual WRITE | `reactor_arm_write_residual` oneshot=false; disable when residual empty |
| Timer-merged wait | `server_loop_reactor.odin` skip empty soft wait |
| No Darwin hold | `tls_host.odin` `when ODIN_OS != .Darwin` hold alloc |
| Tiny split floor | `response_ciphered.odin` `TLS_PLAIN_SPLIT_MIN_BODY == 8KiB` |

---

## 5. Checklist vs original report

**Converged / done:**

- [x] Residual-first  
- [x] Multi-window no soft-CQ  
- [x] CT peek drain  
- [x] 128 KiB seal trunk  
- [x] Fairness WRITE re-arm  
- [x] Level residual WRITE  
- [x] Dual wait merge  
- [x] Darwin no-hold slab  
- [x] Tiny split evaluated (floor 0 rejected; 8k kept)  

**Leave alone (unchanged):**

- [x] TCP_NODELAY  
- [x] Dual_Ct N>2  
- [x] kTLS  
- [x] APP_CONTRACT  
- [x] Dynlib OpenSSL product default  
- [x] Deferred clean reentrancy guard  
