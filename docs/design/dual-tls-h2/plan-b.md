# Plan B (r3) — proactr multi-protocol high-level API  
## vapor-informed TLS + HTTP/2 · single-slot ontology · completion-native

**Status:** design freeze candidate (r3 — ergonomics phase-honesty pass; structural WOW retained)  
**Identity:** proactr-odin stays proactor-first. vapor-http is the multi-protocol *evidence base* and **private physics** source — not a package to fork forever, not a second public ontology.  
**Who reads what:** **App authors stop after App Contract + capability matrix.** Implementers continue.  
**Audience (rest of doc):** implementers who refuse SSL, readiness, stream-ids, and dual H1/H2 host worlds in app-facing code.

---

## North star

> **One `Stream_Slot` owns every exchange. One pipe owns every socket send. Handlers emit only intent (commands | effects). Vapor’s windows, mem-BIO, and duplex laws live under the pipe — never as a parallel product.**

---

# PART I — APP SURFACE (authors · freeze · CI)

**App invariant (every tutorial title):**  
**If it is correct on clear HTTP/1.1, it is correct on HTTPS and HTTP/2** — *for capabilities marked ✅ below*. Capabilities marked ⏳ are listen/phase-gated, not handler `#if`.

---

## App Contract (≤1 page — the only public story)

Copy into `docs/APP_CONTRACT.md` verbatim at Phase 0. **No Exec_Op, no seal SM, no vapor anatomy in that file.**

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
  progressive stream_* as a second long-lived product (see below)
```

| Concept for apps | Meaning |
|------------------|---------|
| **Intent** | commands (oneshot) or effects (long-lived) — **exactly two rails** |
| **Exchange** | this request/response or session |
| **Backpressure** | write effects; wait `.Writable`; hangup is always `.Client_Gone` |

**Temporary host behavior (not app API):** session/slot admission may assert until soft 503 lands (Phase 8). Load tests can hit that — not a handler contract change.

**Unary bytes law:** only body cmds; host may window large Static/File privately — **no third public intent rail** (no app pull API, no sample that registers pull from app code).

**Long-lived law:** only Effects. Existing progressive `stream_*` (if still present) is not a second product story — fold under oneshot multi-CQE or deprecate in APP_CONTRACT; **SSE/WS use Effects only**.

**Identity law:** public `Session.id` is generation only — never H2 stream id.

Framework authors may know Slot · Pipe · Framer · Cipher. **App tutorials never say those words.**

### Author capability matrix (what you may write *now*)

Phase numbers = product readiness for **authors**, not internal engineering milestones.  
Until a cell is ✅, do not market that combo; handlers still use the same API — listen options simply do not offer it yet.

| Capability | Clear H1 | TLS H1 | TLS H2 |
|------------|:--------:|:------:|:------:|
| Oneshot cmds + `respond` | ✅ Phase 1 | ✅ Phase 3 | ✅ Phase 5 (unary); **multiplex concurrent** ✅ Phase 6 |
| Large `body_file` / Static (same API; host windows) | ✅ Phase 2 | ✅ Phase 3 | ✅ Phase 6 |
| **SSE** (`sse_start` / Effects) | ✅ today / Phase 1 | ✅ Phase 3 | ⏳ **Phase 6** (with multi-slot; same callbacks) |
| **WS** (`ws_start`) | ✅ H1 | ✅ TLS H1 | ⏳ later phase (not H2 until documented) |
| Concurrent unary on one connection | N/A (pipelining H1) | N/A | ✅ Phase 6 (M1) |
| Concurrent SSE sessions on one connection | N/A | N/A | ✅ Phase 6 (M6) |
| “Supports HTTP/2” in README | — | — | Only after Phase 6: concurrent slots **and** SSE-on-H2 |

**Honesty rules (README / release notes):**

1. **Do not** say “HTTP/2” without “concurrent streams: yes” after Phase 6 (or list ⏳).  
2. **Do not** imply SSE works on H2 before Phase 6 — same honesty as WS on H1-only.  
3. TLS and H2 are **listen options**, never handler options.  
4. Early engineering “curl --http2 green” (Phase 5) is **not** an author-facing H2 product.

### Plan_Context (public — four fields only)

```odin
Plan_Context :: struct {
    sendfile_ok:           bool, // kernel file→socket path available
    preferred_copy_budget: u32,
    max_write_unit:        u32,  // 0 = ignore
    zero_copy_send:        bool,
}
```

No ring free, SQE budget, iovecs, fixed_files, flow windows, caps, or high-water on this struct. Everything else is host-private.

---

## Middleware Contract (frozen)

| May | Must not |
|-----|----------|
| Rewrite `[]Response_Cmd` only | Import `tls_server` / Provider / SSL |
| Read **thin** `plan_context` | Read stream ids, slots, rings, SQEs |
| Set headers before `respond` / before `sse_start` | Emit frames, ALPN, or HPACK |
| Short-circuit with unary `respond_*` | Assume exchange finished after `next` for SSE (open ≠ end) |
| Keep `File` / `Static` / `Bytes` under TLS/H2 | Branch “if TLS then different body mode” for correctness |

**Rule:** File stays File; planner demotes mechanism (`sendfile_ok` false). Stream body bytes are never middleware’s job.

---

## Phase 0 ergonomics freeze gate (merge blocker)

Land **before** any TLS/H2 author marketing. Hard fail CI if missing:

| Gate | Artifact / check |
|------|------------------|
| **E0.1** | `docs/APP_CONTRACT.md` ≤1 page — Part I text only (no seal SM, no Exec_Op, no Provider) |
| **E0.2** | `docs/MIDDLEWARE_CONTRACT.md` — may/must-not table |
| **E0.3** | `docs/CAPABILITY_MATRIX.md` or same table inside APP_CONTRACT — author-facing ⏳/✅ |
| **E0.4** | CI: **same handler sample** under clear H1; later jobs add TLS H1 / H2 as those phases land — sample has **zero** protocol `#if`, no stream ids |
| **E0.5** | No `examples/` import of `http/debug` (or caps/proto introspection) |
| **E0.6** | No sample, godoc, or middleware helper that registers **Host_Pull** / pull from app code |
| **E0.7** | No example sets or prints stream id / `Response._sid` |
| **E0.8** | Pure `plan_body` policy table tests: File+TLS → no Sendfile (implementer; may live under `http/plan_test`) |

**Dual-API social ban:** the freeze is theater if examples reintroduce duals. Review examples with the same ferocity as types.

---

# PART II — IMPLEMENTATION (physics · ontology · phases)

*App authors: you can stop here. Below is host law.*

---

## 0. Vapor lessons (evidence — keep; decisions updated for r2/r3)

Distilled from `/Users/bngreer/Projects/odin-http` (vapor-http). Each: **adopt / invert / hybridize** for proactr r2.

### L1 — Layer cake is ownership, not three hosts

**Evidence:** `server/HOST.md` § Layers; `server/NBIO_UNIFIED.md` §3.

```
App intent → Slot (exchange) → Framer (sans-I/O) → Cipher? → Pipe wire → Ring
```

**Brilliant:** sessions never know workers; hosts never re-parse HTTP.  
**Accidental:** nbio vs demux vs thread as peer product modes.  
**r2:** **Adopt** sans-I/O framer + adapter split. **Invert** host engine to proactr Ring. **One** connection model grown in place (slot façade first).

### L2 — Sans-I/O protocol engine

**Evidence:** `session_h1.odin`, `session_h2.odin`, `http2/connection.odin`.

Feed plaintext in; produce framed plaintext out. No sockets.  
**r2:** **Adopt.** `Framer` private bag: `feed_pt` / `take_pt_unit`. Never `submit_send` inside http2/H1 parse.

### L3 — One cipher SM; one I/O driver (proactr)

**Evidence:** `NBIO_UNIFIED.md` §4; `tls_conn.odin`; `nbio_tls.odin`.

Vapor needed two drivers (poll demux + membio nbio).  
**r2:** **Adopt one SM, drop second driver as product.** Completions only. kqueue façade remains inside proactr backend, not a public TLS mode.

### L4 — Mem-BIO bulk path

**Evidence:** `HOST.md` H2 matrix; `VAPOR_RESULTS.md`; `nbio_tls.odin`.

App-owned wire + memory BIOs beat `SSL_set_fd` for data-SQE hosts.  
**r2:** **Adopt membio as the only TLS product path.** Demux/thread TLS = non-goals.

### L5 — Write contract: windows, high-water, inflight, progress

**Evidence:** `VAPOR_PROGRAM.md` §0/§4; `write_pipe.odin`; `tls_write_mode.odin`.

```
PULL_WINDOW_DEFAULT          = 64 * 1024
TLS_RECORD_BATCH_TARGET      ≈ (5+16384+32)*4
CT_HIGH_WATER_DEFAULT        = 128 * 1024
PT_HIGH_WATER_DEFAULT        = 128 * 1024
CT_SLOTS                     = 2          // encrypt ∥ send
SOCKET_SEND_INFLIGHT_MAX     = 1          // one FD send CQE
SEAL_INFLIGHT                ∈ {0,1,2}    // PT→CT pipeline depth
BIO_RX_HOLD_MAX              = 16 * 1024  // fixed cap, not growable firehose
```

**r2:** **Adopt as private pipe POD and law** — not as public `Plan_Context` knobs.

### L6 — Bulk produce vs live push (do not collapse)

**Evidence:** `STREAMS.md`; `Body_Source_Kind`.

**r2:** **Hybrid.** Oneshot intent = `Response_Cmd` only (Static/Bytes/File). Large bodies are **windowed by the host/planner** under those cmds (view/file windows, internal deferred produce). Long-lived = **Effects only**. No public `Body_Source` enum. No `body_set_pull` second rail. No `io.Stream` SSE dual in freeze.

### L7 — ALPN selects framer privately

**Evidence:** `tls_conn_finish_handshake`; ALPN constants.

**r2:** **Adopt privately.** ALPN never becomes app `Conn_Proto`. Fills `Conn_Caps` + which framer bag is live.

### L8 — H2 duplex: never hold recv while DATA pumps

**Evidence:** `HOST.md` H2 rules; `STREAMS.md` pitfall; `http2/flow.odin`.

**r2:** **Hard law + review reject.** Recv may be armed while socket send or CT seal is in flight under multiplex.

### L9 — Response ≠ connection (multiplex)

**Evidence:** H2 stream map; vapor `body_sid` one-deferred limit.

**r2:** **Adopt meaning, invert type shape.** One `Stream_Slot` type for H1 (N=1) and H2 (N≥1). Kill vapor’s “H1 session on conn / H2 special slot” dual. Concurrent deferred bodies are a **phase exit gate**, not optional folklore.

### L10 — Provider IOC stays under cipher module

**Evidence:** `tls_server/provider.odin`.

**r2:** **Adopt as private L2.** Not a product-layer sermon; not imported by handlers.

### L11 — Effects beat mid-handler live flush

**Evidence:** vapor `h*_live_stream.odin` vs proactr `session.odin` / `SESSION_SSE.md`.

**r2:** **Invert** vapor primary SSE. Effects only. No experimental `io.Stream` adapter in freeze surface.

### L12 — Middleware: one chain; open ≠ finished for SSE

**Evidence:** `MIDDLEWARE_SHAPE.md`.

**r2:** **Adopt** with hard cmd-only table (above).

### L13 — Thread-per-core; never thread-per-conn TLS

**Evidence:** vapor product outcome #7; proactr worker rings.

**r2:** **Adopt.**

### L14 — Idle/fairness are host concerns

**Evidence:** demux budgets; proactr software timers.

**r2:** **Hybrid.** Timers for idle; CQ batch for accept flood; **seal-unit fairness** on the pipe (not poll RR as product).

### L15 — Do not port

| Artifact | Why |
|----------|-----|
| demux default / `poll_once` TLS mode | readiness product |
| thread-per-conn TLS | forbidden |
| growable multi‑MiB `session.out` | firehose |
| handler-blocking live flush | fights CQE sessions |
| vapor `server/` wholesale | dual substrate |
| dual H1 Loop vs H2_Stream_Slot types | dual architecture (R1 fatal) |
| `Response._sid` | stream-id API leak |
| forever vapor package fork | dual-maint (R1 craft fail) |

---

## A. Ontology (single world)

### A.1 Six primitives (implementer meta — not app docs)

| Role | Type / home |
|------|-------------|
| **Intent** | `Response_Cmd[]` \| `Effects` |
| **Constraints** | thin public `Plan_Context` + private host snapshot |
| **Policy** | `plan_body` (pure) + seal scheduler |
| **Mechanism** | private produce → seal → submit (one path) |
| **Slot** | `Stream_Slot` — sole exchange ownership |
| **Pipe** | `Connection` — socket + optional cipher + framer demux + **one** send schedule |

### A.2 Stream_Slot (the cut)

```odin
Slot_Gen :: distinct u32

Stream_Slot :: struct {
    gen:          Slot_Gen,       // bumped on free; public Session.id derives from this
    // Framing id is PRIVATE — never on Response
    frame_id:     u32,            // 0 for H1; H2 odd stream id
    // Exchange
    req:          Request,
    res:          Response,       // res binds slot; conn is derivable
    session:      ^Session_State, // optional long-lived
    // Plan / wire progress (slot-local)
    cmds:         [PLAN_MAX_BODY_CMDS]Response_Cmd,
    cmd_n:        int,
    plan_cursor:  Plan_Cursor,    // survives park; aborted on RST/GOAWAY
    body_off:     int,            // view/file/window cursor
    // Live flow (H2); H1: max int
    stream_window: i64,
    // Lifecycle
    state:        Slot_State,     // Idle, Active, Sealing, Waiting_Flow, Streaming, Closed
    want_writable: bool,
}

// H1:  slots_len == 1, frame_id == 0
// H2:  slots_len == N, gen-pooled slab or freelist
```

**Laws:**

1. **H1 = degenerate single slot.** No long-term `Connection.loop` as response storage. Migration: Phase 0–1 moves `Loop` fields into `slots[0]`; accessors only; dual-write forbidden after Phase 1 exit.
2. **Response holds `^Stream_Slot` (or opaque slot token), not `_sid`.** `Response._conn` may remain as derivable sugar (`slot → conn`) during migration; wire/session paths use **slot only**.
3. **Public `Session.id` = generation**, not H2 stream id. Mailbox/timer/CQE callbacks: lookup by (conn, gen); **abort if gen mismatch**.
4. **Map/slab lookup always checks gen.**

### A.3 Connection (the pipe)

```odin
Conn_Cap :: enum u8 {
    Ciphered,          // TLS path active
    Multiplex,         // H2+ framing
    Sendfile_Possible, // OS path; host may clear
    Zero_Copy_Send,    // backend claim; host may clear
}
Conn_Caps :: bit_set[Conn_Cap; u8]

Connection :: struct {
    server:     ^Server,
    socket:     net.TCP_Socket,
    caps:       Conn_Caps,        // filled once at open/ALPN; not app API
    // Slot storage — sole home of Response/Session/plan cursor
    slots:      []Stream_Slot,    // or slab header + freelist
    slots_live: int,
    // Framer (exactly one bag active)
    framer:     Framer_State,     // H1 scanner machine OR H2 engine — exclusive
    // Cipher (nil path when !Ciphered)
    cipher:     ^Cipher_State,    // Tls_Pipe guts; private
    // Single outbound scheduler
    wire_conn:  Wire_Conn_State,  // ≤1 socket send; fairness queue of sealed units
    // Private PT staging for framed output (H2) / H1 heading+body windows
    pt:         Pt_Window_Ring,   // FIXED slots, high-water; not growable firehose
    // ... existing: scanner buf ownership, stream_pool hooks, worker_index
}
```

**No `Conn_Proto` product enum as architecture.** Caps are orthogonal: `Ciphered` × `Multiplex`. ALPN is private input to fill caps + framer.

### A.4 Framer (sans-I/O, private)

```odin
// Conceptual contract — not a vtable product
// H1: parse requests → open slot[0]; format status-line responses from slot plan
// H2: demux frames → open/credit slots; encode HEADERS/DATA from sealed PT units
Framer_State :: struct {
    kind: enum u8 { H1, H2 },
    // H1 fields OR H2 engine fields (exclusive union storage)
    h1:   H1_Framer,   // when kind == H1
    h2:   H2_Engine,   // when kind == H2 — cherry-picked engine, proactr types
}

// Engine port boundary (maintenance):
//   Steal: frame layouts, h2spec vectors, flow math, HPACK algorithms
//   Own:   types under Stream_Slot / Connection; ONE owner in this tree
//   Do not: forever dual-maint a vapor package import of server/
```

### A.5 Layer ownership table

| Layer | Owns | Must not know |
|-------|------|---------------|
| Handler / middleware | Intent only | SSL, SQE, frame_id, caps branching for correctness |
| Stream_Slot | Response, Session, plan_cursor, body_off, stream_window | Ring, Provider |
| Framer | Parse/encode, conn flow window, HPACK | submit_send, BIO |
| Cipher (`Cipher_State`) | SSL, PT→CT windows, handshake SM | HTTP semantics |
| Wire_Conn | Socket send CQE, seal queue fairness | Handler heap |
| Ring | Completions | HTTP |

**Session-never-knows-workers:** held. Slot never arms I/O; pipe arms from CQE only.

---

## B. Public handler surface (r3)

### B.1 Unary — one vocabulary

```odin
body_static / body_bytes / body_file   // Response_Cmd
body_set*                               // thin wrappers → cmds
respond(res)
```

Large immortal/file bodies: still those cmds. **Host windows produce** (read file / slice view ≤ `PULL_WINDOW`) as private deferred source state on the **slot** after respond — not a second public API. **No third public intent rail.**

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

### B.2 Long-lived — one vocabulary

```odin
sse_start(res, on_event, hooks) -> Session  // Session.id = slot.gen
// on_event → Effects; hangup always .Client_Gone (RST, TCP drop, TLS alert → same)
// backpressure → .Writable (buffer high-water OR H2 window reopen)
```

**No** `Stream_Reset` event. Codes → metrics/logs only.  
**No** `io.Stream` SSE path in freeze (port demos to Effects).  
**SSE-on-H2:** same API when authoring; **product readiness** is Phase 6 / M6 (capability matrix) — not a second handler API and not Phase 5 curl green.

### B.3 Thin Plan_Context (public)

Exactly the **four fields** in Part I — no second, fatter definition here.

**Private host snapshot** (planner/executor only):

```odin
Host_Plan_Snap :: struct {
    caps:              Conn_Caps,
    max_plain_write:   u32,  // default PULL_WINDOW; batch target may pack N records
    tls_record_batch:  u32,
    stream_window:     i64,  // advisory at plan compile; LIVE re-read on each unit
    conn_window:       i64,
    pt_high_water:     u32,
    ct_high_water:     u32,
    output_ring_free:  u32,
    sqe_budget:        u16,
}
```

### B.4 Conn_Caps truth table (planner fill — once)

| Condition | Sendfile_Possible | Zero_Copy_Send | Ciphered | Multiplex |
|-----------|-------------------|----------------|----------|-----------|
| Clear H1, OS ok | maybe true | maybe true | false | false |
| TLS H1 | **false** | **false** | true | false |
| TLS H2 | **false** | **false** | true | true |
| H2 framing (any) | **false** | false | — | true |

`sendfile_ok` public field = `Sendfile_Possible in caps` after host clears impossibilities. **Never** true under TLS or H2 framing in v1. No “kTLS later” implied as current ZC.

---

## C. One outbound law (write pipeline)

### C.1 Single scheduler contract (non-optional)

```
                    ┌─────────────────────┐
  slot sources  ──► │  produce ≤ WINDOW   │  (view/file/cmd bytes / effect frames)
                    │  into PT slot ring  │  stop if pt_len ≥ PT_HIGH_WATER
                    └──────────┬──────────┘
                               │ framed PT unit (H1 bytes or H2 DATA/HEADERS already encoded)
                               ▼
                    ┌─────────────────────┐
                    │  seal queue (fair)  │  RR/deficit over slots ready to seal
                    └──────────┬──────────┘
                               │
              ┌────────────────┼────────────────┐
              ▼                ▼                ▼
         clear path      Cipher_State      (same wire_conn)
         submit_send     PT window →      ≤1 socket send CQE
                         CT slots[2]      
                         seal_inflight∈{0,1,2}
```

**Law O1 — Only the pipe submits sends.**  
`Wire_Conn_State` / clear executor / `Cipher_State` post-encrypt path. Framer **never** calls `submit_send`. Mux/engine only appends framed PT into `pt` ring under high-water.

**Law O2 — No fuse optionality.**  
One implementation path: produce unit → (optional cipher seal into CT slot) → `wire_conn` queue → one `submit_send`. Not “sometimes fused ad-hoc in adapter, sometimes Exec_Op laundry list.” Private steps may be inlined; **semantics and tests are one path.**

**Law O3 — PT ring ownership.**  
`Connection.pt` is the only framed plaintext staging for the pipe. Fixed window slots from conn/worker pool. **High-water pauses slot pumps** (not only CT high-water). Bound: `pt_slots * PULL_WINDOW`, not O(sum of bodies).

**Law O4 — Live windows.**  
`Host_Plan_Snap.stream_window` / `conn_window` at respond are **advisory**. Executor/framer re-reads live slot/conn windows **every** seal unit. Park = slot `Waiting_Flow`; resume does not use stale plan tokens. On RST/GOAWAY: **abort plan_cursor**, free deferred, no resume into freed buffers.

**Law O5 — Seal-while-send SM (inflight real)**

```odin
Seal_SM :: enum u8 { Idle, Sealing, Seal_And_Send, Wait_Sock, Wait_Flow }

// CT slots: 2 fixed
// seal_inflight counts CT buffers with encrypt done or in progress awaiting send recycle
// sock_send_inflight ∈ {0,1}

// Transitions (normative):
//  Idle + pt ready + below CT HW     → encrypt into free CT slot → Sealing
//  Sealing + encrypt done + sock free → submit_send(CT) → Seal_And_Send (or Wait_Sock if sock busy)
//  Encrypt may start on free CT while other CT is in sock send  → seal_inflight up to 2
//  Send CQE → recycle CT → pull/produce next → ...
//  Flow 0 on H2 → Wait_Flow; recv stays armed
```

**`send_inflight: bool` alone is forbidden** in the freeze types. Use counts + SM.

### C.2 Cipher_State (mem-BIO, CQE-driven)

```odin
Cipher_State :: struct {
    provider:  rawptr,            // private Provider*
    ssl:       rawptr,
    state:     enum u8 { Handshake, Open, Closing, Closed },
    // Fixed windows — never multi‑MiB dynamic out
    pt_win:    [PULL_WINDOW_DEFAULT]u8, // encrypt input view may alias pt ring
    ct:        [2]struct { buf: []u8, len: int, sealed: bool },
    seal_i:    u8,
    seal_n:    u8,                // 0..2
    sock_send: bool,              // 0..1 socket CT send
    // RX
    rx_buf:    []u8,              // owned until recv CQE free
    recv_in:   bool,
    rx_hold:   [BIO_RX_HOLD_MAX]u8, // FIXED cap remainder for short bio_write_net
    rx_hold_n: int,               // if full and still short → protocol error / close (no grow)
    // Policy
    want_recv: bool,
    want_send: bool,
}
```

**Drive (only from CQE paths):**

```
recv CQE → bio_write_net (hold capped) → SSL_accept | SSL_read burst
         → plaintext → framer.feed_pt → slot dispatch / WINDOW_UPDATE
         → arm_next
send CQE → recycle CT → seal more if pt ready → arm_next
progress → burst SSL_read until WANT_* or BURST cap (H2 rBIO lesson)
```

**Handshake:** same loop; on success private ALPN → set caps + framer kind; offer only protocols you serve (Phase TLS-H1: ALPN http/1.1 only; Phase H2: add h2). **No lie at handshake.**

### C.3 Private mechanism vocabulary (compressed)

Public contract is windows/high-water/inflight — not an Exec_Op museum.

| Role | Meaning |
|------|---------|
| **Produce** | next ≤WINDOW from slot deferred/cmd/effect into PT |
| **Seal** | frame (if not preframed) + optional cipher into CT / clear view |
| **Submit** | one socket send |
| **Wait_Flow** | park slot; live windows; recv armed |
| **Flush unit** | `min(app intent, max_plain, max_frame, live windows)` — one definition |

Existing `Write_Slice` / `Writev` / `Sendfile` / `Copy_Into` remain for **clear H1**. Under `Ciphered` or `Multiplex`, sendfile path is dead; produce→seal→submit applies.

### C.4 Map vapor Write_Pipe → r2

| vapor | r2 |
|-------|-----|
| `session.out` firehose | forbidden; fixed `pt` ring |
| `body_view` + off | `Slot_Deferred` + `body_off` |
| `cout`/`sending` | `Cipher_State.ct[2]` + seal SM |
| `out_off` | seal cursor into CT/pt |
| live SSE write | Effects → produce framed PT into pt under HW |
| one `body_sid` forever | **not frozen**; concurrent deferred required before H2 perf claims |

---

## D. Multiplex & fairness

### D.1 Product meaning of H2

H2 is not “H1 framing with ALPN.” Before any **author-facing “supports HTTP/2”** or **H2 performance** claim:

| Gate | Requirement |
|------|-------------|
| **M1** | Concurrent unary: ≥2 slots sealed fairly on one conn |
| **M2** | Concurrent deferred large bodies: ≥2 (or Server_Opts documents HOL with default ≥2 in perf configs) |
| **M3** | Fair seal schedule: deficit/RR over slots ready to produce/seal |
| **M4** | Duplex law + rBIO burst under multi-stream load (h2load-class) |
| **M5** | Peak PT/CT memory O(windows × slots_armed), not O(sum bodies) |
| **M6** | **SSE/Effects on H2 slots:** ≥2 concurrent long-lived sessions on one conn; same `sse_start` callbacks as H1; `.Client_Gone` on RST |

v0 **may** ship single-dispatch unary for first green **only** as a labeled **engineering** milestone (`H2_UNARY_SERIAL=1` internal) — **never** README “supports HTTP/2,” never App Contract ✅ for H2 multiplex/SSE.  
**Author-facing “H2 ready”** = M1–M6 + capability matrix TLS H2 column all ✅ (except WS).

### D.2 Wire_Conn fairness

```odin
Wire_Conn_State :: struct {
    sock_send_inflight: bool,     // ≤1
    queue:              [/*small*/]Seal_Unit, // ready CT or clear views
    rr:                 int,      // fairness cursor over slots
}

Seal_Unit :: struct {
    slot_gen: Slot_Gen,
    view:     []u8,               // CT or clear; stable until CQE
    is_ct:    bool,
}
```

Partial send stays conn-local. Slot teardown removes pending units for that gen.

### D.3 Dispatch

Sync handlers, same worker, interleaving between CQEs — not threads. Concurrent slots = concurrent **state**, one handler at a time per slot (re-entrant only after return).

---

## E. Effect sessions

### E.1 Unified events

| Event | Meaning |
|-------|---------|
| Start | after attach |
| Timer | effect_arm |
| External | mailbox |
| **Client_Gone** | TCP drop, TLS alert, H2 RST, GOAWAY-affecting stream — **one event** |
| Idle_Timeout | idle watchdog |
| Writable | PT/CT high-water drained **or** H2 window reopened |

### E.2 Apply path (no Session_Wire vtable)

Private host switch on `framer.kind` + slot:

```odin
session_apply_write :: proc(conn: ^Connection, slot: ^Stream_Slot, p: []u8) -> bool {
    // H1: chunked TE into pt / stream path
    // H2: DATA frames into pt under flow + HW
}
```

Two lines of framing selection — **not** a product `Session_Wire` struct of function pointers unless a third backend exists (H3 refused now).

### E.3 Attachment

`sse_start` attaches to **active slot** (the exchange). Public Session carries **gen**. Never “attach to stream id” in docs.

### E.4 Phase honesty for sessions (app-visible)

| Transport | SSE ready when |
|-----------|----------------|
| Clear H1 | Existing / Phase 1 |
| TLS H1 | Phase 3 exit (cipher + slot stream path) |
| TLS H2 | **Phase 6 exit (M6)** — not Phase 5 unary curl green |

Until Phase 6, authors use SSE on H1(/TLS); the **source stays identical** so flipping listen to H2 later needs no rewrite. Do not ship a separate “H2 session package.”

---

## F. TLS path strategy

| Mode | Role |
|------|------|
| **Completion + mem-BIO** | **Only product TLS path** |
| poll demux | non-goal |
| thread-per-conn | **forbidden** |
| kqueue/IOCP | proactr backends; cipher still mem-BIO on completed reads |
| soft_cq synthetic complete | tests only |

Clear H1: `cipher == nil`; same slot + wire_conn path.

h2c: non-goal v1.

---

## G. Phased implementation (structure first)

### Phase 0 — Ergonomics freeze (E0.1–E0.8)

- `APP_CONTRACT.md`, `MIDDLEWARE_CONTRACT.md`, capability matrix.  
- CI same-handler sample (clear H1).  
- Plan policy table tests; ban Host_Pull / http/debug / sid in examples.  
- **Exit:** E0.* green; no crypto required.

### Phase 1 — Stream_Slot façade (N=1) on clear H1

- Move Response/Session/plan/wire cursor into `slots[0]`.  
- Gen on Session; dual-write of old `Connection.loop` fields **forbidden** at exit.  
- Response binds slot; clear-H1 SSE on slot.  
- **Exit:** clear H1 suite green; capability matrix Clear H1 ✅; structure admits N slots.

### Phase 2 — Private write windows on clear bulk

- PT window produce for large Static/File (64 KiB); metrics.  
- **Exit:** m1/m4 peak staging O(window).

### Phase 3 — Cipher_State + TLS H1

- Provider under cipher module; mem-BIO; handshake SM; ALPN http/1.1 only.  
- Caps fill; sendfile false; seal SM with CT[2].  
- SSE on TLS H1 (same Effects API).  
- CI: same handler sample under TLS H1.  
- **Exit:** HTTPS empty/json + SSE; bulk O(window); capability matrix TLS H1 ✅.

### Phase 4 — H2 engine (sans host) cherry-pick

- Port frame/HPACK/flow **into proactr types** (not forever-vendored vapor server).  
- Vectors + h2spec offline.  
- **Exit:** unit green; OWNERS: one tree.

### Phase 5 — TLS H2 unary (**engineering milestone only**)

- ALPN h2; multi-slot slab; optional serial dispatch flag.  
- **Exit:** curl --http2; h2spec core.  
- **Forbidden:** README “supports HTTP/2”; App Contract H2 multiplex/SSE ✅; H2 perf claims.

### Phase 6 — H2 **product** bar (M1–M6)

- Concurrent unary + concurrent deferred + fairness + duplex evidence.  
- **Effects/SSE on H2 multi-slot (M6)** — same callbacks as H1; Client_Gone on RST.  
- CI: same handler sample under TLS H2.  
- **Exit:** capability matrix TLS H2 ✅ (except WS); “supports HTTP/2” + H2 perf language allowed; ratios recorded.

### Phase 7 — Soft admission + session soak

- Soft 503 admission (replace assert under load).  
- Soak long-lived H1/H2; mailbox/wake polish.  
- **Exit:** load-test footgun closed; no io.Stream dual.

### Phase 8 — Multi-worker TLS + production checklist

- Shared SSL_CTX policy; multi-worker REUSEPORT; soak.  
- WS remains H1(/TLS) until a **named later** phase (matrix ⏳).

### Steal vs own

| Steal (facts) | Own (types) |
|---------------|-------------|
| Window numbers, duplex law, membio shape | Stream_Slot, Wire_Conn, seal SM |
| Frame layouts, h2spec vectors, HPACK math | Framer integration, plan cursor |
| Provider method set (BoringSSL mem-BIO) | Single cipher module under Connection |
| Anti-firehose autopsy | One outbound path tests |

**Not a dual-maint vapor package fork.** Cherry-pick commits/vectors; rewrite engine storage to slots. If upstream vapor fixes flow bugs, port as patches to **our** engine.

---

## H. Non-goals & anti-patterns

### Non-goals

H3/QUIC · h2c · demux TLS mode · thread TLS · kTLS/SendZc default · H2 push/priority · async handler pools · io.Stream SSE · public stream-id API · body_set_pull public rail · Conn_Proto as app/host architecture enum · 0-RTT/tickets (later track) · forever vapor `server` import

### Anti-patterns (reject PR)

1. Handler/middleware imports Provider or branches on stream id.  
2. Second submit_send path outside wire_conn.  
3. `send_inflight: bool` without seal SM / CT[2] under TLS bulk.  
4. Growable `pt` or `rx_hold` past fixed caps.  
5. Holding H2 recv solely because send/CT inflight or flow 0.  
6. `Response._sid` or public Message_Proto required for correctness.  
7. Dual-write Connection.loop **and** slot after Phase 1.  
8. H2 perf claims before Phase 6 gates.  
9. Plan-time frozen windows as sole flow authority.  
10. Optional “fuse encrypt in adapter differently than tests.”  
11. `Stream_Reset` app event.  
12. Experimental io.Stream SSE “for demos.”  
13. README “supports HTTP/2” before M1–M6.  
14. `examples/` importing `http/debug` or registering Host_Pull.  
15. Marketing SSE-on-H2 before Phase 6 while claiming full invariant without ⏳.

---

## I. Key Decisions (r3)

| ID | Decision |
|----|----------|
| **D1** | Single `Stream_Slot` ownership; H1 = N=1 |
| **D2** | One outbound submit path; no fuse optionality |
| **D3** | Mem-BIO completion TLS only |
| **D4** | Effects only long-lived; unified Client_Gone |
| **D5** | Public Plan_Context = exactly four fields; fat snap private |
| **D6** | Conn_Caps orthogonal; no Conn_Proto product worlds |
| **D7** | Seal SM + CT[2]; inflight ∈ {0,1,2} real |
| **D8** | Live flow re-read; plan_cursor slot-owned; abort on RST |
| **D9** | Duplex recv law + SSL_read burst |
| **D10** | Phase 0–1 structure before TLS green |
| **D11** | Multiplex **M1–M6** (incl. SSE-on-H2) before author “supports H2” / perf claims |
| **D12** | Cherry-pick engine facts; one owned engine |
| **D13** | Gen-stable Session/slot handles |
| **D14** | Unary intent = commands only; deferred produce is host-private; **no app Host_Pull** |
| **D15** | Provider private under cipher module |
| **D16** | Author capability matrix is part of freeze; Phase 5 ≠ H2 product |
| **D17** | Public Plan_Context stays exactly four fields |
| **D18** | Phase 0 E0.* is ergonomics merge gate (docs + CI + example bans) |

---

## J. Open Questions (narrowed)

1. Slot storage default: fixed slab per conn vs worker freelist with gen? (**Recommend:** worker freelist + gen; H1 embeds one slot inline to avoid alloc.)  
2. Shared SSL_CTX across REUSEPORT workers — refcount vs clone? (**Recommend:** shared, free on last worker — vapor pattern.)  
3. HPACK dyn table allocator — conn_allocator vs per-slot? (**Recommend:** conn_allocator; free_all discipline per request arena for encode scratch.)  
4. Fairness weights: equal RR vs prefer interactive (SSE) over bulk? (**Recommend:** equal RR v1; document.)  
5. Request body full-buffer on H2 v0? (**Recommend:** yes like vapor; stream later.)

---

## K. PR Plan

| PR | Content | Gate |
|----|---------|------|
| **PR0** | APP_CONTRACT + MIDDLEWARE + capability matrix + CI sample + plan tables + example ban list | E0.1–E0.8 |
| **PR1** | Stream_Slot N=1 façade; gen Session; kill dual-write | clear H1 suite + SSE |
| **PR2** | PT window produce clear bulk | m1/m4 O(window) |
| **PR3** | Cipher_State TLS H1 + SSE + seal SM | HTTPS + CI sample TLS |
| **PR4** | H2 engine cherry-pick unit | vectors |
| **PR5** | H2 unary engineering milestone | curl/h2spec; **no** README H2 |
| **PR6** | M1–M6 multiplex + SSE-on-H2 + CI H2 sample | product H2 + ratios |
| **PR7** | soft 503 + session soak | load-test gate |
| **PR8** | multi-worker + production checklist | checklist |

---

## L. Close state machine (free order)

Normative free order — implementers must not invent:

```
Triggers: handshake fail | TLS alert | GOAWAY | RST_STREAM | TCP EOF | CT send error | idle | server stop

On stream RST / stream GOAWAY-affected:
  1. slot.gen bump intent (mark dying)
  2. abort plan_cursor; drop Slot_Deferred
  3. session → Client_Gone effects once; on_close after wire quiet
  4. remove Seal_Units for slot.gen from wire_conn queue (if not mid-socket-send)
  5. if socket send view owned by this slot → wait CQE then recycle
  6. free slot storage; gen++

On conn-level death (TLS alert, GOAWAY all, TCP EOF, handshake fail):
  1. cipher.state = Closing
  2. for each live slot: stream death path above
  3. fail/cancel inflight recv; wait sock send CQE if any
  4. SSL_shutdown best-effort (no block); free SSL
  5. free pt ring slots, ct slots, rx_hold clear
  6. close fd; Connection slab recycle

Invariant: never free CT/PT buffer still referenced by outstanding send CQE.
Invariant: never resume Waiting_Flow into freed plan buffers (gen check).
```

---

## Type sketch (collect)

```odin
// Caps — orthogonal
Conn_Cap :: enum u8 { Ciphered, Multiplex, Sendfile_Possible, Zero_Copy_Send }
Conn_Caps :: bit_set[Conn_Cap; u8]

// Public thin constraints
Plan_Context :: struct {
    sendfile_ok:           bool,
    preferred_copy_budget: u32,
    max_write_unit:        u32,
    zero_copy_send:        bool,
}

// Ownership
Stream_Slot :: struct { gen: Slot_Gen, frame_id: u32, /* req, res, session, plan_cursor, ... */ }
Connection  :: struct { caps: Conn_Caps, slots: /*slab*/, framer: Framer_State, cipher: ^Cipher_State, wire_conn: Wire_Conn_State, pt: Pt_Window_Ring }

// Cipher seal
Cipher_State :: struct { /* Handshake|Open|Closing, ct[2], seal_n, sock_send, rx_hold fixed */ }

// Private host snap + deferred
Host_Plan_Snap :: struct { /* caps, windows live-reread, high-waters */ }
Slot_Deferred  :: struct { /* View | File_Window | Host_Pull — not public API */ }
```

---

## Round-2→3 critic response (ergonomics)

R2 scores elsewhere WOW’d (≥9); ergonomics **8.6** — residual only. r3 surgical fixes:

| R2 ergonomics issue | r3 fix |
|---------------------|--------|
| SSE/long-lived on H2 Phase 7 — late vs invariant | **M6 + Phase 6 product bar**; capability matrix ⏳ until then; same API, honest listen readiness |
| Phase 0 docs/CI soft | **E0.1–E0.8 hard freeze gate**; same-handler CI sample; ban Host_Pull / http/debug / sid in examples |
| Narrative teaches implementers first | **PART I app surface first**; PART II physics; authors stop after matrix |
| Host_Pull social dual | **NEVER in App Contract**; E0.6; “no third public intent rail” wording |
| Multiplex easy to market away | README honesty rules + Phase 5 **forbidden** product language |
| Progressive `stream_*` silence | App Contract: not second long-lived product; Effects for SSE/WS |
| Soft 503 late footgun | Temporary host behavior called out in App Contract; Phase 7 soft 503 |
| Keep thin Plan_Context | **Still exactly four fields** (B’s R2 win) |

**Not reopened:** Stream_Slot, Seal_SM, O1–O5, mem-BIO, vapor lessons, gen ABA, no fuse, free-order close.

---

## Round-1 critic response

How r2 answers each fatal/major cluster.

### Code quality

| R1 issue | r2 fix |
|----------|--------|
| Dual Loop vs H2_Stream_Slot | **Single `Stream_Slot`; H1 = N=1** |
| Three outbound owners + fuse optionality | **Law O1–O2: only wire_conn/cipher submit; one path** |
| Weak Session ABA | **gen on slot; lookup checks gen; CQE abort on mismatch** |
| TLS before structure | **Phase 0–1 slot façade + plan tables before TLS** |
| `Response._sid` | **Removed; frame_id private on slot** |
| `rx_hold` growable | **Fixed `BIO_RX_HOLD_MAX`; overflow → close** |
| Forever vapor fork | **Cherry-pick facts; one owned engine** |
| Close free order | **§L state machine** |

### Ergonomics

| R1 issue | r2 fix |
|----------|--------|
| No App Contract page | **§ App Contract frozen ≤1 page** |
| Dual hangup / Stream_Reset | **Only `.Client_Gone`** |
| body_set_pull second rail | **Host-private deferred only; unary = cmds** |
| io.Stream dual | **Refused in freeze** |
| Fat Plan_Context | **Thin public; private Host_Plan_Snap** |
| Middleware soft | **Hard may/must-not table** |
| Conn_Proto app leak | **Caps private fill; no product enum** |

### Performance

| R1 issue | r2 fix |
|----------|--------|
| `sending: bool` vs CT[2] | **Seal SM + seal_n ∈ {0,1,2}** |
| Serial H2 as product | **M1–M5 gates before perf claims** |
| Soft out_pt bound | **Fixed pt ring + PT high-water pauses pumps** |
| Live vs snapshot flow | **Law O4 live re-read** |
| Fairness deferred forever | **Wire_Conn RR + Phase 6 exit** |
| Smoke ≠ bulk | **Evidence exits on bulk phases** |

### Semantic compression

| R1 issue | r2 fix |
|----------|--------|
| Parallel H1/H2 worlds | **One slot type** |
| Intent tri-rail | **cmds \| effects only** |
| Conn_Proto product | **Orthogonal Conn_Caps** |
| Session_Wire vtable | **Private switch; no product plug-in type** |
| Body_Source taxonomy | **Not a public type** |
| Evidence as spine | **Lessons in §0; types lead the freeze** |

### Handmade / craft

| R1 issue | r2 fix |
|----------|--------|
| Dual-maint strategy | **One owner engine; steal facts not packages** |
| Interface soup | **Provider under cipher only; no Session_Wire product** |
| Ported not carved | **Slot/Pipe thesis first; vapor is physics footnotes** |
| Window numbers missing from POD | **§L5 constants + Cipher_State / pt ring** |

### What we kept from B’s strengths (all critics)

Mem-BIO-only product path · window numbers · high-water · Provider private IOC · duplex H2 recv law · SSL_read burst · demux not product · pull-window write contract · sans-I/O framer · vapor lessons with file anchors · anti-firehose · CQE arm-next · Effects over live flush.

### What we absorbed from A (via critics)

Stream_Slot ontology · wire conn vs slot progress · Conn_Caps truth · gen Session · phase structure-before-crypto · middleware purity · Client_Gone / Writable unification · thin public constraints · plan policy table tests.

---

## Closing

r1 was a dual-world vapor field manual. r2 fixed ontology and physics. **r3 makes the app story honest in time:** authors get a front-matter contract, a capability matrix with ⏳/✅, and H2 product meaning that includes SSE-on-slots — without diluting single-slot law, seal SM, or mem-BIO private physics. Handlers stay ignorant; examples stay dual-free; README cannot lie about H2.
