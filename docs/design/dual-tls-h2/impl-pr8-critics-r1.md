# Implementation Critics — PR8 r1 (multi-axis)

**Posture:** harsh elite. Credit only **claimed PR8 eng-unary scope**.  
**Bar:** WOW ≥ 9 for **claimed eng-unary scope only** (product M1–M6 **not** required):

| Claimed in | Claimed out |
|------------|-------------|
| ALPN prefer `h2`, fallback `http/1.1` | Product “supports HTTP/2” / README |
| After TLS Open: `h2_host` feed/dispatch/respond (**not** H1 scanner) | Concurrent mux product / fairness |
| Multi-slot slab `H2_SLOT_CAP=8`; **serial** dispatch default | Matrix concurrent/SSE H2 ✅ |
| Duplex CT recv re-arm while H2 DATA may pump | SSE-on-H2 / M1–M6 |
| Live windows: feed `WINDOW_UPDATE` → flush pending DATA | Named `Wait_Flow` executor op zoo |
| `curl --http2` eng oneshot green (**manual**) | Full h2spec / CI ring e2e H2 |
| Same `server.handler` / `respond` | Plan-A progressive H2 produce path |

**Not required for WOW:** product concurrent slots, SSE-on-H2, M1–M6, matrix flips, dual-CT seal∥send, peer-grade HPACK encoder, inbound recv-window throttle.  
**Required for WOW:** real ALPN→engine host (not a flag), H1 dual-path stays clean, serial gate is real, destroy/free order holds, duplex is not theater, live-window drain works without lying about GOAWAY/flags, docs refuse product overclaim, residuals named.

**Date:** 2026-08-08  
**Subject:** `http/h2_host.odin`, `http/h2_host_test.odin`, `http/tls_host.odin` (ALPN Open branch + CT/send demux), `http/response.odin` (H2 respond), `http/server.odin` / `http/conn_slab.odin` (Connection H2 fields), `tls_server` ALPN selectors, `docs/{H2_ENGINE,IMPLEMENTATION_STATUS,CAPABILITY_MATRIX}.md`.

---

## Verify (this pass)

| Command / check | Result |
|-----------------|--------|
| `odin test http -define:ODIN_TEST_THREADS=1 -o:none` | **136/136 pass** (OpenSSL dynlib present on this host) |
| H2 unit surface | `h2_host_test`: request build, pre-body, response headers, offline loopback glue, slot slab, serial busy gate, default serial true |
| ALPN unit | `tls_server` tests: prefer `h2`, fallback `http/1.1`, H1-only selector, `alpn_is_h2` nil-safe |
| Product “supports HTTP/2” | **Clean** — matrix TLS H2 concurrent/SSE **⏳**; README not flipped; status/H2_ENGINE forbid claim |
| Live `curl --http2` | **Not automated this pass** — docs: manual against `examples/https_demo` |

**LOC (approx.):** `h2_host.odin` ~750; `h2_host_test.odin` ~287; integration is thin branches in `tls_host` / `response` / `server` / `conn_slab`.

---

## Scoreboard

| Axis | Score | WOWED | Worst class |
|------|------:|:-----:|-------------|
| Code quality | **7.9** | **no** | Major (GOAWAY never written; `h2_serial_dispatch=false` is a broken switch) |
| Performance | **8.4** | **no** | Major fringe (oneshot materialize + O(n) `h2_out` shift; no host-level tight-window proof) |
| Memory | **7.4** | **no** | Major (always-on `H2_SLOT_CAP`×`Stream_Slot` on every Connection; body triple-buffer) |
| Shortcuts / honesty | **8.6** | **no** | Major fringe (“Best-effort GOAWAY” comment; serial flag implies concurrency) |
| **Mean** | **8.1** | — | — |

**Verdict:** PR8 is a **real engineering unary H2 host**, not a paper PR. ALPN prefer-h2 is wired into shared `SSL_CTX`; post-Open `alpn_is_h2` diverts off the H1 scanner into `h2_host_*`; `respond` never assembles H1 wire under `h2_active`; multi-slot sid map exists; serial busy is the default and is unit-tested; duplex re-arms CT recv while frame CT may be in flight; engine pending + `conn_has_pending_body` keep the exchange open until DATA drains under peer windows. Product honesty in status/matrix/H2_ENGINE is elite.

**WOW is withheld on all four axes.** Eng unary *can* WOW without M1–M6 — this pass does not. The host violates its own engine contract on connection errors (never emits `GOAWAY` despite “transport runtime sends GOAWAY”); exposes `h2_serial_dispatch=false` as if concurrent while a single `h2_dispatch_sid` / `loop.req` / finish path cannot host two handlers; taxes every Connection with eight full `Stream_Slot`s for a serial eng path that uses one; and proves almost nothing on the live TLS ring (offline glue + manual curl only). That is solid Phase-4 eng craft with sharp residual edges — not wow.

---

## Architecture map (what PR8 actually installed)

```text
TLS accept → SSL_CTX ALPN select: alpn_select_h2_or_http11 (prefer h2)
  Handshake CQE… → Open
    tls_host_open_start_protocol
      alpn_is_h2?
        yes → h2_host_on_open
                conn_init(engine) + SETTINGS preface → h2_out
                flush_out (windowed SSL_write → CT send)
                tls_host_arm_recv (duplex; even if send inflight)
        no  → tls_host_open_start_http → H1 scanner (unchanged)

CT recv CQE (Open, h2_active):
  h2_host_on_ct_ready
    SSL_read burst → h2_pt_buf → conn_feed(engine, pt, h2_out)
      (WINDOW_UPDATE → _flush_stream → more DATA into h2_out)
    flush_out → maybe_finish_exchange → dispatch_one
    re-arm CT recv always (duplex law)

dispatch_one (serial default):
  if serial && h2_serial_busy → return
  conn_take_request → slot_alloc(sid) → h2_request_from_headers
  response_init(h2_slots[i]) → server.handler → respond

respond (h2_active):
  skip H1 body-discard scanner path (pre_body already complete)
  skip H1 status-line assembly
  materialize body cmds → resp_buf scrap
  conn_send_response (flow-aware engine) → h2_out → flush_out
  maybe_finish: wait h2_out empty + !wire + !pending_body + end_sent
  exchange_done → slot_free → serial_busy=false → dispatch_one again

CT send CQE:
  h2_host_on_send_complete → flush_out → maybe_finish → dispatch_one → arm_recv

destroy (connection_destroy):
  tls_host_conn_destroy then h2_host_destroy
    conn_destroy engine; delete h2_out; reset slots; delete h2_pt_buf
```

**H1 regression gate:** `h2_active` is false until ALPN h2 Open; respond/recv/send paths fall through to H1. Full `odin test http` green is the regression proof available this pass.

---

## 1. Code quality — Score **7.9** / WOWED **no**

### What is elite for claimed eng-unary scope

1. **Real protocol branch, not a sticky note.** `tls_host_open_start_protocol` is the single post-Open demux; `alpn_is_h2` → `h2_host_on_open`, else H1 `conn_handle_reqs`. CT Open path short-circuits to `h2_host_on_ct_ready` before scanner decrypt. Send complete returns early through `h2_host_on_send_complete`. That is the dual-path law done correctly for eng.

2. **Same handler / respond surface.** Pseudos map to `Request` with version **1.1** (documented handler-compat). Body lands in `_pre_body`; `body()` works offline. `respond` applies body middleware then `h2_host_send_response` — no second public API, no stream-id on the App Contract.

3. **Serial gate is a real gate.** `h2_serial_busy` + `h2_dispatch_sid`; default `Server_Opts.h2_serial_dispatch = true`; unit test proves dispatch no-ops while busy. Engine still `conn_feed`s other streams’ frames while one handler owns the exchange — correct eng HOL shape.

4. **Multi-slot structure is not a comment.** `H2_SLOT_CAP=8`, sid map, alloc/find/free, `response_init(..., slot)` binds `h2_slots[i]`. Serial uses one at a time; the slab is pre-positioned for PR9 without pretending it is product mux.

5. **Destroy path is ordered and free-list safe.** `connection_destroy` → `tls_host_conn_destroy` then `h2_host_destroy`; engine `conn_destroy` only when `h2_active`; `h2_out` / `h2_pt_buf` deleted; slots reset; `h2 = {}` so free-list reuse + re-open can `conn_init` cleanly. Alloc path zeros H2 flags/buffers. Close still defers on wire / CT-recv inflight (shared free-order discipline).

6. **Hop-by-hop strip on response map.** `connection` / `transfer-encoding` / `keep-alive` / `upgrade` dropped; `:status` digits; date parity for common 2xx–5xx range. Offline test pins `connection` absence.

7. **Handler fail-closed.** No `respond` → forced 500 on the dispatch sid. OPTIONS `*` short-circuit. HEAD body suppressed. File body cmd omitted with warn (eng honesty).

8. **H1 stays out of the H2 framing path.** No scanner for H2 PT; PT scratch is `h2_pt_buf`. TCP0 / recv error under `h2_active` close the conn (no session hangup theater on eng oneshot).

### Fatal

None for **claimed eng-unary scope**. There is no product-matrix lie, no H1 scanner still owning ALPN-h2 bytes, no free-list UAF obvious on paper, no double-submit of CT recv without the PR6 inflight guard (reused correctly).

### Majors

| ID | Issue | Evidence |
|----|--------|----------|
| **CQ-M1** | **Connection errors never emit GOAWAY.** Engine `_fail` only sets `fail_code` and documents “the transport runtime sends GOAWAY”. Host on `conn_feed` error: log, `flush_out` (whatever was already queued), `connection_close`. **`goaway_write` is never called anywhere in the tree.** Comment “Best-effort GOAWAY” is aspirational fiction. Peers see TCP death, not a coded GOAWAY. | `h2_host_on_pt` ~169–175; `goaway_write` only defined in `http2/frame.odin` |
| **CQ-M2** | **`h2_serial_dispatch=false` is a broken dual path, not concurrent.** If the flag is false, `dispatch_one` skips the busy check and can `take_request` / run a second handler while the first still owns `h2_dispatch_sid`, `loop.req`, and `maybe_finish_exchange`. There is **one** dispatch sid and **one** finish path. Flipping the opt does not install mux — it installs a clobber. Default true saves product; the opt surface is still a landmine. | `h2_host_dispatch_one` ~189–195 vs single `h2_dispatch_sid` / `h2_host_send_response` |
| **CQ-M3** | **Slot exhaustion closes the whole connection.** No free slot → `connection_close` with a warn, not `RST_STREAM(REFUSED_STREAM)` / GOAWAY. Eng serial with CAP=8 makes this rare, but the multi-slot structure claim meets a crude failure mode the engine already knows how to express. | `h2_host_dispatch_one` ~204–208 |
| **CQ-M4** | **No host-level test of the live dual path.** Offline glue feeds engine buffers without TLS/ring. ALPN selectors are unit-tested. There is no automated “handshake → ALPN h2 → SETTINGS → GET → 200 DATA” on the ring. Claimed curl green is manual-only — acceptable as eng milestone **only if** craft elsewhere is airtight; CQ-M1/M2 say it is not. | `h2_host_test`; `IMPLEMENTATION_STATUS` Quick verify |

### Minors

| ID | Issue |
|----|--------|
| **CQ-m1** | Bad-request 400 path **frees the slot before** exchange finish; complete hooks cannot fire for that sid (serial_busy still held until flush/end). |
| **CQ-m2** | `sse_start` / progressive stream still hard-code `conn.slot`, not `r._slot` / `h2_slots[i]`. Eng forbids SSE-on-H2 — residual dual-path landmine for PR9. |
| **CQ-m3** | `body_reserve` writes an H1-style heading into `resp_buf`; H2 materialize scrapes body after `\r\n\r\n`. Works only by coincidence of scrap logic — not a designed H2 body_reserve path. |
| **CQ-m4** | Date header only when status in `[OK, Internal_Server_Error]` inclusive — 501–599 skip date. |
| **CQ-m5** | Feed-error path does not even attempt `goaway_write` with `fail_code` / `last_peer_sid` before close (same as CQ-M1; listed for fix targeting). |
| **CQ-m6** | Serial recursive `exchange_done → dispatch_one` can stack under a flooded client; eng OK, not production-hardened. |

### What would WOW

1. **On every connection-error return:** `goaway_write(&h2_out, last_peer_sid, fail_code)` then flush then close — and a unit test that peer sees GOAWAY bytes.
2. **`h2_serial_dispatch=false`:** either remove, or assert/ignore, or implement real multi-sid respond finish. Do not ship a boolean that means “corrupt.”
3. **Slot full → RST that stream**, keep conn (engine already has the RST write path).
4. **One automated TLS H2 oneshot** (even a short-lived local server in `http` tests) so ALPN+host is not faith-based.
5. **H2 path assert** if `sse_start` / `begin_stream` under `h2_active` until PR9 owns it.

### WOWED: **no**

Dual-path skeleton is correct and H1-preserving; GOAWAY omission and the fake concurrent switch are craft failures under the host’s own responsibilities.

---

## 2. Performance — Score **8.4** / WOWED **no**

### What is elite for eng-unary performance honesty

1. **Serial HOL is default and labeled.** Engine accepts frames; handlers do not interleave. Docs and `Default_Server_Opts` agree. No “H2 multiplex perf” marketing. That is the right eng posture (plan-a D3 / Phase 4).

2. **Duplex is structural, not a hope.** After seal/submit, after send CQE, after respond with possible pending DATA: `tls_host_arm_recv` runs. `tls_ct_recv_inflight` keeps arm single-flight (PR6 fix reused). WINDOW_UPDATE can arrive while CT DATA still drains — required for live windows under tight peers.

3. **Windowed seal reuses TLS H1 physics.** `h2_out` sealed ≤ `PULL_WINDOW` with `pt_admit` high-water; residual wBIO drain; partial SSL_write consumes prefix; recursion only when wire idle. Not a dump-entire-buffer SSL_write.

4. **Engine path is flow-aware (PR7 r2).** Host uses `conn_send_response` → headers+body with pending; `conn_feed` on WINDOW_UPDATE re-`_flush_stream`s into `h2_out`; `maybe_finish` waits `conn_has_pending_body`. Live windows for oneshot are real **without** inventing a public Wait_Flow API.

### Fatal

None for eng oneshot. No mandatory mid-response clean_request_loop, no plain-send of H2 frames under TLS.

### Majors

| ID | Issue | Evidence |
|----|--------|----------|
| **PERF-M1** | **Oneshot materialize-all then frame.** Entire Static/Bytes body copies into `resp_buf`, then engine copies into `stream.pending`, then frames into `h2_out`. Eng unary tolerates this; large bodies pay 2–3× bandwidth memory and cannot progressive-produce into windows. Claimed scope is oneshot — Major fringe, not Fatal. | `h2_host_materialize_body` + `conn_send_body` append |
| **PERF-M2** | **`h2_out` prefix drop is O(n) copy+resize per seal window.** Same class as naive buffer shift; fine for small eng responses; will show under multi-frame DATA. | `h2_host_flush_out` ~476–483 |

### Minors

| ID | Issue |
|----|--------|
| **PERF-m1** | No host offline test of “tight INITIAL_WINDOW_SIZE → duplex WINDOW_UPDATE → finish.” Engine `flow_test` covers codec; host chain unproven. |
| **PERF-m2** | Slot alloc is linear scan of 8 — fine at CAP=8; do not grow CAP without freelist. |
| **PERF-m3** | `conn_has_pending_body` / finish checks scan engine streams — OK under serial + reap; watch under future mux. |
| **PERF-m4** | Named plan-a `Wait_Flow` op is absent; eng oneshot parks implicitly via `serial_busy` + pending. Correct for Phase 4; not a progressive produce path. |

### What would WOW

1. Cursor/`remove_range`-style or head-index drain for `h2_out` (avoid full shift per window).
2. Host unit (sans ring): inject SETTINGS window=10, send 25-byte body, feed WINDOW_UPDATEs through `h2_host_on_pt`, assert finish only after drain — pins duplex+live-window host law.
3. Optional streaming `conn_send_body` chunks for large eng bodies without full materialize (still serial).

### WOWED: **no**

Duplex + serial honesty are strong; materialize/shift and missing host-level window proof keep this under 9.

---

## 3. Memory — Score **7.4** / WOWED **no**

### What is solid

1. **Engine destroy + buffer delete on conn teardown.** `h2_pt_buf` uses `conn_allocator`; free-list zeros pointers after destroy. Slot reset clears exchange state when used.
2. **Stream reap after respond** (engine F16): `conn_send_*` / `conn_feed` reap closed streams so the map does not retain every historical sid under serial oneshot load.
3. **Request body owned once** into temp allocator (`_pre_body` copy) so stream reaping cannot free handler-visible bytes mid-handler.
4. **PT high-water** on seal refuses unbounded plaintext admit (close on refuse).

### Fatal

None observed on free-list reuse paths in this read (destroy before free-list return; H2 re-init on open).

### Majors

| ID | Issue | Evidence |
|----|--------|----------|
| **MEM-M1** | **Always-on multi-slot tax on every Connection.** `h2_slots: [8]Stream_Slot` embeds **eight full `Response`s** (headers maps, cmd arrays, hook arrays, buffer handles) plus session/stream fields — paid by clear-H1 and TLS-H1 conns that never negotiate h2. Eng “structure is real” is true; memory cost of pre-positioning PR9 on the hot Connection object is real too. | `server.odin` Connection; `Stream_Slot` / `Response` |
| **MEM-M2** | **Body triple-buffer under windows.** Materialize (`resp_buf`) + engine `pending` + framed `h2_out` (plus TLS CT tx scratch). Large oneshot response under small peer window holds the payload multiple times until drain. | materialize + `conn_send_body` + `h2_out` |
| **MEM-M3** | **`h2_out` growth unbounded until seal catches up.** Engine may append control + DATA faster than CT send CQEs drain; no host cap on `len(h2_out)` beyond eventual PT admit per window. | `h2_host_flush_out` early-return when wire in flight |

### Minors

| ID | Issue |
|----|--------|
| **MEM-m1** | `h2_pt_buf` sized to recv_buf_size, retained for conn life under H2 — fine; not shared with scanner pool. |
| **MEM-m2** | Slot free on 400 before complete hooks (CQ-m1) can leave hook side-effects unrun (resource discipline for middleware). |
| **MEM-m3** | Free-list alloc clears H2 flags but does not `stream_slot_reset_exchange` unused `h2_slots[*]` — open path resets all eight; OK if open always runs. |

### What would WOW

1. **Lazy multi-slot:** allocate/grow `h2_slots` only after ALPN h2 (or a small serial-only single slot until concurrent).
2. **Single body ownership** into engine pending (skip full resp_buf materialize when cmds are already contiguous bytes).
3. **Cap or backpressure** when `len(h2_out)` exceeds N windows (stop take/dispatch; keep duplex arm).

### WOWED: **no**

Teardown is careful; always-on 8× slot embedding and triple body buffering are not eng-elite memory craft.

---

## 4. Shortcuts / honesty — Score **8.6** / WOWED **no**

### What is elite (product / status honesty)

1. **No README “supports HTTP/2”.** Capability matrix TLS H2 oneshot is “Phase 4 eng may work / not product”; concurrent/SSE **⏳**. `IMPLEMENTATION_STATUS` PR8 row and non-claims table are explicit. `H2_ENGINE.md` forbids product claim and separates PR8 eng from PR9 M1–M6.
2. **Serial default named HOL.** Comments and opts document eng unary, not multiplex product.
3. **Version 1.1 view of H2** is documented on the request builder — not smuggled as true HTTP/2 semantics to handlers.
4. **Manual curl is labeled manual** in Quick verify (“not live curl” for `odin test http`).
5. **File cmd unsupported** logs rather than silent success.

### Fatal

None on product overclaim. This tree does **not** flip matrix concurrent/SSE or market M6.

### Majors

| ID | Issue | Evidence |
|----|--------|----------|
| **HON-M1** | **“Best-effort GOAWAY” is a written lie.** Host comment claims GOAWAY may already be in `h2_out`; engine never auto-writes GOAWAY on `_fail`; host never calls `goaway_write`. Close-after-error is the real behavior. | CQ-M1 |
| **HON-M2** | **`h2_serial_dispatch` opt surface overclaims.** Name + docs (“when true… at most one”) imply false enables multi-handler dispatch. Implementation cannot. Ship default true is honest; shipping a non-working false is a shortcut. | CQ-M2; `Server_Opts` comment |
| **HON-M3** | **“Live windows” claim is true at engine+duplex, missing formal Wait_Flow.** Plan-a language (Wait_Flow / Produce_Window) is not implemented as host roles. Eng oneshot still drains via feed+pending — **behaviorally honest** if you do not claim progressive produce. Residual: do not let status language drift into “full live-window executor.” Currently H2_ENGINE/status stay careful enough — fringe Major for the missing named mechanism the design track taught. | plan-a vs `h2_host_maybe_finish_exchange` |

### Minors

| ID | Issue |
|----|--------|
| **HON-m1** | Multi-slot “structure” is real; **use** under serial is one slot. Docs mostly say this; keep PR9 language from claiming CAP=8 concurrent. |
| **HON-m2** | `curl --http2` green is **operator faith** on a given OpenSSL/PEM host — not CI. Status is mostly honest; “Done (engineering only)” still reads stronger than “unit+manual.” |
| **HON-m3** | ALPN comment “does not imply product HTTP/2 framing” is good; framing **does** run under eng host — fine if product bar stays M1–M6. |

### What would WOW

1. Emit real GOAWAY; delete the fake comment; add a regression test.
2. Delete or hard-force `h2_serial_dispatch` until concurrent finish exists; document “always serial in PR8.”
3. One CI-able eng probe (or skip with explicit `// +build` / env) so “Done” is not only offline unit.
4. Keep matrix/README discipline through PR9 (already elite — hold it).

### WOWED: **no**

Product honesty is near-WOW; internal GOAWAY/serial-flag shortcuts block the axis.

---

## Cross-cutting: dual path (H1 vs H2)

| Path | H1 | H2 eng |
|------|----|--------|
| Post-Open | `conn_handle_reqs` / scanner | `h2_host_on_open` |
| PT | scanner free window | `h2_pt_buf` → `conn_feed` |
| Request body | scanner + `body()` | `_pre_body` (framed complete) |
| `respond` wire | status-line / plan / CT seal | HPACK + DATA via engine |
| Exchange slot | `conn.slot` | `h2_slots[i]` |
| Long-lived SSE/WS | PR6 TLS H1 | **not eng** (landmine if called) |
| Send complete | oneshot clean / long-lived stream | `h2_host_on_send_complete` only |

**Regression:** full `odin test http` green under this tree is strong evidence H1 was not gutted. Remaining dual-path bugs are **H2-side incompleteness** (GOAWAY, serial=false, SSE slot ownership), not H1 scanner corruption under ALPN h2.

---

## Fatals / Majors (rollup)

### Fatals
- **None** for claimed eng-unary scope.

### Majors
| ID | Axis | One-liner |
|----|------|-----------|
| CQ-M1 / HON-M1 | CQ / Honesty | Never write GOAWAY; comment pretends otherwise |
| CQ-M2 / HON-M2 | CQ / Honesty | `h2_serial_dispatch=false` cannot concurrent-dispatch safely |
| CQ-M3 | CQ | Slot full closes connection instead of RST stream |
| CQ-M4 | CQ | No automated TLS H2 oneshot proof |
| PERF-M1 | Perf | Full body materialize + multi-copy under windows |
| PERF-M2 | Perf | O(n) `h2_out` prefix shift per seal window |
| MEM-M1 | Mem | Eight full `Stream_Slot`s on every Connection always |
| MEM-M2 | Mem | Body triple-buffer (resp_buf / pending / h2_out) |
| MEM-M3 | Mem | Unbounded `h2_out` while CT send is in flight |
| HON-M3 | Honesty | Live windows yes; formal Wait_Flow / progressive produce no — keep language tight |

---

## What would WOW (eng unary — still without M1–M6)

| Axis | Minimal WOW package |
|------|---------------------|
| **Code quality** | Real GOAWAY on `fail_code`; kill or implement `serial=false`; RST on slot refuse; one ring/TLS eng oneshot test |
| **Performance** | Host tight-window duplex unit; cheaper `h2_out` drain; optional chunked send_body for large oneshot |
| **Memory** | Lazy/single slot until concurrent; avoid triple body copy; cap `h2_out` |
| **Honesty** | Match comments to wire; serial-only API until PR9; hold matrix/README discipline (already good) |

---

## Bottom line

PR8 **lands** the engineering unary H2 host the plan asked for: ALPN prefer-h2, post-Open engine host, multi-slot structure, serial default, duplex CT re-arm, oneshot `respond` mapping, product non-claim. That is more than a spike.

It does **not** WOW on any axis under a harsh bar because the host still skips the GOAWAY half of the engine contract, leaves a non-working concurrency switch on `Server_Opts`, taxes every connection with eight exchange slots for a one-at-a-time eng path, and proves the live ALPN path only by manual curl. Fix the Majors above and eng unary can clear ≥9 **without** product M1–M6.

**Mean 8.1 — ship-as-eng, do not celebrate as host craft complete.**
