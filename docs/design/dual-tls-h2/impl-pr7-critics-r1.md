# Implementation Critics — PR7 r1 (multi-axis)

**Posture:** harsh elite. Credit only **claimed PR7 scope**.  
**Bar:** WOW ≥ 9 for **claimed PR7 scope only**:

| Claimed in | Claimed out |
|------------|-------------|
| Sans-I/O packages `http2/` (frame + connection + flow), `hpack/`, `huffman/` | Product HTTP/2 / host / ALPN `h2` |
| `conn_feed` / `conn_send_*` / stream take / outbound flow | Ring, sockets, TLS, multi-slot slab |
| Offline unit tests green (no listen) | Matrix TLS H2 ✅, README “supports HTTP/2” |
| Own types under proactr tree (no vapor package import) | M1–M6 / SSE-on-H2 / live h2spec |

**Not required for WOW:** PR8 host install, ALPN, multi-slot, live curl `--http2`, dual-CT seal, product matrix flips.  
**Required for WOW:** the engine is a **real** RFC-facing connection codec (not frame toys + a thin demux), ownership/error paths are coherent, destroy/reap free paths hold, docs refuse product overclaim, and completeness claims match code.

**Date:** 2026-08-08  
**Subject:** `http2/{types,frame,connection,flow}.odin` + tests; `hpack/{hpack,integer}.odin` + tests; `huffman/huffman.odin` + tests; `docs/{H2_ENGINE,IMPLEMENTATION_STATUS,CAPABILITY_MATRIX}.md`.

---

## Verify (this pass)

| Command | Result |
|---------|--------|
| `odin test http2 -o:none` | **15/15 pass** |
| `odin test hpack -o:none` | **7/7 pass** |
| `odin test huffman -o:none` | **3/3 pass** |

No ring, no OpenSSL, no listen. Packages import only `core:*`, `../hpack`, `../huffman` — **no** `proactr`, `http`, `tls_server`.

**LOC (approx.):** ~2.4k lines across three packages (prod + tests). Connection core ~650 LOC.

---

## Scoreboard

| Axis | Score | WOWED | Worst class |
|------|------:|:-----:|-------------|
| Code quality | **8.0** | **no** | Major (HPACK desync on REFUSE; dual send API) |
| Performance | **7.2** | **no** | Major (map scan, O(n) pending shift, naïve Huffman) |
| Memory | **7.6** | **no** | Major (unbounded defaults; client never reaps) |
| Shortcuts / honesty | **8.5** | **no** | Major fringe (internal “complete / both-direction FC” stretch) |
| **Mean** | **7.8** | — | — |

**Verdict:** PR7 is a **real** sans-I/O HTTP/2 engine, not a paper PR. Frame wire layout, connection preface, SETTINGS/PING auto-ACK, HEADERS+CONTINUATION reassembly, request pseudo-header validation, outbound send windows with pending-buffer backpressure, stream reap under mux load, HPACK static+dynamic decode with RFC C.* vectors, Huffman Appendix B table + known vector — all land under owned packages, offline-green, with **no** product README/matrix lie.

**WOW is withheld on all four axes.** The engine is unfinished craft relative to its own scope claims: a dual send surface where only one path respects flow control; `MAX_CONCURRENT_STREAMS` refusal that **skips HPACK** (compression desync under the feature it advertises); inbound “flow control” that is 1:1 auto-grant with no receive windows; `SETTINGS_MAX_FRAME_SIZE` stored but not applied to decode/flush; encoder that never indexes; unbounded body/header defaults; client stream map never reaped. Honesty about *product* is elite; honesty about *engine completeness* is only good.

---

## Architecture map (what the engine actually is)

```text
BYTES IN
  conn_feed(c, data, out)
    → append rx buffer
    → server: consume CLIENT_PREFACE once
    → frame_decode loop (default max 16 KiB; not local_settings.max_frame_size)
    → _handle_frame:
         SETTINGS → validate + peer_settings + ACK (+ window delta flush)
         HEADERS/CONTINUATION → reassemble → hpack.decode → validate request
         DATA → append body; optional max_body; 1:1 WINDOW_UPDATE grants
         WINDOW_UPDATE → grow send windows → _flush_stream
         PING → ACK; RST/GOAWAY → fail streams; PUSH → PROTOCOL_ERROR
         PRIORITY → shape only
    → conn_reap_streams (server only)
    → out accumulates auto-replies for host to seal/send later

BYTES OUT (two APIs — see CQ-M1)
  conn_send_headers / conn_send_body  → flow-aware (pending + windows)
  conn_send_request / conn_send_response → _write_message (one-shot; no windows)

TAKE
  conn_take_request (server) / conn_response (client)  — slices into stream storage

NOT PRESENT (correct for PR7)
  ring submit_*, sockets, TLS, ALPN, Stream_Slot host, multi-slot slab
```

**Sans-I/O purity (grep fact):** zero `submit_`, `io_uring`, `kqueue`, `socket`, `SSL_`, `BIO`, `ALPN` in package sources. Contract matches `H2_ENGINE.md`.

---

## 1. Code quality — Score **8.0** / WOWED **no**

### What is elite for claimed sans-I/O engine scope

1. **Real connection state, not frame toys.** `Http2_Connection` owns HPACK decoder table, stream map, open-stream count, CONTINUATION reassembly, GOAWAY state, fail_code, send windows. `conn_feed` demuxes into that state and emits control replies into a caller-owned byte buffer. That is the PR7 contract.

2. **Owned types, no vapor import.** `Header :: hpack.Header`; packages under the tree; comments refuse foreign server types as architecture. Steal-facts / own-types law holds.

3. **Strictness that matters for smuggling / h2spec core.** Idle DATA → PROTOCOL_ERROR; even client stream id → fail; SETTINGS window > 2³¹−1 → FLOW_CONTROL_ERROR; zero WINDOW_UPDATE increment → PROTOCOL_ERROR; stream window overflow → RST_STREAM (connection survives); request pseudo rules (missing/empty `:path`, response `:status` in request, uppercase names, `connection`, `te≠trailers`); content-length mismatch; HPACK size update > SETTINGS limit → COMPRESSION_ERROR. `strict_test` pins these offline.

4. **CONTINUATION contiguity.** While `cont_sid != 0`, non-matching frames reject. Header block size can cap via `max_header_bytes`.

5. **Outbound flow + backpressure API.** `conn_send_body` returns buffered count; `_flush_stream` clamps to `min(stream_window, conn_window, frame_cap)`; WINDOW_UPDATE and SETTINGS initial-window delta re-flush. `flow_test` proves 25-byte body through 10-byte windows with END_STREAM only on the last frame; drain loop + `conn_has_pending_body` tested.

6. **Stream reap (F16).** Closed+delivered (or failed) server streams leave the map; 64 sequential empty GETs end with `len(streams)==0` and `open_streams==0`. Map growth under mux was a real RPS invert elsewhere; the fix is here and tested.

7. **PUSH refuse is intentional and correct.** `ENABLE_PUSH=0` + PUSH_PROMISE → connection error (silent skip would desync HPACK). Comment explains why.

8. **HPACK decode is a real codec.** Static table, dynamic insert/evict, size updates with `limit`, all literal forms, Huffman path, RFC C.1 / C.2.1 / C.3 / C.4 vectors. Integer codec extracted cleanly.

9. **Huffman table + known vector.** RFC 7541 C.4.1 `www.example.com` bytes match; all-256-byte roundtrip; padding/EOS checks present.

10. **Tests are offline and meaningful.** Loopback GET→200 through two connections exchanging buffers; not only encode/decode unit atoms.

### Fatal

None for **claimed PR7 scope**. No ring free-order disaster, no product ALPN lie, no host double-submit. The worst defects are Majors that will bite PR8+ or h2spec under concurrency — not “this is fake.”

### Majors

| ID | Issue | Evidence |
|----|--------|----------|
| **CQ-M1** | **Dual outbound API; only one path is flow-correct.** `conn_send_headers` / `conn_send_body` honor windows. `conn_send_request` / `conn_send_response` → `_write_message` dumps entire body as one DATA frame with **no** window check and **no** `pending` / `end_sent` bookkeeping. Loopback test uses the bypass path. Hosts that pick the “simple” API under tight peer windows will violate RFC 9113 §6.9. | `connection.odin` `_write_message` vs `flow.odin` `_flush_stream` |
| **CQ-M2** | **`MAX_CONCURRENT_STREAMS` refuse skips HPACK.** On NEW stream over limit: `rst_stream_write(REFUSED_STREAM); return .None` **before** header-block decode. Peer incremental indexing still mutates *their* encoder state; *our* decoder never sees the block → **COMPRESSION_ERROR** on later good streams. Classic H2 footgun. Gate is written “before HPACK so CONTINUATION path is covered” — wrong direction: must reassemble/decode for table sync, then refuse delivery. | `connection.odin` ~279–284 |
| **CQ-M3** | **Inbound flow control is not flow control.** Receiving DATA always emits connection (+ stream) WINDOW_UPDATE for full frame length. There is **no** receive window, no local credit, no ability to apply backpressure inbound. Comment admits “we buffer everything.” Under claimed “both-direction flow control” this is half a story: outbound is real; inbound is auto-grant + optional hard caps. | DATA arm ~334–341; header comment L9–12 |
| **CQ-M4** | **`SETTINGS_MAX_FRAME_SIZE` is decorative on the hot path.** `frame_decode` in `conn_feed` always uses default 16384. Outbound `_flush_stream` clamps to `DEFAULT_MAX_FRAME_SIZE`, not `peer_settings.max_frame_size`. Peer advertising larger frames is ignored for send; local advertised max is not enforced as decode max from settings. | `conn_feed` L209; `flow.odin` L67; settings stored but unused for size |
| **CQ-M5** | **`fail_code` is incomplete on Protocol paths.** Preface mismatch and CONTINUATION contiguity violation return `.Protocol` without `_fail(...)`, so `fail_code` stays 0 while `conn_feed` failed — host told to GOAWAY(0) if it only reads `fail_code`. | `connection.odin` L202, L227 vs `_fail` elsewhere |
| **CQ-M6** | **HPACK encoder is not a peer-grade compressor.** Encode path: static exact match → Indexed; else Literal **Without** Indexing only. Never grows encoder dynamic table; never emits size updates. Decode is complete; encode is deliberately simple. Docs call it a “Complete RFC 7541 codec” — decode yes, encode partial. | `hpack.odin` encode L216–230 |

### Minors

| ID | Issue |
|----|--------|
| **CQ-m1** | Unknown frame types silently ignored (no error). RFC allows; document if intentional for forward-compat. |
| **CQ-m2** | No CONTINUATION unit test — only HEADERS single-frame paths in suite. Reassembly code exists untested. |
| **CQ-m3** | Trailers allowed only with END_STREAM; good. No test that trailers actually deliver. |
| **CQ-m4** | Client `conn_response` does not require `headers_done` separately from `end_stream` — OK if HEADERS always sets both; fragile if DATA-only end ever appeared. |
| **CQ-m5** | `settings_write` omits `HEADER_TABLE_SIZE` / `MAX_HEADER_LIST_SIZE` — peers keep 4096 assumption; fine if permanent, silent if not. |
| **CQ-m6** | Priority is stripped/validated only; no dependency tree (correct for modern H2 deprecation) — comment is honest enough. |

### What would WOW

1. **One send surface** that always respects flow (or mark `_write_message` `@(private)` test-only and force hosts through `conn_send_*`).
2. **Refuse after HPACK process** (decode for table sync; do not `conn_take_request` / do not count as delivered; RST or REFUSED).
3. **Apply `max_frame_size`** from local settings on decode and peer settings on flush.
4. **Set `fail_code` on every connection-error return.**
5. **CONTINUATION + refuse + multi-stream HPACK sync tests** (not only atom strictness).
6. Optional: encoder dynamic table or an explicit `// encode is non-indexing by design` in `H2_ENGINE.md` so “complete codec” is not a stretch.

### WOWED: **no**

Real engine; dual-path and REFUSE/HPACK are craft failures under the engine’s own concurrent-streams and flow claims.

---

## 2. Performance — Score **7.2** / WOWED **no**

Claimed scope is offline engine correctness, not RPS. Still score honesty of data structures the host will inherit in PR8.

### What is acceptable for an offline codec

| Path | Behavior | Grade |
|------|----------|-------|
| Frame parse | Fixed 9-byte header + slice payload; no alloc in `frame_decode` | **Good** |
| SETTINGS/PING ACK | Append to `out` dynamic | **Fine** |
| HPACK static match | Linear scan 61 entries per field | **OK at engine stage** |
| Stream lookup | `map[u32]^Http2_Stream` | **Correct shape** until slab |
| Flow flush | Frame-sized chunks; pending buffer | **Correct backpressure kernel** |

### Majors

| ID | Issue |
|----|--------|
| **PERF-M1** | **Huffman decode is O(bits × 257) linear table walk per bit.** Package comment admits FSM/state-table is “later.” Fine for unit vectors; catastrophic if PR8 hosts this under header-heavy traffic without replacing it. |
| **PERF-M2** | **`remove_range` on `pending` and `rx` is O(n) per consume.** Every DATA flush shifts the remainder of `s.pending`. Every `conn_feed` that advances `pos` shifts `c.rx`. Under large bodies / pipelined bytes this is classic accidental quadratic. A read cursor (or ring buffer) is the engine-grade fix. |
| **PERF-M3** | **`conn_take_request` / WINDOW_UPDATE conn-level flush / `conn_has_pending_body` scan entire stream map.** Reap (F16) bounds growth on the *server happy path*; while many streams are open under mux, every WINDOW_UPDATE(conn) does `_flush_stream` on **all** streams. Correct but O(open) per control frame — host will need a “blocked streams” set later. |

### Minors

| ID | Issue |
|----|--------|
| **PERF-m1** | `conn_send_body` always `append(..data)` then flush — double-touch of bytes that fit the window immediately. |
| **PERF-m2** | HPACK encode always prefers Huffman when shorter — good; static name scan is linear. |
| **PERF-m3** | Temp allocator used for encode blocks and reap id lists — good for tests; host must keep temp discipline. |
| **PERF-m4** | No buffer pooling; every stream allocates three dynamics (`headers`, `body`, `pending`). Expected pre-slab. |

### What would WOW

1. Huffman decode FSM (or at least a prefix trie) with a comment that encode table stays rodata.
2. `rx` / `pending` cursor or chunk queue — no head `remove_range` on large buffers.
3. Blocked-stream set for flush on WINDOW_UPDATE(conn).
4. Document that map+scan is intentional Phase-3 and PR8+ owns slab/index — if so, score rises without code if honesty is explicit.

### WOWED: **no**

Engine-stage structures are honest enough to ship offline; not elite, and two O(n) habits will poison the first multiplex host if copied blindly.

---

## 3. Memory — Score **7.6** / WOWED **no**

### What holds

1. **`conn_destroy` is complete.** Streams: `headers_destroy` + delete headers/body/pending + free stream; delete map; `hpack.destroy`; delete rx + cont_frag. No SSL/host resources to free (none exist).

2. **HPACK dynamic table destroy** frees every cloned name/value then the entries array. `headers_destroy` for decoded lists is exported and used by reap/destroy.

3. **Server stream reap** frees the same set as destroy for closed+delivered/failed streams. Test proves map empties after 64 request/response cycles.

4. **Huffman / HPACK tests** use defer delete; runner memory tracking green (15+7+3).

5. **Push disabled** avoids a class of unbounded promised streams.

### Majors

| ID | Issue |
|----|--------|
| **MEM-M1** | **Defaults are unbounded.** `max_body_bytes` / `max_header_bytes` default **0 = unlimited**. Engine buffers whole messages (`body`, `cont_frag`, headers). Comment tells servers to set both — but `conn_init` does not; tests do not set them. A peer can grow `s.body` / `cont_frag` without bound until OOM. For a sans-I/O engine this is a **footgun packaged as default**. |
| **MEM-M2** | **Client streams never reaped.** `conn_reap_streams` returns immediately if `!c.is_server`. Client map retains every historical stream for connection lifetime. Loopback and long client sessions leak stream structs + header/body storage. |
| **MEM-M3** | **`pending` has no cap.** If peer never WINDOW_UPDATEs, handler `conn_send_body` appends forever (returns buffered count — backpressure *signal* exists, enforcement is caller’s). Documented as host responsibility; still a memory cliff if PR8 forgets to pause the producer. |
| **MEM-M4** | **Incremental HPACK decode double-owns strings.** `decode_literal` allocates; `insert` **clones again** into the dynamic table; `out` keeps the first copy. Correct freeness, **2× header RAM** on every incremental field. Acceptable for clarity; not free. |

### Minors

| ID | Issue |
|----|--------|
| **MEM-m1** | After CONTINUATION finish, `cont_frag` is not `clear`ed (capacity retained). Fine; size cap depends on `max_header_bytes`. |
| **MEM-m2** | Reap requires `delivered \|\| failed` — stream closed both ways but never taken leaks until destroy. Server that forgets `conn_take_request` retains streams (and blocks concurrent budget via `open_streams` until close accounting… actually close happens on both ends END_STREAM; reap needs delivered — **closed but undelivered stays in map**). If handler never takes, map grows with closed streams. |
| **MEM-m3** | RST clears `pending` but does not shrink capacity. |

### What would WOW

1. Non-zero **safe defaults** for `max_body_bytes` / `max_header_bytes` (or hard require set-before-feed in debug).
2. Client reap (or generation-scoped free after `conn_response` consumed).
3. Optional `max_pending_body` in the engine, not only host-level pause.
4. Single-clone path: insert moves ownership into table and clones once for `out` (or reverse).

### WOWED: **no**

Destroy/reap craft is real on the server happy path; defaults and client lifetime are not production-engine memory discipline.

---

## 4. Shortcuts / honesty — Score **8.5** / WOWED **no**

### What is elite

1. **Product non-claims are ironclad across the doc set.**  
   - `IMPLEMENTATION_STATUS.md`: PR7 **Done** as sans-I/O; H2 product / M1–M6 **Not started**; matrix TLS H2 stays ⏳.  
   - `CAPABILITY_MATRIX.md`: PR7 footnote — offline tests do **not** flip cells; rule 7 forbids treating codec green as matrix ✅.  
   - `H2_ENGINE.md`: “Not a product surface”; forbidden README claim until Phase 5 / PR9.  
   - Root `README.md` / `PROJECT.md`: **no** “supports HTTP/2” (grep clean outside third_party).

2. **Sans-I/O gate is real, not aspirational.** Packages have no ring/host deps; tests run offline without OpenSSL.

3. **Steal vs own is explicit.** Comments + H2_ENGINE refuse vapor `server/` fork architecture; integer note “extracted… no QPACK dependency.”

4. **Scorecard honesty matches tree.** Status table “15 / 7 / 3” tests matches this pass. “Not PR8 host” is true — zero ALPN/host install.

5. **Known incompleteness often labeled.** Push off; priority advisory; Huffman FSM later; max body “servers should set.”

### Majors (internal overclaim / incomplete RFC honesty)

| ID | Issue |
|----|--------|
| **HON-M1** | **“Both-direction flow control” oversells inbound.** Connection header and H2_ENGINE “flow” language read as full FC. Outbound is real; inbound is 1:1 auto WINDOW_UPDATE + buffer. That is **not** peer receive-window management. For PR7 this may be intentional — then docs should say “outbound FC + inbound auto-credit,” not “both-direction.” |
| **HON-M2** | **“Complete RFC 7541 codec” oversells the encoder.** Decode + dynamic table + size updates + vectors: yes. Encoder never indexes, never size-updates. Say “full decoder + simple non-indexing encoder” or implement indexing. |
| **HON-M3** | **Plan A Phase 3 exit included “h2spec offline.”** Landed: sample `strict_test` pins, not an h2spec harness or 145/146-class suite. Comment in `strict_test` mentions “h2spec conformance work (145/146)” as lineage — **aspirational residue**. Offline unit green meets `IMPLEMENTATION_STATUS` PR7 row; plan-a wording is still ahead of evidence. |
| **HON-M4** | **`SETTINGS_MAX_FRAME_SIZE` / dual send API are silent gaps.** Docs list flow and frames as Done without noting the simple send path ignores windows or that max frame is not applied on feed/flush. |

### Minors

| ID | Issue |
|----|--------|
| **HON-m1** | `connection_test` user-agent string `"vapor-http2"` — harmless lineage tattoo; slightly confuses “no vapor” messaging. |
| **HON-m2** | H2_ENGINE “15 total” tests — accurate today; keep in sync if suite grows. |
| **HON-m3** | No CI script dedicated to PR7 (unlike firehose/e0). Documented manual `odin test` only — OK for offline codec, weaker as regression gate if someone breaks package discovery. |

### What would WOW

1. Tighten `H2_ENGINE.md` completeness language to match code (encoder, inbound credit, frame size).
2. Either wire a minimal h2spec-offline subset job or demote plan-a “h2spec offline” wording to “strict unit pins.”
3. Delete dual send path or document it as **unsafe / tests-only**.
4. Keep product matrix ⏳ (already held).

### WOWED: **no**

Product honesty is **WOW-adjacent (~9)**; withheld because this axis also grades incomplete-RFC honesty inside the engine claim, and several “full/complete/both-direction” phrases outrun the code.

---

## Cross-axis themes (do not double-count as separate Fatals)

| Theme | Axes | Summary |
|-------|------|---------|
| Dual send API | CQ, HON | Simple path untested against windows; loopback uses it |
| REFUSE without HPACK | CQ, HON | Feature that breaks compression under its own limit |
| Auto-grant inbound | CQ, PERF, HON | Not real recv windows; flood = buffer growth |
| Unbounded defaults | MEM, HON | Engine trusts host to set caps it does not default |
| Naïve Huffman / remove_range | PERF | Acceptable offline; poison if hosted unchanged |

---

## Gap list vs PR8 readiness (out of scope for WOW, useful handoff)

These do **not** reduce PR7 “sans-I/O Done” if docs stay honest; they are the bill for the next phase:

1. Host: ALPN `h2`, exclusive framer bag, feed PT from TLS, seal `out` to CT.
2. Fix CQ-M1/M2/M4 before multi-stream traffic.
3. Slab / stream id → `Stream_Slot` map; never put stream id on public `Session`.
4. Inbound windows or explicit “buffering engine, host polices credit.”
5. Live h2spec core + curl `--http2` engineering (still not product M1–M6).

---

## Final judgment

| Question | Answer |
|----------|--------|
| Is PR7 a real engine? | **Yes.** Connection + HPACK + Huffman + outbound FC + strict pins + offline green. |
| Is product H2 claimed? | **No.** Matrix ⏳; README clean; status explicit. |
| Sans-I/O pure? | **Yes.** No ring/host imports. |
| WOW (≥9) any axis? | **No.** Mean **7.8**. |
| Worth calling IMPLEMENTATION_STATUS PR7 **Done**? | **Yes, with residuals** — Done as *sans-I/O packages + unit green*, not Done as *RFC-complete peer-grade stack*. |

**Harsh bottom line:** This is the first PR in the dual-TLS/H2 track that ships a **protocol brain** rather than a host wire path. Treat it as a solid Phase-3 kernel with known sharp edges — not as a quiet free pass into PR8. Fix dual-send, REFUSE/HPACK, frame-size application, and default caps before the first multiplex host feed; until then, withhold WOW.

---

## Appendix — test inventory (this pass)

| Package | Tests | Notes |
|---------|------:|-------|
| `http2` | 15 | frame wire/incomplete/too_large/settings/WU/preface; loopback; stream ids; flow; inbound WU; drain; reap; strict frame; strict request/HPACK |
| `hpack` | 7 | static indexed; roundtrip; dynamic table; C.1 ints; C.2.1; C.3 series; C.4 Huffman series |
| `huffman` | 3 | known vector; roundtrip cases; all-bytes |

**Missing coverage worth adding next:** CONTINUATION reassembly; REFUSE+HPACK sync; `conn_send_response` under tiny windows (should fail or buffer); `max_frame_size` from SETTINGS; client reap; fail_code on preface/continuation errors.
