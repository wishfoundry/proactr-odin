// Effect-based Sessions (D0–D2): host-driven events → Effects → wire/timer/end.
// SSE codec in session_sse.odin; WS in session_ws.odin (D3).
// Progressive Stream wire is D0 (response/wire).
// PR9 M6: SSE/Effects on H2 multi-slot — same App Contract; H1 chunked or H2 DATA.
package http

import "base:runtime"

import "core:log"
import "core:mem"
import "core:mem/virtual"
import "core:sync"
import "core:time"

import http2 "../http2"
import proactr "../proactr"

// ---------------------------------------------------------------------------
// D2 metrics (atomics; sum at scrape)
// ---------------------------------------------------------------------------

session_metrics_started:               u64
session_metrics_ended:                 u64
session_metrics_aborted:               u64
session_metrics_client_gone:           u64
session_metrics_backpressure:          u64
session_metrics_mailbox_drops:         u64
session_metrics_pool_reject:           u64
session_metrics_admission_reject:      u64 // session cap soft-503 (sse_start / ws_start)
session_metrics_stream_bytes_admitted: i64 // gauge-ish (worker sum via atomics)
session_metrics_live:                  i64 // gauge-ish

// Defaults when Server_Opts fields are 0.
SESSION_MAX_PER_WORKER_DEFAULT :: 4096
SESSION_MAX_STREAM_BUFFER_DEFAULT :: 64 * 1024
SESSION_IDLE_TIMEOUT_MS_DEFAULT :: 60_000
SESSION_MAILBOX_DEPTH_DEFAULT :: 256

// ---------------------------------------------------------------------------
// Public alloc / hooks
// ---------------------------------------------------------------------------

// Permanent connection allocator (not request temp). Prefer for session nested state.
conn_allocator :: proc(res: ^Response) -> runtime.Allocator {
	assert(res != nil && res._conn != nil && res._conn.server != nil)
	return res._conn.server.conn_allocator
}

// Host pad from conn_allocator; zeroed. Freed AFTER hooks.on_close (not by app).
// Call before sse_start; pad is linked on the exchange Stream_Slot until session destroy.
sse_alloc :: proc(res: ^Response, size: int, loc := #caller_location) -> rawptr {
	assert(res != nil && res._conn != nil, "sse_alloc: nil response/conn", loc)
	assert(size > 0, "sse_alloc: size must be > 0", loc)
	conn := res._conn
	assert(conn.server != nil, "sse_alloc: no server", loc)
	ex := response_slot(res)
	assert(ex != nil, "sse_alloc: no exchange slot", loc)
	// One pad per exchange attach cycle.
	assert(ex.session_pad == nil, "sse_alloc: pad already allocated", loc)
	p, err := mem.alloc_bytes(size, alignment = max(8, align_of(rawptr)), allocator = conn.server.conn_allocator)
	assert(err == .None && p != nil, "sse_alloc: out of memory", loc)
	mem.zero(raw_data(p), size)
	ex.session_pad = raw_data(p)
	ex.session_pad_size = size
	return ex.session_pad
}

Session_Hooks :: struct {
	user:     rawptr, // single user for on_event + on_close
	on_close: proc(user: rawptr), // optional; free nested only, not pad
}

// Lightweight public handle (safe to copy). Host-owned; no stream id.
// H1: _slot = &conn.slot. H2: _slot = &h2_slots[i] (exchange multi-slot).
Session :: struct {
	_conn: ^Connection,
	_slot: ^Stream_Slot,
	id:    u32,
}

// Resolve exchange slot for a live Session_State (H1 embed or H2 multi-slot).
@(private)
_session_ex :: proc(st: ^Session_State) -> ^Stream_Slot {
	if st == nil {
		return nil
	}
	if st.public._slot != nil {
		return st.public._slot
	}
	if st.public._conn != nil {
		return &st.public._conn.slot
	}
	return nil
}

// Lookup Session_State from a public handle (gen check at call sites).
@(private)
_session_lookup :: proc(s: Session) -> ^Session_State {
	if s._slot != nil && s._slot.session != nil {
		return s._slot.session
	}
	if s._conn != nil && s._conn.slot.session != nil {
		return s._conn.slot.session
	}
	return nil
}

Session_Event_Kind :: enum u8 {
	Start,         // after heading committed / first attach drive
	Timer,         // heartbeat / user arm
	External,      // session_post_external drained on owning worker
	Client_Gone,   // peer hangup / RST / stream send error
	Idle_Timeout,  // idle watchdog (no effect_arm for stream_idle_timeout_ms)
	Writable,      // after backpressure drop when wire becomes free again
}

Session_Event :: struct {
	kind:  Session_Event_Kind,
	timer: u32,
	ext:   rawptr,
}

Session_On_Event :: #type proc(sess: ^Session, ev: Session_Event, user: rawptr) -> Effects

// ---------------------------------------------------------------------------
// Effects
// ---------------------------------------------------------------------------

EFFECTS_MAX :: 8

Effect_Kind :: enum u8 {
	None,
	Sse_Data,
	Sse_Event,
	Sse_Comment,
	// D3 WebSocket
	Ws_Text,
	Ws_Binary,
	Ws_Close,
	Arm,
	End,
	Abort,
}

Effect :: struct {
	kind:     Effect_Kind,
	data:     string,
	name:     string,
	delay_ns: i64,
	// Ws_Close optional code (0 = default 1000).
	ws_code:  u16,
}

Effects :: struct {
	items: [EFFECTS_MAX]Effect,
	n:     u8,
}

effect_sse_data :: proc(data: string) -> Effect {
	return Effect{kind = .Sse_Data, data = data}
}

effect_sse_event :: proc(name, data: string) -> Effect {
	return Effect{kind = .Sse_Event, name = name, data = data}
}

effect_sse_comment :: proc(comment: string = "") -> Effect {
	return Effect{kind = .Sse_Comment, data = comment}
}

// Single timer slot per session; replaces any prior arm.
effect_arm :: proc(delay: time.Duration) -> Effect {
	return Effect{kind = .Arm, delay_ns = i64(delay)}
}

effect_end :: proc() -> Effect {
	return Effect{kind = .End}
}

effect_abort :: proc() -> Effect {
	return Effect{kind = .Abort}
}

effects_empty :: proc() -> Effects {
	return {}
}

effects_of :: proc(effs: ..Effect, loc := #caller_location) -> Effects {
	assert(len(effs) <= EFFECTS_MAX, "effects_of: overflow EFFECTS_MAX", loc)
	out: Effects
	out.n = u8(len(effs))
	for i in 0 ..< len(effs) {
		out.items[i] = effs[i]
	}
	return out
}

// ---------------------------------------------------------------------------
// Host Session_State (conn_allocator)
// ---------------------------------------------------------------------------

Session_Proto :: enum u8 {
	Sse,
	Ws,
}

// Timer purpose for the single software timer slot.
Session_Timer_Kind :: enum u8 {
	None,
	Heartbeat, // effect_arm → deliver .Timer
	Idle,      // idle watchdog → deliver .Idle_Timeout then force abort
}

// Internal session bag on Stream_Slot.session. Not part of the public API.
// After closed=true, the struct may still be reachable from a soft_cq Timeout
// until timer_pending_cqes hits 0 (then freed). Never free while timer CQEs live.
Session_State :: struct {
	on_event:  Session_On_Event,
	hooks:     Session_Hooks,
	proto:     Session_Proto,
	// Attach snapshot of slot.gen / Session.id (immutable after attach).
	// slot.gen is the sole ABA owner; destroy bumps slot.gen, not this field.
	gen:       u32,
	// Single software timer slot (proactr submit_timeout).
	timer_op:  u32,
	timer_gen: u32,
	timer_kind: Session_Timer_Kind,
	// Count of Timeout CQEs still expected. Free only when 0 after closed.
	timer_pending_cqes: i32,
	idle_ns:   i64,
	public:    Session,
	ending:    bool,
	closed:    bool,
	started:   bool,
	// App asked for Writable-style refill (backpressure drop this cycle).
	want_writable: bool,
	// Allocator used for this Session_State (for deferred free after timer CQEs).
	allocator: runtime.Allocator,
}

// ---------------------------------------------------------------------------
// sse_start
// ---------------------------------------------------------------------------

/*
Start a long-lived SSE session on this response.

Defaults if unset: Content-Type text/event-stream, Cache-Control: no-cache.
H1: Transfer-Encoding chunked, drop Content-Length (via begin_stream).
H2: HEADERS (:status + CT/cache-control, no TE/CL) without END_STREAM; body is DATA.
Asserts on attach conflicts (already sent, cmds, second session on this exchange).

Soft admission: if live sessions are at max_sessions_per_worker × thread_count,
sends 503 Service Unavailable (no panic), increments session_metrics_admission_reject,
and returns Session{} (id=0). Callers should check session_status or id != 0.

Drives Session_Event_Kind.Start immediately and applies returned Effects.
After return (on success), the handler must not call respond / stream_* / body_*.
*/
sse_start :: proc(
	res:      ^Response,
	on_event: Session_On_Event,
	hooks:    Session_Hooks = {},
	loc := #caller_location,
) -> Session {
	assert(res != nil && res._conn != nil, "sse_start: nil response", loc)
	assert(on_event != nil, "sse_start: nil on_event", loc)
	assert(!res.sent, "sse_start: response already sent", loc)
	assert(!res._session_attached, "sse_start: session already attached", loc)
	assert(!res._streaming, "sse_start: stream already started", loc)
	assert(res._cmd_count == 0, "sse_start: body cmds already set", loc)
	assert(res._body_off == 0, "sse_start: body_reserve in progress", loc)
	conn := res._conn
	assert(conn.server != nil, "sse_start: no server", loc)
	ex := response_slot(res)
	assert(ex != nil, "sse_start: no exchange slot", loc)
	assert(ex.session == nil, "sse_start: exchange already has session", loc)

	// Soft admission: max sessions per worker (0 opts → default). Over cap → 503, not assert.
	if !_session_admission_ok(conn) {
		return _session_soft_reject(res, loc)
	}

	// Defaults when handler left headers unset.
	if !headers_has_unsafe(res.headers, "content-type") {
		headers_set_content_type(&res.headers, "text/event-stream")
	}
	if !headers_has_unsafe(res.headers, "cache-control") {
		headers_set_unsafe(&res.headers, "cache-control", "no-cache")
	}

	if conn.h2_active {
		// H2: no chunked TE / Content-Length. HEADERS without END_STREAM.
		if headers_has_unsafe(res.headers, "transfer-encoding") {
			headers_delete_unsafe(&res.headers, "transfer-encoding")
		}
		if headers_has_unsafe(res.headers, "content-length") {
			headers_delete_unsafe(&res.headers, "content-length")
		}
		sid, sok := h2_host_sid_for_slot(conn, ex)
		assert(sok && sid != 0, "sse_start: H2 slot has no stream id", loc)
		// PR10: mark stream interactive so RR flush prefers SSE over bulk oneshots.
		http2.conn_stream_set_interactive(&conn.h2, sid, true)
		// Default 200 when handler left the response_init Not_Found.
		if res.status == .Not_Found {
			res.status = .OK
		}
		hdrs: [dynamic]http2.Header
		hdrs.allocator = context.temp_allocator
		h2_response_headers_from(res, &hdrs)
		http2.conn_send_headers(&conn.h2, &conn.h2_out, sid, hdrs[:], false /* end_stream */)
		h2_host_flush_out(conn)
		res._heading_written = true
		res._streaming = true
		res._stream_ended = false
		// Mark sent so H2 dispatch does not inject a 500; session owns the stream.
		res.sent = true
		ex.stream_open = true
	} else {
		// H1: heading freeze + chunked TE.
		_ = response_begin_stream(res, loc)
	}

	// Session owns wire; block respond / public stream_*.
	res._session_attached = true

	// Alloc host state (conn_allocator, not request temp).
	st := new(Session_State, conn.server.conn_allocator)
	assert(st != nil, "sse_start: Session_State alloc failed", loc)
	st^ = {}
	st.allocator = conn.server.conn_allocator
	st.on_event = on_event
	st.hooks = hooks
	st.proto = .Sse
	// Monotonic per-slot gen (ABA-safe across free-list reuse); Session.id uses this.
	st.gen = stream_slot_bump_gen(ex)
	st.public = Session{_conn = conn, _slot = ex, id = st.gen}
	idle_ms := conn.server.opts.stream_idle_timeout_ms
	if idle_ms <= 0 {
		idle_ms = SESSION_IDLE_TIMEOUT_MS_DEFAULT
	}
	st.idle_ns = i64(idle_ms) * 1_000_000
	ex.session = st

	sync.atomic_add(&session_metrics_started, 1)
	sync.atomic_add(&session_metrics_live, 1)

	// Soft-shrink oversized resp_buf capacity for long-lived sessions (H1 heading in it).
	if !conn.h2_active {
		_stream_shrink_resp_for_session(conn)
	}

	// Drive Start while request temp may still be live (fmt/framing).
	_session_drive_st(st, Session_Event{kind = .Start})

	// Detach ~4.5 MiB request temp only AFTER Start apply — later drives use worker session_scratch.
	// Offline/unit without a real temp slot: skip (assert_has_td would pass with stub workers).
	if td != nil && td.state != .Uninitialized && conn.temp_slot >= 0 {
		conn_temp_detach(conn)
	}

	// D2: arm idle watchdog if no heartbeat arm already scheduled.
	// Needs a live proactr ring (ops table from ring_init). Offline unit workers skip.
	if st.timer_op == 0 && st.idle_ns > 0 && !st.closed && !st.ending &&
	   td != nil && td.state != .Uninitialized && td.ring.ops != nil {
		_session_arm_timer_st(st, st.idle_ns, .Idle)
	}

	// Ciphered Open (H1 TLS): arm CT recv so peer FIN / close_notify → Client_Gone.
	// H2 hangup is per-stream RST (h2_host_poll_session_resets). Clear-H1: idle + send errors.
	if !conn.h2_active && !st.closed && !st.ending {
		_session_arm_hangup_watch(conn)
	}

	return st.public
}

// Worker-affine external event post (D2). Any thread may call; drained on owning
// worker via session_mailbox_drain (hook from on_worker_tick or host loop).
// Returns false if mailbox full (metric session_metrics_mailbox_drops).
session_post_external :: proc(s: Session, cookie: rawptr) -> bool {
	st := _session_lookup(s)
	if st == nil || st.closed || st.public.id != s.id {
		return false
	}
	return _session_mailbox_post(st, cookie)
}

// Optional: session still live?
session_status :: proc(s: Session) -> bool {
	st := _session_lookup(s)
	return st != nil && !st.closed && st.public.id == s.id
}

// True when live sessions are under max_sessions_per_worker × thread_count.
@(private)
_session_admission_ok :: proc(conn: ^Connection) -> bool {
	if conn == nil || conn.server == nil {
		return false
	}
	max_sess := conn.server.opts.max_sessions_per_worker
	if max_sess <= 0 {
		max_sess = SESSION_MAX_PER_WORKER_DEFAULT
	}
	threads := max(1, conn.server.opts.thread_count)
	cap := i64(max_sess) * i64(threads)
	live := sync.atomic_load(&session_metrics_live)
	return live < cap
}

// Soft 503 when session cap is exceeded. Does not allocate Session_State.
// H1: respond(503) on a worker; offline unit marks sent only.
// H2: 503 HEADERS + END_STREAM on the exchange stream; no session attach.
// Returns Session{} (id=0) — caller checks session_status / id != 0.
@(private)
_session_soft_reject :: proc(res: ^Response, loc := #caller_location) -> Session {
	_ = loc
	sync.atomic_add(&session_metrics_admission_reject, 1)
	if res == nil {
		return {}
	}
	res.status = .Service_Unavailable
	if !headers_has_unsafe(res.headers, "retry-after") {
		headers_set_unsafe(&res.headers, "retry-after", "1")
	}
	conn := res._conn
	if conn != nil && conn.h2_active {
		// Drop H1-only / body framing headers; 503 is oneshot END_STREAM.
		if headers_has_unsafe(res.headers, "transfer-encoding") {
			headers_delete_unsafe(&res.headers, "transfer-encoding")
		}
		if headers_has_unsafe(res.headers, "content-length") {
			headers_delete_unsafe(&res.headers, "content-length")
		}
		ex := response_slot(res)
		sid, sok := h2_host_sid_for_slot(conn, ex)
		if !sok || sid == 0 {
			// Fallback: last dispatch sid (serial / bound respond path).
			sid = conn.h2_dispatch_sid
		}
		if sid != 0 {
			hdrs: [dynamic]http2.Header
			hdrs.allocator = context.temp_allocator
			h2_response_headers_from(res, &hdrs)
			http2.conn_send_headers(&conn.h2, &conn.h2_out, sid, hdrs[:], true /* end_stream */)
			h2_host_flush_out(conn)
		}
		res.sent = true
		res._heading_written = true
		// Free multi-slot when oneshot frames are out (offline: flush cleared h2_out).
		h2_host_maybe_finish_exchange(conn)
		return {}
	}
	// H1: full respond on a live worker; offline unit tests only set status/sent.
	if td != nil && td.state != .Uninitialized {
		respond(res)
	} else {
		res.sent = true
	}
	return {}
}

// Test helper: drive an event and return Effects without requiring sockets when
// the connection has an attached session (apply still runs if worker present).
sse_drive_for_test :: proc(sess: ^Session, ev: Session_Event) -> Effects {
	assert(sess != nil)
	st := _session_lookup(sess^)
	assert(st != nil && !st.closed)
	return _session_drive_st(st, ev)
}

// ---------------------------------------------------------------------------
// Drive + apply
// ---------------------------------------------------------------------------

// H1 convenience: drive the embed slot session (TLS hangup / wire error paths).
@(private)
_session_drive :: proc(conn: ^Connection, ev: Session_Event) -> Effects {
	if conn == nil || conn.slot.session == nil {
		return {}
	}
	return _session_drive_st(conn.slot.session, ev)
}

@(private)
_session_drive_st :: proc(st: ^Session_State, ev: Session_Event) -> Effects {
	if st == nil || st.closed || st.ending {
		// Allow Client_Gone / Idle while ending? skip if fully closed.
		if st == nil || st.closed {
			return {}
		}
		if ev.kind != .Client_Gone && ev.kind != .Idle_Timeout {
			return {}
		}
	}
	// Framing / app fmt after temp detach: bind worker session_scratch (not request temp).
	_session_bind_scratch()
	effs := st.on_event(&st.public, ev, st.hooks.user)
	if ev.kind == .Start {
		st.started = true
	}
	_session_apply_effects_st(st, effs)
	return effs
}

// Use per-worker fixed scrap for effect apply after request temp is detached.
@(private)
_session_bind_scratch :: proc() {
	if td == nil || td.state == .Uninitialized {
		return
	}
	if td.session_scratch_block == nil {
		// 64 KiB worker-local framing scrap (not the 4.5 MiB request slot).
		alloc := context.allocator
		if td.server != nil {
			alloc = td.server.conn_allocator
		}
		if alloc.procedure == nil {
			return // offline mock worker without allocator
		}
		td.session_scratch_block = make([]u8, 64 * 1024, alloc)
		_ = virtual.arena_init_buffer(&td.session_scratch, td.session_scratch_block)
	} else {
		// Rewind for this drive.
		if td.session_scratch.kind == .Buffer && td.session_scratch.curr_block != nil {
			td.session_scratch.curr_block.used = 0
			td.session_scratch.total_used = 0
		}
	}
	context.temp_allocator = virtual.arena_allocator(&td.session_scratch)
}

@(private)
_session_apply_effects :: proc(conn: ^Connection, effs: Effects) {
	if conn == nil || conn.slot.session == nil {
		return
	}
	_session_apply_effects_st(conn.slot.session, effs)
}

@(private)
_session_apply_effects_st :: proc(st: ^Session_State, effs: Effects) {
	if st == nil || st.closed {
		return
	}
	conn := st.public._conn
	ex := _session_ex(st)
	if conn == nil || ex == nil {
		return
	}
	r := &ex.res
	want_end := false
	want_abort := false
	h2 := conn.h2_active

	for i in 0 ..< int(effs.n) {
		e := effs.items[i]
		switch e.kind {
		case .None:
			// skip
		case .Sse_Data, .Sse_Event, .Sse_Comment:
			frame: [dynamic]u8
			frame.allocator = context.temp_allocator
			_sse_format_effect(&frame, e)
			if len(frame) == 0 {
				continue
			}
			// D2 soft backpressure: per-session pending unsent bytes.
			max_buf := SESSION_MAX_STREAM_BUFFER_DEFAULT
			if conn.server != nil && conn.server.opts.max_stream_buffer > 0 {
				max_buf = conn.server.opts.max_stream_buffer
			}
			if h2 {
				sid, sok := h2_host_sid_for_slot(conn, ex)
				pending_h2 := 0
				if sok {
					if s, ok := conn.h2.streams[sid]; ok {
						// Unsent only (cursor); not full buffer with dead prefix.
						pending_h2 = http2.stream_pending_len(s)
					}
				}
				if pending_h2 + len(frame) > max_buf {
					sync.atomic_add(&session_metrics_backpressure, 1)
					st.want_writable = true
					continue
				}
				if sok && sid != 0 {
					_ = http2.conn_send_body(&conn.h2, &conn.h2_out, sid, frame[:], false)
					h2_host_flush_out(conn)
				}
			} else {
				pending := len(r._buf.buf) - ex.stream_sent + len(frame) + 32 // chunk overhead
				if pending > max_buf {
					sync.atomic_add(&session_metrics_backpressure, 1)
					st.want_writable = true
					continue // drop this payload; still honor End/Abort later
				}
				_http_write_chunk(&r._buf, frame[:])
				conn.resp_buf = r._buf.buf
			}
		case .Ws_Text, .Ws_Binary, .Ws_Close:
			// WS is H1-only (ws_start asserts !h2_active).
			_ws_apply_effect(conn, e)
		case .Arm:
			_session_arm_timer_st(st, e.delay_ns, .Heartbeat)
		case .End:
			want_end = true
		case .Abort:
			want_abort = true
		}
	}

	if want_abort {
		sync.atomic_add(&session_metrics_aborted, 1)
		_session_abort_st(st)
		return
	}

	if want_end {
		_session_end_st(st)
		return
	}

	if !h2 {
		// Flush progressive stream after effects (arm Stream send if wire idle).
		if len(r._buf.buf) > ex.stream_sent {
			_stream_flush_response(r)
		}
		// Compact delivered prefix so long sessions do not retain full history in resp_buf.
		_stream_compact_delivered(conn)
	}
}

@(private)
_session_arm_timer :: proc(conn: ^Connection, delay_ns: i64, kind: Session_Timer_Kind = .Heartbeat) {
	if conn == nil || conn.slot.session == nil {
		return
	}
	_session_arm_timer_st(conn.slot.session, delay_ns, kind)
}

@(private)
_session_arm_timer_st :: proc(st: ^Session_State, delay_ns: i64, kind: Session_Timer_Kind = .Heartbeat) {
	// Offline unit (no worker / no ring_init): skip timer arm — effects still apply.
	if td == nil || td.state == .Uninitialized || td.ring.allocator.procedure == nil {
		return
	}
	assert_has_td()
	if st == nil || st.closed {
		return
	}
	// Replace: cancel prior live timer (best-effort). cancel posts TIMEOUT_CANCELED
	// for the same op already counted in timer_pending_cqes (one CQE total for that op).
	if st.timer_op != 0 {
		_ = proactr.cancel_timeout(&td.ring, st.timer_op)
		st.timer_op = 0
	}
	st.timer_gen += 1
	ns := delay_ns if delay_ns > 0 else 1
	// ±20% jitter for heartbeats (not idle) so mass re-arms do not cohere.
	if kind == .Heartbeat && ns > 1_000_000 {
		j := i64(st.timer_gen * 1103515245 + 12345)
		pct := (j % 41) - 20 // -20..+20
		ns = ns + (ns * pct) / 100
		if ns < 1 {
			ns = 1
		}
	}
	id, err := proactr.submit_timeout(&td.ring, ns, rawptr(st))
	if err != .None {
		log.errorf("session arm timer failed: %v", err)
		return
	}
	st.timer_op = id
	st.timer_kind = kind
	st.timer_pending_cqes += 1
}

@(private)
_session_end :: proc(conn: ^Connection) {
	if conn == nil || conn.slot.session == nil {
		return
	}
	_session_end_st(conn.slot.session)
}

@(private)
_session_end_st :: proc(st: ^Session_State) {
	if st == nil || st.closed {
		return
	}
	if st.ending {
		return
	}
	st.ending = true
	conn := st.public._conn
	ex := _session_ex(st)
	if conn == nil || ex == nil {
		return
	}
	r := &ex.res

	if conn.h2_active {
		// Empty DATA with END_STREAM (or flush pending end). Free session/slot after.
		sid, sok := h2_host_sid_for_slot(conn, ex)
		if sok && sid != 0 {
			_ = http2.conn_send_body(&conn.h2, &conn.h2_out, sid, nil, true /* end_stream */)
			h2_host_flush_out(conn)
		}
		r._stream_ended = true
		r.sent = true
		ex.stream_ending = true
		stream_inc_responses()
		// Long-lived H2 session does not close the connection.
		_session_destroy_st(st, after_wire = false)
		// Free multi-slot entry if this was an H2 exchange slot.
		if si, ok := h2_host_slot_find_by_ptr(conn, ex); ok {
			h2_host_slot_free(conn, si)
		}
		return
	}

	// H1: SSE uses HTTP chunked 0-terminator; WS already sent frames / close frame via effects.
	if st.proto == .Sse && !r._stream_ended {
		_http_write_chunk_end(&r._buf)
		r._stream_ended = true
		stream_inc_responses()
	} else if st.proto == .Ws {
		r._stream_ended = true
		stream_inc_responses()
	}
	r.sent = true
	ex.stream_open = true
	ex.stream_ending = true
	headers_set_close(&r.headers)
	_ = connection_set_state(conn, .Will_Close)
	conn.resp_buf = r._buf.buf
	_stream_flush_response(r)
}

@(private)
_session_abort :: proc(conn: ^Connection) {
	if conn == nil || conn.slot.session == nil {
		return
	}
	_session_abort_st(conn.slot.session)
}

@(private)
_session_abort_st :: proc(st: ^Session_State) {
	if st == nil || st.closed {
		return
	}
	// Skip 0-chunk / graceful END_STREAM; hard close of this exchange.
	st.ending = true
	// Cancel timer best-effort.
	if st.timer_op != 0 && td != nil {
		_ = proactr.cancel_timeout(&td.ring, st.timer_op)
		st.timer_op = 0
	}
	conn := st.public._conn
	ex := _session_ex(st)

	if conn != nil && conn.h2_active {
		// Optional RST_STREAM so peer stops the stream; free session/slot only.
		sid, sok := h2_host_sid_for_slot(conn, ex)
		if sok && sid != 0 {
			http2.rst_stream_write(&conn.h2_out, sid, http2.H2_CANCEL)
			// Mark engine stream failed if still present.
			if s, ok := conn.h2.streams[sid]; ok {
				s.failed = true
				s.error_code = http2.H2_CANCEL
				http2.stream_pending_clear(s)
				s.end_pending = false
			}
			h2_host_flush_out(conn)
		}
		_session_destroy_st(st, after_wire = false)
		if ex != nil {
			if si, ok := h2_host_slot_find_by_ptr(conn, ex); ok {
				h2_host_slot_free(conn, si)
			}
		}
		return
	}

	_session_destroy_st(st, after_wire = false)
	// Drop any in-flight stream buffer ownership then close the H1 connection.
	if conn == nil {
		return
	}
	if conn.wire.kind != .None {
		// Defer full close until CQE (close_on_io path).
		conn.close_on_io = true
		if conn.state < .Will_Close {
			_ = connection_set_state(conn, .Will_Close)
		}
		return
	}
	connection_close(conn)
}

// after_wire=true: called from _stream_finish (do not clean again; caller will).
// after_wire=false: abort/end path; caller handles connection/slot close.
@(private)
_session_destroy :: proc(conn: ^Connection, after_wire: bool) {
	if conn == nil || conn.slot.session == nil {
		return
	}
	_session_destroy_st(conn.slot.session, after_wire)
}

@(private)
_session_destroy_st :: proc(st: ^Session_State, after_wire: bool) {
	if st == nil {
		return
	}
	if st.closed {
		return
	}
	st.closed = true

	conn := st.public._conn
	ex := _session_ex(st)
	if ex == nil && conn != nil {
		ex = &conn.slot
	}

	// Single gen owner: slot.gen. st.gen stays the attach snapshot (immutable).
	// Plan §E.4 free-order: drop seal_q units for this attach gen, then bump so
	// stale Session handles and Seal_Unit.slot_gen fail gen checks.
	attach_gen := st.gen
	if conn != nil && attach_gen != 0 && conn.wire_conn.q != nil {
		_ = seal_q_remove_gen(conn.wire_conn.q, attach_gen)
	}
	if ex != nil {
		_ = stream_slot_bump_gen(ex)
	}

	// Best-effort cancel timer — Session_State stays alive until pending CQEs drain.
	if st.timer_op != 0 && td != nil {
		_ = proactr.cancel_timeout(&td.ring, st.timer_op)
		st.timer_op = 0
	}

	// hooks.on_close — nested free only; host frees pad after.
	if st.hooks.on_close != nil {
		st.hooks.on_close(st.hooks.user)
	}

	// Free sse_alloc pad (after on_close; never leave for reset_exchange alone).
	if ex != nil {
		stream_slot_free_pad(ex)
		ex.res._session_attached = false
		ex.session = nil
		ex.stream_open = false
		ex.stream_ending = false
	}

	// Clear public attach flags; keep st until timer CQEs harvested.
	st.public._conn = nil
	st.public._slot = nil

	sync.atomic_add(&session_metrics_ended, 1)
	sync.atomic_add(&session_metrics_live, -1)

	// Free Session_State only when no Timeout CQEs still reference it.
	if st.timer_pending_cqes <= 0 {
		free(st, st.allocator)
	}
	// else: _session_on_timeout_cqe will free when pending hits 0

	_ = after_wire
}

// ---------------------------------------------------------------------------
// D2 mailbox (per-worker, drained on host tick)
// ---------------------------------------------------------------------------

Session_Mail_Slot :: struct {
	conn:   ^Connection,
	ex:     ^Stream_Slot, // exchange that owns the session (H1 or H2)
	gen:    u32,
	cookie: rawptr,
}

// Simple process-wide queues keyed by worker index (filled at first post).
// Depth limited; overflow drops. Empty drain avoids lock when flag is clear.
@(private)
_session_mail: [dynamic][dynamic]Session_Mail_Slot
@(private)
_session_mail_mu: sync.Mutex
@(private)
_session_mail_pending: i64 // atomic: total queued slots

@(private)
_session_mailbox_post :: proc(st: ^Session_State, cookie: rawptr) -> bool {
	if st == nil {
		return false
	}
	conn := st.public._conn
	ex := _session_ex(st)
	if conn == nil || ex == nil {
		return false
	}
	// Route to owning worker (set on accept). Fall back to current worker or 0.
	widx := conn.worker_index
	if widx < 0 {
		widx = server_worker_index()
	}
	if widx < 0 {
		widx = 0
	}
	depth := SESSION_MAILBOX_DEPTH_DEFAULT
	if conn.server != nil && conn.server.opts.stream_mailbox_depth > 0 {
		depth = conn.server.opts.stream_mailbox_depth
	}

	sync.mutex_lock(&_session_mail_mu)
	for len(_session_mail) <= widx {
		append(&_session_mail, make([dynamic]Session_Mail_Slot, 0, 32))
	}
	q := &_session_mail[widx]
	if len(q^) >= depth {
		sync.mutex_unlock(&_session_mail_mu)
		sync.atomic_add(&session_metrics_mailbox_drops, 1)
		return false
	}
	append(q, Session_Mail_Slot{conn = conn, ex = ex, gen = st.gen, cookie = cookie})
	sync.mutex_unlock(&_session_mail_mu)
	sync.atomic_add(&_session_mail_pending, 1)
	// Per-worker wake short-circuit for ring_wait.
	if conn.server != nil && widx >= 0 && widx < len(conn.server.threads) {
		sync.atomic_add(&conn.server.threads[widx].mail_pending, 1)
	}
	return true
}

// Drain external posts for this worker. Call from host loop (after CQEs).
// Fast path: no lock when no mail is pending process-wide.
session_mailbox_drain :: proc() {
	if sync.atomic_load(&_session_mail_pending) == 0 {
		return
	}
	widx := server_worker_index()
	if widx < 0 {
		return
	}
	batch: [dynamic]Session_Mail_Slot
	sync.mutex_lock(&_session_mail_mu)
	if widx < len(_session_mail) && len(_session_mail[widx]) > 0 {
		n := len(_session_mail[widx])
		batch = _session_mail[widx]
		_session_mail[widx] = make([dynamic]Session_Mail_Slot, 0, 32)
		sync.atomic_add(&_session_mail_pending, -i64(n))
		if td != nil {
			sync.atomic_add(&td.mail_pending, -i64(n))
			if td.mail_pending < 0 {
				td.mail_pending = 0
			}
		}
	}
	sync.mutex_unlock(&_session_mail_mu)
	if len(batch) == 0 {
		return
	}
	for m in batch {
		conn := m.conn
		ex := m.ex
		if conn == nil || ex == nil || ex.session == nil {
			continue
		}
		// Only drive if this worker owns the connection (same map as accept).
		if td != nil {
			if _, ok := td.conns[conn.socket]; !ok {
				// Wrong worker — drop (producer should post on owner).
				continue
			}
		}
		st := ex.session
		if st.closed || st.gen != m.gen {
			continue
		}
		_session_drive_st(st, Session_Event{kind = .External, ext = m.cookie})
	}
	delete(batch)
}

// Timeout CQE from host_dispatch. user is Session_State* (may outlive slot.session).
@(private)
_session_on_timeout_cqe :: proc(user: rawptr, result: i32, op_id: u32) {
	if user == nil {
		return
	}
	st := cast(^Session_State)user
	// Always account for this CQE against pending harvest count.
	if st.timer_pending_cqes > 0 {
		st.timer_pending_cqes -= 1
	}

	// Session already destroyed: only free when no more timer CQEs pending.
	if st.closed {
		if st.timer_pending_cqes <= 0 {
			free(st, st.allocator)
		}
		return
	}

	conn := st.public._conn
	ex := _session_ex(st)
	if conn == nil || ex == nil || ex.session != st {
		if st.timer_pending_cqes <= 0 {
			free(st, st.allocator)
		}
		return
	}

	// Cancelled or replaced: ignore drive.
	if result == proactr.TIMEOUT_CANCELED {
		if st.timer_op == op_id {
			st.timer_op = 0
			st.timer_kind = .None
		}
		return
	}
	if st.timer_op != op_id {
		return
	}

	kind := st.timer_kind
	st.timer_op = 0
	st.timer_kind = .None
	if conn.state >= .Closing {
		return
	}

	// Ensure temp allocator is the connection scrap for any fmt in on_event.
	// (May be empty after reset; use context.temp_allocator as-is.)

	if kind == .Idle {
		sync.atomic_add(&session_metrics_client_gone, 1)
		_session_drive_st(st, Session_Event{kind = .Idle_Timeout, timer = op_id})
		// Host forces abort if still open.
		if ex.session == st && !st.closed && !st.ending {
			_session_abort_st(st)
		}
		return
	}

	// Heartbeat (or unknown): deliver Timer.
	_session_drive_st(st, Session_Event{kind = .Timer, timer = op_id})
	// If still open and no timer, arm idle watchdog.
	if ex.session == st && !st.closed && !st.ending && st.timer_op == 0 && st.idle_ns > 0 {
		_session_arm_timer_st(st, st.idle_ns, .Idle)
	}
}

// After a full Stream flush CQE while session is live (backpressure relief only).
// H1 path (embed slot). H2 Writable is delivered when pending body drains (optional).
@(private)
_session_on_writable :: proc(conn: ^Connection) {
	st := conn.slot.session
	if st == nil || st.closed || st.ending {
		return
	}
	if !st.want_writable {
		return
	}
	st.want_writable = false
	_session_drive_st(st, Session_Event{kind = .Writable})
}
