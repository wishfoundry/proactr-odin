# proactr vs drogon — TLS H1 path compare (Darwin reactor · bulk + tiny)

**Date:** 2026-08-09  
**Anchor:** `BASELINE_P5.md` (SHA `c93ddb8`) · host MBP · WORKERS=8 · h2load `-c 50 -D 10`  
**Scoreboard:** h1s s1m **0.30×** drogon (2599 / 8612); h1s plaintext **0.74×** (111730 / 150542)  
**Busy bulk profile (proactr sample):** non-kevent tops ≈ **send 46% / AES-GCM 30% / memmove 20%**  
**Constraint:** APP_CONTRACT frozen · no CLOSED_RPS_FLAGS reopen without NEW LAW · no kTLS as fair fix  

**Method:** source read of live paths (not guesswork).

| Side | Primary files |
|------|----------------|
| proactr | `http/tls_reactor_flush.odin`, `http/io_reactor_kqueue.odin`, `http/server_loop_reactor.odin`, `http/reactor_law.odin`, `http/tls_oneshot.odin`, `http/response_ciphered.odin`, `http/response_materialize.odin`, `http/wire.odin`, `http/tls_host.odin`, `tls_server/provider_openssl_dynlib.odin` |
| drogon/trantor | `third_party/drogon/trantor/.../OpenSSLProvider.cc` (`sendData`/`sendTLSData`), `TLSProvider.h` (`writeBuffer_` residual), `TcpConnectionImpl.cc` (`writeCallback`/`writeRaw`/`writeInLoop`), `poller/KQueue.cc`, `lib/src/HttpResponseImpl.cc` (`renderToBuffer`), `lib/src/HttpServer.cc` (`sendResponse`), matrix peer `comparisons/tls-h2/drogon/main.cc` |

---

## 1. Executive summary

1. **Bulk multi-window law is largely converged.** proactr Darwin `reactor_tls_flush` already does residual-first → `SSL_write(64 KiB)` → drain wBIO → `write` until EAGAIN → single residual WRITE re-arm; duty shows `soft_cq_send=0`, `windows/turn≈17` on s1m (≈ one turn per MiB response).  
2. **0.30× is not “still one CQE per seal.”** P5 killed façade soft-CQ between windows; remaining gap is **per-byte encrypt+send+copy cost** and **event/idle structure**, not the old dual-CT promote soup.  
3. **Drogon’s weapon is encrypt→socket density under level-triggered write**, with residual gate identical in spirit (`getBufferedData().readableBytes()==0` before next `SSL_write`).  
4. **Biggest structural CT copy delta:** drogon `sendTLSData` uses **`BIO_get_mem_data` (peek) + `write` + `BIO_reset`**, and only **appends residual** on partial; proactr **`BIO_read` → `dual_ct.tx` (always copy) → `host_try_send_nb`**. Matches bulk memmove ~20%. *BIO peek as a named CLOSED flag package stays closed; reduction must be NEW-LAW-shaped or alternative.*  
5. **Body physics already favor proactr on bulk:** ≥8 KiB borrowed Static/Bytes (`response_ciphered.odin`); drogon `setBody` + `renderToBuffer` **double-copies** the full 1 MiB plain before `SSL_write` — and still wins. Density > body zero-copy.  
6. **Tiny H1 gap (0.74×) is different:** full materialize every request (`materialize==reqs`), parse/route, oneshot READ re-arm; not multi-window AES.  
7. **Event model:** proactr **EV_ONESHOT** per R/W; drogon **level-triggered** EV_ADD/ENABLE until disable. Extra kevent change tax on residual arms; low EAGAIN on s1m mutes it, still relevant for mid-bulk / backpressure.  
8. **Wait model:** proactr worker = `ring_wait(soft timers)` + **separate** reactor `kevent`; drogon = one `EventLoop` poll. Dual wait is honest (D5 timers) but not free.  
9. **Do not reopen:** Dual_Ct N>2, H1 dense soft-CQ, 1 MiB seal as flag, TCP_NODELAY, kTLS, BIO_peek_package-as-RPS without NEW LAW.  
10. **First free cut (recommended):** seal-window **64 vs 128 KiB A/B under reactor law** — cheapest, baseline-licensed, APP_CONTRACT-safe, mirrors drogon trunk experiment without reopening closed density flags.

---

## 2. End-to-end path sketches

### 2.1 proactr Darwin TLS H1 bulk (s1m)

```text
respond → response_send_got_body
  → ciphered_oneshot_plan (≥8KiB Borrowed Static)
       → response_send_ciphered_heading_body  # heading → resp_buf; body view borrowed
  → tls_host_flush_response (Darwin oneshot)
       → reactor_tls_flush
            loop:
              residual_first: reactor_write_residual → EAGAIN? reactor_arm_write_residual
              else drain wBIO: reactor_drain_wbio  # BIO_read → dual_ct.tx → host_try_send_nb
              else if plain==0: reactor_finish_oneshot → reactor_defer_clean
              else fairness? return (H1: no WRITE re-arm today)
              else reactor_ssl_write_window(64KiB) → SSL_write
              → reactor_drain_wbio again
  EVFILT_WRITE oneshot → reactor_on_writable → residual drain → reactor_on_send_complete
       → reactor_tls_flush again
  end turn: reactor_drain_deferred_clean → clean_request_loop → arm next READ
```

Key symbols:

| Step | Symbol | File (approx) |
|------|--------|----------------|
| Policy | `ciphered_oneshot_plan` / `response_send_ciphered_heading_body` | `response_ciphered.odin` |
| Entry | `tls_host_flush_response` → `reactor_tls_flush` | `tls_oneshot.odin` ~109–122; `tls_reactor_flush.odin` ~19–190 |
| Window | `REACTOR_SEAL_WINDOW` = 64 KiB | `reactor_law.odin` ~5–6 |
| Drain | `reactor_drain_wbio` / residual | `tls_reactor_flush.odin` ~322–373; `io_reactor_kqueue.odin` ~44–111 |
| Send | `host_try_send_nb` (`posix.send`) | `wire.odin` ~158–187 |
| Arm | `reactor_arm_write_residual` (EV_ONESHOT WRITE) | `io_reactor_kqueue.odin` ~385–413 |
| Wait | `server_reactor_worker_loop` / `reactor_wait` | `server_loop_reactor.odin`; `io_reactor_kqueue.odin` ~653+ |

### 2.2 drogon TLS H1 bulk (same matrix routes)

```text
handler setBody(P_1M) → cb(resp)
  → HttpServer::sendResponse
       → HttpResponseImpl::renderToBuffer()  # headers+Date+full body append
       → TcpConnection::send(MsgBuffer)
            → sendInLoop → writeInLoop → OpenSSLProvider::sendData
                 while hasSent < len && writeBuffer_ empty:
                   SSL_write(trunk ≤ 64KiB)
                   sendTLSData:
                     BIO_get_mem_data(wbio)   # peek, no BIO_read copy
                     write(fd, data, len)
                     if partial: appendToWriteBuffer(remainder)
                     BIO_reset(wbio)
                 if residual: enableWriting (level)
  POLLOUT → writeCallback → sendBufferedData (residual first)
           → sendNodeInLoop more plain → sendData again
```

Key symbols:

| Step | Symbol | File (approx) |
|------|--------|----------------|
| Body | `setBody` / `renderToBuffer` | `HttpResponseImpl.cc` ~812–930; matrix `main.cc` ~32–40 |
| Send entry | `TcpConnectionImpl::writeInLoop` → `tlsProviderPtr_->sendData` | `TcpConnectionImpl.cc` ~765–774 |
| SSL loop | `OpenSSLProvider::sendData` maxSend **64 KiB** | `OpenSSLProvider.cc` ~532–560 |
| CT out | `sendTLSData` **BIO_get_mem_data** + residual | `OpenSSLProvider.cc` ~731–749 |
| Residual | `TLSProvider::writeBuffer_` / `sendBufferedData` | `TLSProvider.h` ~51–84 |
| Write event | `writeCallback` level POLLOUT | `TcpConnectionImpl.cc` ~204–257 |
| kqueue | `KQueue::update` **EV_ADD\|EV_ENABLE**, no oneshot | `KQueue.cc` ~171–228 |

---

## 3. Full divergence table

| Area | proactr | drogon | Impact on bulk / tiny | Converge? How? |
|------|---------|--------|----------------------|----------------|
| **Event model** | Per-worker **reactor kqueue**; filters **EV_ONESHOT** (`reactor_arm_filter`); separate proactr kq for timers | trantor **level-triggered** kqueue/epoll; WRITE stays until `disableWriting` | Bulk: muted when `eagain_arms` low; mid-bulk/backpressure: more kevent changes + idle. Tiny: extra oneshot re-arm per req R/W | **Partial.** Level-triggered residual WRITE only (or EV_CLEAR carefully) is structure convergence; keep APP_CONTRACT (no handler exposure). Not dual-CT. |
| **Write residual buffer** | Single region **in `dual_ct.tx[off:off+n]`** (`reactor_res_*`); no growable chain | `TLSProvider::writeBuffer_` (MsgBuffer) holds **only unsent CT remainder**; growable | Bulk: both residual-first. proactr residual lives in fixed slab (good). drogon residual is post-peek copy of partial only | **Already law-converged** (D3 single residual). Leave shape; optionally avoid re-copying residual on re-arm (`pending_send` already views residual). |
| **SSL_write window & loop** | `REACTOR_SEAL_WINDOW` **64 KiB**; multi-window in one flush until residual/EAGAIN/fairness | `maxSend = 64*1024` in `sendData`; loop while residual empty | **Bulk law matched.** s1m ≈17 seals/req both. Further: **128 KiB A/B** (baseline-licensed); **not** 1 MiB flag | **Yes — A/B 64→128.** Files: `reactor_law.odin` `REACTOR_SEAL_WINDOW`; gates in BASELINE_P5 §4. |
| **Residual-first / no seal while residual** | `reactor_may_ssl_write` / residual branch before SSL_write | `sendData` returns EAGAIN if `getBufferedData()!=0`; writeCallback drains residual first | **Converged.** Correctness law; not an RPS hole | **Leave alone** (R-ORDER). |
| **BIO / CT buffer strategy** | **Always `BIO_read` → dual_ct.tx** then `send`; slab `TLS_CT_SLAB_DEFAULT` = 256 KiB+16 KiB (oversized for 64 KiB seal) | **`BIO_get_mem_data` peek → write → `BIO_reset`**; residual append only on partial | **Bulk HIGH** on memmove (~20% busy). Tiny LOW (small CT) | **Careful.** Do **not** ship “BIO_peek_package” as closed-flag RPS reopen. Prefer: (1) seal-window A/B; (2) if NEW LAW + duty gates, peek-or-equivalent **inside reactor_drain_wbio only** with residual-first preserved; (3) avoid zeroing slab / extra memcpy in drain loop. |
| **Plain body path** | ≥8 KiB: **heading + borrowed body** (`TLS_PLAIN_SPLIT_MIN_BODY`); tiny: **full materialize** into `resp_buf` | **Always** `setBody` copy + `renderToBuffer` append body (double plain copy on bulk) | Bulk: proactr **already better**; gap elsewhere. Tiny: both materialize | **Bulk leave.** Tiny: optional heading+borrow for small static if single seal still wins (today 8 KiB floor is deliberate for RPS). |
| **Fairness / multi-conn yield** | Cap **2 MiB plain or 32 windows** (`REACTOR_FAIR_*`); on hit **returns without H1 WRITE re-arm** (comment: next product event) | **No** per-conn window fairness; drives until EAGAIN / buffer empty | s1m (16 win) **under cap**. Bodies >2 MiB / multi-conn fairness: proactr can **stall** without re-entry | **Yes (correctness).** On fairness hit with plain remaining: arm WRITE or schedule re-flush (plan D9 intent). Files: `tls_reactor_flush.odin` ~105–119. |
| **Accept / nonblocking / REUSEPORT** | Per-worker **SO_REUSEPORT** listen; accept drain ≤64; accepted fd nonblocking | Single acceptor → round-robin `ioLoops_`; `SO_REUSEPORT` **opt-in** (`enableReusePort`, default off in matrix main); accept nonblock | Bulk steady-state: low impact. Startup / conn churn: different accept fanout | **Leave** for matrix fairness (both WORKERS=8). Do not chase REUSEPORT parity as bulk fix. |
| **TCP_NODELAY / cork** | **No** TCP_NODELAY on accept (historical A/B **hurt** bulk −11–12%; CLOSED) | **No** NODELAY in matrix peer; `setTcpNoDelay` API exists but unused by default | CLOSED dead end | **Leave alone.** |
| **Thread model** | N workers, each own reactor kq + soft timer ring; conn pinned to worker | N `EventLoop` threads + main loop also IO; conn pinned after accept | Similar 1-conn-1-loop | **Leave.** APP_CONTRACT independent. |
| **OpenSSL usage** | **dynlib** OpenSSL · **mem-BIO** · `SSL_MODE_ENABLE_PARTIAL_WRITE \| ACCEPT_MOVING_WRITE_BUFFER` | **Linked** OpenSSL · **mem-BIO** · same SSL_set_bio shape | Bulk: dynlib PLT noise small vs AES. Architecture: same mem-BIO family | **Leave** dynlib (product). Static OpenSSL A/B only offline, not matrix claim. |
| **Handshake drain** | `tls_host_drive_handshake` loop; Darwin residual via `reactor_drain_wbio` / `reactor_on_send_complete` HS demux | `processHandshake` + `sendTLSData` same residual buffer | Not bulk RPS primary (session keep-alive) | **Mostly leave.** Ensure HS residual never blocks first request arm (already demuxed). |
| **Close / shutdown** | `connection_close` / `reactor_host_close` EV_DELETE; SSL_shutdown best-effort on destroy | `SSL_shutdown` + `sendTLSData`; `closeOnEmpty_` if residual | Correctness | **Leave.** |
| **Keep-alive reentry** | Sync finish → **`reactor_defer_clean`** (reentrancy) → end-of-batch `clean_request_loop` → `conn_handle_req` | Parser may continue in-loop after send; no defer queue | Tiny: **+1 turn latency** possible if deferred clean delays READ re-arm for pipelined/next req | **Measure.** If tiny shows clean lag: drain deferred clean before next wait (already after kevent); avoid clean while nested handler. Do not sync clean inside flush. |
| **Header / Date** | Per-worker `server_date` refresh ~1s; `_response_format_heading` scratch 512 B | `getHttpFullDateStr`; optional cached `httpString_` date patch for expiredTime paths | Tiny LOW–MED (format once/req both) | **Optional.** Cache full status-line template for static matrix routes only if profile shows heading cost (not bulk primary). |
| **Worker wait** | `ring_wait(0)` soft + `reactor_wait(timeout)` **two syscalls** per loop | One `poll/kevent` + timer queue | Idle overhead; bulk sample already kevent-dominated | **Refine later.** Merge timer deadline into single reactor wait if free; keep soft_cq for timers (D5). |
| **CT slab / dual hold** | Allocates **tx+hold** (2× ~272 KiB) even though Darwin reactor **forbids dual-CT ahead** | One residual MsgBuffer; no dual slab | Memory / cold cache; mild bulk | **Optional Darwin:** skip `hold` alloc when ODIN_OS Darwin (APP_CONTRACT OK). |
| **pt_admit / high-water** | `pt_admit` around SSL_write windows | No PT high-water in OpenSSLProvider | Correctness overhead tiny if admit always succeeds | **Leave** unless profile shows. |
| **Metrics / path_metrics** | Instrument turns/seals/eagain | None in peer | Engineering only | Keep for gates. |
| **H2** | Full product H2 on reactor | Matrix peer **no H2 claim** | Out of drogon bulk narrative | Do not use H2 cells to explain h1s s1m gap. |

---

## 4. Ranked impact list (likely RPS on **h1s s1m** vs 0.30× baseline)

| Rank | Divergence | Likely impact | Status | Notes |
|-----:|------------|---------------|--------|-------|
| 1 | **Per-window CT copy (`BIO_read` vs peek+reset)** | **High** on busy memmove; honest **+10–25%** if eliminated without reordering | **Open / constrained** | Peer pattern clear; CLOSED as “BIO_peek_package RPS flag.” Need NEW LAW-shaped implement or non-peek copy cuts. |
| 2 | **Seal window 64→128 KiB A/B** | **Med–High** setup tax cut (17→~9 SSL_write/req); baseline-licensed | **Open free win** | Prior 1 MiB seal failed under **old law**; 128 under reactor is allowed experiment (D8). |
| 3 | **Level-triggered residual WRITE (vs oneshot re-arm)** | **Med** when EAGAIN frequent; **Low** on current s1m (few arms) | **Open structure** | Helps s64k / multi-conn more than perfect s1m. |
| 4 | **Dual wait (soft ring + reactor)** | **Low–Med** idle/latency | Open | Not AES path. |
| 5 | **Fairness H1 without WRITE re-arm** | **Correctness / large body**; **nil** for 1 MiB | Bugfix | Must fix before >2 MiB / fairness tests. |
| 6 | **Keep-alive deferred clean** | **Low bulk; Med tiny** | Intentional | Reentrancy guard (P5 UAF); optimize carefully. |
| 7 | **Dynlib OpenSSL vs static link** | **Low** | Product choice | Offline A/B only. |
| 8 | **Body materialize / double copy** | proactr **already wins bulk**; tiny materialize=reqs | **Tiny track** | Separate PR from bulk. |
| 9 | **TCP_NODELAY** | Negative historically | **CLOSED** | Leave. |
| 10 | **Dual_Ct N>2 / soft-CQ density** | Law already multi-window | **CLOSED / converged** | Do not reopen. |
| 11 | **kTLS** | Theoretical ceiling | **Out of scope** | Not fair fix. |

### Already converged (law) — do not re-solve

- Residual-first before SSL_write (R-ORDER)  
- Multi-window seal + write until EAGAIN without soft-CQ between full windows (`soft_cq_send=0`)  
- 64 KiB seal trunk matching drogon `maxSend`  
- Single residual CT region on Darwin (D3); dual-CT ahead Linux-only  
- Nonblocking sockets; no handler visibility of kqueue/SSL*  
- Borrowed body for large H1 TLS oneshot (≥8 KiB)  

### Intentional product differences — leave alone

- APP_CONTRACT (handlers never see kqueue/SSL*/CQ)  
- H2 product stack (drogon matrix N/A)  
- Planner / body cmds / middleware hooks  
- Dynlib OpenSSL provider  
- Deferred clean for reentrancy  
- REUSEPORT multi-listen vs drogon acceptor RR  

### Free wins (safe structure / measurement)

1. **Seal-window A/B 64 vs 128 KiB** under reactor  
2. **Fairness H1 WRITE re-arm** when preempt mid-body  
3. **Darwin skip dual hold slab** alloc (memory/cache)  
4. **Tiny track (separate):** kill full materialize for static plaintext when single small Static (careful vs 8 KiB floor)  
5. **Drain-loop hygiene:** fewer zeroing/memmove steps inside `reactor_drain_wbio` without BIO_get_mem_data package  

---

## 5. Convergence roadmap (ordered, agent-sized PRs)

### PR-A — Seal window A/B under reactor law (**first**)

| | |
|--|--|
| **What** | Make `REACTOR_SEAL_WINDOW` trial **128 KiB** (or compile-time/A-B knob internal only); keep residual-first + fairness caps; adjust fairness windows if needed so 1 MiB still one-turn capable |
| **Files** | `http/reactor_law.odin` (`REACTOR_SEAL_WINDOW`); possibly `tls_reactor_flush.odin` comments; path_metrics scrape |
| **Mirrors** | drogon `maxSend` trunk sizing experiment; D8 in plan-r2 |
| **APP_CONTRACT risk** | **None** (internal seal) |
| **Correctness risk** | Low–Med (partial SSL_write, pt_admit, CT slab 272 KiB already fits 128 KiB+overhead) |
| **Expected duty/RPS** | seals/req ~17→~9; possible **+10–20%** h1s s1m if setup tax real; plain ≥ −3% |
| **Gates** | vs BASELINE_P5: h1s s1m **≥ +15%** *or* document duty↑/RPS +8–14%; `soft_cq_send=0`; 0 errors; report drogon ratio same session |

### PR-B — Fairness H1 re-entry (correctness)

| | |
|--|--|
| **What** | On `reactor_fairness_hit` with plain remaining and residual empty: **arm WRITE** (or explicit re-flush interest) so multi-MiB / multi-conn cannot stall |
| **Files** | `http/tls_reactor_flush.odin` ~105–119; tests T10 in plan-r2 |
| **Mirrors** | drogon keeps POLLOUT until drained |
| **Risk** | Low; APP_CONTRACT OK |
| **RPS** | Neutral on s1m; correctness for larger bodies |
| **Gates** | large-body soak; no plain regression |

### PR-C — Residual WRITE level-trigger experiment (structure)

| | |
|--|--|
| **What** | For residual CT only: arm **level** EVFILT_WRITE (or keep oneshot but batch changelist); disable when residual empty — mirror trantor `enableWriting`/`disableWriting` |
| **Files** | `http/io_reactor_kqueue.odin` `reactor_arm_filter` / `reactor_arm_write_residual` / `reactor_on_writable` |
| **Mirrors** | `TcpConnectionImpl::writeCallback` + Channel write interest |
| **Risk** | Med (spurious writable loops, EV_DELETE storms — proactr already ENOENT-tolerant) |
| **RPS** | Low on s1m today; **Med** s64k / multi-conn EAGAIN |
| **Gates** | eagain_arms + RPS A/B; no CPU spin |

### PR-D — CT drain copy reduction (NEW LAW only if peek)

| | |
|--|--|
| **What (safe first)** | Profile `reactor_drain_wbio`: avoid double-copy of residual already in `dual_ct.tx`; ensure one write loop per BIO_read chunk; no slab memset |
| **What (peer-shaped, constrained)** | Optional: wBIO **peek + reset after full write** like `sendTLSData`, residual-first unchanged — **only with NEW LAW statement** (reactor multi-window + duty gates already true; document residual ownership). **Not** the old façade “BIO_peek_package” flag reopen |
| **Files** | `tls_reactor_flush.odin` `reactor_drain_wbio`; possibly `tls_server` BIO helpers |
| **Mirrors** | `OpenSSLProvider::sendTLSData` + `appendToWriteBuffer` |
| **Risk** | High if BIO lifetime wrong; Med with careful residual |
| **RPS** | Target memmove share ↓; **+10–25%** bulk if real |
| **Gates** | sample memmove ↓; s1m ≥ +15%; residual unit tests T1–T3 |

### PR-E — Dual wait / timer merge (idle)

| | |
|--|--|
| **What** | Single wait path: reactor kevent timeout = min(timer, wait_ms); harvest soft_cq only when due / after I/O |
| **Files** | `server_loop_reactor.odin` |
| **Mirrors** | trantor one `EventLoop::loop` poll |
| **Risk** | Timer latency bugs |
| **RPS** | Low bulk absolute; may help tiny / idle |
| **Gates** | timer correctness tests; plain ±3% |

### PR-F — Tiny H1 materialize cut (**separate track**)

| | |
|--|--|
| **What** | Static/tiny ciphered oneshot: avoid full body memcpy when still **one** seal window (tune `TLS_PLAIN_SPLIT_MIN_BODY` or heading-only for all Borrowed Static) |
| **Files** | `response_ciphered.odin`, `response_materialize.odin` |
| **Mirrors** | n/a (drogon worse on body); improves vs self baseline |
| **Risk** | Lifetime of Borrowed; RPS regress if split adds seal turns on tiny |
| **RPS** | h1s plain / s4k target **+5–15%** |
| **Gates** | materialize/req ↓; plain +s4k; **no s1m regression** |

### PR-G — Darwin no-hold slab (optional)

| | |
|--|--|
| **What** | On Darwin, allocate only `dual_ct.tx` (reactor residual), skip `hold` |
| **Files** | `tls_host.odin` ~145–165 |
| **Risk** | Low if all Darwin paths ignore hold |
| **RPS** | Low; RSS/cache win |

### Explicitly **not** on roadmap

| Item | Why |
|------|-----|
| Dual_Ct N>2 | CLOSED; Darwin law is single residual |
| H1 dense soft-CQ | CLOSED; soft_cq already 0 on bulk |
| TCP_NODELAY | CLOSED; hurt bulk |
| 1 MiB seal as flag | CLOSED; use measured 128 A/B only |
| kTLS | Out of fair matrix |
| Handler-visible engine knobs | APP_CONTRACT |
| Copy drogon `setBody` double materialize | Would regress proactr bulk body path |

---

## 6. Already converged / leave alone (checklist)

**Converged (keep):**

- [x] Residual-first SSL_write gate  
- [x] Multi-window until EAGAIN, no soft-CQ between windows  
- [x] 64 KiB trunk (drogon-shaped)  
- [x] Single residual CT on Darwin  
- [x] Native kqueue product sockets (P5)  
- [x] Large-body borrowed plain (≥8 KiB)  
- [x] APP_CONTRACT firewall  

**Leave alone (intentional or dead):**

- [ ] TCP_NODELAY  
- [ ] Dual_Ct ahead on Darwin  
- [ ] kTLS  
- [ ] Handler kqueue/SSL exposure  
- [ ] Matching drogon double body copy  
- [ ] REUSEPORT vs acceptor as bulk RPS lever  
- [ ] H2 vs drogon comparisons for bulk H1 narrative  

---

## 7. Recommended **first PR** (one sentence)

**PR-A only:** A/B `REACTOR_SEAL_WINDOW` 64→128 KiB under existing reactor residual-first law, with BASELINE_P5 duty+RPS gates — cheapest drogon-structure trunk experiment that does not reopen CLOSED flags and does not touch APP_CONTRACT.

---

## 8. Appendix — cited code anchors

### drogon `sendData` (64 KiB trunk + residual gate)

```532:559:third_party/drogon/trantor/trantor/net/inner/tlsprovider/OpenSSLProvider.cc
    virtual ssize_t sendData(const char *data, size_t len) override
    {
        if (getBufferedData().readableBytes() != 0)
        {
            errno = EAGAIN;
            return 0;
        }
        constexpr size_t maxSend = 64 * 1024;
        size_t hasSent = 0;
        while (hasSent < len && getBufferedData().readableBytes() == 0)
        {
            auto trunkLen = len - hasSent;
            if (trunkLen > maxSend)
                trunkLen = maxSend;
            int n = SSL_write(ssl_, data + hasSent, (int)trunkLen);
            // ...
            auto num = sendTLSData();
            // ...
            hasSent += trunkLen;
        }
        return static_cast<ssize_t>(hasSent);
    }
```

### drogon `sendTLSData` (peek + residual copy + BIO_reset)

```731:748:third_party/drogon/trantor/trantor/net/inner/tlsprovider/OpenSSLProvider.cc
    ssize_t sendTLSData()
    {
        void *data = nullptr;
        int len = BIO_get_mem_data(wbio_, &data);
        // ...
        int n = writeCallback_(conn_, data, len);
        if (n >= 0)
        {
            appendToWriteBuffer((char *)data + n, len - n);
        }
        (void)BIO_reset(wbio_);
        // ...
    }
```

### drogon kqueue level-trigger (no EV_ONESHOT)

```206:215:third_party/drogon/trantor/trantor/net/inner/poller/KQueue.cc
    if ((events & Channel::kWriteEvent) &&
        (!(oldEvents & Channel::kWriteEvent)))
    {
        EV_SET(&ev[n++],
               fd,
               EVFILT_WRITE,
               EV_ADD | EV_ENABLE,
               0,
               0,
               (void *)(intptr_t)channel);
    }
```

### proactr reactor flush residual-first + 64 KiB

```56:135:http/tls_reactor_flush.odin
		// --- residual first (R-ORDER): write only; no SSL_write while residual > 0 ---
		if conn.reactor_res_n > 0 {
            // ... reactor_write_residual / arm ...
		}
        // ... drain wBIO ...
		// SSL_write one trunk window (64 KiB).
		// ...
			ok, consumed = reactor_ssl_write_window(conn)
```

### proactr oneshot WRITE arm

```229:240:http/io_reactor_kqueue.odin
reactor_arm_filter :: proc(fd: i32, filter: kqueue.Filter, udata: rawptr) {
	// ...
	ev.flags = {.Add, .One_Shot, .Enable}
	// ...
}
```

### proactr drain always BIO_read into slab

```337:370:http/tls_reactor_flush.odin
	for tls_server.bio_pending_out(p, ssl) > 0 {
		n := tls_server.bio_read_net(p, ssl, dst)
		// ...
		for left > 0 {
			sent, would_block, err := host_try_send_nb(conn, dst[off:][:left])
			// EAGAIN → reactor_residual_set
		}
	}
```

### Baseline scoreboard (anchor)

| Cell | proactr | drogon | ratio |
|------|--------:|-------:|------:|
| h1s s1m | 2599 | 8612 | **0.30×** |
| h1s s64k | 30554 | 65093 | 0.47× |
| h1s s4k | 86942 | 149807 | 0.58× |
| h1s plain | 111730 | 150542 | 0.74× |

Source: `comparisons/tls-h2/results/BASELINE_P5.md`.

---

## 9. Measurement recipe (any convergence PR)

```bash
cd comparisons/tls-h2
SERVERS="proactr ntex drogon" WORKERS=8 BENCH_C=50 BENCH_Z=10 WARMUP_Z=3 \
  LOGDIR=/tmp/proactr-vs-drogon-ab ./run_matrix.sh
# Require: soft_cq_send_completes=0 on TLS bulk; 0 failed/timeout
# Claim bulk: h1s s1m ≥ +15% vs 2599 and/or duty doc; same-session drogon ratio
```

**Honesty ladder (unchanged):** L0 0.30× → L1 0.35–0.45× after next bulk cuts → L3 ~1.0× not next.
