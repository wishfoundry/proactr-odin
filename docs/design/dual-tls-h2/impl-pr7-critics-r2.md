# Implementation Critics — PR7 r2 (multi-axis)

**Posture:** harsh elite. Credit only **claimed PR7 scope**.  
**Bar:** WOW ≥ 9 for **claimed PR7 scope only**:

| Claimed in | Claimed out |
|------------|-------------|
| Sans-I/O packages `http2/` (frame + connection + flow), `hpack/`, `huffman/` | Product HTTP/2 / host / ALPN `h2` |
| `conn_feed` / `conn_send_*` / stream take / outbound flow | Ring, sockets, TLS, multi-slot slab |
| Offline unit tests green (no listen) | Matrix TLS H2 ✅, README “supports HTTP/2” |
| Own types under proactr tree (no vapor package import) | M1–M6 / SSE-on-H2 / live h2spec |

**Not required for WOW:** PR8 host install, ALPN, multi-slot, live curl `--http2`, dual-CT seal, product matrix flips, full recv-window throttle, peer-grade HPACK encoder, Huffman FSM.  
**Required for WOW:** R1 **Majors** that undermined engine craft under its own claims are closed; one flow-aware send surface; refuse-after-HPACK; `max_frame_size` applied; safe server body/header defaults; docs refuse product overclaim **and** match engine completeness.

**Date:** 2026-08-08  
**Prior:** [`impl-pr7-critics-r1.md`](impl-pr7-critics-r1.md) (mean **7.8**, WOW withheld — dual send, REFUSE/HPACK, decorative max frame, unbounded defaults, completeness language stretch).  
**Subject:** `http2/{types,frame,connection,flow}.odin` + tests; `hpack/{hpack,integer}.odin` + tests; `huffman/huffman.odin` + tests; `docs/{H2_ENGINE,IMPLEMENTATION_STATUS,CAPABILITY_MATRIX}.md`.

---

## Verify (this pass)

| Command / check | Result |
|-----------------|--------|
| `odin test http2 -o:none` | **17/17 pass** (was 15 in r1; +send_response window + refuse HPACK) |
| `odin test hpack -o:none` | **7/7 pass** |
| `odin test huffman -o:none` | **3/3 pass** |
| Sans-I/O purity | **Yes** — zero `submit_`, `io_uring`, `SSL_`, `BIO`, `ALPN` in package sources |
| Product “supports HTTP/2” | **Clean** — matrix TLS H2 ⏳; README / status forbid claim |
| LOC (approx.) | ~2.6k lines across three packages (prod + tests) |

No ring, no OpenSSL, no listen. Packages import only `core:*`, `../hpack`, `../huffman`.

---

## R1 → fixed (spot-checked)

| R1 ID | Claim | Evidence | Verdict |
|-------|--------|----------|---------|
| **CQ-M1** | Dual send API; `conn_send_request` / `conn_send_response` bypassed windows via `_write_message` | Both now call `conn_send_headers` + `conn_send_body`. `_write_message` **gone**. Comments: “Always flow-aware.” Test `test_h2_send_response_respects_window`: 25-byte body under 10-byte peer window → DATA(10) + 15 pending, no END_STREAM until drain. Loopback uses the same path. | **Fixed** |
| **CQ-M2** | `MAX_CONCURRENT_STREAMS` refuse skipped HPACK → decoder desync | `_finish_header_block`: refuse **after** `hpack.decode` into temp headers (destroy without deliver); RST `REFUSED_STREAM`; track `last_peer_sid`. Test `test_h2_refuse_still_decodes_hpack`: over-limit stream inserts dynamic entry; later stream resolves Indexed 62. | **Fixed** |
| **CQ-M4** | `SETTINGS_MAX_FRAME_SIZE` decorative | Decode: `conn_feed` passes `c.local_settings.max_frame_size` (fallback default). Flush: `_flush_stream` clamps to `c.peer_settings.max_frame_size`. Too-large → `_fail(FRAME_SIZE_ERROR)`. | **Fixed** |
| **MEM-M1** | Unbounded `max_body` / `max_header` defaults | `conn_init(is_server=true)`: `max_body_bytes = 1 MiB`, `max_header_bytes = 64 KiB`. Explicit 0 after init = unbounded. | **Fixed** |
| **HON-M1..M4** | “Both-direction FC” / “complete codec” / h2spec offline / silent dual-send & frame-size gaps | `H2_ENGINE.md`: outbound real / inbound auto-credit table; full decoder + simple non-indexing encoder; all `conn_send_*` flow-aware; strict unit pins ≠ full h2spec; frame-size + server defaults named. `IMPLEMENTATION_STATUS` PR7 row + residual limits. Connection package header matches. `strict_test` header demotes 145/146 lineage. | **Fixed** |
| **MEM-M2** (bonus) | Client streams never reaped | `conn_reap_streams` no longer server-only; `conn_response` marks `delivered`. Status docs: client + server reap. | **Fixed** |

---

## Scoreboard

| Axis | Score | WOWED | Worst class |
|------|------:|:-----:|-------------|
| Code quality | **9.2** | **yes** | Minor (fail_code on preface / cont contiguity) |
| Performance | **9.0** | **yes** | Phase residual (Huffman linear; `remove_range`; map scan) |
| Memory | **9.1** | **yes** | Minor (pending host-enforced; 2× HPACK clone) |
| Shortcuts / honesty | **9.3** | **yes** | Minor (plan-a Phase 3 “h2spec offline” design-doc residue) |
| **Mean** | **9.2** | — | — |

**Verdict:** R1 Majors that made the engine sharp under its **own** concurrent-streams and flow claims are closed with correct craft and regression tests. Claimed PR7 scope — sans-I/O connection codec + HPACK/Huffman + offline green + product non-claim — now holds as a coherent Phase-3 kernel. Residuals are **phase / PR8 handoff** (recv windows, encoder indexing, Huffman FSM, cursor buffers, host install) or **minors** (fail_code on two early Protocol returns). **All four axes clear WOW (≥9).** Willing: the bar was a real flow-correct offline engine without product lie — that is what landed.

---

## Architecture map (post majors fix)

```text
BYTES IN
  conn_feed(c, data, out)
    → append rx buffer
    → server: consume CLIENT_PREFACE once
    → frame_decode(…, local max_frame_size)     ← CQ-M4
    → _handle_frame:
         SETTINGS → validate + peer_settings + ACK (+ window delta flush)
         HEADERS/CONTINUATION → reassemble → _finish_header_block
              refuse_new? decode HPACK (tmp) → RST REFUSED → no deliver  ← CQ-M2
              else decode + validate request → stream
         DATA → append body; max_body cap; 1:1 WINDOW_UPDATE grants
         WINDOW_UPDATE → grow send windows → _flush_stream
         PING → ACK; RST/GOAWAY → fail streams; PUSH → PROTOCOL_ERROR
    → conn_reap_streams (server + client)
    → out accumulates auto-replies for host to seal/send later

BYTES OUT (one flow-aware surface)              ← CQ-M1
  conn_send_headers / conn_send_body
  conn_send_request / conn_send_response → same path
  _flush_stream: min(stream_window, conn_window, peer max_frame_size)

TAKE
  conn_take_request (server) / conn_response (client) — delivered → reap-eligible

DEFAULTS (server)                               ← MEM-M1
  max_body_bytes = 1 MiB; max_header_bytes = 64 KiB

NOT PRESENT (correct for PR7)
  ring submit_*, sockets, TLS, ALPN, Stream_Slot host, multi-slot slab
```

---

## 1. Code quality — Score **9.2** / WOWED **yes**

### What is elite for claimed sans-I/O engine scope

1. **One send surface, always flow-correct.** The dual-path failure that R1 treated as craft-breaking is gone. Hosts cannot accidentally dump unbounded DATA via the “simple” API.
2. **Refuse after HPACK.** Concurrent-limit enforcement no longer desyncs the shared decoder table — the classic H2 footgun is closed and pinned offline.
3. **Real connection state** (unchanged elite core): HPACK table, stream map, open count, CONTINUATION contiguity, GOAWAY, send windows, stream reap under mux.
4. **Strictness pins** remain meaningful: idle DATA, even client id, SETTINGS window bounds, zero WINDOW_UPDATE, pseudo-header rules, content-length, HPACK size-update limit.
5. **Outbound flow + backpressure API** with `_flush_stream` peer frame cap; WINDOW_UPDATE / SETTINGS window-delta re-flush.
6. **Owned types, no vapor import.** Steal-facts / own-types law holds.
7. **Tests grew on the failure modes that mattered:** send_response under tight window; refuse-then-index from refused dynamic entry.

### Fatal

None for claimed PR7 scope.

### Majors

None remaining that undermine claimed engine scope. Inbound auto-credit and simple encoder are **intentional phase limits**, labeled in docs (see Honesty).

### Minors

| ID | Issue |
|----|--------|
| **CQ-m1** | Preface mismatch and CONTINUATION contiguity violation still `return .Protocol` without `_fail(...)`, so `fail_code` may stay 0 while `conn_feed` failed (R1 CQ-M5 residue → demoted). |
| **CQ-m2** | Unknown frame types silently ignored (RFC-forward-compat; still unstated in H2_ENGINE). |
| **CQ-m3** | No dedicated CONTINUATION multi-frame unit test (reassembly path exists; refuse test is single-frame). |
| **CQ-m4** | `settings_write` still omits `HEADER_TABLE_SIZE` / `MAX_HEADER_LIST_SIZE` — peers keep 4096 assumption. |
| **CQ-m5** | Priority shape-only (correct for modern H2); no dependency tree. |

### What would push higher (not required for WOW)

1. `_fail` on every connection-error return (preface + cont contiguity).
2. CONTINUATION reassembly unit test.
3. Optional: inbound receive windows when host needs real peer throttle (PR8+).

### WOWED: **yes**

R1 craft failures under the engine’s own flow and concurrent-streams claims are closed. Residuals are minors / phase.

---

## 2. Performance — Score **9.0** / WOWED **yes**

Claimed scope is **offline engine correctness**, not RPS. Score grades honesty of structures the host will inherit — and whether anything in the engine path is accidentally wrong for that stage.

### What holds for an offline codec

| Path | Behavior | Grade |
|------|----------|-------|
| Frame parse | Fixed 9-byte header + slice payload; no alloc in `frame_decode` | **Good** |
| SETTINGS/PING ACK | Append to `out` dynamic | **Fine** |
| Flow flush | Frame-sized chunks; pending + windows; peer max frame | **Correct backpressure kernel** |
| Stream lookup | `map[u32]^Http2_Stream` + reap | **Correct pre-slab shape** |
| HPACK static match | Linear 61 entries | **OK at engine stage** |

### Majors

None for claimed offline scope. R1 PERF-M1..M3 remain **phase residuals** (document, do not copy blindly into a multi-Gbps host without replacement):

| Residual | Note |
|----------|------|
| Huffman decode linear table walk | Package still admits FSM later; fine for offline vectors |
| `remove_range` on `pending` / `rx` | O(n) per consume — cursor/chunk queue is PR8+ craft |
| Full map scan on conn WINDOW_UPDATE / `has_pending` | Correct; blocked-stream set later under heavy mux |

### Minors

| ID | Issue |
|----|--------|
| **PERF-m1** | `conn_send_body` always appends then flush (double-touch when window fits). |
| **PERF-m2** | No buffer pooling; three dynamics per stream (expected pre-slab). |
| **PERF-m3** | Temp allocator for encode blocks and reap id lists — host must keep temp discipline. |

### WOWED: **yes**

For **claimed** scope the structures are the right Phase-3 kernel: correct flow clamp, frame size applied, reap bounds map growth on the happy path. Host-RPS perfection is explicitly out of bar.

---

## 3. Memory — Score **9.1** / WOWED **yes**

### What holds

1. **`conn_destroy` complete** — streams, HPACK, rx, cont_frag.
2. **Server defaults bound the buffer-everything model** (1 MiB body / 64 KiB headers).
3. **Reap on server and client** after delivered/failed + closed — F16 map growth inverted bulk RPS elsewhere; fix is here for both roles.
4. **Test runner memory tracking green** (17+7+3).
5. **Push disabled** avoids unbounded promised streams.

### Majors

None for claimed scope.

### Minors

| ID | Issue |
|----|--------|
| **MEM-m1** | `pending` still uncapped if peer never WINDOW_UPDATEs — backpressure **signal** exists (`conn_send_body` buffered count); enforcement is caller’s (documented host duty). |
| **MEM-m2** | Incremental HPACK decode still double-owns strings (decode alloc + insert clone). Correct freeness; 2× header RAM. |
| **MEM-m3** | Reap still needs `delivered \|\| failed` — closed but never taken stays until destroy (handler discipline). |
| **MEM-m4** | Client `conn_init` leaves max_body/header at 0 (unlimited) — acceptable for client engine use; server is the flood surface. |

### WOWED: **yes**

Safe server defaults + dual-role reap close the R1 memory majors that were packaged footguns. Remaining cliffs are host-enforced pending pause and optional single-clone HPACK — phase polish.

---

## 4. Shortcuts / honesty — Score **9.3** / WOWED **yes**

### What is elite

1. **Product non-claims remain ironclad.** Matrix TLS H2 ⏳; CAPABILITY_MATRIX rule 7; H2_ENGINE “Not a product surface”; IMPLEMENTATION_STATUS PR7 Done-as-engine / not PR8 / not M1–M6; root README clean of “supports HTTP/2.”
2. **Engine completeness language now matches code.** Outbound FC real / inbound 1:1 auto-credit; full decoder + simple non-indexing encoder; all send paths flow-aware; frame size applied; server memory defaults named; strict unit pins ≠ full h2spec.
3. **Sans-I/O gate real** — packages and tests offline without OpenSSL.
4. **Status scorecard accurate** — 17 / 7 / 3 this pass; residual limits table lists what is still not peer-grade.
5. **Steal vs own explicit** — own packages; refuse vapor server fork architecture.

### Majors

None.

### Minors

| ID | Issue |
|----|--------|
| **HON-m1** | Design `plan-a.md` Phase 3 exit still says “h2spec offline” in places — product status docs demoted it; design-plan residue only. |
| **HON-m2** | `connection_test` user-agent `"vapor-http2"` lineage tattoo (harmless). |
| **HON-m3** | No dedicated CI script for PR7 packages (manual `odin test` documented) — OK for offline codec. |

### WOWED: **yes**

Product honesty was already WOW-adjacent; internal engine honesty caught up. Axis grades both — both now clear.

---

## Cross-axis themes (r1 → r2)

| Theme | r1 | r2 |
|-------|----|----|
| Dual send API | CQ/HON Major | **Closed** — one flow path + test |
| REFUSE without HPACK | CQ/HON Major | **Closed** — decode then RST + test |
| Decorative max frame | CQ Major | **Closed** — local decode / peer flush |
| Unbounded defaults | MEM Major | **Closed** — server 1 MiB / 64 KiB |
| Completeness overclaim | HON Major | **Closed** — docs match code |
| Auto-grant inbound | CQ/HON | **Phase residual**, labeled intentional |
| Naïve Huffman / remove_range | PERF | **Phase residual** for host inheritance |
| Client never reaped | MEM Major | **Closed** (bonus) |

---

## Gap list vs PR8 readiness (out of scope for WOW; handoff)

1. Host: ALPN `h2`, exclusive framer bag, feed PT from TLS, seal `out` to CT.
2. Slab / stream id → `Stream_Slot`; never put stream id on public `Session`.
3. Inbound receive windows **or** keep auto-credit with host-policed caps (already defaulted).
4. Optional: Huffman FSM; rx/pending cursor; blocked-stream flush set.
5. Live h2spec core + curl `--http2` engineering (still not product M1–M6).
6. Minor: set `fail_code` on preface / CONTINUATION contiguity failures.

---

## Final judgment

| Question | Answer |
|----------|--------|
| Is PR7 a real engine? | **Yes.** Connection + HPACK + Huffman + **unified outbound FC** + refuse-after-HPACK + frame-size + strict pins + offline green. |
| Is product H2 claimed? | **No.** Matrix ⏳; README clean; status explicit. |
| Sans-I/O pure? | **Yes.** |
| R1 Majors closed? | **Yes** (all five verification targets + client reap). |
| WOW (≥9) any axis? | **Yes — all four.** Mean **9.2**. |
| Worth calling IMPLEMENTATION_STATUS PR7 **Done**? | **Yes** — Done as *sans-I/O packages + unit green + coherent flow/refuse/frame craft*; residuals are phase/host, not silent engine lies. |

**Bottom line:** PR7 r1 was a real protocol brain with sharp edges under its own claims. PR7 r2 closes those edges without scope-creeping into product H2. Treat the packages as a shippable Phase-3 kernel for PR8 host install — with eyes open on auto-credit inbound, simple encoder, and map/scan/remove_range inheritance. **WOW granted for claimed scope.**

---

## Appendix — test inventory (this pass)

| Package | Tests | Notes |
|---------|------:|-------|
| `http2` | **17** | frame wire/incomplete/too_large/settings/WU/preface; loopback; stream ids; flow; inbound WU; drain; reap; strict frame; strict request/HPACK; **send_response respects window**; **refuse still decodes HPACK** |
| `hpack` | 7 | static indexed; roundtrip; dynamic table; C.1 ints; C.2.1; C.3 series; C.4 Huffman series |
| `huffman` | 3 | known vector; roundtrip cases; all-bytes |

**Still useful next (not blocking WOW):** CONTINUATION multi-frame unit; fail_code on preface/cont; client reap under multi-exchange stress; optional `max_frame_size` SETTINGS peer advertisement round-trip test.
