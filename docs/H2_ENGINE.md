# HTTP/2 engine and host

App authors do not import codec packages. The host terminates TLS ALPN `h2` and
drives the sans-I/O engine. Concurrent unary streams and multi-SSE are supported;
WS-on-H2 is not.

## Codec layers

| Layer | Package | Role |
|-------|---------|------|
| Frames + connection + flow | `http2/` | RFC 9113 framing; `conn_feed` / `conn_send_*` |
| Header compression | `hpack/` | RFC 7541 decoder + simple encoder |
| Huffman | `huffman/` | RFC 7541 Appendix B |

Codec unit tests run offline (no ring).

## Host

Installed under `http/` (not a public app import):

| Piece | Role |
|-------|------|
| ALPN | Prefer `h2`, fallback `http/1.1`; post-Open `alpn_is_h2` branch |
| `h2_host.odin` | `h2_host_on_open` / `on_pt` / `dispatch_available` / `flush_out` / `send_response` / `destroy` |
| Multi-slot | Lazy: `h2_slots` is `^[H2_SLOT_CAP]Stream_Slot` allocated only on ALPN-h2 open; nil on clear/TLS H1 |
| Concurrent | Default **`h2_serial_dispatch=false`** (product); `true` = eng/debug single-flight |
| Fair RR | Engine `flush_rr` + `_flush_pending_rr` on conn WINDOW_UPDATE / SETTINGS Δwindow |
| GOAWAY | Error: `conn_send_goaway(last_peer_sid, code)` → flush → close. Graceful: on `Server.closing`, `GOAWAY(NO_ERROR)` once; refuse new streams `> last_sid`; drain existing (incl. SSE) then close when idle |
| Fairness weights | Optional `Server_Opts.h2_weight_interactive` / `h2_weight_bulk` (default 2/1); `sse_start` marks stream interactive for RR quanta |
| Duplex | Re-arm CT recv after H2 CT send complete (do not hold recv off for send alone) |
| Handler | Same `server.handler` + `respond` / `sse_start`; version view **HTTP/1.1** for handler compat |
| Gates | `http/h2_m_gates_test.odin` offline gates |

**Not claimed yet:** WS-on-H2, multi-stream peer RPS matrix, full h2spec, multi-MiB bulk firehose on TLS.

Manual probe (when PEMs + OpenSSL work; not RPS):

```bash
curl -k --http2 https://127.0.0.1:18443/
```

---

## Sans-I/O `Http2_Connection`

Intended private contract (testable without proactr Ring):

```text
conn_feed(conn, plaintext_in)
 → demux inbound frames into events
 (headers, data, rst, window_update, goaway, settings, …)

conn_send_*(conn, …)
 → append outbound frames into a byte buffer the host will seal/send later
 (HEADERS/DATA units, SETTINGS ACK, WINDOW_UPDATE, RST, GOAWAY, …)
```

Design-plan synonyms (same idea; exclusive framer bag on the host later):

```text
feed(framer, plaintext_in) → demux events
pull_control(framer) → outbound control into seal schedule
```

Rules for this layer:

- **Bytes in, bytes/events out.** No `submit_*`, no BIO, no socket.
- **No stream-id on public `Session`.** Stream ids stay engine-private; host maps
 accept → `Stream_Slot` only in +.
- **No handler API.** Apps keep `respond` / Effects; listen options grow later.

Landed under `http2/`: frame codec + **full sans-I/O connection**
(`conn_init` / `conn_destroy` / `conn_feed` / `conn_send_*` / flow control / stream take).

All outbound DATA paths (`conn_send_headers` / `conn_send_body` /
`conn_send_request` / `conn_send_response`) are **flow-aware** (pending buffer +
peer windows). There is no dump-the-body bypass.

---

## Packages

### `http2/`

- `types.odin` — `Frame_Error`, `Settings`, `Header` alias, defaults (push **off**).
- `frame.odin` — 9-byte header + type-specific writers/decoders; sans-I/O only.
- `connection.odin` — `Http2_Connection` / `Http2_Stream`; `conn_feed`; server `conn_take_request`.
- `flow.odin` — outbound windows; `conn_send_headers` / `conn_send_body`; `_flush_stream`
 clamps to peer `SETTINGS_MAX_FRAME_SIZE`.
- Decode uses local `SETTINGS_MAX_FRAME_SIZE`.
- Server `conn_init` defaults: `max_body_bytes = 1 MiB`, `max_header_bytes = 64 KiB`
 (set either to **0** after init for unbounded).
- Tests: `frame_test`, `connection_test`, `flow_test`, `strict_test` — **strict unit
 pins / subset**, **not** a full h2spec harness or 145/146-class suite.

### `hpack/`

- **Decoder:** complete RFC 7541 — static table, size-evicting dynamic table, prefix
 integers, indexed / all literal forms, size updates, optional Huffman via `../huffman`.
- **Encoder:** simple by design — exact static match → Indexed; else Literal **Without**
 Indexing only. Does **not** grow an encoder dynamic table or emit size updates.
- Owned `Header` type — **no** vapor/qpack import.
- RFC C.* series vectors in `hpack_test.odin`.

### `huffman/`

- Canonical HTTP Huffman table (RFC 7541 Appendix B).
- `encode` / `decode` / `encoded_len`; known vector `www.example.com` + roundtrips.
- Decode is a linear table walk (FSM later) — fine for offline vectors.

---

## Flow control (honest)

| Direction | Behavior |
|-----------|----------|
| **Outbound** | Real: `pending` + stream/conn send windows; `WINDOW_UPDATE` re-flushes |
| **Inbound** | Auto-credit: each DATA frame emits connection (+ stream) `WINDOW_UPDATE` for the full payload length (1:1). There is **no** local receive-window budget / peer-throttle strategy — the engine buffers; host/cap fields bound memory |

`MAX_CONCURRENT_STREAMS` refusals **fully HPACK-decode** the refused header block (table
sync) then `RST_STREAM(REFUSED_STREAM)` — never RST mid-block without decoding.

---

## How to run (offline unit tests)

From the repo root (no OpenSSL, no listen, no ring):

```bash
odin test http2 -o:none
odin test hpack -o:none
odin test huffman -o:none
```

These are **codec/engine** tests (including fair RR / peak window). Host M1–M6
gates live under `odin test http`. Together they form the offline product bar;
they do **not** prove:

- live bastion multi-stream RPS / peer matrix
- full h2spec pass rates
- WS-on-H2

---

## Steal vs own

| | |
|--|--|
| **Steal** | RFC facts, frame layouts, h2spec/offline vectors, HPACK algorithms, flow-window math lessons from vapor lineage |
| **Own** | Types and packages under this tree (`http2/`, `hpack/`, `huffman/`); one engine owner; proactr `Stream_Slot` / `Connection` integration later |
| **Refuse** | Forever dual-maint of a vapor `server/` package fork; importing foreign server types as architecture |

Cherry-pick **facts**; own **types**. offline M1–M6 is the product bar;
bastion RPS remains future evidence.

---

## Explicit non-claims

| Claim | Status |
|-------|--------|
| Offline frame / HPACK / Huffman unit tests | Green when packages present |
| Full h2spec suite | **Not** claimed — strict unit subset only |
| Product concurrent unary + SSE-on-H2 (M1–M6 offline) | **Done** — see `H2_ENGINE.md` |
| ALPN `h2` / lazy multi-slot host | **Done** — default concurrent; real GOAWAY on feed fail |
| Capability matrix concurrent/SSE TLS H2 | **✅** (WS-on-H2 still ⏳) |
| Live bastion multi-stream RPS peer matrix | **Not measured** |
| HPACK encoder dynamic indexing | **Not** implemented (literal/static only) |
| Inbound receive-window throttle | **Not** implemented (1:1 auto WINDOW_UPDATE) |

See design track: `docs/ARCHITECTURE.md` Phase 3 / vs Phase 4–5 / –.
