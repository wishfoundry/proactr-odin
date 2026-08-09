# Implementation Critics — PR9 r1 (multi-axis)

**Posture:** harsh elite. Credit only **claimed PR9 product bar (offline M1–M6)**.  
**Bar:** WOW ≥ 9 for **product bar offline** — concurrent multi-stream + multi-SSE + fair RR + peak on-wire O(window) + duplex + RST Client_Gone, with matrix/README honesty.

| Claimed in | Claimed out |
|------------|-------------|
| Default concurrent multi-stream dispatch (`h2_serial_dispatch=false`) | Live bastion multi-stream RPS / peer matrix |
| SSE multi-slot on H2; peer RST → `.Client_Gone` once | WS-on-H2 |
| Fair RR flush (`flush_rr` / `_flush_pending_rr`) | Full h2spec |
| Offline M1–M6 gates in `http/h2_m_gates_test.odin` | Live dual-CT seal∥send bulk firehose |
| Matrix TLS H2 concurrent + SSE ✅; README experimental H2 OK | HPACK dynamic encoder / inbound recv-window throttle |
| GOAWAY on feed/`fail_code`; lazy multi-slot (PR8 residuals kept) | Automated ring TLS H2 concurrent CI |

**Not required for WOW:** peer-grade RPS, bastion numbers, WS-H2, full h2spec, live multi-MiB firehose CI.  
**Required for WOW:** concurrent dispatch is real (not a boolean lie); multi-SSE + RST are real slot craft; RR is real under shared conn credit; peak **on-wire** claim is not heap fiction; duplex law is not a nil-SSL tautology; docs do not overclaim live RPS/WS/bulk; named M gates actually prove what their titles say.

**Date:** 2026-08-08  
**Prior:** [`impl-pr8-critics-r2.md`](impl-pr8-critics-r2.md) (eng-unary WOW mean **9.2**; product M1–M6 handoff).  
**Subject:** `http/h2_host.odin`, `http/h2_m_gates_test.odin`, `http/h2_host_test.odin` (concurrent/SSE/RST), `http/session.odin` (H2 `sse_start` / apply / abort), `http2/flow.odin` (`_flush_pending_rr`), `http2/flow_test.odin` (RR/peak), docs `{CAPABILITY_MATRIX,IMPLEMENTATION_STATUS,H2_PRODUCT_BASELINE,README,H2_ENGINE}`.

---

## Verify (this pass)

| Command / check | Result |
|-----------------|--------|
| `odin test http2 -o:none` | **19/19 pass** |
| `odin test http -define:ODIN_TEST_THREADS=1 -o:none` | **153/153 pass** (OpenSSL dynlib present) |
| M1–M6 named gates only | **6/6 pass** (`test_m1`…`test_m6`) |
| Engine RR + peak | `test_h2_flush_rr_two_pending_streams`, `test_h2_peak_wire_o_window_two_large_bodies` **pass** |
| Host concurrent + SSE + RST companions | `test_h2_host_concurrent_two_get_streams`, `test_h2_sse_two_sessions_data_frames`, `test_h2_sse_rst_client_gone_once` **pass** |
| `./scripts/check_e0_bans.sh` | **OK** (README has no unphased HTTP/2 product claim) |
| Live bastion multi-stream RPS | **Not measured** (correct non-claim) |
| Live TLS concurrent CI | **Not present** — offline + manual `curl --http2` only |

**LOC (approx.):** `h2_host.odin` ~1060; `h2_m_gates_test.odin` ~459; `h2_host_test.odin` ~1093; RR core in `http2/flow.odin` ~60 LOC (`_flush_pending_rr` + one-frame quantum).

---

## Scoreboard

| Axis | Score | WOWED | Worst class |
|------|------:|:-----:|-------------|
| Code quality | **8.2** | **no** | Major (M6 gate bypasses dispatch; M4 nil-SSL theater; slot-full → conn close) |
| Performance / fairness honesty | **8.0** | **no** | Major (RR only on conn WINDOW_UPDATE path; weak fairness proof; oneshot dump + O(n) shift) |
| Memory / slot lifecycle | **8.1** | **no** | Major (heap still O(sum bodies) via pending; shared `resp_buf` / single `loop.req`) |
| Shortcuts / marketing honesty | **8.7** | **no** | Major fringe (✅ matrix without live concurrent TLS; named gates overstate M4/M6 coverage) |
| **Mean** | **8.3** | — | — |

**Verdict:** PR9 is a **real product step**, not a docs flip on eng unary. Default concurrent multi-slot dispatch runs two GET handlers offline and lands two 200s; fair RR under shared connection credit is implemented and unit-tested; peak on-wire DATA is window-bounded while remainder sits in `pending` (and docs say so); multi-slot SSE writes DATA on two sids; peer RST drives `.Client_Gone` once and leaves the sibling session alive; GOAWAY + lazy slab + serial opt-in survive from PR8; README stays “experimental” and refuses peer RPS / WS-H2 / bulk firehose. That is honest product-bar engineering.

**WOW is withheld on all four axes.** Offline M1–M6 is **green ink**, not a sealed product bar. The named M4 gate is a tautology on the `tls_ssl == nil` early return. The named M6 gate never exercises RST (and never runs two SSEs through `h2_host_dispatch_available` + `server.handler`). Fairness is real only after both bodies are already pending under zero conn credit — first `conn_send_body` still monopolizes existing window via `_flush_stream`. Concurrent oneshot still shares one `loop.req`, one temp scrap, and one `resp_buf` scrap. Heap for large oneshots remains O(sum full bodies) in `pending` while the matrix only ✅s concurrent unary + SSE, not large-body. Matrix/README language is careful — and still easier to misread as “TLS H2 concurrent product” without noticing every proof is sans-I/O. Mean **8.3**. Fix the gate theater, host-level multi-SSE dispatch, and initial-window fairness story before claiming WOW on a product bar.

---

## Architecture map (what PR9 actually installed)

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
    take_request → slot_alloc(sid) → build loop.req (shared scrap)
    response_init(h2_slots[i]) → handler → respond / sse_start
    serial=false: loop again even if slot remains used (SSE hold / pending finish)

respond (h2_active):
  materialize cmds → conn.resp_buf (shared scrap)
  conn_send_response → flow-aware headers+body → h2_out
  flush_out; maybe_finish; arm_recv

sse_start (h2_active):
  HEADERS no END_STREAM on sid for r._slot
  Session on exchange slot; Start effects → DATA via conn_send_body(sid)
  peer RST → poll → Client_Gone → abort frees that slot only

WINDOW_UPDATE sid=0 / SETTINGS +window:
  _flush_pending_rr  ← fair quantum per stream turn (M3)
  (stream WINDOW_UPDATE still _flush_stream one stream)

oneshot finish:
  h2_out drained + end_sent + empty pending → free slot → dispatch more
```

**H1 regression:** `h2_active` false and `h2_slots` nil until ALPN-h2 open; `ws_start` asserts `!h2_active`. Full `odin test http` green this pass.

---

## Gate map vs reality (harsh)

| Gate | Claimed meaning | What the named test actually does | Companion stronger proof? |
|------|-----------------|-----------------------------------|---------------------------|
| **M1** | Concurrent unary ≥2 | Full offline host: two GETs → `dispatch_available` → 2 slots used → both bodies | Yes — `test_h2_host_concurrent_two_get_streams` |
| **M2** | Concurrent deferred large bodies + WINDOW_UPDATE drain | **Engine only** — no host, no slots, no `respond` | Weak alias only |
| **M3** | Fair RR both progress | Engine: both pending under zero conn window; +16 conn credit → both DATA; `flush_rr>0` | Engine `test_h2_flush_rr_*` similar |
| **M4** | Duplex: flush does not unarm recv | Sets `tls_ssl=nil`, residual `h2_out`, `tls_ct_recv_inflight=true` → `flush_out` early-returns → flag still true | **No** live TLS duplex unit |
| **M5** | Peak on-wire O(window) | Engine: wire DATA ≤8; pending+wire conserve 400 | Engine peak test |
| **M6** | Two concurrent SSE + RST Client_Gone | Named gate: **manual** `slot_alloc` + `sse_start` → DATA both sids; **no RST**, **no dispatch/handler** | RST only in `test_h2_sse_rst_client_gone_once` |

**Product bar honesty requires the gate table to match the code.** M1 is solid. M2/M3/M5 are legitimate **engine** product mechanics but are not host concurrent proofs. M4 and the **named** M6 are the soft underbelly.

---

## 1. Code quality — Score **8.2** / WOWED **no**

### What is elite for claimed product offline scope

1. **Concurrent dispatch is a real loop, not a broken flag.** PR8 r1’s landmine (`false` → clobber) is gone. Default `h2_serial_dispatch=false`; serial is opt-in single-flight. `dispatch_available` takes while free slots exist; long-lived hold on one slot does not block another (`test_h2_host_long_lived_slot_allows_other_stream`). Serial busy is ignored under concurrent (`test_h2_concurrent_ignores_stale_serial_busy`). Default opt pin exists.

2. **Multi-slot ownership is coherent.** Lazy `^[H2_SLOT_CAP]Stream_Slot`; sid map; `h2_host_sid_for_response` prefers `r._slot` over last `h2_dispatch_sid`. Finish free walks all used slots; SSE/`_session_attached` retained. Free after drain allows a third stream.

3. **SSE-on-H2 is real slot craft (when exercised).** `sse_start` under `h2_active`: strip TE/CL, HEADERS without END_STREAM on sid from slot, `conn_send_body` per effect, END_STREAM / RST abort free **that** slot only. `ws_start` hard-asserts off H2. Hangup is per-stream poll, not H1 CT hangup theater on eng oneshot.

4. **RST → Client_Gone once.** `h2_host_poll_session_resets` after feed: failed stream or reaped-after-Start → drive once; abort if app did not end; re-poll does not double-fire (`test_h2_sse_rst_client_gone_once`). Matches App Contract hangup law.

5. **GOAWAY remains real wire craft** (PR8 r2 fix held). Feed protocol / fail_code → `goaway_write` → flush → close / offline Closing. Unit pins frame type + code.

6. **Same handler / respond surface.** Pseudos → `Request` version 1.1 view; body `_pre_body`; `respond` → HPACK + DATA; hop-by-hop stripped. No stream-id on App Contract.

7. **Fair RR is not a comment.** Cursor `flush_rr`, sorted pending sids, one quantum frame per turn, invoked on conn WINDOW_UPDATE and positive SETTINGS window growth. Product baseline documents the mechanism correctly.

### Fatal

None for **claimed offline product bar**. No WS marketed on H2. No peer RPS number invented. No H1 scanner owning ALPN-h2 bytes. No free-list always-on multi-slot tax regression.

### Majors

| ID | Issue | Evidence |
|----|--------|----------|
| **CQ-M1** | **Named M6 product gate does not prove multi-SSE product path.** `test_m6_two_concurrent_sse_sessions` manually `slot_alloc`s, drains `take_request`, calls `sse_start` — never `h2_host_dispatch_available` + `server.handler`. Concurrent SSE “through the host” is unproven by the gate that authorizes the matrix cell. | `h2_m_gates_test.odin` M6; compare M1 which *does* dispatch |
| **CQ-M2** | **Named M4 is a nil-SSL tautology.** `h2_host_flush_out` returns immediately when `tls_ssl == nil` without touching `tls_ct_recv_inflight`. The test only proves the offline early return does not clear a flag it never reaches. Duplex law in the real seal path (`arm_recv` after flush/send-complete, single-flight inflight) is PR6 craft reused — **not** re-proven as an H2 product gate. | `h2_host_flush_out` ~565–568; `test_m4_*` |
| **CQ-M3** | **Slot exhaustion still closes the whole connection.** Free-slot fail → warn + `connection_close` / offline Closing. Engine already speaks `RST_STREAM(REFUSED_STREAM)` for max concurrent. Product concurrent with CAP=8 will hit this under modest mux; killing the conn is crude vs stream refuse. | `h2_host_dispatch_available` ~313–321 |
| **CQ-M4** | **Single shared `loop.req` + temp scrap for concurrent takes.** Concurrent means sequential multi-slot on one worker, not re-entrant handlers — OK for sync oneshot. Second take rebuilds `loop.req` and may `conn_temp_reset` while another slot is still used. SSE detaches temp after Start (good). Any oneshot/async pattern that retains `Request` or temp slices across a peer take is UAF. Product concurrent contract is under-specified and under-tested. | `h2_host_dispatch_available` ~326–395 |
| **CQ-M5** | **M2/M3/M5 product gates never enter the host.** Large deferred bodies, RR flush, peak wire — all pure `http2` connection tests. Host concurrent unary bodies under tight windows (materialize → `resp_buf` → pending → `h2_out` → flush) is not an M-gate. Engine green ≠ host concurrent bulk path green. | `h2_m_gates_test` M2/M3/M5 |

### Minors

| ID | Issue |
|----|--------|
| **CQ-m1** | Bad-request 400 path still frees the slot before finish; serial busy / dispatch_sid edge cases remain eng-shaped. |
| **CQ-m2** | `poll_session_resets`: missing map entry after Start ⇒ gone. Relies on reap timing; oneshot without session is fine, but any mid-flight reaping ambiguity is implicit. |
| **CQ-m3** | Date header range still `[OK, Internal_Server_Error]` — 501–599 skip date on H2. |
| **CQ-m4** | File body cmd still omitted with warn on H2 eng path — correct honesty, incomplete product surface. |
| **CQ-m5** | `body_reserve` H1 heading scrape path still coincidence for H2 materialize. |
| **CQ-m6** | Recursive `maybe_finish → dispatch_available` under flood can stack; single-threaded OK, not hardened. |

### What would WOW

1. **M6 named gate:** two GETs → `dispatch_available` → handler `sse_start` both → DATA both sids → RST one → Client_Gone once + sibling live — **one** test, no manual slot_alloc.
2. **M4 named gate:** assert flush / send-complete paths **do not assign** `tls_ct_recv_inflight = false` (static/read of SSL path), or a short TLS-armed structural test that is not the nil early return.
3. **Slot full → RST that stream**, keep conn (engine already can).
4. **Host-level M2:** two concurrent large oneshots through `h2_host_send_response` + WINDOW_UPDATE drain offline.
5. Document concurrent contract: handlers must not retain `Request`/temp after return; request scrap is connection-serial.

---

## 2. Performance / fairness honesty — Score **8.0** / WOWED **no**

### What is elite

1. **Fair RR exists and is wired on the right events.** Conn-level WINDOW_UPDATE and positive SETTINGS initial-window delta call `_flush_pending_rr`, not map-order single-stream drain. Quantum `max(1, conn_window / n_pending)` when ≥2 pending — first credit package can advance both.

2. **Peak on-wire claim is mechanically true.** Without further WINDOW_UPDATE, sum of DATA payloads ≤ connection send window (M5 + engine peak). That is the right product sentence for backpressure.

3. **Backpressure signal is real.** `conn_send_body` returns buffered count; SSE soft-drops when `pending + frame > max_stream_buffer` and sets `want_writable`. Not a Wait_Flow zoo — acceptable product intermediate.

4. **Docs do not claim peer RPS.** Baseline + matrix + README refuse bastion multi-stream numbers. That is performance *honesty* even when craft is mid.

### Majors

| ID | Issue | Evidence |
|----|--------|----------|
| **PERF-M1** | **Initial send is still HOL on existing conn credit.** `conn_send_body` → `_flush_stream` drains **one** stream up to full min(stream, conn, max_frame). Second stream only buffers if the first already zeroed conn window. RR starts when both are pending **and** a later conn WINDOW_UPDATE arrives. Product phrase “fair RR flush” without “on shared credit recovery” oversells steady-state fairness of first-write scheduling. | `flow.odin` `conn_send_body` / `_flush_stream`; RR only from `connection.odin` WINDOW_UPDATE sid=0 / SETTINGS |
| **PERF-M2** | **Fairness tests are existence proofs, not fairness proofs.** M3 checks both DATA > 0 and total ≤ credit once. No multi-round asymmetric bodies (e.g. 1 MiB vs 1 KiB over N WINDOW_UPDATEs) showing byte share within a bound. Starvation-resistance is plausible, not measured. | `test_m3_*`, `test_h2_flush_rr_*` |
| **PERF-M3** | **Oneshot path still dumps full body into engine pending.** Materialize full cmds → append all bytes to `pending` → emit O(window) on wire. Peak **wire** O(window); peak **producer heap** O(body). Progressive H2 produce is not PR9. Matrix large-body cell correctly ⏳ — but concurrent large unary still multiplies pending. | `h2_host_materialize_body`; M5 comment admits pending |
| **PERF-M4** | **RR outer loop rebuilds + sorts sid list every pass.** Fine for CAP=8 / small maps; not a peer mux scheduler. Combined with O(n) `h2_out` prefix shift on every sealed window, host outbound is still eng-shaped. | `_flush_pending_rr`; `h2_host_flush_out` copy/resize |

### Minors

| ID | Issue |
|----|--------|
| **PERF-m1** | Stream-level WINDOW_UPDATE still `_flush_stream` one sid (correct) — no cross-stream interaction; only conn credit needs RR. |
| **PERF-m2** | No host concurrent RPS or latency unit even offline (two stream timing). |
| **PERF-m3** | HPACK encoder still non-indexing — every response pays literal bandwidth (engine residual). |
| **PERF-m4** | Inbound still 1:1 auto WINDOW_UPDATE — peer can push body until max_body; not product throttle. |

### What would WOW

1. Document + test: **“RR on conn credit recovery; first writer may take residual window.”** Or change first multi-pending flush to RR always when `len(pending_streams)>1`.
2. Multi-round fairness test with asymmetric sizes and share bounds.
3. Host M2 concurrent large respond + WINDOW_UPDATE without O(sum) wire (already true) **and** optional progressive produce later.
4. Cap or chunk `h2_out` growth under multi-stream seal lag.

---

## 3. Memory / slot lifecycle — Score **8.1** / WOWED **no**

### What is elite

1. **Lazy multi-slot tax fixed in PR8 r2 and still true.** Clear/TLS-H1 Connections pay a pointer; H2 open allocates slab; destroy frees. Size pin test remains.

2. **Slot lifecycle for oneshot is tested.** Two concurrent → free after drain → third admits. Session free on `slot_free` fail-closed destroy. RST path frees one slot, sibling lives.

3. **M5 conservation honesty.** `pending_sum + wire == 400` — product admits remainder is buffered, not vaporized. Baseline text matches.

4. **SSE session alloc is conn_allocator; framing uses worker session_scratch after Start.** Temp detach after Start is the right multi-session memory shape on one conn.

5. **Engine stream reap** still limits unbounded map under mux (PR7 residual closed for server).

### Majors

| ID | Issue | Evidence |
|----|--------|----------|
| **MEM-M1** | **Oneshot concurrent still triples body ownership under windows.** Cmds → `resp_buf` materialize → `stream.pending` copy → framed `h2_out` (+ TLS CT). Two concurrent large oneshots ⇒ O(sum bodies) heap before any WINDOW_UPDATE. Product bar correctly does not ✅ large-body live firehose — but concurrent oneshot memory shape is still eng dump. | `h2_host_materialize_body`; `conn_send_body` append |
| **MEM-M2** | **Shared `conn.resp_buf` scrap across concurrent responds.** Sequential sync oneshots copy into engine before next clear — works today. Any overlap (deferred respond, session still pointing at `_buf`) aliases. Concurrent product multiplies the landmine surface vs serial eng. | `h2_host_materialize_body` clear/append |
| **MEM-M3** | **Full `Stream_Slot` (Response-bearing) × 8 on every H2 open (~16 KiB class).** Lazy vs always-on is a win; product CAP is still coarse (all or nothing). No slab pooling / smaller oneshot slot. | `H2_SLOT_CAP`; size test |
| **MEM-M4** | **M6/RST tests free sessions with partial manual cleanup** (header map dance, flag clears). Production paths use `slot_free` / abort; tests paper over map ownership. Not a production leak proof, but a signal the offline harness is fragile. | `test_m6_*`, `test_h2_sse_rst_*` defers |

### Minors

| ID | Issue |
|----|--------|
| **MEM-m1** | `h2_out` grows until seal catches up; no high-water close under multi-stream flood. |
| **MEM-m2** | `h2_pt_buf` sized to recv_buf once per H2 conn — fine. |
| **MEM-m3** | Request body cloned into temp on take — concurrent takes reset scrap; long-lived must not hold `_pre_body`. |

### What would WOW

1. Single ownership: contiguous Static/Bytes → engine pending without full `resp_buf` clone when possible.
2. Per-slot or non-aliased materialize scrap under concurrent.
3. Slot full RST without conn death (pairs CQ-M3).
4. Lifecycle unit: open → 8 SSE → RST half → free → reopen without growth (metrics/heap).

---

## 4. Shortcuts / marketing honesty — Score **8.7** / WOWED **no**

### What is elite

1. **Baseline document is the right artifact.** [`H2_PRODUCT_BASELINE.md`](H2_PRODUCT_BASELINE.md) states offline unit bar, not peer RPS, not h2spec, not WS, not live multi-MiB CI. Explicit non-claims table. How-to-run includes M-gate filter.

2. **IMPLEMENTATION_STATUS / CAPABILITY_MATRIX language is careful.** PR9 “Done (offline product bar)”; WS ⏳; bastion RPS not measured; large-body ⏳; residual HPACK/inbound FC named. Matrix TLS H2 note repeats offline M1–M6 and forbids peer-matrix RPS from this bar alone.

3. **README is experimental, not triumphal.** “experimental product HTTP/2 … offline M1–M6 … Not a peer-matrix H2 RPS claim.” `check_e0_bans` green.

4. **Non-claims match code absences.** No WS-H2 path (`ws_start` assert). No fabricated bastion TSV. No “full HTTP/2 production ready” for bulk.

5. **M5 on-wire vs heap distinction is written down.** Rare and valuable — product marketing usually lies here; this tree does not.

### Majors / major-fringe

| ID | Issue | Evidence |
|----|--------|----------|
| **HON-M1** | **Matrix ✅ for concurrent unary + SSE is true only under the offline definition of “product.”** Author-facing matrix reads as ship-ready TLS H2 concurrent/SSE. Fine print says offline gates. That is allowed by honesty rules — and still the highest-risk misread in the tree. A release note that quotes ✅ without “offline M1–M6” becomes a lie. | `CAPABILITY_MATRIX.md` TLS H2 column |
| **HON-M2** | **Named gates over-claim relative to bodies.** Baseline table: M4 “duplex…”, M6 “≥2 concurrent SSE; RST → Client_Gone”. Named M4 does not touch duplex SSL path; named M6 does not RST. Companions exist — the **gate names** are the marketing surface for CI. That is honesty-of-proof debt. | Gate map above |
| **HON-M3** | **No automated live TLS concurrent or multi-SSE probe.** Manual `curl --http2` oneshot is the live evidence. Same honesty split as PR5/PR6 — acceptable only if offline gates are airtight. M4/M6 named softness undercuts that. | Quick verify docs; no ring H2 CI |

### Minors

| ID | Issue |
|----|--------|
| **HON-m1** | APP_CONTRACT “correct on HTTPS and HTTP/2 — for capabilities marked ✅” is correct **and** easy to skim past the offline caveat. |
| **HON-m2** | PHASE0 / TLS_H1 tables say PR9 Done offline — good cross-link hygiene. |
| **HON-m3** | “Fair RR” without “on conn WINDOW_UPDATE recovery” appears in some status lines; baseline mechanism section is more precise. Prefer baseline wording everywhere. |

### What would WOW

1. Rename or extend gates so **M4/M6 titles are literally true** of the named tests.
2. Matrix cell footnote one-liner: “✅ offline M1–M6; live RPS ⏳” in the cell text, not only the note below.
3. Optional: one automated local TLS H2 oneshot (even skip-if-no-libssl) so ALPN+host is not faith — same bar PR5 eventually wanted.
4. Keep refusing peer RPS until bastion numbers exist — do not regress this axis for vanity.

---

## PR8 → PR9 residual ledger

| PR8 residual / handoff | PR9 status |
|------------------------|------------|
| Concurrent finish / multi-sid respond | **Landed** — default concurrent; sid-from-slot; multi free |
| SSE-on-H2 slot ownership | **Landed** — `sse_start` / apply / end / abort on `r._slot` |
| RST Client_Gone | **Landed** — poll after feed; unit once |
| Fair RR / peak window | **Landed** engine + gates (host M2 weak) |
| Slot full → close | **Still open** (CQ-M3) |
| Shared scrap / materialize dump | **Still open** under concurrent (MEM-M1/M2) |
| Automated ring TLS H2 | **Still open** (eng-tolerated; product bar offline) |
| GOAWAY / lazy slab | **Held** from PR8 r2 |

---

## Score justification (why not WOW)

| Axis | Why ≥9 fails this pass |
|------|------------------------|
| Code quality | Gate theater (M4/M6 named), slot-full conn kill, shared req scrap under concurrent product |
| Performance / fairness | RR not on first-write path; fairness unquantified; dump materialize |
| Memory | O(sum bodies) pending under concurrent oneshot; shared `resp_buf` |
| Honesty | ✅ matrix + soft named gates + no live concurrent proof — careful docs, not airtight proof |

**WOW bar reminder:** offline product bar **can** WOW without bastion RPS. This pass does not, because the **named** product gates and concurrent host memory/fairness edges are not elite relative to the matrix flip they authorize.

---

## Recommended fix order (if r2 is earned)

1. **HON/CQ:** Rewrite `test_m6` as dispatch+handler dual SSE + RST once; rewrite `test_m4` so it is not nil-SSL vacuous.
2. **CQ:** Slot full → `RST_STREAM(REFUSED_STREAM)` (or GOAWAY enhance), keep connection.
3. **PERF:** Either RR whenever ≥2 streams have pending on any flush, or document+test first-writer residual window explicitly; add asymmetric multi-round RR test.
4. **MEM:** Host concurrent large oneshot gate; reduce materialize aliasing under multi-slot.
5. **HON:** Matrix cell text carries “offline”; baseline gate table matches test bodies exactly.

---

## Bottom line

PR9 **ships a real offline concurrent H2 host + multi-SSE + RR + windowed wire peak**, with documentation that mostly refuses the usual lies (RPS, WS-H2, bulk firehose, h2spec). That is better than most “we support HTTP/2” milestones.

It does **not** yet earn WOW on the product bar: too much of M2–M5 is engine-only, M4/M6 named gates are soft, fairness is recovery-path-only, and concurrent oneshot memory/scrap still look like serial eng with a loop around it. Mean **8.3**. Green tests are necessary; they are not sufficient.
)
