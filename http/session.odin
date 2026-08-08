// Effect-based Sessions (D0–D2): host-driven events → Effects → wire/timer/end.
// SSE codec in session_sse.odin; WS in session_ws.odin (D3).
// Progressive Stream wire is D0 (response/wire).
package http

import "base:runtime"

import "core:log"
import "core:mem"
import "core:mem/virtual"
import "core:sync"
import "core:time"

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
// Call before sse_start; pad is linked on the connection until session destroy.
sse_alloc :: proc(res: ^Response, size: int, loc := #caller_location) -> rawptr {
	assert(res != nil && res._conn != nil, "sse_alloc: nil response/conn", loc)
	assert(size > 0, "sse_alloc: size must be > 0", loc)
	conn := res._conn
	assert(conn.server != nil, "sse_alloc: no server", loc)
	// One pad per connection attach cycle.
	assert(conn.session_pad == nil, "sse_alloc: pad already allocated", loc)
	p, err := mem.alloc_bytes(size, alignment = max(8, align_of(rawptr)), allocator = conn.server.conn_allocator)
	assert(err == .None && p != nil, "sse_alloc: out of memory", loc)
	mem.zero(raw_data(p), size)
	conn.session_pad = raw_data(p)
	conn.session_pad_size = size
	return conn.session_pad
}

Session_Hooks :: struct {
	user:     rawptr, // single user for on_event + on_close
	on_close: proc(user: rawptr), // optional; free nested only, not pad
}

// Lightweight public handle (safe to copy). _conn is host-owned.
Session :: struct {
	_conn: ^Connection,
	id:    u32,
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

// Internal session bag on Connection.session. Not part of the public API.
// After closed=true, the struct may still be reachable from a soft_cq Timeout
// until timer_pending_cqes hits 0 (then freed). Never free while timer CQEs live.
Session_State :: struct {
	on_event:  Session_On_Event,
	hooks:     Session_Hooks,
	proto:     Session_Proto,
	// Generation / public id (bumped on destroy).
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
Always: Transfer-Encoding chunked, drop Content-Length (via begin_stream).
Asserts on attach conflicts (already sent, cmds, second session).

Drives Session_Event_Kind.Start immediately and applies returned Effects.
After return, the handler must not call respond / stream_* / body_*.
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
	assert(conn.session == nil, "sse_start: connection already has session", loc)
	assert(conn.server != nil, "sse_start: no server", loc)

	// D2 admission: max sessions per worker (0 opts → default).
	max_sess := conn.server.opts.max_sessions_per_worker
	if max_sess <= 0 {
		max_sess = SESSION_MAX_PER_WORKER_DEFAULT
	}
	live := sync.atomic_load(&session_metrics_live)
	assert(live < i64(max_sess) * i64(max(1, conn.server.opts.thread_count)), "sse_start: session cap exceeded", loc)

	// Defaults when handler left headers unset.
	if !headers_has_unsafe(res.headers, "content-type") {
		headers_set_content_type(&res.headers, "text/event-stream")
	}
	if !headers_has_unsafe(res.headers, "cache-control") {
		headers_set_unsafe(&res.headers, "cache-control", "no-cache")
	}

	// Heading freeze + chunked TE.
	_ = response_begin_stream(res, loc)

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
	// Monotonic per-connection epoch (ABA-safe across free-list reuse).
	conn.session_epoch += 1
	if conn.session_epoch == 0 {
		conn.session_epoch = 1
	}
	st.gen = conn.session_epoch
	st.public = Session{_conn = conn, id = st.gen}
	idle_ms := conn.server.opts.stream_idle_timeout_ms
	if idle_ms <= 0 {
		idle_ms = SESSION_IDLE_TIMEOUT_MS_DEFAULT
	}
	st.idle_ns = i64(idle_ms) * 1_000_000
	conn.session = st

	sync.atomic_add(&session_metrics_started, 1)
	sync.atomic_add(&session_metrics_live, 1)

	// Soft-shrink oversized resp_buf capacity for long-lived sessions (heading already in it).
	_stream_shrink_resp_for_session(conn)

	// Drive Start while request temp may still be live (fmt/framing).
	_session_drive(conn, Session_Event{kind = .Start})

	// Detach ~4.5 MiB request temp only AFTER Start apply — later drives use worker session_scratch.
	conn_temp_detach(conn)

	// D2: arm idle watchdog if no heartbeat arm already scheduled.
	if st.timer_op == 0 && st.idle_ns > 0 && !st.closed && !st.ending {
		_session_arm_timer(conn, st.idle_ns, .Idle)
	}

	return st.public
}

// Worker-affine external event post (D2). Any thread may call; drained on owning
// worker via session_mailbox_drain (hook from on_worker_tick or host loop).
// Returns false if mailbox full (metric session_metrics_mailbox_drops).
session_post_external :: proc(s: Session, cookie: rawptr) -> bool {
	if s._conn == nil || s._conn.session == nil {
		return false
	}
	st := s._conn.session
	if st.closed || st.public.id != s.id {
		return false
	}
	return _session_mailbox_post(s._conn, cookie)
}

// Optional: session still live?
session_status :: proc(s: Session) -> bool {
	if s._conn == nil || s._conn.session == nil {
		return false
	}
	st := s._conn.session
	return !st.closed && st.public.id == s.id
}

// Test helper: drive an event and return Effects without requiring sockets when
// the connection has an attached session (apply still runs if worker present).
sse_drive_for_test :: proc(sess: ^Session, ev: Session_Event) -> Effects {
	assert(sess != nil && sess._conn != nil)
	conn := sess._conn
	st := conn.session
	assert(st != nil && !st.closed)
	return _session_drive(conn, ev)
}

// ---------------------------------------------------------------------------
// Drive + apply
// ---------------------------------------------------------------------------

@(private)
_session_drive :: proc(conn: ^Connection, ev: Session_Event) -> Effects {
	st := conn.session
	if st == nil || st.closed || st.ending {
		// Allow Client_Gone / Abort while ending? skip if fully closed.
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
	_session_apply_effects(conn, effs)
	return effs
}

// Use per-worker fixed scrap for effect apply after request temp is detached.
@(private)
_session_bind_scratch :: proc() {
	if td == nil {
		return
	}
	if td.session_scratch_block == nil {
		// 64 KiB worker-local framing scrap (not the 4.5 MiB request slot).
		td.session_scratch_block = make([]u8, 64 * 1024, td.server.conn_allocator)
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
	if conn.session == nil || conn.session.closed {
		return
	}
	r := &conn.loop.res
	want_end := false
	want_abort := false

	for i in 0 ..< int(effs.n) {
		e := effs.items[i]
		switch e.kind {
		case .None:
			// skip
		case .Sse_Data, .Sse_Event, .Sse_Comment:
			frame: [dynamic]u8
			frame.allocator = context.temp_allocator
			_sse_format_effect(&frame, e)
			if len(frame) > 0 {
				// D2 soft backpressure: per-session pending unsent bytes.
				max_buf := SESSION_MAX_STREAM_BUFFER_DEFAULT
				if conn.server != nil && conn.server.opts.max_stream_buffer > 0 {
					max_buf = conn.server.opts.max_stream_buffer
				}
				pending := len(r._buf.buf) - conn.stream_sent + len(frame) + 32 // chunk overhead
				if pending > max_buf {
					sync.atomic_add(&session_metrics_backpressure, 1)
					if conn.session != nil {
						conn.session.want_writable = true
					}
					continue // drop this payload; still honor End/Abort later
				}
				_http_write_chunk(&r._buf, frame[:])
				conn.resp_buf = r._buf.buf
			}
		case .Ws_Text, .Ws_Binary, .Ws_Close:
			_ws_apply_effect(conn, e)
		case .Arm:
			_session_arm_timer(conn, e.delay_ns, .Heartbeat)
		case .End:
			want_end = true
		case .Abort:
			want_abort = true
		}
	}

	if want_abort {
		sync.atomic_add(&session_metrics_aborted, 1)
		_session_abort(conn)
		return
	}

	if want_end {
		_session_end(conn)
		return
	}

	// Flush progressive stream after effects (arm Stream send if wire idle).
	if len(r._buf.buf) > conn.stream_sent {
		_stream_flush_response(r)
	}

	// Compact delivered prefix so long sessions do not retain full history in resp_buf.
	_stream_compact_delivered(conn)
}

@(private)
_session_arm_timer :: proc(conn: ^Connection, delay_ns: i64, kind: Session_Timer_Kind = .Heartbeat) {
	assert_has_td()
	st := conn.session
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
	st := conn.session
	if st == nil || st.closed {
		return
	}
	if st.ending {
		return
	}
	st.ending = true
	r := &conn.loop.res
	// SSE uses HTTP chunked 0-terminator; WS already sent frames / close frame via effects.
	if st.proto == .Sse && !r._stream_ended {
		_http_write_chunk_end(&r._buf)
		r._stream_ended = true
		stream_inc_responses()
	} else if st.proto == .Ws {
		r._stream_ended = true
		stream_inc_responses()
	}
	r.sent = true
	conn.stream_open = true
	conn.stream_ending = true
	headers_set_close(&r.headers)
	_ = connection_set_state(conn, .Will_Close)
	conn.resp_buf = r._buf.buf
	_stream_flush_response(r)
}

@(private)
_session_abort :: proc(conn: ^Connection) {
	st := conn.session
	if st == nil || st.closed {
		return
	}
	// Skip 0-chunk; hard close.
	st.ending = true
	// Cancel timer best-effort.
	if st.timer_op != 0 && td != nil {
		_ = proactr.cancel_timeout(&td.ring, st.timer_op)
		st.timer_op = 0
	}
	_session_destroy(conn, after_wire = false)
	// Drop any in-flight stream buffer ownership then close.
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
// after_wire=false: abort path; caller handles connection close.
@(private)
_session_destroy :: proc(conn: ^Connection, after_wire: bool) {
	st := conn.session
	if st == nil {
		return
	}
	if st.closed {
		return
	}
	st.closed = true
	st.gen += 1

	// Best-effort cancel timer — Session_State stays alive until pending CQEs drain.
	if st.timer_op != 0 && td != nil {
		_ = proactr.cancel_timeout(&td.ring, st.timer_op)
		st.timer_op = 0
	}

	// hooks.on_close — nested free only; host frees pad after.
	if st.hooks.on_close != nil {
		st.hooks.on_close(st.hooks.user)
	}

	// Free sse_alloc pad.
	if conn.session_pad != nil && conn.server != nil {
		mem.free(conn.session_pad, conn.server.conn_allocator)
		conn.session_pad = nil
		conn.session_pad_size = 0
	}

	// Clear public attach flags; keep st until timer CQEs harvested.
	conn.loop.res._session_attached = false
	conn.session = nil
	st.public._conn = nil

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
_session_mailbox_post :: proc(conn: ^Connection, cookie: rawptr) -> bool {
	st := conn.session
	if st == nil {
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
	append(q, Session_Mail_Slot{conn = conn, gen = st.gen, cookie = cookie})
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
	for slot in batch {
		conn := slot.conn
		if conn == nil || conn.session == nil {
			continue
		}
		// Only drive if this worker owns the connection (same map as accept).
		if td != nil {
			if _, ok := td.conns[conn.socket]; !ok {
				// Wrong worker — drop (producer should post on owner).
				continue
			}
		}
		st := conn.session
		if st.closed || st.gen != slot.gen {
			continue
		}
		_session_drive(conn, Session_Event{kind = .External, ext = slot.cookie})
	}
	delete(batch)
}

// Timeout CQE from host_dispatch. user is Session_State* (may outlive conn.session).
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
	if conn == nil || conn.session != st {
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
		_session_drive(conn, Session_Event{kind = .Idle_Timeout, timer = op_id})
		// Host forces abort if still open.
		if conn.session == st && !st.closed && !st.ending {
			_session_abort(conn)
		}
		return
	}

	// Heartbeat (or unknown): deliver Timer.
	_session_drive(conn, Session_Event{kind = .Timer, timer = op_id})
	// If still open and no timer, arm idle watchdog.
	if conn.session == st && !st.closed && !st.ending && st.timer_op == 0 && st.idle_ns > 0 {
		_session_arm_timer(conn, st.idle_ns, .Idle)
	}
}

// After a full Stream flush CQE while session is live (backpressure relief only).
@(private)
_session_on_writable :: proc(conn: ^Connection) {
	st := conn.session
	if st == nil || st.closed || st.ending {
		return
	}
	if !st.want_writable {
		return
	}
	st.want_writable = false
	_session_drive(conn, Session_Event{kind = .Writable})
}
