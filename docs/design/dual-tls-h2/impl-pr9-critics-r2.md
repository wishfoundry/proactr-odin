# Implementation Critics — PR9 r2 (multi-axis)

**Posture:** harsh elite. Credit only **claimed PR9 product bar (offline M1–M6)**.  
**Bar:** WOW ≥ 9 for **product bar offline** — concurrent multi-stream + multi-SSE + fair RR + peak on-wire O(window) + duplex + RST Client_Gone, with matrix/README honesty.

| Claimed in | Claimed out |
|------------|-------------|
| Default concurrent multi-stream dispatch (`h2_serial_dispatch=false`) | Live bastion multi-stream RPS / peer matrix |
| SSE multi-slot on H2; peer RST → `.Client_Gone` once | WS-on-H2 |
| Fair RR flush (`flush_rr` / `_flush_pending_rr`) whenever ≥2 streams pending | Full h2spec |
| Offline M1–M6 gates in `http/h2_m_gates_test.odin` (titles match bodies) | Live dual-CT seal∥send bulk firehose |
| Matrix TLS H2 concurrent + SSE ✅ **offline M1–M6**; README experimental H2 OK | HPACK dynamic encoder / inbound recv-window throttle |
| GOAWAY on feed/`fail_code`; lazy multi-slot (PR8 residuals kept) | Automated ring TLS H2 concurrent CI |

**Not required for WOW:** peer-grade RPS, bastion numbers, WS-H2, full h2spec, live multi-MiB firehose CI.  
**Required for WOW:** R1 **Majors** that made the product bar soft — named M4/M6 gate theater, RR only on recovery credit, matrix/gate honesty mismatch — are closed with craft + regression tests; concurrent dispatch remains real; residuals named, not hidden.

**Date:** 2026-08-08  
**Prior:** [`impl-pr9-critics-r1.md`](impl-pr9-critics-r1.md) (mean **8.3**, WOW withheld — M4 nil-SSL tautology; named M6 bypassed dispatch/RST; RR recovery-only; soft named gates).  
**Subject:** `http/h2_host.odin`, `http/h2_m_gates_test.odin`, `http/h2_host_test.odin` (concurrent/SSE/RST), `http/session.odin` (H2 `sse_start` / apply / abort), `http2/flow.odin` (`_flush_stream` multi-pending → RR), `http2/flow_test.odin` (RR/peak/multi-pending), docs `{CAPABILITY_MATRIX,IMPLEMENTATION_STATUS,H2_PRODUCT_BASELINE,README,H2_ENGINE}`.

---

## Verify (this pass)

| Command / check | Result |
|-----------------|--------|
| `odin test http2 -o:none` | **20/20 pass** (was 19 in r1; +`test_h2_flush_multi_pending_always_rr`) |
| `odin test http -define:ODIN_TEST_THREADS=1 -o:none` | **153/153 pass** (OpenSSL dynlib present) |
| M1–M6 named gates only | **6/6 pass** (`test_m1`…`test_m6`) |
| Engine RR + multi-pending + peak | `test_h2_flush_rr_two_pending_streams`, `test_h2_flush_multi_pending_always_rr`, `test_h2_peak_wire_o_window_two_large_bodies` **pass** |
| Host concurrent + SSE + RST companions | `test_h2_host_concurrent_two_get_streams`, `test_h2_sse_two_sessions_data_frames`, `test_h2_sse_rst_client_gone_once` **pass** |
| `./scripts/check_e0_bans.sh` | **OK** (README has no unphased HTTP/2 product claim) |
| Live bastion multi-stream RPS | **Not measured** (correct non-claim) |
| Live TLS concurrent CI | **Not present** — offline + manual `curl --http2` only |

**LOC (approx.):** `h2_host.odin` ~1077; `h2_m_gates_test.odin` ~508; `h2_host_test.odin` ~1093; RR core in `http2/flow.odin` ~209 LOC (incl. multi-pending branch + `_flush_pending_rr`).

---

## R1 → fixed (spot-checked)

| R1 ID | Claim | Evidence | Verdict |
|-------|--------|----------|---------|
| **CQ-M1 / HON-M2** | Named M6 bypasses dispatch; no RST in product gate | `test_m6_two_concurrent_sse_sessions`: two GETs → `h2_host_dispatch_available` → handler `sse_start` → DATA both sids (M6a); peer `RST_STREAM` on sid1 → `_h2_m6_gone_a==1`, sibling session lives, re-poll no double-fire (M6b). Comment header: “via dispatch+handler + RST”. Baseline M6 row matches. | **Fixed** |
| **CQ-M2 / HON-M2** | Named M4 is nil-SSL tautology | `test_m4_duplex_flush_does_not_unarm_recv`: (1) flush leaves `tls_ct_recv_inflight`; (2) `h2_host_on_send_complete` with `tls_pipe.state=.Open` increments `h2_test_arm_recv_count` and does not force unarm; (3) Closed pipe does not arm. `h2_host_on_send_complete` always takes arm path when Open (count before `tls_host_arm_recv`, which may no-op without SSL). Baseline M4 row documents arm counter. | **Fixed** |
| **PERF-M1** | RR only on conn WINDOW_UPDATE recovery; first writer monopolizes residual multi-pending credit | `_flush_stream`: if `_n_pending_streams(c) > 1` → `_flush_pending_rr` (not sole-stream drain). Wired from `conn_send_body` path. Unit: `test_h2_flush_multi_pending_always_rr` (both pending, residual window 16 → DATA both sids). Baseline fairness section: “whenever ≥2 streams have pending (including first multi-pending flush…)”. | **Fixed** |
| **HON-M1 / HON notes** | Matrix ✅ easy to misread as live concurrent product; scrap/RR wording soft | CAPABILITY_MATRIX cells carry **offline M1–M6** / **offline M1** / **offline M6** in-cell; note: fair RR multi-pending / recovery; peak on-wire. `H2_PRODUCT_BASELINE`: M4/M6 titles match tests; Concurrent scrap honesty (MEM); Fairness (M3) mechanism. `h2_host.odin` header documents sequential handler + shared `resp_buf` contract. README: experimental offline M1–M6, not peer RPS. | **Fixed** |

### R1 majors intentionally residual (product offline tolerates)

| R1 ID | Status after r2 | Why not WOW-blocker for offline bar |
|-------|-----------------|-------------------------------------|
| **CQ-M3** | Slot full → `connection_close` / `.Closing` still | CAP=8 product concurrent; rare; engine can REFUSED_STREAM — **named minor polish**, not gate theater |
| **CQ-M4 / MEM-M2** | Shared `loop.req` + `resp_buf` scrap | Documented: sequential oneshot handlers; materialize copies into engine before next take. Concurrent = multi-slot hold, not re-entrant respond |
| **CQ-M5** | M2/M3/M5 still engine-primary | Flow/RR/peak are engine product mechanics; M1+M6 host paths prove concurrent host craft. Host large oneshot under tight windows remains residual |
| **PERF-M2** | Fairness still existence-class (both progress, ≤ credit) | Multi-round asymmetric share bounds not measured — acceptable once multi-pending RR is real and tested |
| **PERF-M3 / MEM-M1** | Oneshot dump → O(sum) pending heap | Product claim is peak **on-wire** O(window); baseline + M5 admit pending remainder. Large-body matrix ⏳ |
| **HON-M3** | No automated live TLS concurrent probe | Same honesty split as PR5/PR6; offline gates now airtight enough for product bar |

---

## Scoreboard

| Axis | Score | WOWED | Worst class |
|------|------:|:-----:|-------------|
| Code quality | **9.2** | **yes** | Minor (slot-full → close; shared scrap under concurrent contract docs; recursive dispatch stack) |
| Performance / fairness honesty | **9.1** | **yes** | Minor / residual (existence-class fairness bounds; oneshot dump heap; O(n) `h2_out` shift; sort-per-RR-pass) |
| Memory / slot lifecycle | **9.0** | **yes** | Minor (O(sum bodies) pending under concurrent oneshot; full CAP×`Stream_Slot` slab; `h2_out` growth) |
| Shortcuts / marketing honesty | **9.4** | **yes** | Minor (manual curl faith; no automated ring TLS concurrent CI) |
| **Mean** | **9.2** | — | — |

**Verdict:** R1 Majors that withheld product-bar WOW — named M4/M6 theater, recovery-only RR, matrix/gate honesty soft underbelly — are closed with correct craft and regression tests. Offline M1–M6 is no longer green ink over soft proofs: M1 host concurrent unary; M6a+M6b real dispatch+handler dual SSE + RST once; M4 duplex arm path counted offline; M3 multi-pending RR on first shared flush and on WINDOW_UPDATE; M5 on-wire window bound with pending conservation; docs/matrix/README refuse bastion RPS and label ✅ **offline**. Residuals (slot-full conn kill, oneshot heap dump, engine-only M2 host chain, no live concurrent CI) are **named product polish / eng-tolerated scale**, not contract lies.

**All four axes clear WOW (≥9).** Willing: the bar was offline product concurrent + multi-SSE + fair RR + windowed peak + duplex + RST, with honesty — not bastion RPS. That is what landed after the r1 fix pass.

---

## Architecture map (post majors fix)

```text
DEFAULT: Server_Opts.h2_serial_dispatch = false

TLS Open + ALPN h2
  → h2_host_on_open
       conn_init + SETTINGS preface
       h2_host_ensure_slots  → heap [H2_SLOT_CAP]Stream_Slot (lazy)
       flush_out + arm CT recv (duplex)

CT recv (h2_active):
  SSL_read → h2_host_on_pt → conn_feed
    err/fail_code → goaway_write → flush → close
    RST/failed streams → h2_host_poll_session_resets → .Client_Gone once
  flush_out → maybe_finish_exchange → dispatch_available
  re-arm CT recv

dispatch_available (concurrent default):
  while free slot && complete request ready:
    take_request → slot_alloc(sid) → build loop.req (shared scrap; sequential)
    response_init(h2_slots[i]) → handler → respond / sse_start
    serial=false: loop again even if slot remains used (SSE hold / pending finish)

respond (h2_active):
  materialize cmds → conn.resp_buf (shared scrap; copy into engine before return)
  conn_send_response → flow-aware headers+body → h2_out
  flush_out; maybe_finish; arm_recv

sse_start (h2_active):
  HEADERS no END_STREAM on sid for r._slot
  Session on exchange slot; Start effects → DATA via conn_send_body(sid)
  peer RST → poll → Client_Gone → abort frees that slot only

conn_send_body / stream WINDOW_UPDATE:
  append pending → _flush_stream
    n_pending > 1 → _flush_pending_rr   ← multi-pending always RR (PERF-M1)
    n_pending ≤ 1 → sole drain frames

WINDOW_UPDATE sid=0 / SETTINGS +window:
  _flush_pending_rr  ← fair quantum per stream turn (M3)

send-complete:
  flush → maybe_finish → dispatch → arm path (+ h2_test_arm_recv_count offline)  ← M4

oneshot finish:
  h2_out drained + end_sent + empty pending → free slot → dispatch more
```

**H1 regression:** `h2_active` false and `h2_slots` nil until ALPN-h2 open; `ws_start` asserts `!h2_active`. Full `odin test http` green this pass.

---

## Gate map vs reality (r2)

| Gate | Claimed meaning | What the named test actually does | Match? |
|------|-----------------|-----------------------------------|--------|
| **M1** | Concurrent unary ≥2 | Full offline host: two GETs → `dispatch_available` → 2 slots → both bodies | **Yes** |
| **M2** | Concurrent deferred large bodies + WINDOW_UPDATE drain | Engine: two streams, tight windows, WINDOW_UPDATE drains both pending + END_STREAM | **Yes** (engine; host residual) |
| **M3** | Fair RR both progress | Engine: both pending under zero/shared credit → both DATA; `flush_rr>0`; companion multi-pending always RR | **Yes** |
| **M4** | Duplex: flush does not unarm; send-complete arms | Flush keeps inflight; send-complete Open → arm count +1; Closed → no arm | **Yes** (structural offline, not live SSL) |
| **M5** | Peak on-wire O(window) | Engine: wire DATA ≤ window; pending+wire conserve full bodies | **Yes** |
| **M6** | Two concurrent SSE + RST Client_Gone | Dispatch+handler dual SSE DATA both sids; RST one → Client_Gone once; sibling lives | **Yes** |

**Product bar honesty:** named gate table matches code. M2/M3/M5 remain legitimate **engine** product mechanics (documented). M1 and M6 are full host product paths.

---

## 1. Code quality — Score **9.2** / WOWED **yes**

### What is elite for claimed product offline scope

1. **Concurrent dispatch is a real loop, not a broken flag.** Default `h2_serial_dispatch=false`; serial is opt-in single-flight. `dispatch_available` takes while free slots exist; long-lived hold does not block another. Default opt pin + concurrent-ignores-serial-busy tests held.

2. **Named M6 is real host craft.** Two complete requests → dispatch → `server.handler` → `sse_start` → DATA on both sids; peer RST → Client_Gone once; sibling session survives; re-poll does not double-fire. Closes r1 CQ-M1 gate theater.

3. **Named M4 is structural duplex law, not nil-SSL vacuity alone.** Flush never clears `tls_ct_recv_inflight`. Send-complete always takes the arm path when Open (`h2_test_arm_recv_count`); Closed does not arm. Offline proves call order without requiring live SSL/ring.

4. **Multi-slot ownership is coherent.** Lazy `^[H2_SLOT_CAP]Stream_Slot`; sid map; `h2_host_sid_for_response` prefers `r._slot`. Finish free walks used slots; SSE/`_session_attached` retained. Free after drain admits next stream.

5. **RST → Client_Gone once** (poll after feed; abort frees that slot). Matches App Contract hangup law. GOAWAY remains real wire craft from PR8 r2.

6. **Same handler / respond surface.** Pseudos → `Request` version 1.1 view; `respond` → HPACK + DATA; hop-by-hop stripped. No stream-id on App Contract. `ws_start` hard-asserts off H2.

7. **Fair RR is not a comment** — and is not recovery-only. Multi-pending first flush + conn WINDOW_UPDATE + SETTINGS window growth.

### Fatal

None for **claimed offline product bar**.

### Majors

None remaining for claimed offline product bar. R1 CQ-M1/M2 closed; CQ-M3/M4/M5 demoted (see minors / residual ledger).

### Minors

| ID | Issue |
|----|--------|
| **CQ-m1** | Slot exhaustion still closes the whole connection (no `RST_STREAM(REFUSED_STREAM)`). Engine already speaks REFUSED_STREAM for max concurrent; host CAP=8 still crude. |
| **CQ-m2** | Shared `loop.req` + temp scrap for concurrent takes — safe only under sequential handlers (documented). Any async pattern retaining `Request`/temp across a peer take is UAF. |
| **CQ-m3** | Bad-request 400 path still frees the slot before finish; serial busy / dispatch_sid edge cases remain eng-shaped. |
| **CQ-m4** | `poll_session_resets`: missing map entry after Start ⇒ gone. Relies on reap timing. |
| **CQ-m5** | Date header range still `[OK, Internal_Server_Error]` — 501–599 skip date on H2. |
| **CQ-m6** | File body cmd still omitted with warn on H2 eng path — correct honesty, incomplete product surface. |
| **CQ-m7** | Recursive `maybe_finish → dispatch_available` under flood can stack; single-threaded OK, not hardened. |
| **CQ-m8** | M2/M3/M5 never enter host materialize → `resp_buf` → pending path end-to-end (engine gates). |

### What would polish further

1. Slot full → `RST_STREAM(REFUSED_STREAM)`, keep conn.
2. Host-level M2: two concurrent large oneshots through `h2_host_send_response` + WINDOW_UPDATE drain offline.
3. Optional: keep concurrent contract assertion in debug builds if Request scrap escapes.

---

## 2. Performance / fairness honesty — Score **9.1** / WOWED **yes**

### What is elite

1. **Fair RR on multi-pending flush (PERF-M1 closed).** When ≥2 streams have pending, `_flush_stream` routes to `_flush_pending_rr` with quantum `max(1, conn_window / n_pending)`. Residual connection credit is shared — not monopolized by the stream that triggered the flush. Unit pins both DATA under residual 16.

2. **RR still wired on credit recovery.** Conn-level WINDOW_UPDATE and positive SETTINGS initial-window delta call `_flush_pending_rr`. Cursor `flush_rr` advances.

3. **Peak on-wire claim is mechanically true.** Without further WINDOW_UPDATE, sum of DATA payloads ≤ connection send window (M5 + engine peak). Remainder sits in `pending`; docs say so.

4. **Backpressure signal is real.** `conn_send_body` returns buffered count; SSE soft-drops when over stream buffer and sets `want_writable`.

5. **Docs do not claim peer RPS.** Baseline + matrix + README refuse bastion multi-stream numbers. Fairness wording matches mechanism (multi-pending + recovery).

### Majors

None for claimed offline product bar.

### Minors / residuals

| ID | Issue |
|----|--------|
| **PERF-m1** | Fairness tests remain existence proofs (both progress, total ≤ credit), not multi-round asymmetric share bounds. |
| **PERF-m2** | Oneshot path still dumps full body into engine pending — peak **wire** O(window); peak **producer heap** O(body). Progressive H2 produce not PR9. |
| **PERF-m3** | RR outer loop rebuilds + sorts sid list every pass. Fine for CAP=8; not a peer mux scheduler. |
| **PERF-m4** | O(n) `h2_out` prefix shift on every sealed window; host outbound still eng-shaped under multi-stream seal lag. |
| **PERF-m5** | Stream-level WINDOW_UPDATE still `_flush_stream` one sid (correct when sole pending; multi routes RR). |
| **PERF-m6** | HPACK encoder still non-indexing; inbound 1:1 auto WINDOW_UPDATE (engine residuals). |
| **PERF-m7** | Sole first writer with **only one** pending may still take full residual window (correct; multi-pending is the fixed path). |

### What would polish further

1. Multi-round asymmetric bodies (1 MiB vs 1 KiB over N WINDOW_UPDATEs) with share bounds.
2. Cap or chunk `h2_out` growth under multi-stream seal lag.
3. Host concurrent large respond timing unit (offline).

---

## 3. Memory / slot lifecycle — Score **9.0** / WOWED **yes**

### What is elite

1. **Lazy multi-slot tax fixed in PR8 r2 and still true.** Clear/TLS-H1 Connections pay a pointer; H2 open allocates slab; destroy frees. Size pin test remains.

2. **Slot lifecycle for oneshot is tested.** Two concurrent → free after drain → third admits. Session free on `slot_free`; RST frees one slot, sibling lives. M6 production path uses real dispatch/abort free for RST side.

3. **M5 conservation honesty.** `pending_sum + wire == 400` — product admits remainder is buffered. Baseline peak section matches.

4. **SSE session alloc is conn_allocator; framing uses worker session_scratch after Start.** Temp detach after Start is the right multi-session memory shape on one conn.

5. **Shared scrap contract is written down** (host package comment + baseline Concurrent scrap honesty). Sequential oneshot materialize → engine pending before next take — closes r1 “silent landmine” honesty gap even though the scrap shape remains.

6. **Engine stream reap** still limits unbounded map under mux.

### Majors

None for claimed offline product bar (large-body heap not ✅’d; scrap sequential contract documented).

### Minors / residuals

| ID | Issue |
|----|--------|
| **MEM-m1** | Oneshot concurrent still multiplies body ownership under windows: cmds → `resp_buf` → `pending` → `h2_out` (+ TLS CT). O(sum bodies) heap before WINDOW_UPDATE. |
| **MEM-m2** | Shared `conn.resp_buf` — safe for sequential oneshot; any deferred/async overlap aliases (documented). |
| **MEM-m3** | Full `Stream_Slot` (Response-bearing) × 8 on every H2 open (~16 KiB class). Lazy vs always-on is a win; CAP is coarse. |
| **MEM-m4** | M6 cleanup frees sibling with `slot_free`; header map ownership still unit-harness careful. Production abort/slot_free path is the real free. |
| **MEM-m5** | `h2_out` grows until seal catches up; no high-water close under multi-stream flood. |
| **MEM-m6** | Request body cloned into temp on take — concurrent takes reset scrap; long-lived must not hold `_pre_body`. |

### What would polish further

1. Single ownership: contiguous Static/Bytes → engine pending without full `resp_buf` clone when possible.
2. Slot full RST without conn death (pairs CQ-m1).
3. Lifecycle unit: open → 8 SSE → RST half → free → reopen without growth (metrics/heap).

---

## 4. Shortcuts / marketing honesty — Score **9.4** / WOWED **yes**

### What is elite

1. **Baseline document is the right artifact and now matches gate bodies.** M4 documents arm counter; M6 documents dispatch+handler + RST; fairness documents multi-pending first flush; Concurrent scrap honesty section present; non-claims table intact.

2. **CAPABILITY_MATRIX cells carry “offline” in the cell text.** Concurrent unary ✅ offline M1; concurrent SSE ✅ offline M6; oneshot/SSE cells ✅ offline M1–M6. Note under matrix repeats multi-pending RR + on-wire peak + no peer RPS. Closes r1 HON-M1 high-risk misread.

3. **IMPLEMENTATION_STATUS / PHASE0 / APP_CONTRACT / SESSION_SSE / TLS_H1** cross-links stay careful: Done offline product bar; WS ⏳; bastion RPS not measured.

4. **README is experimental, not triumphal.** “experimental product HTTP/2 … offline M1–M6 … Not a peer-matrix H2 RPS claim.” `check_e0_bans` green.

5. **Named gates no longer over-claim relative to bodies.** M4/M6 titles are literally true of the named tests (structural offline duplex; host dual SSE + RST). Companions remain.

6. **M5 on-wire vs heap distinction remains written down.** Rare and valuable.

### Majors

None for claimed offline product bar.

### Minors

| ID | Issue |
|----|--------|
| **HON-m1** | No automated live TLS concurrent or multi-SSE probe — manual `curl --http2` oneshot remains the live evidence (PR5/PR6 honesty split). Acceptable with airtight offline gates. |
| **HON-m2** | APP_CONTRACT “correct on HTTPS and HTTP/2 — for capabilities marked ✅” still requires reading matrix offline labels (now present in cells). |
| **HON-m3** | Engine-only M2/M3/M5 could be skimmed as “host concurrent bulk proven” — baseline is clear; keep host M2 polish on the residual list. |

### What would polish further

1. Optional env-gated local TLS H2 oneshot (skip-if-no-libssl) so ALPN+host is not faith.
2. Keep refusing peer RPS until bastion numbers exist — do not regress this axis for vanity.

---

## PR8 / PR9 residual ledger (r2)

| Item | Status after r2 |
|------|-----------------|
| Concurrent finish / multi-sid respond | **Landed** — default concurrent; sid-from-slot; multi free |
| SSE-on-H2 slot ownership | **Landed** — `sse_start` / apply / end / abort on `r._slot` |
| RST Client_Gone | **Landed** — poll after feed; M6b + companion once |
| Fair RR / multi-pending first flush | **Landed** — `_flush_stream` → RR when ≥2 pending + recovery paths |
| Peak window on-wire | **Landed** — M5 + engine peak; pending conservation |
| Named M4 duplex (not nil theater) | **Landed** — arm counter + inflight preserve |
| Named M6 dispatch+handler + RST | **Landed** |
| Matrix/baseline honesty offline labels | **Landed** |
| Slot full → close | **Still open** (CQ-m1) |
| Shared scrap / materialize dump heap | **Documented residual** (MEM-m1/m2; large-body ⏳) |
| Host concurrent large oneshot under windows | **Still open** (CQ-m8) |
| Automated ring TLS H2 concurrent | **Still open** (eng-tolerated; product bar offline) |
| GOAWAY / lazy slab | **Held** from PR8 r2 |

---

## Score justification (why WOW now)

| Axis | Why ≥9 holds this pass |
|------|------------------------|
| Code quality | Named M4/M6 prove what they claim; concurrent host craft real; residuals are polish (slot RST, host M2), not theater |
| Performance / fairness | Multi-pending RR on first shared flush + recovery; peak wire honest; fairness existence-class is minor once RR is real |
| Memory | Lazy slab; lifecycle tested; scrap sequential contract documented; O(sum) heap correctly not ✅’d as product large-body |
| Honesty | Matrix cells + baseline gate table + README refuse live RPS; gate titles match bodies; e0 bans green |

**WOW bar reminder:** offline product bar **can** WOW without bastion RPS. r1 withheld because named gates and fairness story were soft under the matrix flip. r2 closes those; mean **9.2**.

---

## Recommended polish order (post-WOW residuals)

1. **CQ:** Slot full → `RST_STREAM(REFUSED_STREAM)`, keep connection.
2. **CQ/PERF:** Host concurrent large oneshot + WINDOW_UPDATE drain offline (host M2).
3. **PERF:** Multi-round asymmetric RR share bound test.
4. **MEM:** Reduce materialize aliasing / double-copy when Static/Bytes contiguous.
5. **HON:** Optional automated local TLS H2 oneshot (env/libssl gated).

---

## Bottom line

PR9 r2 **earns WOW on the offline product bar.** Concurrent multi-slot dispatch, multi-SSE through real host dispatch+handler, peer RST → Client_Gone once, fair RR on multi-pending and recovery, peak on-wire O(window) with pending honesty, structural duplex arm path, and documentation that refuses bastion RPS while labeling ✅ **offline** — that is the claimed bar, sealed with green `odin test http` (153) + `http2` (20) and e0 bans.

Residuals remain (slot-full conn kill, oneshot heap dump, engine-primary M2, no live concurrent CI). They are **named polish**, not the r1 soft underbelly that blocked WOW. Mean **9.2**.
)
