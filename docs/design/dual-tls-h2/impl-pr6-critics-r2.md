# Implementation Critics — PR6 r2 (multi-axis)

**Posture:** harsh elite. Credit only **claimed PR6 scope**.  
**Bar:** WOW ≥ 9 for **claimed PR6 scope only**:

| Claimed in | Claimed out |
|------------|-------------|
| Progressive stream over TLS H1: windowed `SSL_write`, CT send, **no mid-session** `clean_request_loop` | H2 / M1–M6 |
| Same App Contract (`sse_start` / `ws_start` / Effects) | Live dual-CT seal∥send on wire |
| Hangup: CT recv + `ZERO_RETURN` / TCP0 → `.Client_Gone` **with flight-safe ownership** | Bulk multi‑MiB firehose CI on TLS ring |
| Tests in `session_test` + `tls_host_test`; matrix TLS H1 SSE/WS ✅ | Production “HTTPS complete” for large-body |

**Not required for WOW:** dual-CT live SM, H2 concurrent SSE, bulk firehose product, automated multi-tick ring e2e (manual `https_demo` + structural gates match PR5 oneshot bar).  
**Required for WOW:** R1 **Fatal** hangup double-arm closed; plain/`stream_sent` ownership correct; no mid-session oneshot clean; no plain-send bypass; close defers on CT recv; fail-closed CT drain; docs refuse overclaim outside scope.

**Date:** 2026-08-08  
**Prior:** [`impl-pr6-critics-r1.md`](impl-pr6-critics-r1.md) (Fatal: hangup CT RECV re-arm without flight bit).  
**Subject:** `http/tls_host.odin`, `http/response.odin` (`_session_arm_hangup_watch`), `http/server.odin` (`tls_ct_recv_inflight`, `connection_close`, `host_on_recv`), `http/session_test.odin`, `http/tls_host_test.odin`, docs `{IMPLEMENTATION_STATUS,CAPABILITY_MATRIX,TLS_H1}`.

---

## Verify (this pass)

| Check | Result |
|-------|--------|
| `odin test http -define:ODIN_TEST_THREADS=1 -o:none` | **127/127 pass** (OpenSSL dynlib loaded on this host) |
| `tls_ct_recv_inflight` idempotent arm | **Yes** — `tls_host_arm_recv`: if inflight → `return true` (no second `submit_recv`) |
| Clear on CQE | **Yes** — `host_on_recv` clears before demux; defensive clear in `tls_host_on_recv` |
| Close defers when inflight | **Yes** — `connection_close` sets `close_on_io` when `tls_ct_recv_inflight` |
| `bio_read_net` fail-closed (progressive) | **Yes** — `n <= 0` after `pending > 0` → clear `tls_stream_plain_n`, `tls_host_session_client_gone` (no `stream_sent` advance) |
| Mid-session no `clean_request_loop` | **Yes** — `tls_host_on_send_complete` long-lived branch; OpenSSL unit asserts `stream_open` stays |

No automated TLS SSE ring multi-tick e2e in CI (docs: manual `https_demo` + `curl -kN … /sse` — same honesty split as PR5 oneshot).

---

## R1 → fixed (spot-checked)

| R1 ID | Claim | Evidence | Verdict |
|-------|--------|----------|---------|
| **CQ-F1 / MEM-F1** | Hangup CT RECV re-armed without flight bit; kqueue EV_ADD replaces udata → orphan Recv | `Connection.tls_ct_recv_inflight`; `tls_host_arm_recv` short-circuits when true; set true only after successful `submit_recv`. Multi-tick path: attach arm → flush → mid-idle `_session_arm_hangup_watch` → second arm is idempotent (no second SQE). Tests: `test_tls_ct_recv_inflight_arm_idempotent`, `test_tls_ct_recv_inflight_clear_on_recv`. | **Fixed** |
| **CQ-M3 / MEM-M1** | Close/abort while CT hangup Recv live | `connection_close`: if `tls_ct_recv_inflight` → `close_on_io` (mirror wire). `host_on_recv` clears inflight then honors `close_on_io`. Comment on Connection documents CT flight. Structural test: `test_tls_ct_recv_inflight_close_defers`. | **Fixed** |
| **CQ-M2 / MEM-M2** | `bio_read_net` fail advances `stream_sent` | Progressive `tls_host_stream_try_submit`: fail-closed Client_Gone; does **not** advance plain cursor. | **Fixed** |
| **CQ-M1** | Arm hangup ignores `tls_host_arm_recv` failure | `_session_arm_hangup_watch` now `log.errorf` on fail (no silent `_ =`). Not escalate-to-gone; residual **Minor**. | **Improved → Minor** |
| **HON-M3** | Hangup Done text vs unsafe re-arm | Status / TLS_H1 / matrix name single-flight `tls_ct_recv_inflight`; code matches. | **Fixed** |

R1 progressive skeleton still green: one `_stream_try_submit` divert, no stream_pool on TLS, `tls_stream_plain_n` + `stream_sent` after full CT, App Contract surface unchanged, long_lived demux, docs exclude H2 / dual-CT live / bulk.

---

## Scoreboard

| Axis | Score | WOWED | Worst class |
|------|------:|:-----:|-------------|
| Code quality | **9.1** | **yes** | Minor |
| Performance | **9.0** | **yes** | Minor |
| Memory | **9.2** | **yes** | Minor |
| Shortcuts / honesty | **9.0** | **yes** | Minor |
| **Mean** | **9.1** | — | — |

**Verdict:** R1 **Fatal** (hangup CT double-arm / kqueue orphan) is closed with the correct craft: single-flight bit, CQE clear, close defer, fail-closed CT drain. Claimed progressive scope was already the right architecture; hangup is now safe under multi-tick re-arm. Residuals are minors (no full ring multi-tick CI, arm-fail log-only, structural tests for flight bit, serial dual-CT residual). **All four axes clear WOW (≥9).** Willing: the bar was flight-safe hangup for claimed SSE/WS TLS H1 — that is what landed.

---

## Architecture map (post single-flight hangup)

```text
CLEAR H1 SESSION
  hangup: PIN intentionally no-op

TLS H1 SESSION (PR6 live + r2 flight fix)
  same sse_start / ws_start / Effects
    → _stream_try_submit → tls_host_stream_try_submit
         window plain ≤ PULL_WINDOW
         SSL_write → wBIO → tls_ct_tx → host_submit_send (.Send)
         CQE → tls_host_on_send_complete
           long_lived? advance stream_sent / reflush / arm hangup
           else oneshot clean_request_loop
    hangup: _session_arm_hangup_watch
              → tls_host_arm_recv
                   if tls_ct_recv_inflight: return true   ← single-flight
                   else submit_recv → inflight = true
            host_on_recv: inflight = false first
            peer TCP0 / ZERO_RETURN / unexpected PT → Client_Gone
    close: wire inflight OR tls_ct_recv_inflight → close_on_io

NOT USED ON LIVE PROGRESSIVE PATH
  pipe_seal_step / dual CT[2] / stream_pool slabs
```

---

## 1. Code quality — Score **9.1** / WOWED **yes**

### What is elite for claimed progressive scope

1. **Single-flight CT recv ownership (closes R1 Fatal).** `tls_ct_recv_inflight` is the gen-less armed flag R1 required: arm only if clear; re-arm from mid-idle / attach is safe while a Recv is outstanding; CQE clears before any re-arm path. This is the kqueue discipline the product needed.
2. **Same App Contract, one submit entry.** Handlers keep `sse_start` / `ws_start` / Effects. Ciphered divert has no plain-send bypass.
3. **Long-lived vs oneshot demux.** `tls_host_stream_long_lived` keeps mid-session complete off oneshot `clean_request_loop` — verified under OpenSSL mem-BIO complete path.
4. **Plain ownership.** Seal records `tls_stream_plain_n`; advance only after full CT buffer delivery (partial TCP handled before host complete).
5. **Fail-closed CT drain (CQ-M2).** Progressive path no longer silently advances on `bio_read_net` fail after pending > 0.
6. **Close discipline matches wire send.** CT hangup Recv is first-class for `close_on_io` — destroy/free of `tls_ct_rx` cannot race an outstanding Recv under the normal close path.
7. **Hangup arm failure is visible.** Error log instead of `_ =` (R1 CQ-M1).

### Fatal

**None** under claimed scope.

### Majors

**None** remaining under claimed scope. (R1 CQ-M4 “no SSL_write→CQE integration” softened: OpenSSL mid-session complete + inflight unit gates + ciphered attach tests exist; full multi-tick ring e2e stays a **Minor** residual, same class as PR5 manual curl for oneshot.)

### Minors

| ID | Issue |
|----|--------|
| **CQ-m1** | Arm hangup failure logs only — does not drive Client_Gone / retry. Idle timer + send errors still cover many deaths; hangup watch can be silently absent after submit_recv fail. |
| **CQ-m2** | Connection comment still reads “at most one of {recv, send, close}” while progressive intentionally allows **CT hangup Recv ∥ CT send** (different filters; close waits for both). Comment lag, not a flight bug. |
| **CQ-m3** | Recursion in `tls_host_stream_try_submit` for WANT_WRITE / zero-pending continue — fine for windows; loop would be clearer. |
| **CQ-m4** | No automated multi-tick TLS SSE peer-close on the ring (manual demo only). |
| **CQ-m5** | Package-public host zoo residual (R3/PR5) — not PR6-specific. |

### What would still polish

1. Escalate hangup arm failure on long-lived to Client_Gone after N fails (or force close).  
2. One scripted/demo-smoke or skip-without-OpenSSL multi-event hangup test next to firehose check.  
3. Refresh Connection invariant comment for CT-recv ∥ send.

### WOWED: **yes**

Flight-safe hangup + progressive demux + fail-closed drain is production craft for the claim.

---

## 2. Performance — Score **9.0** / WOWED **yes**

### What is real under claim

| Path | Behavior | Grade |
|------|----------|-------|
| Progressive seal | Window plain ≤ `PULL_WINDOW`, serial SSL_write → one `tls_ct_tx` | **Correct serial progressive** |
| Clear session compare | Clear copies slabs; TLS encrypts from `resp_buf` view | **TLS avoids pool copy** |
| Backpressure | Session drop when unsent > max_stream_buffer; Writable refill | **Same as clear** |
| Mid-session idle | One hangup CT arm (idempotent re-arm) + timers | **No kqueue thrash on re-arm** |
| Compaction | `_stream_compact_delivered` after advance | **RSS hygiene** |

R1 PERF-m4 (double hangup arm wastes kevent updates every mid-idle complete) is **gone** — second arm is a bool check.

### Fatal / Majors

**None** for performance under claimed scope.

### Minors

| ID | Issue |
|----|--------|
| **PERF-m1** | No PT high-water on progressive path — session buffer cap only. Out of bulk claim. |
| **PERF-m2** | Serial seal only — dual-CT seal∥send remains PR5.1/PR6.x residual (explicitly out). |
| **PERF-m3** | Heartbeat flush → full seal/CQE per tiny SSE frame; acceptable v1. |

### WOWED: **yes**

Serial progressive physics are the right claim; hangup is now free (idempotent) rather than a changelist tax.

---

## 3. Memory — Score **9.2** / WOWED **yes**

### What is solid

1. **No stream_pool on TLS progressive** — encrypt-in-place from `resp_buf`.  
2. **`tls_stream_plain_n` lifecycle** — set on seal, clear on advance / destroy / fail paths.  
3. **Compact after delivery** for long-lived sessions.  
4. **CT scratch O(1)** — fixed rx/tx bags per conn.  
5. **Flight bit + close defer** — no free of `tls_ct_rx` under outstanding Recv on the product close path; no orphaned Recv slots from double-arm.  
6. **Fail-closed drain** — no soft wBIO leak from silent plain advance.

### Fatal / Majors

**None.** R1 MEM-F1 / MEM-M1 / MEM-M2 closed by the same three fixes as CQ.

### Minors

| ID | Issue |
|----|--------|
| **MEM-m1** | `probe: [512]u8` stack in `tls_host_stream_ct_recv` — fine. |
| **MEM-m2** | Progressive TLS still skips `pt_admit` peak metrics — observability only. |
| **MEM-m3** | Concurrent CT recv + send means two outstanding ring ops; ownership is correct; peak op slots per conn is 2 not 1 during active flush-with-hangup-still-armed (if hangup left armed across submit_send). Intentional; not a leak. |

### WOWED: **yes**

Buffer model was already clean; flight ownership for hangup Recv now matches.

---

## 4. Shortcuts / honesty — Score **9.0** / WOWED **yes**

### What is honest

1. **Scope exclusions hold.** IMPLEMENTATION_STATUS / TLS_H1 / CAPABILITY_MATRIX refuse live dual-CT, bulk firehose CI, H2/M6.  
2. **Hangup packaging matches code.** Single-flight named in status, matrix TLS note, TLS_H1 hangup row — no longer selling a broken re-arm machine.  
3. **Manual vs CI split stated.** Unit gates + manual `curl -kN … /sse`; CI same-handler TLS job still Not yet.  
4. **No fake dual-CT** on progressive path.  
5. **https_demo `/sse`** remains the live App Contract proof path.

### Fatal / Majors

**None.** R1 HON-M3 closed with the flight fix. HON-M1 matrix ✅ is no longer “ahead of unsafe hangup”; remaining proof gap is automated multi-tick (accepted as Minor under PR5 oneshot precedent of manual curl + unit gates).

### Minors

| ID | Issue |
|----|--------|
| **HON-m1** | Some “PR6 gates” still document arithmetic (`test_tls_stream_plain_n_cqe_advance_semantics`) without calling production complete — accompanied by real `tls_host_on_send_complete` OpenSSL test and inflight tests. Soft. |
| **HON-m2** | SESSION_SSE title “SSE first, WebSocket later” may still lag WS-TLS Done packaging. |
| **HON-m3** | No `check_tls_sse.sh` presence gate analogous to `check_firehose_pipe.sh`. |
| **HON-m4** | Connection “at most one SQE” comment slightly understates CT-recv ∥ send — docs elsewhere are clearer. |

### WOWED: **yes**

Docs refuse the big lies; hangup Done is earned by flight-safe code, not intention text.

---

## Cross-axis issue index (r2)

| ID | Class | Axis | One-line |
|----|-------|------|----------|
| CQ-m1 | Minor | CQ | Hangup arm fail → log only |
| CQ-m2 / HON-m4 | Minor | CQ, HON | Comment: at-most-one SQE vs CT-recv ∥ send |
| CQ-m4 / HON-m3 | Minor | CQ, HON | No automated multi-tick TLS SSE / peer-close CI |
| PERF-m* / MEM-m* / HON-m* | Minor | various | See sections |
| ~~CQ-F1 / MEM-F1~~ | ~~Fatal~~ | — | **Closed** — `tls_ct_recv_inflight` |
| ~~CQ-M2 / MEM-M2~~ | ~~Major~~ | — | **Closed** — fail-closed progressive drain |
| ~~CQ-M3 / MEM-M1~~ | ~~Major~~ | — | **Closed** — close defers on CT recv |
| ~~HON-M3~~ | ~~Major~~ | — | **Closed** — hangup text matches flight-safe code |

---

## R2 residuals (optional polish; not WOW blockers)

1. Escalate or hard-fail long-lived hangup arm failure (CQ-m1).  
2. Scripted multi-tick / peer-close smoke (even skip-without-OpenSSL).  
3. Align Connection in-flight comment with CT-recv ∥ send reality.  
4. Prefer production-proc tests over pure arithmetic mirrors where cheap.

---

## Bottom line

PR6 r1 had the **right progressive skeleton** and a **Fatal hangup ownership hole**. r2 closes that hole with `tls_ct_recv_inflight` (idempotent arm, CQE clear, close defer), plus fail-closed CT drain and visible hangup arm errors. Suite is **127/127**.  

Claimed scope — SSE/WS on TLS H1 progressive stream + flight-safe hangup — is met at elite craft for this codebase’s phase bar. Bulk firehose, dual-CT live seal∥send, and H2 remain correctly out.

**Mean 9.1 / four-axis WOW: yes.**
