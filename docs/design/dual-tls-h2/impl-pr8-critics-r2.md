# Implementation Critics — PR8 r2 (multi-axis)

**Posture:** harsh elite. Credit only **claimed PR8 eng-unary scope**.  
**Bar:** WOW ≥ 9 for **claimed eng-unary scope only** (product M1–M6 **not** required):

| Claimed in | Claimed out |
|------------|-------------|
| ALPN prefer `h2`, fallback `http/1.1` | Product “supports HTTP/2” / README |
| After TLS Open: `h2_host` feed/dispatch/respond (**not** H1 scanner) | Concurrent mux product / fairness |
| Lazy multi-slot slab `H2_SLOT_CAP=8` (heap on open only); **always serial** eng | Matrix concurrent/SSE H2 ✅ |
| Duplex CT recv re-arm while H2 DATA may pump | SSE-on-H2 / M1–M6 |
| Live windows: feed `WINDOW_UPDATE` → flush pending DATA | Named `Wait_Flow` executor op zoo |
| Real GOAWAY on feed/`fail_code` then flush-once close | Full h2spec / CI ring e2e H2 |
| `curl --http2` eng oneshot green (**manual**) | Plan-A progressive H2 produce path |
| Same `server.handler` / `respond` | |

**Not required for WOW:** product concurrent slots, SSE-on-H2, M1–M6, matrix flips, dual-CT seal∥send, peer-grade HPACK encoder, inbound recv-window throttle, automated TLS ring oneshot (manual + offline host unit match PR5/PR6 honesty split).  
**Required for WOW:** R1 **Majors** that broke host craft under its own claims are closed — real GOAWAY, no fake concurrent switch, no always-on multi-slot tax — dual path clean, duplex not theater, docs refuse product overclaim, residuals named.

**Date:** 2026-08-08  
**Prior:** [`impl-pr8-critics-r1.md`](impl-pr8-critics-r1.md) (mean **8.1**, WOW withheld — GOAWAY never written; `h2_serial_dispatch=false` clobber switch; always-on `H2_SLOT_CAP`×`Stream_Slot`).  
**Subject:** `http/h2_host.odin`, `http/h2_host_test.odin`, `http/tls_host.odin` (ALPN Open branch + CT/send demux), `http/response.odin` (H2 respond), `http/server.odin` / `http/conn_slab.odin` (Connection H2 fields), `tls_server` ALPN selectors, `docs/{H2_ENGINE,IMPLEMENTATION_STATUS,CAPABILITY_MATRIX}.md`.

---

## Verify (this pass)

| Command / check | Result |
|-----------------|--------|
| `odin test http -define:ODIN_TEST_THREADS=1 -o:none` | **141/141 pass** (was 136 in r1; +GOAWAY, lazy-nil, serial coerce, ptr-not-embedded) |
| H2 unit surface | request build, pre-body, response headers, offline glue, slot slab, lazy-nil without open, GOAWAY on preface + `_fail` path, serial busy, serial-false coerce, default serial true, pointer slab size pin |
| ALPN unit | `tls_server` prefer `h2`, fallback `http/1.1`, H1-only, `alpn_is_h2` nil-safe (unchanged) |
| Product “supports HTTP/2” | **Clean** — matrix concurrent/SSE H2 **⏳**; README not flipped; status/H2_ENGINE forbid claim |
| Live `curl --http2` | **Not automated this pass** — docs: manual against `examples/https_demo` (same honesty as PR5/PR6) |

**LOC (approx.):** `h2_host.odin` ~828; `h2_host_test.odin` ~422; integration thin in `tls_host` / `response` / `server` / `conn_slab`.

---

## R1 → fixed (spot-checked)

| R1 ID | Claim | Evidence | Verdict |
|-------|--------|----------|---------|
| **CQ-M1 / HON-M1** | Connection errors never emit GOAWAY; “Best-effort GOAWAY” fiction | `h2_host_on_pt` → `h2_host_emit_goaway_and_close`: `goaway_write(&h2_out, last_peer_sid, code)` then `flush_out` then close (ring) / `.Closing` (offline). Comment: “never claim GOAWAY if not written.” Tests: `test_h2_host_feed_protocol_error_emits_goaway` (bad preface → FRAME_GOAWAY + PROTOCOL_ERROR code); `test_h2_host_feed_fail_code_emits_goaway` (DATA stream 0 → GOAWAY). Docs: H2_ENGINE / IMPLEMENTATION_STATUS name real GOAWAY. | **Fixed** |
| **CQ-M2 / HON-M2** | `h2_serial_dispatch=false` is a broken concurrent switch | Busy gate **always** applied. `false` → one-shot warn (“ignored — eng unary forces serial; concurrent needs PR9”); no skip of `h2_serial_busy`. `Server_Opts` comment: “not a working mux switch.” Test: `test_h2_serial_false_coerced_still_blocks`. Default remains true (`test_default_opts_h2_serial_true`). | **Fixed** |
| **MEM-M1** | Always-on eight full `Stream_Slot`s on every Connection | `h2_slots: ^[H2_SLOT_CAP]Stream_Slot` — **nil** until `h2_host_ensure_slots` on ALPN-h2 open; free in `h2_host_destroy`. Clear/TLS-H1 pay a pointer. Tests: `test_h2_slots_lazy_nil_without_open`, `test_h2_slots_pointer_not_embedded_tax` (slab ≫ 8 KiB vs rawptr). Comments on `Connection` / package header match. | **Fixed** |

---

## Scoreboard

| Axis | Score | WOWED | Worst class |
|------|------:|:-----:|-------------|
| Code quality | **9.2** | **yes** | Minor (slot-full → close; no ring TLS oneshot CI; SSE slot landmine for PR9) |
| Performance | **9.0** | **yes** | Phase residual (oneshot materialize; O(n) `h2_out` shift; no host tight-window unit) |
| Memory | **9.1** | **yes** | Minor (body triple-buffer under windows; `h2_out` grows until seal catches up) |
| Shortcuts / honesty | **9.3** | **yes** | Minor (manual curl faith; formal Wait_Flow still absent — language tight) |
| **Mean** | **9.2** | — | — |

**Verdict:** R1 Majors that made the eng host sharp under its **own** contract — GOAWAY half of the engine handoff, non-working concurrency flag, always-on multi-slot tax — are closed with correct craft and regression tests. Claimed PR8 eng-unary scope — ALPN prefer-h2, post-Open engine host, lazy multi-slot structure, **always** serial, duplex CT re-arm, live-window drain via feed+pending, oneshot `respond`, product non-claim — now holds as a coherent Phase-4 engineering host. Residuals are **PR9 handoff** (concurrent finish, SSE-on-H2 slot ownership, RST on slot refuse) or **eng-tolerated oneshot edges** (materialize/shift, no automated ring TLS probe). **All four axes clear WOW (≥9).** Willing: the bar was eng unary without product lie and without the R1 craft failures — that is what landed.

---

## Architecture map (post majors fix)

```text
TLS accept → SSL_CTX ALPN select: alpn_select_h2_or_http11 (prefer h2)
  Handshake CQE… → Open
    tls_host_open_start_protocol
      alpn_is_h2?
        yes → h2_host_on_open
                conn_init(engine) + SETTINGS preface → h2_out
                h2_host_ensure_slots  ← lazy [H2_SLOT_CAP]Stream_Slot
                flush_out (windowed SSL_write → CT send)
                tls_host_arm_recv (duplex; even if send inflight)
        no  → tls_host_open_start_http → H1 scanner (unchanged)
              h2_slots stays nil

CT recv CQE (Open, h2_active):
  h2_host_on_ct_ready
    SSL_read burst → h2_pt_buf → conn_feed(engine, pt, h2_out)
      on err / fail_code → goaway_write → flush_out → close   ← CQ-M1
    flush_out → maybe_finish_exchange → dispatch_one
    re-arm CT recv always (duplex law)

dispatch_one (always serial eng):
  false opt → warn once, still force serial                       ← CQ-M2
  if h2_serial_busy → return
  conn_take_request → slot_alloc(sid) → h2_request_from_headers
  response_init(h2_slots[i]) → server.handler → respond

respond (h2_active):
  skip H1 body-discard scanner path
  skip H1 status-line assembly
  materialize body cmds → resp_buf scrap
  conn_send_response (flow-aware engine) → h2_out → flush_out
  maybe_finish: wait h2_out empty + !wire + !pending_body + end_sent
  exchange_done → slot_free → serial_busy=false → dispatch_one again

CT send CQE:
  h2_host_on_send_complete → flush_out → maybe_finish → dispatch_one → arm_recv

destroy (connection_destroy):
  tls_host_conn_destroy then h2_host_destroy
    conn_destroy engine; delete h2_out; free h2_slots if any; delete h2_pt_buf
```

**H1 regression gate:** `h2_active` false and `h2_slots` nil until ALPN h2 Open; respond/recv/send fall through to H1. Full `odin test http` green is the regression proof this pass.

---

## 1. Code quality — Score **9.2** / WOWED **yes**

### What is elite for claimed eng-unary scope

1. **Real protocol branch, not a sticky note.** `tls_host_open_start_protocol` demux; `alpn_is_h2` → `h2_host_on_open`, else H1. CT Open short-circuits to `h2_host_on_ct_ready` before scanner decrypt. Send complete returns early through `h2_host_on_send_complete`. Dual-path law done correctly for eng.

2. **GOAWAY is real wire craft.** Engine `_fail` only sets `fail_code`; host owns `goaway_write` + flush-once + close. Offline unit path marks `.Closing` without claiming ring close. Two regression tests pin frame type and error code. Matches engine contract language in H2_ENGINE.

3. **Serial is always serial.** Single `h2_dispatch_sid` / finish path cannot mux; the opt surface no longer pretends otherwise. Coerce + warn is the honest eng answer until PR9 multi-handler finish.

4. **Same handler / respond surface.** Pseudos → `Request` version **1.1** (handler-compat). Body in `_pre_body`. `respond` → `h2_host_send_response` — no second public API.

5. **Lazy multi-slot structure is real and paid only when used.** CAP=8 sid map, alloc/find/free, `response_init(..., slot)`; serial uses one at a time; slab pre-positions PR9 without taxing H1 Connections.

6. **Destroy path ordered and free-list safe.** `connection_destroy` → TLS then `h2_host_destroy`; engine destroy only when active; free slab + PT buf; `h2 = {}` for re-open. Close defers on wire / CT-recv inflight (PR6 discipline reused).

7. **Hop-by-hop strip, fail-closed handler, HEAD/OPTIONS parity, File cmd warn.** Offline headers pin `connection` absence.

### Fatal

None for claimed eng-unary scope.

### Majors

None remaining that undermine claimed eng-unary host craft. Slot-full → connection_close and missing automated TLS oneshot are **residuals** (see Minors), not craft breaks of the R1 class.

### Minors

| ID | Issue |
|----|--------|
| **CQ-m1** | Slot exhaustion still closes the whole connection (no `RST_STREAM(REFUSED_STREAM)`). Eng serial + CAP=8 makes this rare; multi-slot structure still meets a crude failure mode. PR9 should RST-the-stream. |
| **CQ-m2** | No automated “handshake → ALPN h2 → SETTINGS → GET → 200 DATA” on the ring. Offline host + ALPN unit + manual curl — same honesty split as PR5/PR6 oneshot/SSE. Acceptable for eng WOW; not a product bar. |
| **CQ-m3** | Bad-request 400 frees the slot before exchange finish; complete hooks cannot fire for that sid (serial_busy held until flush/end). |
| **CQ-m4** | `sse_start` / progressive stream still hard-code `conn.slot`, not `h2_slots[i]`. Eng forbids SSE-on-H2 — residual dual-path landmine for PR9. |
| **CQ-m5** | `body_reserve` H1-style heading into `resp_buf`; H2 materialize scrapes after `\r\n\r\n` by coincidence. |
| **CQ-m6** | Date header only when status in `[OK, Internal_Server_Error]` inclusive — 501–599 skip date. |
| **CQ-m7** | Serial recursive `exchange_done → dispatch_one` can stack under a flooded client; eng OK. |

### What would still polish (not required for eng WOW)

1. Slot full → RST that stream, keep conn.
2. One short-lived local TLS H2 oneshot in `http` tests (or env-gated).
3. Assert/fail-closed if `sse_start` under `h2_active` until PR9 owns it.

### WOWED: **yes**

R1 GOAWAY omission and fake concurrent switch are gone. Dual-path skeleton + real error wire + forced serial are eng-elite for claimed scope.

---

## 2. Performance — Score **9.0** / WOWED **yes**

### What is elite for eng-unary performance honesty

1. **Serial HOL is default, forced, and labeled.** Engine accepts frames; handlers do not interleave. Docs, defaults, and coerce path agree. No “H2 multiplex perf” marketing.

2. **Duplex is structural.** After seal/submit, send CQE, respond with pending DATA: `tls_host_arm_recv`. `tls_ct_recv_inflight` keeps arm single-flight. WINDOW_UPDATE can arrive while CT DATA drains.

3. **Windowed seal reuses TLS H1 physics.** `h2_out` sealed ≤ `PULL_WINDOW` with `pt_admit`; residual wBIO drain; partial SSL_write consumes prefix. Not dump-entire-buffer SSL_write.

4. **Engine path is flow-aware (PR7).** Host uses `conn_send_response` → pending; `conn_feed` on WINDOW_UPDATE re-flushes; `maybe_finish` waits `conn_has_pending_body`. Live windows for oneshot without inventing public Wait_Flow.

### Fatal

None for eng oneshot.

### Majors

None that break eng-unary performance claims. Materialize-all and O(n) prefix shift remain **phase residuals** (scale under large multi-frame bodies), not falsifications of eng oneshot duplex/window law.

### Minors / phase residuals

| ID | Issue |
|----|--------|
| **PERF-m1** | Oneshot materialize Static/Bytes into `resp_buf`, then engine `pending`, then `h2_out` — 2–3× bandwidth memory for large bodies; no progressive produce. Eng unary tolerates; PR9 progressive path is separate. |
| **PERF-m2** | `h2_out` prefix drop is O(n) copy+resize per seal window. Fine for eng small responses. |
| **PERF-m3** | No host offline unit of “tight INITIAL_WINDOW_SIZE → duplex WINDOW_UPDATE → finish.” Engine `flow_test` covers codec; host chain unproven end-to-end offline. |
| **PERF-m4** | Slot alloc linear scan of 8 — fine at CAP=8. |
| **PERF-m5** | Named plan-a `Wait_Flow` op absent; eng oneshot parks via `serial_busy` + pending. Correct for Phase 4. |

### What would polish

1. Host unit: SETTINGS window=10, 25-byte body, feed WINDOW_UPDATEs through `h2_host_on_pt`, assert finish only after drain.
2. Head-index / `remove_range` drain for `h2_out`.
3. Optional chunked `conn_send_body` without full materialize (still serial).

### WOWED: **yes**

For eng unary, duplex + serial honesty + windowed seal are the performance law. Materialize/shift are named scale residuals, same class PR7 r2 accepted under WOW for engine scope.

---

## 3. Memory — Score **9.1** / WOWED **yes**

### What is elite after r2

1. **Lazy multi-slot (R1 MEM-M1 closed).** Clear-H1 and TLS-H1 Connections do not embed eight `Response`-bearing slots. Heap slab only after ALPN h2; free on destroy. Size pin test documents the tax avoided.

2. **Engine destroy + buffer delete on teardown.** Free-list zeros pointers after destroy; slot reset clears exchange state when used.

3. **Stream reap after respond** (engine F16): map does not retain every historical sid under serial oneshot load.

4. **Request body owned once** into temp (`_pre_body`) so stream reaping cannot free handler-visible bytes mid-handler.

5. **PT high-water** on seal refuses unbounded plaintext admit (close on refuse).

### Fatal

None observed on free-list reuse (destroy before free-list return; H2 re-init on open).

### Majors

None remaining that match R1’s always-on slab class. Body multi-copy and `h2_out` growth are eng oneshot residuals.

### Minors

| ID | Issue |
|----|--------|
| **MEM-m1** | Body triple-buffer under tight peer windows: materialize (`resp_buf`) + engine `pending` + framed `h2_out` (+ TLS CT tx). Large oneshot holds payload multiple times until drain. |
| **MEM-m2** | `h2_out` growth unbounded until seal catches up (no host cap beyond PT admit per window). Early-return when wire in flight is correct; backpressure on take/dispatch would polish. |
| **MEM-m3** | `h2_pt_buf` sized to recv_buf_size, retained for H2 conn life — fine; not shared with scanner pool. |
| **MEM-m4** | Slot free on 400 before complete hooks (CQ-m3) can leave hook side-effects unrun. |
| **MEM-m5** | Engine `Http2_Connection` still lives on every Connection struct (zeroed until open) — small vs former 8× slot tax; acceptable eng embedding. |

### What would polish

1. Single body ownership into engine pending when cmds are already contiguous bytes.
2. Cap or backpressure when `len(h2_out)` exceeds N windows (stop take/dispatch; keep duplex arm).
3. Optional serial-only single-slot until concurrent product needs CAP=8.

### WOWED: **yes**

Headline memory failure (always-on multi-slot tax on every Connection) is closed. Residual multi-copy is eng oneshot physics, not a free-list or H1-tax crime.

---

## 4. Shortcuts / honesty — Score **9.3** / WOWED **yes**

### What is elite (product + internal honesty)

1. **No README “supports HTTP/2.”** Matrix concurrent/SSE **⏳**; TLS H2 oneshot is Phase 4 eng only. IMPLEMENTATION_STATUS PR8 row and non-claims table explicit. H2_ENGINE forbids product claim and separates PR8 eng from PR9 M1–M6.

2. **Serial always named; false coerced honestly.** Opt comment, package header, status docs, and one-shot warn agree: not a mux switch.

3. **GOAWAY comments match wire.** No more “Best-effort GOAWAY” fiction; host documents ownership of `goaway_write`.

4. **Version 1.1 view of H2** documented on request builder — not smuggled as full HTTP/2 semantics to handlers.

5. **Manual curl labeled manual** in Quick verify / status.

6. **File cmd unsupported** logs rather than silent success.

7. **Lazy slots documented** as eng structure for PR9, not concurrent product use under serial.

### Fatal

None on product overclaim.

### Majors

None. HON-M1/M2 closed; formal Wait_Flow absence stays language-tight in H2_ENGINE/status (not sold as progressive produce).

### Minors

| ID | Issue |
|----|--------|
| **HON-m1** | `curl --http2` green is operator faith on a given OpenSSL/PEM host — not CI. Status mostly honest; “Done (engineering only)” still stronger than “unit+manual” alone — acceptable at eng bar. |
| **HON-m2** | Multi-slot “structure” is real; **use** under serial is one slot. Docs mostly say this; keep PR9 language from claiming CAP=8 concurrent. |
| **HON-m3** | Live windows yes; formal Wait_Flow / Produce_Window host roles no — residual design-track language only if status drifts. Currently careful. |

### What would polish

1. Optional CI-able eng probe (env-gated) so “Done” is not only offline unit + manual.
2. Hold matrix/README discipline through PR9 (already elite — hold it).

### WOWED: **yes**

Product honesty was already near-WOW in r1; internal GOAWAY/serial shortcuts that blocked the axis are closed and tested.

---

## Cross-cutting: dual path (H1 vs H2)

| Path | H1 | H2 eng |
|------|----|--------|
| Post-Open | `conn_handle_reqs` / scanner | `h2_host_on_open` (+ lazy slots) |
| PT | scanner free window | `h2_pt_buf` → `conn_feed` |
| Request body | scanner + `body()` | `_pre_body` (framed complete) |
| `respond` wire | status-line / plan / CT seal | HPACK + DATA via engine |
| Exchange slot | `conn.slot` | `h2_slots[i]` (nil until h2 open) |
| Conn error | H1 close paths | GOAWAY + flush + close |
| Long-lived SSE/WS | PR6 TLS H1 | **not eng** (landmine if called) |
| Send complete | oneshot clean / long-lived stream | `h2_host_on_send_complete` only |

**Regression:** full `odin test http` green (141) under this tree is strong evidence H1 was not gutted. Remaining dual-path bugs are **H2-side PR9 landmines** (SSE slot ownership, slot-full RST), not H1 scanner corruption under ALPN h2.

---

## Fatals / Majors / Residuals (rollup)

### Fatals
- **None** for claimed eng-unary scope.

### Majors
- **None remaining** from r1 that undermine eng-unary claims.

### Fixed from r1
| ID | Axis | One-liner |
|----|------|-----------|
| CQ-M1 / HON-M1 | CQ / Honesty | Real GOAWAY + flush-once + close; tests pin frame |
| CQ-M2 / HON-M2 | CQ / Honesty | Serial always; false coerced with warn |
| MEM-M1 | Mem | Lazy `^[H2_SLOT_CAP]Stream_Slot` on open only |

### Named residuals (not WOW blockers for eng unary)
| ID | Axis | One-liner |
|----|------|-----------|
| CQ-m1 | CQ | Slot full → close conn (prefer RST stream in PR9) |
| CQ-m2 | CQ | No automated TLS H2 oneshot on ring |
| CQ-m4 | CQ | SSE still on `conn.slot` under H2 |
| PERF-m1/m2 | Perf | Materialize-all; O(n) `h2_out` shift |
| PERF-m3 | Perf | No host tight-window duplex unit |
| MEM-m1/m2 | Mem | Triple body buffer; unbounded `h2_out` until seal |
| HON-m1 | Honesty | Manual curl / no CI eng probe |

---

## What would still polish (eng unary — still without M1–M6)

| Axis | Optional polish (not required for this WOW) |
|------|-----------------------------------------------|
| **Code quality** | RST on slot refuse; one ring/TLS eng oneshot test; assert on SSE under `h2_active` |
| **Performance** | Host tight-window duplex unit; cheaper `h2_out` drain; optional chunked send_body |
| **Memory** | Avoid triple body copy; cap `h2_out` / dispatch backpressure |
| **Honesty** | Optional CI eng probe; hold matrix/README (already good) |

---

## Bottom line

PR8 r2 **closes the craft failures** that withheld WOW on r1 without expanding into product M1–M6. Real GOAWAY on connection error, forced-serial (false coerced), and lazy multi-slot allocation make the engineering unary H2 host match its own docs and engine contract.

It still does **not** claim concurrent product, SSE-on-H2, or README HTTP/2 — correctly. Residuals are PR9 handoff and eng-oneshot scale edges, not host-contract lies.

**Mean 9.2 — eng unary WOW. Ship-as-eng with residual list; celebrate host craft for claimed scope.**
