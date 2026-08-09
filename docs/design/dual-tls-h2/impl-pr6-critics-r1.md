# Implementation Critics — PR6 r1 (multi-axis)

**Posture:** harsh elite. Credit only **claimed PR6 scope**.  
**Bar:** WOW ≥ 9 for **claimed PR6 scope only**:

| Claimed in | Claimed out |
|------------|-------------|
| Progressive stream over TLS H1: windowed `SSL_write`, CT send, **no mid-session** `clean_request_loop` | H2 / M1–M6 |
| Same App Contract (`sse_start` / `ws_start` / Effects) | Live dual-CT seal∥send on wire |
| Hangup: CT recv + `ZERO_RETURN` / TCP0 → `.Client_Gone` | Bulk multi‑MiB firehose CI on TLS ring |
| Tests in `session_test` + `tls_host_test`; matrix TLS H1 SSE/WS ✅ | Production “HTTPS complete” for large-body |

**Not required for WOW:** dual-CT live SM, H2 concurrent SSE, bulk firehose product.  
**Required for WOW:** hangup path is safe under multi-tick sessions; plain/`stream_sent` ownership correct; no mid-session oneshot clean; no plain-send bypass; docs refuse overclaim; tests prove something real about the ciphered stream path (not only flag arithmetic).

**Date:** 2026-08-08  
**Prior:** PR5 r2 closed oneshot + sever (`impl-pr5-critics-r2.md`).  
**Subject:** `http/tls_host.odin` (stream submit / CT recv / on_send_complete), `http/response.odin` (`_stream_try_submit`, hangup arm), `http/session.odin` / `session_ws.odin`, `http/wire.odin`, `http/session_test.odin`, `http/tls_host_test.odin`, `examples/https_demo`, `docs/{IMPLEMENTATION_STATUS,CAPABILITY_MATRIX,SESSION_SSE,TLS_H1}.md`.

---

## Verify (this pass)

| Command | Result |
|---------|--------|
| `odin test http -define:ODIN_TEST_THREADS=1 -o:none` | **124/124 pass** (OpenSSL dynlib loaded on this host) |

No automated TLS SSE ring e2e in CI (docs: manual `https_demo` + `curl -kN … /sse` only).

---

## Scoreboard

| Axis | Score | WOWED | Worst class |
|------|------:|:-----:|-------------|
| Code quality | **6.8** | **no** | **Fatal** (hangup re-arm) |
| Performance | **8.0** | **no** | Minor |
| Memory | **7.2** | **no** | Major (orphaned Recv / buffer race class) |
| Shortcuts / honesty | **7.6** | **no** | Major (matrix ✅ on paper gates) |
| **Mean** | **7.4** | — | — |

**Verdict:** PR6 has the **right skeleton** for claimed scope: one entry (`_stream_try_submit` → `tls_host_stream_try_submit`), no clear pool slabs on ciphered path, `tls_host_stream_long_lived` blocks oneshot `clean_request_loop`, plain cursor `tls_stream_plain_n` + `stream_sent`, App Contract surface unchanged, docs correctly exclude H2 / dual-CT / bulk. That is real engineering, not a flag flip.

**WOW is withheld on all four axes** because the claimed hangup path re-arms CT `RECV` without an in-flight guard. On kqueue (this product’s Darwin façade), a second `EVFILT_READ` **overwrites udata** and **orphans** the prior Recv op — the multi-tick SSE happy path (attach arm → flush → mid-idle re-arm) hits this. That is a Fatal craft failure under the hangup claim, not a polish nit. Tests mostly assert structure / hand-rolled arithmetic; matrix TLS H1 SSE/WS ✅ is ahead of ring-proven evidence.

---

## Architecture map (what owns progressive TLS stream)

```text
CLEAR H1 SESSION
  sse_start / ws_start
    → effects write frames into resp_buf
    → _stream_try_submit
         stream_pool slab copy → wire.kind=.Stream → CQE advances stream_sent
    hangup: PIN intentionally no-op (idle + send error only)

TLS H1 SESSION (PR6 live)
  same sse_start / ws_start / Effects  (no handler #if)
    → effects write same plain frames into resp_buf
    → _stream_try_submit
         if ciphered || tls_ssl:
           tls_host_stream_try_submit
             window resp_buf[stream_sent:] ≤ PULL_WINDOW
             SSL_write → wBIO → tls_ct_tx → host_submit_send (.Send)
             CQE → tls_host_on_send_complete
               long_lived? advance stream_sent by tls_stream_plain_n
                           reflush / arm hangup / _stream_finish
               else oneshot clean_request_loop
    hangup: _session_arm_hangup_watch → tls_host_arm_recv (CT)
            peer TCP0 / ZERO_RETURN / unexpected PT → Client_Gone

NOT USED ON LIVE PROGRESSIVE PATH
  pipe_seal_step / dual CT[2] / stream_pool slabs
```

**Grep facts:**

- `_stream_try_submit` ciphered branch is a hard divert — no plain `pending_send` of `resp_buf` under TLS.
- `tls_host_on_send_complete` long-lived branch never calls `clean_request_loop` mid-session (ending → `_stream_finish` only).
- Hangup arm has **no** `ct_recv_armed` / gen counter (contrast clear PIN which at least had `stream_pin_armed` when it existed).

---

## 1. Code quality — Score **6.8** / WOWED **no**

### What is elite for claimed progressive scope

1. **Same App Contract, one submit entry.** Handlers keep `sse_start` / `ws_start` / Effects. `_stream_try_submit` routes ciphered/ssl to host seal — no second public API, no plain-send bypass. That is the correct dual-path law.
2. **Long-lived vs oneshot demux is explicit.** `tls_host_stream_long_lived` (`stream_open || session`) gates CT complete away from oneshot `clean_request_loop`. Mid-session clean is the bug this PR exists to prevent; the gate is the right shape.
3. **Plain ownership model is readable.** Seal records `tls_stream_plain_n`; only after **full** CT buffer delivery (partial TCP handled in `_host_on_wire_send` before host complete) does `stream_sent` advance. Multi-record wBIO for one seal: drain remaining CT before advance — correct serial ownership.
4. **No stream_pool on TLS.** Encrypt-from-`resp_buf` view; slab path stays clear-only. Fail-closed when `ciphered` without `tls_ssl` (`stream_flush_pending`, no pool take) — tested.
5. **Hangup semantics surface is complete on paper.** TCP0, SSL hard error, `ZERO_RETURN`, unexpected app data while session owns wire → `tls_host_session_client_gone` → `.Client_Gone` (+ metrics / abort). Attach sites (`sse_start`, `ws_start`) and mid-idle complete both call `_session_arm_hangup_watch`.
6. **Wire kind honesty.** Progressive TLS deliberately stays `.Send` so completion hits `tls_host_on_send_complete` (not clear `_host_on_wire_stream`). Comment in submit path documents why — good.
7. **Session apply stays protocol-agnostic.** Effects still format SSE/WS into plain `resp_buf`; backpressure (`SESSION_MAX_STREAM_BUFFER`) still drops payloads and sets `want_writable`. Cipher is host-only.

### Fatal

| ID | Issue | Evidence |
|----|--------|----------|
| **CQ-F1** | **Hangup CT RECV re-armed without in-flight ownership.** Multi-tick TLS SSE: attach arms CT recv → effects flush → send CQE mid-idle → `_session_arm_hangup_watch` arms **again** while the first Recv is still pending. | `_session_arm_hangup_watch` only gates `_conn_wire_in_flight` (**send** kind). `tls_host_arm_recv` always `submit_recv` into `tls_ct_rx` — no armed flag/gen. On Darwin kqueue, `_kq_arm` is `EV_ADD|EV_ONESHOT` per fd+filter; a second arm **replaces udata** → prior Recv op **never CQEs** (orphaned Submitted slot) and hangup may bind the wrong op. Happy path of `https_demo` `/sse` (Start + N timers) is multi-arm. Clear H1 disabled PIN *because* concurrent recv without cancel is unsafe; PR6 reintroduced concurrent CT recv **and** forgot re-arm discipline. |

This is Fatal under **claimed hangup**, not an out-of-scope bulk complaint. Matrix “SSE on TLS H1 ✅” and SESSION_SSE hangup text both sell CT recv → Client_Gone as product law.

### Majors

| ID | Issue |
|----|--------|
| **CQ-M1** | `_session_arm_hangup_watch` ignores arm failure: `_ = tls_host_arm_recv(conn)`. Silent hangup loss (idle timer + send errors only — same as clear — while docs claim CT hangup). |
| **CQ-M2** | `bio_read_net` `n <= 0` after `pending > 0` in `tls_host_stream_try_submit` treats as “no CT” and **advances `stream_sent`**. That can drop ciphertext still in wBIO / desync plain vs peer. Fail-closed would be Client_Gone or retry, not silent advance. |
| **CQ-M3** | `connection_close` defers only on **wire send** in-flight, not outstanding CT recv. Session abort / finish can `submit_close` while hangup Recv is still live — violates the host’s own “at most one of {recv, send, close}” comment under the new always-armed hangup model. |
| **CQ-M4** | Progressive path has no ring-level regression that seals plain → CT CQE → `stream_sent` with a real `SSL` + mem-BIO write. The one OpenSSL test (`test_tls_host_on_send_complete_mid_session_no_clean`) only exercises **complete with pre-set `tls_stream_plain_n`**, not `SSL_write` + drain + CQE. |

### Minors

| ID | Issue |
|----|--------|
| **CQ-m1** | Recursion in `tls_host_stream_try_submit` (WANT_WRITE / zero-pending continue) is fine for small windows; a loop would be clearer under pathological OpenSSL buffering. |
| **CQ-m2** | `tls_host_session_client_gone` vs `host_on_wire` send-error both drive Client_Gone; metrics can double-count depending on path — observability noise. |
| **CQ-m3** | Submit-send failure on TLS stream drives Client_Gone only if `session != nil`; bare progressive stream (no session) relies on `_wire_fail` alone — OK but asymmetric. |
| **CQ-m4** | Package-public host zoo residual (R3/PR5) — not PR6-specific. |

### What would WOW

1. **Single-flight CT recv ownership:** `tls_ct_recv_armed` / gen (like PIN gen), arm only if clear; re-arm only from CT CQE path (`tls_host_stream_ct_recv` / error), never blind re-arm from send complete. Or cancel-before-rearm if the platform gains portable cancel.
2. Close/abort waits for CT recv CQE or cancels it — same discipline as wire send `close_on_io`.
3. Integration test: mem-BIO client+server or demo harness — multi-event SSE, peer close mid-session, assert one Client_Gone and no orphaned ops.
4. Fail-closed on CT drain failure (no silent `stream_sent` advance).

### WOWED: **no**

Skeleton is strong; hangup arming is not production craft.

---

## 2. Performance — Score **8.0** / WOWED **no**

### What is real under claim

| Path | Behavior | Grade |
|------|----------|-------|
| Progressive seal | Window plain ≤ `PULL_WINDOW` (64 KiB), serial SSL_write → one `tls_ct_tx` | **Correct serial progressive** (dual-CT out of scope) |
| Clear session compare | Clear copies into `STREAM_BUF` slabs; TLS encrypts in place from `resp_buf` | **TLS avoids pool copy** — good |
| Backpressure | Session drops frames when unsent > `max_stream_buffer` (default 64 KiB); `Writable` refill | **Same as clear** — real |
| Mid-session idle | Hangup CT arm + timers; no busy spin | **Intentional** |
| Compaction | `_stream_compact_delivered` after advance (sessions always; non-session ≥1 KiB) | **RSS hygiene** |

Claimed scope does **not** require dual-CT seal∥send or bulk firehose. Serial windowing matching oneshot is the right PR6 physics.

### Fatal

**None** for performance under claimed scope (no O(n²) seal, no unbounded busy loop found).

### Majors

**None** as pure performance majors. (CQ-F1 is correctness; it can also thrash kqueue changelist / leak op slots — counted under quality/memory.)

### Minors

| ID | Issue |
|----|--------|
| **PERF-m1** | No PT high-water (`pt_admit`) on progressive path — relies on session buffer cap only. Fine for 64 KiB frames; large `stream_*` progressive TLS bodies can hold full unsent plain in `resp_buf` until compact. Out of bulk claim but worth naming. |
| **PERF-m2** | Each seal is one SSL_write ≤ 64 KiB then full CT drain before next plain — no dual seal∥send (explicitly out). Residual for PR5.1/PR6.x. |
| **PERF-m3** | Heartbeat-driven flush → full seal/CQE round-trip even for tiny SSE frames; no Nagle-style coalesce beyond effect batching in one drive. Acceptable for v1. |
| **PERF-m4** | Double hangup arm (F1) wastes kevent updates on every mid-idle complete. |

### What would WOW

1. Fix F1 so hangup is one armed Recv for the life of idle gaps (zero redundant arms).  
2. Optional micro-batch: if more plain appears before CT CQE, do not start a second mental path — already serial; document TTFB / ticks-per-sec on demo.  
3. Benchmark note in `BENCHMARKS` or design: progressive TLS SSE tick latency vs clear (honest serial tax).

### WOWED: **no**

Solid serial design for the claim, but nothing elite was proven or instrumented; F1 shadow spoils “hangup is free.”

---

## 3. Memory — Score **7.2** / WOWED **no**

### What is solid

1. **No stream_pool on TLS progressive.** Ciphered-no-ssl test asserts `stream_send_slab == nil`. Avoids dual ownership of plain slabs + CT.
2. **`tls_stream_plain_n` lifecycle.** Set on seal, cleared on advance / destroy / stream finish / clean_request_loop. Destroy zeros field (`tls_host_conn_destroy`).
3. **Compact after delivery** for sessions so long-lived SSE does not retain full history in `resp_buf`.
4. **Session scratch** for framing after `conn_temp_detach` — same as clear; no 4.5 MiB request arena held for session life.
5. **CT scratch sizes fixed:** `TLS_CT_RX_DEFAULT` 16 KiB, `TLS_CT_TX_DEFAULT` = pull window — O(1) network bags per conn, not O(body).
6. **Submit-send fail** clears `pending_send` and `tls_stream_plain_n` before fail path — no dangling alias into `tls_ct_tx` after free if destroy follows.

### Fatal

| ID | Issue |
|----|--------|
| **MEM-F1** | Same root as **CQ-F1**: orphaned Recv operations (kqueue udata replace) leak ring Operation slots for connection lifetime; second arm + first buffer both target `tls_ct_rx` — class of concurrent buffer use if a platform ever dual-completes. Memory **and** lifetime safety. |

### Majors

| ID | Issue |
|----|--------|
| **MEM-M1** | Close while CT hangup Recv outstanding (CQ-M3): destroy path can free `tls_ct_rx` / SSL under an outstanding Recv if close wins the race without `close_on_io` for recv. Clear path avoided this by **not** arming PIN; PR6 arms CT continuously. |
| **MEM-M2** | Silent `stream_sent` advance on failed CT read (CQ-M2) can leave wBIO CT resident while app thinks plain is delivered — soft leak of BIO memory until next drain/close. |

### Minors

| ID | Issue |
|----|--------|
| **MEM-m1** | `probe: [512]u8` stack in `tls_host_stream_ct_recv` — fine; unexpected PT still allocates no heap. |
| **MEM-m2** | Progressive TLS never uses `pt_admit` peak metrics — observability gap only. |
| **MEM-m3** | Soft shrink of `resp_buf` for sessions is good; optional tighter cap under TLS still free. |

### What would WOW

1. Recv flight bit + destroy/close defers until CT CQE (mirror send `close_on_io`).  
2. Stress test: open N TLS SSE sessions, multi-tick, peer RST, assert zero op-slot growth and clean free of `tls_ct_*`.  
3. Keep encrypt-in-place + compact — already the right shape.

### WOWED: **no**

Buffer model for plain/CT is clean; flight ownership for hangup Recv is not.

---

## 4. Shortcuts / honesty — Score **7.6** / WOWED **no**

### What is honest

1. **Scope exclusions are real in docs.** IMPLEMENTATION_STATUS / TLS_H1 / CAPABILITY_MATRIX refuse live dual-CT, bulk firehose CI, H2/M6. PR6 row does not claim seal∥send Done on wire.
2. **Manual vs CI split is stated.** Status lists unit gates + manual `curl -kN … /sse`; “CI same-handler TLS job” still Not yet.
3. **Clear PIN disabled** is still documented; ciphered hangup is described as the compensating path — intention is honest even if implementation is unsafe (F1).
4. **https_demo `/sse`** exists with same App Contract — not a paper-only API.
5. **No fake dual-CT** on progressive path — continues PR5 sever (no zombie seal_q on live Open).

### Fatal

**None** as pure doc fraud. Matrix ✅ is aggressive packaging, not a silent lie about H2.

### Majors

| ID | Issue |
|----|--------|
| **HON-M1** | **Matrix TLS H1 SSE/WS ✅ and “Done” packaging overshoot evidence.** Product cells are green while automated proof is: flag gates, plain effect apply under `ciphered` without SSL, long_lived bool, hand-simulated `stream_sent += plain_n`, one OpenSSL complete without prior `SSL_write`. That is **not** the same bar PR5 used for oneshot (curl green called out as verify). Selling Phase 2 author-ready SSE-on-TLS without ring hangup/e2e is a honesty Major under this project’s own matrix rules (“until a cell is ✅, do not market”). |
| **HON-M2** | Tests that **reimplement** production arithmetic (`test_tls_stream_plain_n_cursor`, `test_tls_stream_plain_n_cqe_advance_semantics`) do not call `tls_host_on_send_complete` / try_submit — they document intent. Calling them “PR6 gates” in IMPLEMENTATION_STATUS is soft oversell. |
| **HON-M3** | Hangup claim (CT recv → Client_Gone) is marketed as Done while re-arm is broken on the primary progressive path — docs describe the **intended** machine, not the **safe** one. |

### Minors

| ID | Issue |
|----|--------|
| **HON-m1** | SESSION_SSE still titled “SSE first, WebSocket later” while WS TLS is claimed Done — stale title. |
| **HON-m2** | “Same App Contract” is true for start/effects; inbound WS frames remain non-goals (unexpected PT → Client_Gone) — fine if SESSION docs keep “send-oriented v1”, slightly sharp for “WS product.” |
| **HON-m3** | No `check_tls_sse.sh` presence gate analogous to `check_firehose_pipe.sh` for pure pipe. |

### What would WOW

1. Keep matrix ✅ only after: (a) F1 fixed, (b) automated multi-tick TLS SSE + peer-close Client_Gone, (c) no orphaned Recv under stress. Until then matrix ⏳ or “engineering Done / product ⏳”.  
2. Tests call production procs, not copy their formulas.  
3. One CI job or scripted demo smoke (even skip-without-OpenSSL) next to firehose check.

### WOWED: **no**

Docs refuse the big lies (H2, dual-CT live, bulk). They still mint a matrix green for a hangup path that is not flight-safe and for tests that are mostly structural.

---

## Cross-axis issue index (r1)

| ID | Class | Axis | One-line |
|----|-------|------|----------|
| **CQ-F1 / MEM-F1** | Fatal | CQ, MEM | Hangup CT RECV re-arm without flight bit; kqueue orphans prior op |
| **CQ-M1** | Major | CQ | Arm hangup ignores `tls_host_arm_recv` failure |
| **CQ-M2** | Major | CQ, MEM | `bio_read_net` fail advances `stream_sent` |
| **CQ-M3 / MEM-M1** | Major | CQ, MEM | Close/abort vs outstanding CT recv not deferred |
| **CQ-M4** | Major | CQ | No SSL_write→CQE progressive integration test |
| **HON-M1** | Major | HON | Matrix SSE/WS TLS ✅ ahead of ring-proven hangup/e2e |
| **HON-M2** | Major | HON | “PR6 gates” include hand-rolled arithmetic tests |
| **HON-M3** | Major | HON | Hangup Done text vs unsafe re-arm |
| PERF-m* / CQ-m* / MEM-m* / HON-m* | Minor | various | See sections |

---

## R1 fix order (minimum for re-review / WOW attempt)

1. **Flight-safe hangup Recv** (closes CQ-F1, MEM-F1, much of MEM-M1): armed flag/gen; arm only if clear; re-arm only after CT CQE / explicit clear; never from send-complete if already armed.  
2. **Close defers for CT recv** (or cancel) — same class as wire `close_on_io`.  
3. **Fail-closed CT drain** (CQ-M2).  
4. **Real tests:** SSL_write seal + simulated/full CQE advance; multi-arm stress (assert single armed recv); peer close → one Client_Gone.  
5. **Honesty:** either fix then keep matrix ✅, or demote matrix / status language until (1–4) land.

---

## Bottom line

PR6 is **not vaporware**. The progressive TLS entry, long-lived send-complete gate, plain/`stream_sent` cursor, no-slab cipher path, and App Contract preservation are the right architecture for “SSE/WS on TLS H1 without H2.”  

It is also **not WOW**. The hangup story — the differentiator called out in every status doc — re-arms CT recv the way clear PIN was deliberately *not* allowed to, and the kqueue façade makes that a hard orphan bug on the multi-tick path. Tests and matrix packaging run ahead of that reality.

**Mean 7.4 / four-axis WOW: no.** Re-review only after Fatal hangup flight ownership is closed and at least one non-paper progressive TLS test exists.
