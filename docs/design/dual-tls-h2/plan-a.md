# Plan A (R4 graft) — proactr multi-protocol high-level API

**Title:** TLS + HTTP/2 designed into the command planner + sessions  
**Lineage:** proactr conversation thesis (G1–G5, semantics≠transport, effect sessions, proactor identity)  
**Status:** **R4 graft — B residual wins absorbed; spine remains A**  
**Not a port:** protocol facts and measured bulk constants may be cited as *peer-measured*; ontology and control plane are proactr’s. Peer-measured numbers (windows, CT slots, high-water) are footnotes to physics — not a package import and not a vapor-server forever-fork.

**Who reads what:**

| Audience | Read |
|----------|------|
| **App authors** | **PART I only** — App Contract, capability matrix, middleware card, honesty rules. Stop there. |
| **Implementers** | PART I + **PART II** (ontology, Tls_Pipe, write physics, multiplex gates, phases, close SM). |
| **Reviewers** | PART I freeze gates (E0.*) + PART II laws (S1, W1/W2, D1, PT1, M1–M6) + anti-patterns. |

---

## 0. Thesis

Handlers keep today’s clear-H1 vocabulary: `body_*` / `respond`, and `(user, event) → Effects` for long-lived streams. TLS and HTTP/2 never invent new body APIs, stream-id APIs, SSL types, or public resume. They fill **pipe capabilities** and drive a **private write pipeline** (windowed PT → seal/frame → CT → one socket send schedule). One ownership unit — **`Stream_Slot`** — holds every exchange; **`Connection`** is only the pipe (socket, cipher, framer, outbound scheduler). H1 is slots with `N=1`. Implementation phases under a frozen **App Contract**: slot truth → TLS pipe physics → H2 engine → H2 unary engineering → **product multiplex + SSE (M1–M6)** → polish.

**Spine (do not dilute):** Conn_Pt_Ring **must** alias seal input (no dual PT); firehose CI fails if peak ≳ 4× high-water; typed `Seal_Unit` + `seal_q` + `rr_cursor` + gen; allocator lifetime table; Laws W1/W2, D1 duplex, PT1; four-field `Plan_Context`; conversation G1–G5 voice.

---

# PART I — APP SURFACE (authors · freeze · CI)

**App invariant (every tutorial title):**  
**If it is correct on clear HTTP/1.1, it is correct on HTTPS and HTTP/2** — *for capabilities marked ✅ below*. Capabilities marked ⏳ are listen/phase-gated, not handler `#if`.

---

## App Contract (frozen — docs-as-API)

> **This section is the only public story for application and middleware authors.**  
> Implementer epics (Tls_Pipe, Exec_Op, PT rings, fairness queues, Conn_Caps, Seal_SM) must **not** appear in handler tutorials, `examples/`, or README “how to write a handler.” Those live in host docs only (PART II).  
> Copy into `docs/APP_CONTRACT.md` verbatim at Phase 0. **No Exec_Op, no seal SM, no pipe POD in that file.**

### App surface (the only public story)

```text
ONESHOT
  body_static | body_bytes | body_file | body_set* wrappers
  headers / status / cookies
  respond(res)                    → plan → execute (host)

LONG-LIVED
  sse_start / ws_start → Effects
  Session events only:
    Start | Timer | External | Client_Gone | Idle_Timeout | Writable
  Hangup law: ONLY .Client_Gone (never Stream_Reset / protocol death enums)
  Backpressure: ONLY .Writable

ADVANCED (optional read — never required for correctness)
  plan_context(res) → exactly four fields:
    sendfile_ok, preferred_copy_budget, max_write_unit, zero_copy_send

NEVER (reject PR / docs / examples)
  SSL*, Provider, BIO, stream ids, Response._sid, Session as frame id
  body_set_pull or any app-registered pull / Host_Pull from app code
  io.Stream as SSE/long-lived API
  resume / poll / “arm write”
  Conn_Proto / Message_Proto / caps / http/debug in handler or examples/
  body modes that mean writev | sendfile | SSL_write
  progressive stream_* as a second long-lived product
  third public intent rail (anything beyond commands | effects)
```

| Path | API |
|------|-----|
| **Oneshot** | headers / status / `body_*` → `respond` |
| **Long-lived** | `sse_start` / `ws_start` → `Effects` |
| **Events** | `Start`, `Timer`, `External`, `Client_Gone`, `Idle_Timeout`, `Writable` |
| **Advanced (optional)** | `plan_context(res)` → **four fields only**. Correctness never requires opening it. |

### App mental model (three words)

1. **Intent** — commands or effects (**exactly two rails**)  
2. **Exchange** — this request/response or session (implementers say *slot*; apps do not)  
3. **Backpressure** — emit effects; host may drop; wait for `.Writable`; death is only `.Client_Gone`

### Hangup law

All peer death maps to **`.Client_Gone`** only (TCP close/RST, TLS alert, H2 RST_STREAM / stream-affecting GOAWAY, send error). Error codes are logs/metrics — not a second `Session_Event_Kind`.

### Unary bytes law

Only body cmds. Host may window large Static/File privately — **no third public intent rail** (no app pull API, no sample that registers pull from app code).

### Long-lived law

Only Effects. Existing progressive `stream_*` (if still present) is **not** a second long-lived product — fold under oneshot multi-CQE or deprecate in APP_CONTRACT; **SSE/WS use Effects only**.

### Identity law

Public `Session.id` is generation only — never H2 stream id.

### Temporary host behavior (not app API)

Session/slot admission may assert until soft 503 lands (polish phase). Load tests can hit that — **not** a handler contract change. Soft 503 is a host footgun close, not a new event or API.

### Middleware card

| May | Must not |
|-----|----------|
| Rewrite `[]Response_Cmd` only | Import `tls` / Provider / SSL |
| Read **four-field** `plan_context` only | Read stream ids, slots, rings, SQEs |
| Set headers before `respond` / before `sse_start` | Emit frames, ALPN, or HPACK |
| Short-circuit with unary `respond_*` | Assume exchange finished after `next` for SSE (open ≠ end) |
| Keep `File` / `Static` / `Bytes` under TLS/H2 | Branch “if TLS then different body mode” for correctness |

**Rule:** File stays File; planner demotes mechanism (`sendfile_ok` false). Stream body bytes are never middleware’s job.  
**No sample / godoc / helper** that registers host deferred-produce (`Host_Pull` / pull) from app code.

### Author capability matrix (what you may write *now*)

Phase numbers = **product readiness for authors**, not internal engineering milestones.  
Until a cell is ✅, do not market that combo; handlers still use the same API — listen options simply do not offer it yet.

| Capability | Clear H1 | TLS H1 | TLS H2 |
|------------|:--------:|:------:|:------:|
| Oneshot cmds + `respond` | ✅ Phase 1 | ✅ Phase 2 | ✅ Phase 4 (unary eng); **multiplex concurrent** ✅ Phase 5 |
| Large `body_file` / Static (same API; host windows) | ✅ Phase 1–2 | ✅ Phase 2 | ✅ Phase 5 |
| **SSE** (`sse_start` / Effects) | ✅ today / Phase 1 | ✅ Phase 2 | ⏳ **Phase 5** (with multi-slot; same callbacks) |
| **WS** (`ws_start`) | ✅ H1 | ✅ TLS H1 | ⏳ later phase (not H2 until documented) |
| Concurrent unary on one connection | N/A (pipelining H1) | N/A | ✅ Phase 5 (M1) |
| Concurrent SSE sessions on one connection | N/A | N/A | ✅ Phase 5 (M6) |
| “Supports HTTP/2” in README | — | — | Only after Phase 5: concurrent slots **and** SSE-on-H2 (M1–M6) |

**Honesty rules (README / release notes):**

1. **Do not** say “HTTP/2” / “supports HTTP/2” without concurrent streams after Phase 5 (or list ⏳).  
2. **Do not** imply SSE works on H2 before Phase 5 — same honesty as WS on H1-only.  
3. TLS and H2 are **listen options**, never handler options.  
4. Early engineering “curl --http2 green” (Phase 4) is **not** an author-facing H2 product — **forbidden** as README “supports HTTP/2.”

### Phase 0 ergonomics freeze gate (merge blocker — E0.1–E0.8)

Land **before** any TLS/H2 author marketing. **Hard fail CI** if missing:

| Gate | Artifact / check |
|------|------------------|
| **E0.1** | `docs/APP_CONTRACT.md` ≤1 page — Part I App Contract text only (no seal SM, no Exec_Op, no Provider, no Tls_Pipe) |
| **E0.2** | `docs/MIDDLEWARE_CONTRACT.md` — may/must-not table |
| **E0.3** | `docs/CAPABILITY_MATRIX.md` or same table inside APP_CONTRACT — author-facing ⏳/✅ |
| **E0.4** | CI: **same handler sample** under clear H1; later jobs add TLS H1 / H2 as those phases land — sample has **zero** protocol `#if`, no stream ids |
| **E0.5** | No `examples/` import of `http/debug` (or caps/proto introspection) |
| **E0.6** | No sample, godoc, or middleware helper that registers **Host_Pull** / pull from app code |
| **E0.7** | No example sets or prints stream id / `Response._sid` |
| **E0.8** | Pure `plan_body` policy table tests: File+TLS → no Sendfile (implementer; may live under `http/plan_test`) |

**Dual-API social ban:** the freeze is theater if examples reintroduce duals. Review examples with the same ferocity as types. Host design docs (PART II) are **not** linked from app README as required reading.

Framework authors may know Slot · Pipe · Framer · Cipher. **App tutorials never say those words.**

---

# PART II — IMPLEMENTATION (physics · ontology · phases)

*App authors: you can stop here. Below is host law.*

---

## A. Layering & vocabulary

### A.1 Layers (ownership of data — not interface seams)

```
L5 App          Request, Response, Response_Cmd[], Body_Middleware, Effects
L4 Exchange     Stream_Slot (Response/Session/plan cursor/slot wire)
L3 Framing      exclusive framer: H1_Framer | H2_Engine  (never a god union blob)
L2 Cipher pipe  Tls_Pipe (or clear) — Handshake→Open→Closing; PT/CT windows
L1 proactr      Ring, submit_*, CQE, timers, soft_cq
```

| Layer | Owns | Must not know |
|-------|------|----------------|
| L5 | intent, headers, effects | writev, sendfile, SSL_write, frames, stream ids |
| L4 | exchange lifetime, session attach, plan cursor | cipher suites, WINDOW_UPDATE arithmetic |
| L3 | byte layout on a stream | SQE shapes, CT buffers |
| L2 | TLS SM, PT/CT slabs, seal schedule input | body cmd kinds, middleware |
| L1 | buffers until CQE | HTTP |

**No Adapter/Session_Wire/Provider product surfaces in public thesis.** Provider-style crypto may exist *inside* the private Tls_Pipe module only.

### A.2 Public vs private names

```odin
// PUBLIC (app + middleware)
Response_Cmd, Body_Flags, Body_Middleware, Handler_Profile
Plan_Context          // THIN — §C.2
Response, Request
Session, Session_Event, Effects, Effect
// helpers: body_*, respond, sse_start, ws_start, effect_*, plan_context, sse_alloc

// PRIVATE (host)
Stream_Slot, Wire_Slot_State, Wire_Conn_State
Conn_Caps, Message_Proto          // host-only; fill Plan_Context
Tls_Pipe, Conn_Cipher_Engine      // no SSL* escape
H1_Framer | H2_Engine             // exclusive; not Frame_State god-object
Exec_Op                           // private; fused where possible
Pipe_Windows                      // PT/CT high-water numbers
Conn_Pt_Ring, Seal_Unit           // first-class pipe admission + fairness
```

### A.3 Six concepts that compose (implementer vocabulary)

| Concept | Role |
|---------|------|
| **Intent** | `Response_Cmd[]` or `Effects` (exactly two rails) |
| **Constraints** | thin `Plan_Context` |
| **Policy** | pure `plan_body` / unit sizing |
| **Mechanism** | private executor + Tls_Pipe + framer |
| **Slot** | ownership unit for one exchange |
| **Pipe** | Connection: socket + optional Tls_Pipe + framer + wire_conn |

Apps learn only: Request, Response, Session, Effects. Slot/Pipe stay out of tutorials.

### A.4 Steal vs own (peer facts, proactr types)

Protocol engines and bulk-pipe numbers exist in the wild (vapor-http and peers). This plan **does not** make proactr a vapor package or a dual-maint forever fork.

| Steal (facts) | Own (types) |
|---------------|-------------|
| Window numbers, duplex law, membio shape | `Stream_Slot`, `Wire_Conn_State`, Seal_SM, `Conn_Pt_Ring` |
| Frame layouts, h2spec vectors, HPACK math | Framer integration, plan cursor, gen Session |
| Provider method set (BoringSSL mem-BIO) | Single cipher module under `Tls_Pipe` / Connection |
| Anti-firehose autopsy | One outbound path tests; **4× HW CI** |

**Not a dual-maint vapor package fork.** Cherry-pick commits/vectors into **proactr types**; rewrite engine storage to slots. If upstream peers fix flow bugs, port as patches to **our** engine. Refuse forever `server/` package import as architecture.

---

## B. Public handler surface

### B.1 Identical across clear H1, TLS H1, TLS H2

```odin
http.body_set(res, body)
http.body_file(res, fd, off, len)
http.respond(res)

pad := cast(^Tick)http.sse_alloc(res, size_of(Tick))
http.sse_start(res, on_ticks, {user = pad, on_close = on_close})

on_ticks :: proc(sess: ^http.Session, ev: http.Session_Event, user: rawptr) -> http.Effects {
	switch ev.kind {
	case .Start:        return http.effects_of(http.effect_sse_event("hello", "ok"), http.effect_arm(1 * time.Second))
	case .Timer:        return http.effects_of(http.effect_sse_data("tick"), http.effect_arm(1 * time.Second))
	case .Client_Gone, .Idle_Timeout: return http.effects_of(http.effect_abort())
	case .Writable, .External: return {}
	}
	return {}
}
```

**Invariant:** correctness never requires reading caps, windows, or protocol.  
**SSE-on-H2:** same API when authoring; **product readiness** is Phase 5 / M6 (capability matrix) — not a second handler API and not Phase 4 curl green.

### B.2 What is not public

| Temptation | Law |
|------------|-----|
| `response_message_proto` / `conn_caps` | **Not app API.** Optional `http/debug` / server introspection only. |
| `Response._sid` / stream id on Session | **Never.** Session carries generation only. |
| Second hangup event | **Never.** `.Client_Gone` only. |
| `body_set_pull` as parallel Response fields | **No public dual.** Large Static/File windowed by host (deferred produce into PT slab). |
| `Host_Pull` from app / samples | **Never.** Host-private deferred only. |
| `io.Stream` SSE adapter | **Refuse in freeze.** |
| Progressive `stream_*` as second long-lived product | **Refuse.** Effects for SSE/WS. |
| Fat `Plan_Context` / ring / SQE meters | **No.** Four semantic fields only; host-private rest. |

### B.3 Response vs Connection (app language)

| Class | Operates on | Examples |
|-------|-------------|----------|
| Response APIs | this exchange | `body_*`, `respond`, headers, thin `plan_context` |
| Session APIs | this long-lived exchange | `sse_start`, effects, `session_post_external` |
| Connection APIs | pipe (host/rare) | close conn, listen TLS opts |

---

## C. Caps, Plan_Context, live windows

### C.1 Orthogonal Conn_Caps (host-private fill; not app API)

Two protocol axes + two OS paths — **no synonym cluster**:

```odin
Conn_Cap :: enum u8 {
	Ciphered,            // TLS path active (records)
	Multiplex,           // H2+ concurrent slots
	Sendfile_Possible,   // OS can sendfile clear TCP
	Zero_Copy_Send,      // backend zc on clear
}
Conn_Caps :: bit_set[Conn_Cap; u8]

// Framing for a slot (host-private)
Message_Proto :: enum u8 { H1, H2 }
```

**Derived (never stored as peer public bits):**

| Need | Derivation |
|------|------------|
| sendfile_ok | `Sendfile_Possible ∈ caps ∧ ¬Ciphered ∧ proto==H1` |
| flow control active | `Multiplex ∈ caps` |
| record framing | `Ciphered ∈ caps` |
| ALPN h2 | selected framer is H2 → set Multiplex; not a fifth cap |

### C.2 Public Plan_Context (four fields only)

Handlers/middleware may rely **only** on semantic constraints. **No ring free, SQE budget, fixed_files, or max_iovecs on the public struct** — those are L1/executor shape and live in host-private snapshots only.

```odin
// PUBLIC — the entire advanced handler surface for constraints
Plan_Context :: struct {
	sendfile_ok:           bool, // kernel file→socket path available for this plan
	zero_copy_send:        bool, // clear-path zc available
	preferred_copy_budget: u32,  // materialize threshold for mem bodies
	max_write_unit:        u32,  // single coalesce of record/frame/policy (0 = ignore)
}
```

| Field | Why public |
|-------|------------|
| `sendfile_ok` | semantic: “kernel file path available” |
| `zero_copy_send` | semantic: clear zc path |
| `preferred_copy_budget` | semantic: eager vs deferred materialize threshold |
| `max_write_unit` | semantic: max plaintext unit the pipe wants apps/middleware to respect when assembling |

**Removed from public surface:** `tls`, raw `caps`, `cipher_blocks_zc`, `prefer_coalesce`, `max_frame_payload`, flow windows, `proto`, **`output_ring_free`**, **`sqe_budget`**, **`max_iovecs`**, **`fixed_files`**.

**Host-private plan input** (planner/executor only; never on `plan_context(res)`):

```odin
Plan_Host :: struct {
	caps:              Conn_Caps,
	proto:             Message_Proto,
	max_write_unit:    u32,  // advisory at respond — NOT live flow token bucket
	max_iovecs:        u16,  // gather budget (clear H1)
	fixed_files:       bool,
	output_ring_free:  u32,  // L1 staging meter — host only
	sqe_budget:        u16,  // L1 batch meter — host only
	// Live windows NEVER snapshotted as authority — Law W1
}
```

### C.3 Law W1 — live windows, advisory plan only

> **Flow windows live on `slot.flow` and `conn.h2` (when Multiplex).**  
> The executor re-reads live windows **every produce/seal unit**.  
> `Plan_Context` / plan compile must **not** freeze stream/conn windows as a token bucket.  
> Any private `Wait_Flow` parks the **slot plan cursor**; on wake, re-read live windows; never resume into a freed plan.

```odin
// LIVE (authoritative)
Slot_Flow :: struct { send_window: u32, recv_window: u32 }
// conn-level send_window on H2_Engine when Multiplex

// On each unit before seal/frame:
unit := min(pt_avail, PULL_WINDOW, max_frame, live_stream_win, live_conn_win, record_batch_plain)
if unit == 0 {
	park Wait_Flow on this slot   // recv stays armed (Law D1)
	return
}
```

### C.4 Law W2 — plan cursor lifetime

> Plan cursor (`exec_i`, remainder, file off, deferred fill cursor) is **slot-owned**.  
> RST_STREAM / stream GOAWAY / slot teardown → **abort cursor**; free PT views for that slot; **no resume** into aborted plan.  
> Conn GOAWAY draining: new slots refused; existing slots complete or abort per GOAWAY rules.

### C.5 sendfile / ZC truth table (unchanged honesty)

| Situation | Ciphered | Multiplex | sendfile_ok | zc send |
|-----------|----------|-----------|-------------|---------|
| Clear H1 | F | F | platform | platform |
| TLS H1 | T | F | **F** | F |
| TLS H2 | T | T | **F** | F |
| h2c (if ever) | F | T | **F** (framing) | maybe |

No “sendfile under TLS because kTLS exists someday” without a real future cap and Phase research.

### C.6 Pure planner policy (still table-tested)

`plan_body(cmds, public_ctx, host)` remains a pure compiler:

1. Choose heading path for `host.proto` (private).  
2. File ∧ !sendfile_ok → Copy_Into / deferred file-window fill (not kernel sendfile).  
3. Size policy via `preferred_copy_budget` / `max_write_unit`.  
4. Emit **produce policy** (materialize vs gather vs deferred window) — not a frozen multi‑MiB token stream of flow units.  
5. Flow splitting is **executor loop** (Law W1), not a giant precomputed `Exec_Op[]` of every DATA frame.

**E0.8 / PR plan:** table tests for (File+Ciphered→no Sendfile), (gather only when clear H1), (max_write_unit coalesce). Flow park is executor unit tests, not frozen window snapshots.

---

## D. Response ≠ Connection — Stream_Slot sole ownership

### D.1 Graph

```
Server / worker (ring, Stream_Buf_Pool, session_scratch)
  └── Connection                    // PIPE ONLY
        ├── socket
        ├── caps: Conn_Caps
        ├── tls: ^Tls_Pipe | nil    // L2 + Seal_SM
        ├── framer: union { h1: H1_Framer, h2: H2_Engine }  // exclusive
        ├── pt: Conn_Pt_Ring        // FIRST-CLASS fixed PT admission (all slots)
        ├── wire_conn: Wire_Conn_State  // sole submit_send + fair Seal_Unit queue
        ├── slots: []Stream_Slot | slab header + freelist
        └── (no Response, no Session_State, no plan cursor)
              │
              └── Stream_Slot         // SOLE exchange storage
                    ├── gen
                    ├── proto
                    ├── frame_id        // private; never on public Session
                    ├── req, res
                    ├── wire: Wire_Slot_State  // plan cursor, file off, stream markers
                    ├── session?, session_pad
                    └── flow: Slot_Flow       // live H2 windows
```

### D.2 Phase 1 exit criterion (hard)

> **Dual-write of session/wire/plan fields forbidden.**  
> - `Response` binds **`_slot`** (conn derivable as `slot.conn` / pipe back-pointer).  
> - `Connection` holds **only** slab header + pipe state (socket, tls, framer, wire_conn).  
> - Accessors for migration may exist for one PR; merge gate: **grep-clean** of `conn.session`, `conn.wire.exec_*`, `conn.stream_*` as storage.  
> - H1: `slots` length 1 (or slab with one active); **same types** as H2.

### D.3 Allocators (lifetime table — keep)

| Memory | Allocator | Lifetime |
|--------|-----------|----------|
| Tls_Pipe CT/PT slabs, HPACK, settings | conn_allocator | connection |
| Stream_Slot slab | worker/conn pool | pooled + gen |
| Request scrap | request temp | until oneshot done or post-Start detach |
| Session pad / Session_State | conn_allocator | until on_close / timer CQEs drain |
| Stream send slabs | worker Stream_Buf_Pool | per Stream CQE |
| Effect scratch | worker session_scratch | per drive |

Never back long-lived wire with request temp. Per-slot temp detach after SSE Start (other slots may keep temp under H2).

### D.4 Wire split + typed fairness (not vibes)

```odin
// Identity for fair schedule — gen for ABA; frame_id private (never app-visible)
Seal_Unit :: struct {
	slot_gen:  u32,       // must match slot.gen when dequeued
	slot_idx:  u16,       // index into Connection.slots
	// private demux only — not Session.id
	frame_id:  u32,       // 0 if H1
	bytes:     []u8,      // view into Conn_Pt_Ring or CT after seal
	kind:      enum u8 { Clear, Ciphertext },
	end_stream: bool,
}

Wire_Conn_State :: struct {
	// Sole path to proactr submit_send on this socket
	kind:              Wire_Kind,  // None | Send
	pending:           []u8,       // bytes owned until CQE
	sock_send_inflight: bool,      // {false,true} ≡ socket {0,1}
	// Typed fairness queue (Law D4) — not an informal comment
	seal_q:            [SEAL_Q_CAP]Seal_Unit,
	seal_q_head:       u16,
	seal_q_tail:       u16,
	seal_q_len:        u16,
	rr_cursor:         u16,        // next slot_idx to prefer (deficit/RR)
	// Optional v1 equal weight; SSE vs bulk weights = open polish (accept starvation risk documented)
}

Wire_Slot_State :: struct {
	// Plan / progressive / file cursor — SLOT OWNED
	exec_i, exec_n: int
	file_send_*:    ...
	stream_open:    bool
	stream_sent:    int
	plan_aborted:   bool
	// Deferred fill cursor for large Static/File (host windowing into Conn_Pt_Ring)
	src_off:        i64
	src_remaining:  i64
	waiting_flow:   bool
	// Index of PT slab(s) checked out from Conn_Pt_Ring (not a private growable buffer)
	pt_hold:        u8             // count of admitted PT units for this slot
}
```

### D.5 Law S1 — single outbound scheduler

> **Only `wire_conn` (clear or via Tls_Pipe completion path) may `submit_send`.**  
> slots produce plaintext into **`Connection.pt`** (conn-level ring), then enqueue `Seal_Unit`s.  
> No second firehose (`session.out` growable multi‑MiB, parallel `resp_buf` send arm, mux-owned TCP send).  
> Effects → framed PT → **same** `seal_q` as oneshot units.

### D.6 Session handle (ABA)

```odin
Session :: struct {
	_slot: ^Stream_Slot, // or {pipe*, slot_index}
	id:    u32,          // generation — NOT H2 frame_id
}
// Lookup: slot.gen == id && !closed; else stale
```

Attach session to **slot**, never “whole conn” under Multiplex.

### D.7 Handler concurrency

Handlers stay synchronous per slot on the worker. Concurrent slots = interleaved completions on one thread-per-core loop — not threads, not async handlers.

---

## E. Tls_Pipe — normative L2 drive SM

### E.1 Default mechanism sentence

> **Mem-BIO (app-owned PT/CT buffers) is the only default bulk TLS path.**  
> No `SSL_set_fd` fighting the proactor. No product-mode poll demux.  
> Crypto engine types (`SSL*`, etc.) **never leave the Tls_Pipe module**.

### E.2 States + Seal_SM (normative — not a diagram caption)

```odin
Tls_Phase :: enum u8 { Handshake, Open, Closing, Closed }

// Seal pipeline depth — FORBID bare `send_inflight: bool` as the only bulk state under TLS
Seal_SM :: enum u8 {
	Idle,            // no CT sealed, socket free
	Sealing,         // AEAD filling free CT[i]
	Send_Armed,      // one CT in sock send; may seal other CT
	Send_And_Sealed, // sock send + second CT ready
}

Tls_Pipe :: struct {
	phase:          Tls_Phase
	engine:         Conn_Cipher_Engine  // opaque; module-private
	seal:           Seal_SM
	// Inflight arms — only mutated from CQE paths
	recv_inflight:  bool
	// Socket sends: bool is correct for {0,1}; seal depth is seal_n, not a second sock counter
	sock_send_inflight: bool
	// CT double-buffer: encrypt ∥ send
	ct:             [2]Ct_Slot          // fixed; never grow
	ct_seal_idx:    u8
	ct_send_idx:    u8
	seal_n:         u8                  // count sealed or in-send ∈ {0,1,2}
	// CT high-water: stop sealing new records when sealed CT bytes exceed (dual HW with PT)
	ct_bytes_held:  u32
	// rx remainder for partial records (BOUNDED fixed cap)
	rx_hold:        []u8                // len ≤ RX_HOLD_CAP; not growable
	// Encrypt input aliases Connection.pt ring views — no second full PT window alloc
}
```

### E.3 Drive laws (arm only from CQE)

| Law | Statement |
|-----|-----------|
| **T1** | `tls_arm_recv` / `tls_arm_send` only from accept path setup, handshake progress, or **CQE handlers** (`tls_on_recv_complete`, `tls_on_send_complete`). Never from handler threads mid-body_*. |
| **T2** | Handshake: WANT_READ → arm recv; WANT_WRITE → seal/send flight handshake records; on Open → set caps, install framer from ALPN. |
| **T3 Seal∥send** | Open bulk: produce into **conn `pt` ring** ≤ PULL_WINDOW if under PT_HIGH_WATER → if free CT and under CT_HIGH_WATER, seal into CT[i] (`seal_n` advances) → if `!sock_send_inflight` submit CT; if sock busy and other CT free, **encrypt may start while other CT is in sock send** (`seal_n∈{0,1,2}`). Anti-pattern: `sock_send_inflight: bool` alone without CT[2]+Seal_SM under TLS bulk. |
| **T4** | On send CQE: recycle CT slot; `sock_send_inflight=false`; `seal_n--`; submit next sealed CT or return to produce/schedule. |
| **T5** | On recv CQE: feed mem-BIO / decrypt; **burst drain** plaintext into framer (`feed`) until WANT_* / burst cap; re-arm recv if Open and not Closing. |
| **T6** | Closing: see §E.4 close state machine. |

### E.4 Close state machine (free order — normative)

Implementers must not invent. Two paths: stream-level vs conn-level.

```
Triggers: handshake fail | TLS alert | GOAWAY | RST_STREAM | TCP EOF | CT send error | idle | server stop

On stream RST / stream GOAWAY-affected:
  1. slot.gen bump intent (mark dying)
  2. abort plan_cursor (Law W2); drop slot deferred produce state
  3. session → Client_Gone effects once; on_close after wire quiet
  4. remove Seal_Units for slot.gen from wire_conn.seal_q
     (if unit is mid-socket-send, wait CQE — do not free view under CQE)
  5. if socket send view owned by this slot → wait CQE then recycle
  6. return Conn_Pt_Ring slabs held by slot (pt_hold); free slot storage; gen++

On conn-level death (TLS alert, GOAWAY all, TCP EOF, handshake fail):
  1. Tls_Pipe.phase = Closing; refuse new slot work that needs cipher
  2. for each live slot: stream death path above
  3. fail/cancel inflight recv; wait sock_send_inflight CQE if any
  4. engine shutdown / SSL_shutdown best-effort (no block); free engine
  5. free CT[2], rx_hold clear; return all Conn_Pt_Ring slabs
  6. Clear Connection.tls; close fd; Connection slab recycle

Invariant: never free CT/PT buffer still referenced by outstanding send CQE.
Invariant: never resume Waiting_Flow into freed plan buffers (gen check).
Invariant: never free Session_State while timer CQEs pending (existing pin).
```

### E.5 ALPN honesty (handmade)

> Phase 2 listen offers **`http/1.1` only**.  
> Phase 4+ may offer `h2` + `http/1.1`.  
> **Do not negotiate h2 and ignore it.** Silent dual personality is forbidden.  
> **No lie at handshake:** offer only protocols you serve.

### E.6 Clear path

Clear H1: `tls == nil`; produce units go wire_conn directly (existing send/writev/sendfile policy). Same scheduler ownership (Law S1).

---

## F. Write pipeline physics (private contract)

### F.1 Pipe POD constants (named table; peer-measured defaults)

These are **pipe POD**, not public `Plan_Context` fields. Apps do not tune per response. `Server_Opts` may override. Numbers are **peer-measured defaults** (same order as common multi-protocol bulk hosts: 64 KiB produce window, ~4× TLS record batch, 128 KiB dual high-water, fixed 16 KiB rx hold, CT×2). Present as proactr constants with optional vapor/peer evidence footnote — **not a package import**.

| Name | Default | Role |
|------|--------:|------|
| `PULL_WINDOW` | **64 KiB** | max PT produce per unit from Static/Bytes/File |
| `TLS_RECORD_PLAIN` | 16 KiB | single TLS record plaintext budget |
| `TLS_RECORD_BATCH` | **~4 records** | coalesce toward ~64 KiB plain before submit when peer allows |
| `CT_SLOTS` | **2** | double-buffer encrypt ∥ send |
| `PT_HIGH_WATER` | **128 KiB** | stop **producing** into conn PT ring when admitted PT bytes ≥ this |
| `CT_HIGH_WATER` | **128 KiB** | stop **sealing** new CT when sealed/in-flight CT bytes ≥ this |
| `RX_HOLD_CAP` | **16 KiB** | bounded partial-record remainder (fixed) |
| `SEAL_Q_CAP` | **32** | max queued Seal_Units per conn (admission; backpressure to slots) |
| Socket send | **{0,1}** | `sock_send_inflight: bool` |
| Seal depth | **{0,1,2}** | `seal_n` — seal while one send inflight |
| `BIO_RX_HOLD_MAX` | **16 KiB** | synonym/alias of `RX_HOLD_CAP` in cipher path |

*Peer evidence footnote (optional audit): same numerical band as vapor-http `PULL_WINDOW_DEFAULT` / `CT_HIGH_WATER_DEFAULT` / `PT_HIGH_WATER_DEFAULT` / `BIO_RX_HOLD_MAX` / `CT_SLOTS=2` — adopted as private POD law under proactr types, not as public knobs.*

### F.2 Conn-level PT ring (first-class — **must** alias; not soft)

```odin
// Single admission point for plaintext under bulk / multiplex.
// Per-slot growable staging is FORBIDDEN as the bulk path.
Conn_Pt_Ring :: struct {
	// Fixed slabs (worker/conn pool); each slab ≤ PULL_WINDOW
	slabs:       [][]u8,       // or fixed array of slab handles
	admitted:    u32,          // bytes currently checked out to slots/seal path
	high_water:  u32,          // PT_HIGH_WATER
	// free list of slab indices
}

// Produce path:
//   if conn.pt.admitted + need > high_water → pause this slot's pump (not grow)
//   take slab → fill ≤ PULL_WINDOW from slot deferred source → hold on slot.pt_hold
//   enqueue Seal_Unit{slot_gen, slot_idx, frame_id, bytes=slab_view, ...}
//   on wire/CT recycle → return slab; admitted -=
//
// Cipher seal input MUST alias pt ring views — Tls_Pipe must not allocate a second
// full PT window (no dual PT surfaces). "May alias" is FORBIDDEN; dual PT is a
// peak-mem regression and a Law PT1 violation.
```

**Law PT1:** All bulk plaintext admission goes through `Connection.pt`. Slot-local views may *reference* ring slabs; they must not own unbounded dynamic PT. **Tls_Pipe encrypt input must alias `Conn_Pt_Ring` views** — not a second full PT window.

### F.3 Pipeline diagram (normative)

```
sources (Static | Bytes | File-window | effect-framed live)
    │
    ▼  produce ≤ PULL_WINDOW into Connection.pt  |  stop if PT_HIGH_WATER
 PT slab (conn ring) ──MUST alias──► seal input
    │
    ▼  if Multiplex: H2 DATA frame (≤ min(max_frame, live windows))
    │  if H1 stream: chunked TE as today
    ▼  if Ciphered: Seal_SM → CT[i]  (batch ~4 records; stop if CT_HIGH_WATER)
    │  else: unit is clear wire bytes
    ▼
 wire_conn.seal_q  (Seal_Unit + rr_cursor; gen-checked dequeue)
    │
    ▼  submit_send when !sock_send_inflight
 CQE → recycle CT/slab → fair next / Wait_Flow / complete slot
```

**Peak memory:** O(PT_HIGH_WATER + CT_HIGH_WATER + ring slabs), not O(body) and not O(body × slots) without admission.  
**Forbid:** growable multi‑MiB session output; per-slot growable PT under multiplex; `remove_range` multi‑MiB firehose; full materialize of multi‑MiB Static into resp_buf when deferred windowing applies; second PT window inside Tls_Pipe.

### F.4 Deferred large bodies (no third public intent rail)

Large `Static` / `Bytes` / `File` remain **one command**. Host sets `Wire_Slot_State.src_off/remaining` and fills **conn PT slabs** on the completion path (pull-as-host-mechanism). **Not** a public `body_set_pull` / `Body_Source` ontology. **No app-facing pull registration** (App Contract NEVER / E0.6).

```odin
// PRIVATE host-only — never app API, never examples/, never app godoc
// Host_Pull: static middleware / host internals only
Slot_Deferred :: struct {
	kind:   enum u8 { None, View, File_Window, Host_Pull },
	view:   []u8,
	fd:     i32,
	offset: i64,
	remain: i64,
	pull:   proc(user: rawptr, dst: []u8) -> (n: int, done: bool),
	user:   rawptr,
}
```

### F.5 Exec_Op compression (mechanism, not laundry)

**Apps never see Exec_Op.** Bulk public contract is **windows / high-water / inflight** only.

Private executor vocabulary (fused preference):

```odin
Exec_Op_Kind :: enum u8 {
	// Existing clear/oneshot
	Write_Slice, Writev, Sendfile, Copy_Into, Patch_CL,
	// Boundaries
	Flush,            // one meaning: commit current unit to scheduler (see §F.6)
	// Control
	Wait_Flow,        // park slot; re-read live windows on wake
	// Produce (optional explicit)
	Produce_Window,   // fill next ≤PULL_WINDOW from cmd source into Conn_Pt_Ring
	// Commit to pipe (FUSED seal/frame — prefer one op)
	Commit_Unit,      // frame if needed + seal if Ciphered + enqueue seal_q
}
```

**Fusion rule:** do not require separate `Write_Plain` + `Cipher_Seal` + `Frame_Data` as three interpreter steps in the hot path. Internal helpers OK; **cursor advances by units**.  
`WINDOW_UPDATE` credit return is **host automatic** — not a plan-emitted op.

### F.6 One flush-unit definition

> **Flush unit** = min(app-intent remaining, PULL_WINDOW, max_write_unit, live stream window, live conn window, TLS batch plain when Ciphered, H2 max_frame when Multiplex).  
> App `stream_flush` / effect apply means: “deliver committed bytes for **this slot** up to flush unit policy.”  
> It does not mean TCP_NODELAY or flush other slots’ records.

### F.7 Law D4 — fairness as type (implementable)

> Dequeue from `wire_conn.seal_q` only if `Seal_Unit.slot_gen == slots[slot_idx].gen`.  
> Schedule: **deficit or round-robin** via `rr_cursor` over slots that have pending produce or queued units.  
> No silent forever monopoly by one deferred body.  
> v1: equal weight (SSE vs bulk starvation accepted until weighted polish — document, do not pretend solved).

---

## G. Framing — exclusive, not god-object

```odin
// Connection holds exactly one active framer personality after handshake
Connection_Framer :: struct {
	kind: enum u8 { H1, H2 },
	// exclusive storage — not a kitchen-sink Frame_State
	using impl: struct #raw_union {
		h1: H1_Framer,   // scanner/keep-alive machine
		h2: H2_Engine,   // settings, HPACK, stream map to slots, conn windows
	},
}
```

**Sans-I/O private contract for engines (testable without ring):**

```
feed(framer, plaintext_in) → demux events (headers, data, rst, window_update, goaway)
pull_control(framer) → outbound control frames (WINDOW_UPDATE, SETTINGS ack) into seal schedule
```

H2 stream accept → allocate/activate `Stream_Slot`, run handler, enqueue units.  
No second `Loop` type for H2; **same** `Stream_Slot` as H1.

**Engine port boundary (maintenance):**

- **Steal:** frame layouts, h2spec vectors, flow math, HPACK algorithms  
- **Own:** types under `Stream_Slot` / `Connection`; ONE owner in this tree  
- **Do not:** forever dual-maint a vapor package import of `server/`

---

## H. Effect sessions under H2

### H.1 Mapping

| | H1 | H2 |
|--|----|----|
| SSE | one slot (often exclusive conn while streaming) | one slot / one stream |
| Hangup | → `.Client_Gone` | RST/GOAWAY stream → `.Client_Gone` |
| Backpressure | buffer full → drop + `.Writable` later | buffer **or** flow 0 → same |
| Timers / External | identical | identical |

### H.2 Effect API frozen

```odin
Session_On_Event :: #type proc(sess: ^Session, ev: Session_Event, user: rawptr) -> Effects
// No protocol parameters. No Stream_Reset. No Window_Update event.
```

Internal: `WINDOW_UPDATE` + buffer drain + scheduled → at most one `.Writable` when `want_writable`.

### H.3 No public resume

Proactor owns timing: timers, send CQEs, mailbox drain, flow wakes. No `http.resume`.

### H.4 SSE vs HTTP framing (no Session_Wire vtable product)

SSE codec (effect → `data:`) stays session layer. Transport is H1 chunked **or** H2 DATA from `framer.kind` — **private host switch**, not a product `Session_Wire` struct of function pointers (unless a third backend exists; H3 refused now).

```odin
session_apply_write :: proc(conn: ^Connection, slot: ^Stream_Slot, p: []u8) -> bool {
	// H1: chunked TE into pt / stream path
	// H2: DATA frames into pt under flow + HW
	// switch on conn.framer.kind — not a public plug-in type
}
```

### H.5 HEADERS for SSE on H2

Host emits HEADERS without `transfer-encoding: chunked`; END_STREAM only on end/abort. Handler sets ordinary headers only.

### H.6 Phase honesty for sessions (app-visible)

| Transport | SSE ready when |
|-----------|----------------|
| Clear H1 | Existing / Phase 1 |
| TLS H1 | Phase 2 exit (cipher + slot stream path) |
| TLS H2 | **Phase 5 exit (M6)** — not Phase 4 unary curl green |

Until Phase 5, authors use SSE on H1(/TLS); the **source stays identical** so flipping listen to H2 later needs no rewrite. Do not ship a separate “H2 session package.”

---

## I. Middleware under multi-protocol

Unchanged purity:

| Middleware | Needs | TLS/H2 |
|------------|--------|--------|
| Range | Seekable + Known_Length | yes — slice cmds |
| Gzip eager | Replayable | yes → Owned Bytes |
| Static / File | File cmd | planner clears sendfile_ok |

**Never:** sendfile, SSL\*, frames, stream ids, proactr ring/SQE meters, `if Ciphered` mechanism branches beyond reading the four public `plan_context` fields for *size* policy.

---

## J. H2 host laws (review reject)

| ID | Law |
|----|-----|
| **D1 Duplex** | **Never unarm recv solely because send/CT is inflight or stream flow is 0.** Drain decrypted inbound (burst after progress) so WINDOW_UPDATE and control frames run. |
| **D2** | RST/GOAWAY on one stream aborts that **slot** only; other slots keep PT/seal progress. |
| **D3** | Multiplex **product** bar before “H2 perf” / author “supports HTTP/2”: concurrent unary N≥2 seal-scheduled; concurrent deferred large bodies N≥2 (or documented Server_Opts HOL — **not default**); **plus M6 SSE-on-H2**. |
| **D4** | Fairness: typed `Seal_Unit` queue + `rr_cursor` + gen check (§D.4, §F.7). |
| **S1** | Single outbound scheduler (§D.5). |
| **W1/W2** | Live windows; slot plan abort (§C.3–C.4). |
| **PT1** | Conn-level `Conn_Pt_Ring` sole PT admission; cipher **must** alias ring; dual HW PT+CT (§F.1–F.2). |
| **E1** | Evidence exits hard — not optional culture (§K phase exits). |

Historical H1 “one of recv/send” mutual exclusion **does not apply** under Multiplex+Ciphered. Document the exception in wire invariants.

### Multiplex product checklist (M1–M6 — before any author-facing “supports HTTP/2” or “H2 perf” claim)

| Gate | Requirement |
|------|-------------|
| **M1** | Concurrent unary ≥2 sealed units scheduled fairly on one conn |
| **M2** | Concurrent deferred large bodies ≥2 (windowed via PT ring) |
| **M3** | Fair seal RR/deficit with gen-checked `Seal_Unit` queue |
| **M4** | Duplex recv + rBIO burst under multi-stream load (Law D1) |
| **M5** | Peak PT/CT = O(high-water) under multi-stream large; not O(body×N) |
| **M6** | **SSE/Effects on H2 slots:** ≥2 concurrent long-lived sessions on one conn; same `sse_start` callbacks as H1; `.Client_Gone` on RST |

**Product bar = M1–M6.**  
v0 **may** ship single-dispatch unary for first green **only** as a labeled **engineering** milestone (Phase 4; optional internal `H2_UNARY_SERIAL=1`) — **never** README “supports HTTP/2,” never App Contract ✅ for H2 multiplex/SSE, never “H2 perf.”  
**Author-facing “H2 ready”** = M1–M6 + capability matrix TLS H2 column ✅ (except WS).

Smoke `curl --http2` is not a product badge.

---

## K. Phased implementation (API stable; eng ≠ product for H2)

### Phase 0 — Ergonomics freeze (E0.1–E0.8)

- Land `APP_CONTRACT.md`, `MIDDLEWARE_CONTRACT.md`, capability matrix (author ⏳/✅).  
- CI same-handler sample (clear H1).  
- Plan policy table tests; ban Host_Pull / http/debug / sid in examples.  
- Four-field public `Plan_Context`; host meters private.  
- **Exit:** E0.* green; no crypto required; **no handler docs that teach Tls_Pipe/Exec_Op**.  

### Phase 1 — Stream_Slot truth (N=1)

- Slot sole storage: Response, session, wire_slot, plan cursor.  
- Connection = pipe header only (+ future pt/wire_conn shapes stubbed).  
- **Grep-clean dual-write**; Response binds slot.  
- Gen on Session.  
- Pure plan_body tables for sendfile truth.  
- **Exit:** clear H1 behavior-identical; structure admits N slots; capability matrix Clear H1 ✅.  

### Phase 2 — TLS H1 + write physics

- Tls_Pipe + **Seal_SM**; mem-BIO default.  
- **Conn_Pt_Ring** (must-alias seal input); PT_HIGH_WATER + CT_HIGH_WATER; CT[2]; seal∥send.  
- ALPN: `http/1.1` only.  
- Caps.Ciphered; sendfile_ok false; deferred large body → PT ring.  
- Arm-only-from-CQE; close SM (§E.4).  
- Sessions/SSE over TLS H1.  
- Metrics: seal units, ct_send, pt_hw hits, ct_hw hits (required counters).  
- **Hard evidence exit (not optional):**  
  - HTTPS H1 multi‑MiB GET: peak PT ≤ PT_HIGH_WATER (+ε slab), peak CT ≤ CT_HIGH_WATER (+ε)  
  - m1 and m4 (or equivalent local bastion) bulk path records peak meters; **fail CI if peak ≳ 4× high-water** (firehose detector)  
  - No sendfile on TLS (counter / plan table)  
- **Exit:** capability matrix TLS H1 ✅.  

### Phase 3 — H2 engine (sans host) cherry-pick

- Port frame/HPACK/flow **into proactr types** (not forever-vendored vapor server).  
- Vectors + h2spec offline.  
- **Exit:** unit green; OWNERS: one tree.  

### Phase 4 — TLS H2 unary (**engineering milestone only**)

- ALPN h2; multi-slot slab; optional serial dispatch flag.  
- Live windows + Wait_Flow; duplex recv law wired.  
- **Exit:** curl --http2; h2spec core.  
- **Forbidden:** README “supports HTTP/2”; App Contract H2 multiplex/SSE ✅; H2 perf claims; capability matrix H2 concurrent/SSE ✅.  

### Phase 5 — H2 **product** bar (M1–M6)

- Concurrent unary + concurrent deferred + fairness + duplex evidence.  
- **Effects/SSE on H2 multi-slot (M6)** — same callbacks as H1; Client_Gone on RST.  
- Typed `seal_q` fairness; peak mem O(high-water).  
- CI: same handler sample under TLS H2 (including SSE).  
- **Recorded** ratio or absolute RPS vs named peer **or** prior clear/TLS baseline (committed artifact) — not optional polish.  
- **Exit:** M1–M6 green; capability matrix TLS H2 ✅ (except WS); “supports HTTP/2” + H2 perf language **allowed**.  

### Phase 6 — Polish

- Soft 503 admission (replace assert under load); GOAWAY drain.  
- Optional SSE-vs-bulk weights.  
- WS-over-H2 if desired (matrix ⏳ until then).  
- kTLS research as executor-only (honest new cap or not at all).  
- Multi-worker TLS + production checklist.  

**Each phase leaves App Contract stable.** Engineering Phase 4 ≠ product Phase 5.

---

## L. Non-goals & anti-patterns

### Non-goals

H3/QUIC detail; full h2spec day-one; public OpenSSL types; reactor-first demux; thread-per-conn; forcing every handler to read Plan_Context; H2 push; TLS renegotiation product; public multi-body mechanism modes; unifying SSE into Response_Cmd; vapor package fork as architecture; io.Stream SSE dual; body_set_pull public rail; Conn_Proto as app/host architecture enum; forever vapor `server` import; dual Loop vs H2-only slot type.

### Anti-patterns (reject in review)

| Anti-pattern | Why |
|--------------|-----|
| Handler SSL_write / SSL* | L5→L2 leak |
| Body mode = writev/sendfile/tls | mechanism as intent |
| Public resume / poll | breaks proactor timing |
| Stream id primary API / Response._sid | wrong abstraction |
| Second hangup event / `Stream_Reset` app event | dual API |
| Middleware on ring/frames/SSL | pipeline purity |
| Dual H1 Loop vs H2-only slot type | parallel worlds |
| Negotiate h2 then ignore | ALPN lie |
| Unarm H2 recv while flow-blocked send | duplex HOL |
| Second submit_send firehose | Law S1 |
| Growable multi‑MiB session.out | firehose |
| Frozen Plan_Context as live window authority | Law W1 |
| Dual-write conn+slot fields after Phase 1 | ownership lie |
| Thread-per-conn / poll demux product | identity |
| Frame_State kitchen sink | god-object |
| Public Plan_Context ring/SQE/iovecs meters | progressive-disclosure leak |
| Per-slot growable PT bulk path | firehose under multiplex |
| Bare sock_send bool without Seal_SM under TLS bulk | serial cliff |
| “H2 ready/perf” or README “supports HTTP/2” before M1–M6 | paper multiplex |
| App docs teaching Exec_Op / Tls_Pipe as handler API | docs dual |
| Dual full PT window in Tls_Pipe + Conn_Pt_Ring | peak-mem regress; Law PT1 |
| README / marketing before M1–M6 product bar | social dual |
| Marketing SSE-on-H2 before Phase 5 while claiming full invariant without ⏳ | honesty fail |
| `examples/` importing `http/debug` or registering Host_Pull | E0 social ban |
| Optional “fuse encrypt in adapter differently than tests” | Law S1 / one path |
| Experimental io.Stream SSE “for demos” | dual long-lived |
| Plan-time frozen windows as sole flow authority | Law W1 |
| Forever dual-maint vapor package fork | craft / dual substrate |

---

## M. Key Decisions

| # | Decision |
|---|----------|
| D1 | Semantics ≠ transport forever; two intent rails only (cmds / effects) |
| D2 | Public Plan_Context = **four fields only**; orthogonal private Conn_Caps; ring/SQE host-private |
| D3 | Stream_Slot sole exchange ownership; Connection is pipe only |
| D4 | H1 = N=1 same types; no dual architecture |
| D5 | Effects frozen; hangup = `.Client_Gone` only; backpressure = `.Writable` |
| D6 | No public resume; proactor owns timing |
| D7 | Law S1 single outbound scheduler; socket send_inflight ∈ {0,1}; CT pipeline {0,1,2} |
| D8 | sendfile never under Ciphered or Multiplex framing |
| D9 | Middleware cmd rewrite only |
| D10 | ALPN honesty; Phase 2 http/1.1 only; no h2 negotiate-and-ignore |
| D11 | Phase order: App freeze (E0) → slot truth → TLS physics → H2 engine → H2 unary eng → **product M1–M6** → polish |
| D12 | Tls_Pipe normative SM + mem-BIO + arm-from-CQE + close SM (§E.4) |
| D13 | Law W1 live windows; W2 plan abort; no frozen flow token bucket |
| D14 | Law D1 H2 duplex recv always drainable while send/flow blocked |
| D15 | Write physics: PULL_WINDOW 64KiB, ~4-record batch, CT×2, dual PT+CT high-water 128KiB, Conn_Pt_Ring — Phase 2 |
| D16 | Concurrent deferred bodies + typed Seal_Unit fairness + **M6 SSE-on-H2** before any author “supports H2” / H2 perf claim (**product bar = M1–M6**) |
| D17 | Exclusive H1_Framer \| H2_Engine; sans-I/O feed for tests |
| D18 | No app escape hatches for caps/proto in v1; debug only; no ring/SQE on public context |
| D19 | Exec_Op fused Commit_Unit; apps never see op zoo |
| D20 | App Contract + CI same sample + **E0.1–E0.8** is Phase 0 freeze (not implementer epic as public story) |
| D21 | Seal_SM + seal_n∈{0,1,2}; forbid bare sock bool alone under TLS bulk |
| D22 | Hard bastion/firehose CI exits for Phase 2 TLS bulk (**fail if peak ≳ 4× HW**) and Phase 5 H2 product gates |
| D23 | Cipher PT input **must** alias Conn_Pt_Ring — single PT owner |
| D24 | Author **capability matrix** is part of freeze; Phase 4 eng ≠ Phase 5 product H2 |
| D25 | README honesty rules: no paper-H2; no early SSE-on-H2 marketing; TLS/H2 are listen options |
| D26 | PART I / PART II packaging; app authors stop after Part I |
| D27 | Steal facts / own types; refuse forever vapor `server/` fork |
| D28 | Session apply = private switch on `framer.kind` — no product Session_Wire vtable |
| D29 | Temporary soft-503 admission is host behavior until polish phase; not app API |
| D30 | NEVER: Host_Pull from app, progressive stream_* as second long-lived product, third intent rail |

---

## N. Open Questions (real; do not block freeze)

1. **TLS engine vendor** inside Tls_Pipe (OpenSSL/BoringSSL/mbedtls/rustls-FFI) — opacity holds regardless.  
2. **HPACK dynamic table RAM** per conn — Server_Opts cap before multi-worker production.  
3. **Max concurrent streams vs session caps** — single worker admission story preferred.  
4. **h2c** — default no; TLS+ALPN only unless deploy forces.  
5. **Slot slab vs freelist** — pick in Phase 1 spike; default fixed slab + gen (or worker freelist + gen; H1 embeds one slot inline).  
6. **kTLS** — Phase 6 research only; never silent sendfile_ok under Ciphered.  
7. **WS over H2** — later phase; App Contract / matrix says H1(/TLS) until then.  
8. **Fairness weights** — equal RR v1; document SSE vs bulk starvation until weighted polish.  
9. **Shared SSL_CTX** across REUSEPORT workers — shared + free on last worker recommended.

---

## O. PR Plan

| PR | Contents | Gate |
|----|----------|------|
| **PR0** | APP_CONTRACT + MIDDLEWARE + **capability matrix** + CI sample + plan tables + example ban list | **E0.1–E0.8** |
| **PR1** | Four-field Plan_Context; private Plan_Host meters; Conn_Caps | tests green |
| **PR2** | Stream_Slot N=1; Response→slot; grep-clean dual-write; gen Session | H1 identical |
| **PR3** | plan_body table tests (sendfile/cipher/unit) | pure tests (E0.8) |
| **PR4** | Tls_Pipe + Seal_SM + Conn_Pt_Ring POD (must-alias); close SM | unit tests |
| **PR5** | HTTPS H1 wire; seal∥send; dual HW; **firehose CI gate (≳4× HW fail)** | bulk O(window) **required** |
| **PR6** | SSE/WS on TLS H1 | session tests; matrix TLS H1 ✅ |
| **PR7** | H2_Engine sans-I/O + vectors (cherry-pick facts; own types) | no ring |
| **PR8** | Multi-slot + ALPN h2 + duplex + live windows (**engineering unary**) | curl/h2spec; **no** README H2 |
| **PR9** | **M1–M6** multiplex + SSE-on-H2 + seal_q fairness + recorded baseline; App CI all three | **product H2**; matrix H2 ✅ |
| **PR10** | Soft 503, GOAWAY, optional weights, multi-worker checklist | production edges |

**Review checklist:** App Contract only for apps · capability matrix · four-field Plan_Context · no dual-write · S1/W1/D1/PT1 · Seal_SM · must-alias PT · no SSL\* · no stream id · **M1–M6** before H2 product language · E0 example bans · clear H1 green.

---

## P. Type sketch (implementable)

```odin
package http

// ----- Public — four fields only -----
Plan_Context :: struct {
	sendfile_ok:           bool,
	zero_copy_send:        bool,
	preferred_copy_budget: u32,
	max_write_unit:        u32,
}

// ----- Host (private) -----
Conn_Cap :: enum u8 { Ciphered, Multiplex, Sendfile_Possible, Zero_Copy_Send }
Conn_Caps :: bit_set[Conn_Cap; u8]
Message_Proto :: enum u8 { H1, H2 }

// Pipe POD (peer-measured defaults; not public Plan_Context)
PULL_WINDOW :: 64 * 1024
TLS_RECORD_BATCH_TARGET :: 4
CT_SLOTS :: 2
PT_HIGH_WATER_DEFAULT :: 128 * 1024
CT_HIGH_WATER_DEFAULT :: 128 * 1024
RX_HOLD_CAP :: 16 * 1024
SEAL_Q_CAP :: 32

Seal_Unit :: struct {
	slot_gen: u32,
	slot_idx: u16,
	frame_id: u32,
	bytes:    []u8,
	kind:     enum u8 { Clear, Ciphertext },
	end_stream: bool,
}

Conn_Pt_Ring :: struct {
	// fixed slabs ≤ PULL_WINDOW; admitted + high_water
	admitted:   u32,
	high_water: u32,
	// ... free list of slabs
}

Stream_Slot :: struct {
	gen:          u32,
	proto:        Message_Proto,
	frame_id:     u32,
	conn:         ^Connection,
	req:          Request,
	res:          Response,
	wire:         Wire_Slot_State,
	session:      ^Session_State,
	flow:         Slot_Flow,
	plan_aborted: bool,
}

Session :: struct {
	_slot: ^Stream_Slot,
	id:    u32,
}

Connection :: struct {
	server:    ^Server,
	socket:    net.TCP_Socket,
	caps:      Conn_Caps,
	tls:       ^Tls_Pipe,
	framer:    Connection_Framer,
	pt:        Conn_Pt_Ring,     // sole PT admission; seal MUST alias
	wire_conn: Wire_Conn_State,  // seal_q + sock send
	slots:     []Stream_Slot,
}

Seal_SM :: enum u8 { Idle, Sealing, Send_Armed, Send_And_Sealed }
Tls_Pipe :: struct {
	phase:              Tls_Phase,
	engine:             Conn_Cipher_Engine,
	seal:               Seal_SM,
	recv_inflight:      bool,
	sock_send_inflight: bool,
	ct:                 [CT_SLOTS]Ct_Slot,
	seal_n:             u8,
	ct_bytes_held:      u32,
	rx_hold:            []u8,
}

Exec_Op_Kind :: enum u8 {
	Write_Slice, Writev, Sendfile, Copy_Into, Patch_CL,
	Flush, Wait_Flow, Produce_Window, Commit_Unit,
}
```

### Server_Opts (admin, not handler)

```odin
// Phase 2+
tls: Tls_Server_Opts           // cert paths / config — not SSL*
pt_high_water: int             // 0 → PT_HIGH_WATER_DEFAULT
ct_high_water: int             // 0 → CT_HIGH_WATER_DEFAULT
// Phase 4+
h2_max_streams: u32
h2_initial_window: u32
// debug only: h2_serialize_bodies (HOL; off by default; never marketed as H2)
```

---

## Q. Success / failure criteria

### Structural success

- [ ] App Contract CI: same handler clear / TLS / H2  
- [ ] E0.1–E0.8 green before TLS/H2 marketing  
- [ ] Author capability matrix published with ⏳/✅  
- [ ] Stream_Slot sole exchange storage; Connection pipe-only  
- [ ] Tls_Pipe + Seal_SM + mem-BIO + CT×2 + Conn_Pt_Ring (must-alias) in Phase 2  
- [ ] Live windows; no Plan_Context flow authority  
- [ ] Duplex recv under H2  
- [ ] Single wire_conn submit path + typed seal_q  
- [ ] Public Plan_Context = four fields; no ring/SQE/caps/proto app APIs  

### Behavioral success

- [ ] Clear H1 unchanged through Phase 1–2  
- [ ] TLS bulk peak O(high-water) with **hard CI firehose detector (≳4× HW fail)**  
- [ ] H2 **M1–M6** green + recorded baseline before product language  
- [ ] Partial send / free-order close SM invariants hold  
- [ ] README honesty: no paper-H2 before Phase 5  

### Failure (redesign triggers)

- Handlers need stream ids or protocol `#if`  
- Dual Loop/H2 architecture returns  
- Public resume or second hangup  
- Firehose multi‑MiB PT/CT / per-slot growable PT  
- Dual PT window (Tls_Pipe + Conn_Pt_Ring without alias)  
- Recv held while H2 flow-blocked  
- Dual-write conn/slot after Phase 1  
- Public Plan_Context regains ring/SQE meters  
- “H2 ready” / “supports HTTP/2” marketed before M1–M6  
- SSE-on-H2 marketed before Phase 5 while claiming full invariant without ⏳  
- Examples reintroduce Host_Pull / http/debug / sid  

---

## R. Reminder

> Apps speak **intent** and **events**.  
> **Slots** own exchanges; the **pipe** owns cipher, framer, and the only send arm.  
> **Windows and high-water** are the bulk truth; **live flow** is re-read, never frozen as plan law.  
> **Tls_Pipe** is driven from **CQEs**; SSL never appears upstairs.  
> **Conn_Pt_Ring must alias** seal input; firehose CI fails at ≳4× high-water.  
> Product H2 means **M1–M6** (including concurrent SSE) — not curl green.  
> Freeze the **App Contract** and **capability matrix**; phase physics underneath.  
> Authors stop at **PART I**; implementers own **PART II**.

---

## Round-4 graft log

B residual wins absorbed into A’s spine. Each row: B residual → where it landed in A R4.

| # | B residual | Landed in A R4 |
|---|------------|----------------|
| 1 | PART I / PART II split; front-matter who-reads-what | Status block + `# PART I` / `# PART II` headers; authors stop after matrix |
| 2 | Author capability matrix (⏳/✅ × phase product readiness) | PART I “Author capability matrix” |
| 3 | README honesty rules (no paper-H2; no early SSE-on-H2; listen options; curl≠product) | PART I honesty rules + Phase 4 Forbidden + anti-patterns |
| 4 | E0.1–E0.8 hard Phase 0 merge blockers | PART I “Phase 0 ergonomics freeze gate”; Key D20; PR0 |
| 5 | Expanded NEVER: Host_Pull from app; progressive stream_* second product; third intent rail | App Contract NEVER block; B.2; D30; F.4 |
| 6 | Temporary soft-503 admission note in App Contract | PART I “Temporary host behavior”; D29 |
| 7 | **M6** concurrent SSE/Effects on one H2 conn; product bar = M1–M6 | §J multiplex checklist M1–M6; Phase 5; D16 |
| 8 | Split eng vs product H2 phases (unary eng forbidden as README H2) | Phase 4 eng / Phase 5 product; D11, D24; PR8 vs PR9 |
| 9 | Align phase map (H2 unary eng ≠ multiplex+SSE product); keep A firehose CI + must-alias + Seal_Unit | §K Phases 0–6; Phase 2 keeps 4× HW CI; F.2 must-alias; D.4 Seal_Unit |
| 10 | Close SM detail (stream RST vs conn death; seal_q gen remove; never free CT/PT on inflight CQE; never resume Waiting_Flow into freed plan) | §E.4 replaces thinner free-order list |
| 11 | L5-style named constant POD + peer-measured footnote (not package import) | §F.1 table + footnote; type sketch POD block |
| 12 | Steal vs own table (cherry-pick facts; refuse forever vapor server fork) | §A.4 + §G engine port boundary; D27 |
| 13 | Session apply path: private switch on framer kind (not Session_Wire vtable product) | §H.4 `session_apply_write` sketch; D28 |
| 14 | Anti-patterns: README before M1–M6; marketing SSE-on-H2 early; examples Host_Pull/debug | §L anti-pattern table expanded |
| — | *(kept A residuals — not diluted)* | Conn_Pt_Ring **must** alias; firehose CI ≳4× HW; typed Seal_Unit+seal_q+rr_cursor+gen; allocator table §D.3; W1/W2/D1/PT1; G1–G5 thesis voice; four-field Plan_Context; Stream_Slot sole ownership |

**Not reopened / not reintroduced:** dual Loop worlds; fat public Plan_Context; app-facing seal SM; Session_Wire product type; dual H1/H2 host architectures.

---
