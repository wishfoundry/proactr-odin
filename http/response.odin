package http

import "core:bytes"
import "core:c"
import "core:io"
import "core:log"
import "core:mem/virtual"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:sys/posix"

import proactr "../proactr"

Response :: struct {
	// Add your headers and cookies here directly.
	headers:          Headers,
	cookies:          [dynamic]Cookie,

	// If the response has been sent.
	sent:             bool,

	// NOTE: use `http.response_status` if the response body might have been set already.
	status:           Status,

	// Only for internal usage.
	// Ownership (Plan A): r lives in Stream_Slot.res; _slot is the owning exchange.
	_slot:            ^Stream_Slot,
	// Pipe convenience; filled only from slot.conn at init — not independent session owner.
	// Prefer response_conn / response_slot in new code; keep _conn for hot-path compat.
	_conn:            ^Connection,
	// TODO/PERF: with some internal refactoring, we should be able to write directly to the
	// connection (maybe a small buffer in this struct).
	_buf:             bytes.Buffer,
	_heading_written: bool,
	// body_reserve state: body written in place after heading; Content-Length patched on commit.
	_body_off:        int, // start index of body in _buf.buf; 0 if not reserved
	_cl_off:          int, // index of first Content-Length digit (fixed width); -1 if none
	_body_max:        int, // max_body from body_reserve
	// Phase 1: body intent as POD commands. Heading is deferred until plan/send unless
	// body_reserve / response_writer / stream already wrote it. Headers may still be set
	// after body_* (not after stream begin — heading is frozen then).
	_cmds:            [PLAN_MAX_BODY_CMDS]Response_Cmd,
	_cmd_count:       int,
	// Phase 2: handler plan bias (zero = server defaults) and optional body middleware.
	_profile:         Handler_Profile,
	_body_mw:         Body_Middleware,
	_body_mw_user:    rawptr,
	// Response-path guards (request facade — NOT dual copies of slot wire fields).
	// Layering: slot.stream_* / slot.session are exchange/wire truth; these flags
	// close the oneshot body API (body_*, respond) when progressive stream or
	// session has taken the response path. Do not read slot.stream_open for body_* asserts.
	_streaming:       bool, // progressive begin_stream or session attach closed oneshot body cmds
	_stream_ended:    bool,
	// True after sse_start/ws_start; mirrors slot.session != nil for assert paths without
	// requiring callers to touch Stream_Slot. Cleared with session destroy / response_init.
	_session_attached: bool,
	// Middleware respond hooks (fixed slots; zero alloc). Fired LIFO at respond
	// before wire assembly. See response_on_respond. Not a public "resume" API —
	// only the host calls these when respond runs.
	_on_respond:      [RESPOND_HOOKS_MAX]Respond_Hook_Entry,
	_on_respond_n:    u8,
	// Fired LIFO at clean_request_loop start (wire done, before arena reset).
	_on_complete:     [RESPOND_HOOKS_MAX]Respond_Hook_Entry,
	_on_complete_n:   u8,
}

// Exchange slot for this response (slot first; falls back to pipe.slot).
@(private)
response_slot :: proc(r: ^Response) -> ^Stream_Slot {
	if r == nil {
		return nil
	}
	if r._slot != nil {
		return r._slot
	}
	if r._conn != nil {
		return &r._conn.slot
	}
	return nil
}

// Pipe for this response (prefer slot.conn; then _conn convenience).
@(private)
response_conn :: proc(r: ^Response) -> ^Connection {
	if r == nil {
		return nil
	}
	if r._slot != nil && r._slot.conn != nil {
		return r._slot.conn
	}
	return r._conn
}

// response_init binds r to c.resp_buf (permanent, conn_allocator). Request temp
// arena is scrap only — never backs the response wire buffer.
// Capacity is retained across keep-alive requests; len is cleared each request.
// r is &conn.slot.res (exchange ownership). Binds _slot = &c.slot and _conn = c.
@(private)
// response_init binds r to the exchange slot (default: H1 conn.slot; H2 passes h2_slots[i]).
response_init :: proc(r: ^Response, c: ^Connection, allocator := context.allocator, slot: ^Stream_Slot = nil) {
	r.status = .Not_Found
	r.sent = false
	r._heading_written = false
	r._body_off = 0
	r._cl_off = -1
	r._body_max = 0
	r._cmd_count = 0
	r._profile = {}
	r._body_mw = nil
	r._body_mw_user = nil
	r._streaming = false
	r._stream_ended = false
	r._session_attached = false
	r._on_respond_n = 0
	r._on_complete_n = 0
	// Ensure pipe backref on slot; Response owns via _slot (exchange), _conn is pipe sugar.
	ex := slot
	if ex == nil {
		ex = &c.slot
	}
	ex.conn = c
	r._slot = ex
	r._conn = c
	r.cookies = {}
	r.cookies.allocator = allocator
	headers_init(&r.headers, allocator)

	// Ensure permanent buffer has initial capacity; keep any grown capacity.
	// Size from Server_Opts.resp_buf_initial (resolved at listen; default HOST_RESP_BUF_INITIAL).
	// H2 eng reuses the same pipe resp_buf for body materialize scrap (not H1 wire).
	resp_init := c.server.opts.resp_buf_initial
	if cap(c.resp_buf) < resp_init {
		if c.resp_buf != nil {
			delete(c.resp_buf)
		}
		c.resp_buf = make([dynamic]u8, 0, resp_init, c.server.conn_allocator)
	} else {
		clear(&c.resp_buf)
	}
	r._buf.buf = c.resp_buf
	r._buf.buf.allocator = c.server.conn_allocator
	r._buf.off = 0
	r._buf.last_read = .Invalid
}

// Append one body command. Heading is not written yet (headers remain mutable until send).
@(private)
_response_append_cmd :: proc(r: ^Response, cmd: Response_Cmd, loc := #caller_location) {
	assert(!r.sent, "response has already been sent", loc)
	assert(!r._streaming, "response stream started; cannot append body cmd", loc)
	assert(!r._heading_written, "heading already written; cannot append body cmd", loc)
	assert(r._body_off == 0, "body_reserve in progress; cannot append body cmd", loc)
	assert(r._cmd_count < PLAN_MAX_BODY_CMDS, "too many body commands (PLAN_MAX_BODY_CMDS)", loc)
	r._cmds[r._cmd_count] = cmd
	r._cmd_count += 1
}

// Set handler plan bias (prefer materialize / gather / sendfile). Cleared on response_init.
// Zero profile: server copy/iovec defaults. With plan_optimize, Sendfile follows
// platform/server plan_sendfile_ok without prefer_sendfile (see Handler_Profile).
response_set_profile :: proc(r: ^Response, p: Handler_Profile) {
	r._profile = p
}

// Optional body middleware: rewrite Response_Cmd[] in place before plan/materialize on send.
// Must obey Body_Middleware contract (same raw_data as input). Pass mw=nil to clear.
// Cleared on response_init.
response_body_middleware :: proc(r: ^Response, mw: Body_Middleware, user: rawptr = nil) {
	r._body_mw = mw
	r._body_mw_user = user
}

// Max respond/complete hooks per request (fixed array; no heap). Outer middleware
// registers first → LIFO fire so onion "after" order is correct.
RESPOND_HOOKS_MAX :: 4

// Invoked by the host only. Must not call respond/stream_end (would re-enter).
// May read req/res; may set headers only if heading not yet written.
Respond_Hook :: #type proc(req: ^Request, res: ^Response, user: rawptr)

Respond_Hook_Entry :: struct {
	cb:   Respond_Hook,
	user: rawptr,
}

/*
Register a hook that runs once status is final and the body is ready to send
(inside response_send_got_body — after optional request-body discard may adjust
status). Before wire plan/send.

Use for access logs (status + duration), metrics. user should live in the request
allocator (or static). Prefer not mutating headers if heading may already be written
(body_reserve / stream).

LIFO: last registered runs first (inner layers before outer). Max RESPOND_HOOKS_MAX.
Not for scheduling work — submit proactr ops; the runtime delivers completions.
*/
response_on_respond :: proc(r: ^Response, user: rawptr, cb: Respond_Hook, loc := #caller_location) {
	assert(cb != nil, "nil respond hook", loc)
	assert(!r.sent, "response already sent; cannot register on_respond", loc)
	assert(r._on_respond_n < u8(RESPOND_HOOKS_MAX), "too many on_respond hooks", loc)
	r._on_respond[r._on_respond_n] = Respond_Hook_Entry{cb = cb, user = user}
	r._on_respond_n += 1
}

/*
Register a hook that runs after the response is fully written (clean_request_loop),
before the request arena is reset. LIFO. Max RESPOND_HOOKS_MAX.

Prefer on_respond for status/logging; use on_complete for post-wire metrics only.
user must still be valid (request arena is not reset until after these hooks).
*/
response_on_complete :: proc(r: ^Response, user: rawptr, cb: Respond_Hook, loc := #caller_location) {
	assert(cb != nil, "nil complete hook", loc)
	assert(!r.sent, "response already sent; cannot register on_complete", loc)
	assert(r._on_complete_n < u8(RESPOND_HOOKS_MAX), "too many on_complete hooks", loc)
	r._on_complete[r._on_complete_n] = Respond_Hook_Entry{cb = cb, user = user}
	r._on_complete_n += 1
}

@(private)
_response_fire_respond_hooks :: proc(r: ^Response) {
	n := int(r._on_respond_n)
	if n == 0 {
		return
	}
	req := &r._conn.loop.req
	// LIFO onion.
	for i := n - 1; i >= 0; i -= 1 {
		e := r._on_respond[i]
		e.cb(req, r, e.user)
	}
	// One-shot: avoid re-entry if a hook somehow nested (should not call respond).
	r._on_respond_n = 0
}

@(private)
_response_fire_complete_hooks :: proc(r: ^Response) {
	n := int(r._on_complete_n)
	if n == 0 {
		return
	}
	req := &r._conn.loop.req
	for i := n - 1; i >= 0; i -= 1 {
		e := r._on_complete[i]
		e.cb(req, r, e.user)
	}
	r._on_complete_n = 0
}

// Base Plan_Policy from connection/server/backend (no handler profile).
// Public four + host meters for plan_body / wire. Safe with nil conn
// (pure defaults + platform sendfile when POSIX).
// Safe off worker thread: thread-local td is nil → fixed_files stays false (no ring touch).
plan_policy_for :: proc(conn: ^Connection) -> Plan_Policy {
	p := plan_policy_default()

	// Platform: plain TCP sendfile is OK on Linux/Darwin (no cipher path in host yet).
	when ODIN_OS == .Linux || ODIN_OS == .Darwin {
		p.sendfile_ok = true
	} else {
		p.sendfile_ok = false
	}

	if conn != nil && conn.server != nil {
		opts := conn.server.opts
		if opts.plan_max_iovecs > 0 {
			p.max_iovecs = opts.plan_max_iovecs
		}
		// 0 → PLAN_DEFAULT_COPY_BUDGET (already in plan_policy_default).
		if opts.plan_copy_budget > 0 {
			p.preferred_copy_budget = opts.plan_copy_budget
		}
		// plan_sendfile_ok: Default_Server_Opts true on posix; false disables.
		// Non-posix remains false from the when above.
		// After profile: plan_optimize keeps this capability; without optimize,
		// prefer_sendfile (or prefer_gather) is required (plan_policy_apply_profile).
		when ODIN_OS == .Linux || ODIN_OS == .Darwin {
			p.sendfile_ok = opts.plan_sendfile_ok
		}
	}

	// fixed_files: registered fd table on this worker's proactr ring.
	// Field read only (no SQE). Only while the ring is live for handlers (Running/Closing).
	// Off-worker / tests: td is nil → leave false. Avoids Cleaning/Closed after ring_destroy.
	if td != nil && (td.state == .Running || td.state == .Closing) {
		p.fixed_files = proactr.ring_has_fixed_files(&td.ring)
	}

	// Cipher path (PR5 host): when conn.ciphered, force no sendfile / no zc and
	// window mem coalesces to PIPE_MAX_WRITE_UNIT_DEFAULT (= PULL_WINDOW). Clear-H1 unchanged.
	if conn != nil && conn.ciphered {
		p.ciphered = true
		p.sendfile_ok = false
		p.zero_copy_send = false
		p.max_write_unit = u32(PIPE_MAX_WRITE_UNIT_DEFAULT)
	} else {
		p.ciphered = false
		p.zero_copy_send = false
		p.max_write_unit = 0
	}
	return p
}

// Base public Plan_Context only (four fields). Handlers that need constraints without host meters.
// Safe with nil conn. For plan_body / wire use plan_policy_for / plan_policy instead.
plan_context_for :: proc(conn: ^Connection) -> Plan_Context {
	return plan_policy_context(plan_policy_for(conn))
}

// Full policy for wire / plan_body: server/conn/backend + Response profile bias.
// Response._profile is request-scoped (cleared in response_init); not atomic — same
// single-worker-per-conn model as the rest of Response.
// optimize flag matches wire gate (plan_optimize | prefer_gather | prefer_sendfile)
// so Sendfile policy aligns with what response_send will actually run.
plan_policy :: proc(r: ^Response) -> Plan_Policy {
	conn: ^Connection
	profile: Handler_Profile
	optimize := false
	if r != nil {
		conn = r._conn
		profile = r._profile
		optimize = _response_wire_use_optimize(r)
	}
	return plan_policy_apply_profile(plan_policy_for(conn), profile, optimize)
}

// Live public Plan_Context for advanced handlers (four fields only).
// Same fill/profile as plan_policy; host meters stripped.
plan_context :: proc(r: ^Response) -> Plan_Context {
	return plan_policy_context(plan_policy(r))
}

// Optimize-policy plan for tests/handlers (shadow of what plan_optimize wire would choose).
// Applies body middleware to a *snapshot* of cmds (does not mutate Response; send applies once).
// Wire path uses plan_body when plan_optimize / prefer_gather; otherwise materialize-only.
response_plan_preview :: proc(r: ^Response) -> Plan_Result {
	if r == nil {
		return plan_body({}, plan_policy(r))
	}
	ctx := plan_policy(r)
	if r._cmd_count == 0 {
		return plan_body({}, ctx)
	}
	// Snapshot so optional middleware can compact without changing r._cmds / r._cmd_count.
	tmp: [PLAN_MAX_BODY_CMDS]Response_Cmd
	n := r._cmd_count
	for i in 0 ..< n {
		tmp[i] = r._cmds[i]
	}
	n = body_middleware_apply(r._body_mw, r._body_mw_user, tmp[:n])
	if n == 0 {
		return plan_body({}, ctx)
	}
	return plan_body(tmp[:n], ctx)
}

// Run body middleware (if set) and update r._cmd_count. In-place only (Body_Middleware contract).
@(private)
_response_apply_body_middleware :: proc(r: ^Response) {
	if r._body_mw == nil || r._cmd_count == 0 {
		return
	}
	// Pass r._cmds[:count] so cap remains PLAN_MAX_BODY_CMDS for in-place expand.
	r._cmd_count = body_middleware_apply(r._body_mw, r._body_mw_user, r._cmds[:r._cmd_count])
}

// Append a borrowed Static body command (immutable for the response lifetime).
body_static :: proc(r: ^Response, data: []u8, loc := #caller_location) {
	_response_append_cmd(r, cmd_static(data), loc)
}

// Append a Bytes body command. owned=true means free-after-send semantics for later phases;
// Phase 1 only materializes into resp_buf (does not free).
body_bytes :: proc(r: ^Response, data: []u8, owned := true, loc := #caller_location) {
	_response_append_cmd(r, cmd_bytes(data, owned), loc)
}

// Append a File body command (fd region). Does not read the file here.
//
// Ownership: by default the caller must keep `fd` open and the region readable until the
// response send fully completes (final send CQE / clean_request_loop); the host does not
// close the fd. Pass owned=true to transfer close responsibility to the host (closes after
// materialize, HEAD headers-only path, or file-region stream clear). With plan_optimize
// (or prefer_sendfile) the wire path uses sendfile(2) or chunked pread (Phase 4); otherwise
// materialize preads the full region into resp_buf at send time.
// length must be known (>= 0) for both paths.
body_file :: proc(r: ^Response, fd: i32, offset: i64, length: i64, owned := false, loc := #caller_location) {
	_response_append_cmd(r, cmd_file(fd, offset, length, owned), loc)
}

/*
Prefer the procedure group `body_set`.

Sets a single Static body command (exclusive). Does not write the HTTP heading yet — headers
and status remain mutable until respond / plan / send. (body_reserve and response_writer still
write the heading immediately.)

For multi-part bodies use body_static / body_bytes / body_file (append). Double body_set asserts
like pre-Phase-1 (body already written).
*/
body_set_bytes :: proc(r: ^Response, byts: []byte, loc := #caller_location) {
	// Preserve exclusive "set" semantics; multi-cmd is via body_static/body_bytes/body_file.
	assert(r._cmd_count == 0, "the response body has already been written", loc)
	// Borrowed for response lifetime; materialize copies into resp_buf at send.
	body_static(r, byts, loc)
}

/*
Prefer the procedure group `body_set`.
*/
body_set_str :: proc(r: ^Response, str: string, loc := #caller_location) {
	// Safe: materialize copies; we do not mutate the string bytes.
	body_set_bytes(r, transmute([]byte)str, loc)
}

/*
Sets the response body to a single Static command (exclusive; second call asserts).

Unlike the pre-Phase-1 path, this does **not** freeze headers: you may still add headers
or change status until respond. At send time the planner materialises into one buffer
by default; with plan_optimize / prefer_gather a pure Writev plan may multi-buffer send
(heading + borrowed body) without copying the body into resp_buf.

Multi-part bodies: body_static / body_bytes / body_file (append).
For in-place fixed-CL bodies use body_reserve / body_commit.
For unknown size / io.Writer use response_writer_init (chunked; heading written early).
For SSE / long-lived chunked streams use response_begin_stream (not body cmds).
*/
body_set :: proc{
	body_set_str,
	body_set_bytes,
}

// Fixed-width Content-Length field for body_reserve (leading zeros; RFC 9110 DIGIT).
BODY_CL_DIGITS :: 10

/*
Reserve a writable body region in the response wire buffer.

Writes the HTTP heading first with a fixed-width Content-Length placeholder, then
returns a slice for the body immediately after the heading. Fill slot[0:n] and call
body_commit(n) — only the length digits are patched (no body memmove, no scratch copy).

	slot := http.body_reserve(res, 4096)
	n := fill(slot)
	http.body_commit(res, n)
	http.respond(res)
*/
body_reserve :: proc(r: ^Response, max_body: int, loc := #caller_location) -> []byte {
	assert_has_td(loc)
	assert(!r.sent, "response has already been sent", loc)
	assert(!r._streaming, "response stream started; cannot body_reserve", loc)
	assert(!r._heading_written, "heading already written; cannot body_reserve", loc)
	assert(r._cmd_count == 0, "body cmds already set; cannot body_reserve", loc)
	assert(bytes.buffer_length(&r._buf) == 0, "response body already started", loc)
	assert(max_body >= 0, "max_body must be non-negative", loc)
	assert(max_body < 1_000_000_000, "max_body exceeds BODY_CL_DIGITS", loc)

	// Heading with placeholder CL; body grows after it.
	hscratch: [512]byte
	hlen, cl_off := _response_format_heading_reserved(r, hscratch[:])
	assert(hlen > 0 && hlen <= len(hscratch), "heading overflow", loc)
	assert(cl_off >= 0, "content-length placeholder missing", loc)

	need := hlen + max_body
	if cap(r._buf.buf) < need {
		reserve(&r._buf.buf, need)
	}
	resize(&r._buf.buf, need)
	copy(r._buf.buf[0:], hscratch[:hlen])

	r._heading_written = true
	r._body_off = hlen
	r._cl_off = cl_off
	r._body_max = max_body
	return r._buf.buf[hlen:][:max_body]
}

/*
Abandon a body_reserve without sending (e.g. generation failed).
*/
body_cancel :: proc(r: ^Response, loc := #caller_location) {
	assert(!r.sent, "response has already been sent", loc)
	assert(!r._streaming, "response stream started; cannot body_cancel", loc)
	resize(&r._buf.buf, 0)
	r._heading_written = false
	r._body_off = 0
	r._cl_off = -1
	r._body_max = 0
	r._cmd_count = 0
}

/*
Finish a body_reserve write: patch Content-Length and truncate the wire buffer
to heading + body_len. Body bytes stay in place (no copy).
*/
body_commit :: proc(r: ^Response, body_len: int, loc := #caller_location) {
	assert_has_td(loc)
	assert(!r.sent, "response has already been sent", loc)
	assert(r._body_off > 0, "body_commit without body_reserve", loc)
	assert(body_len >= 0 && body_len <= r._body_max, "body_len out of reserved range", loc)
	assert(r._cl_off >= 0, "no content-length to patch", loc)

	t0_build: u64
	when HTTP_PHASE_STATS {
		t0_build = phase_now()
	}

	// Patch fixed-width zero-padded Content-Length digits.
	dig: [BODY_CL_DIGITS]byte
	for i in 0 ..< BODY_CL_DIGITS {
		dig[i] = '0'
	}
	// Write decimal into dig right-aligned.
	n := body_len
	i := BODY_CL_DIGITS - 1
	if n == 0 {
		dig[i] = '0'
	} else {
		for n > 0 && i >= 0 {
			dig[i] = byte('0' + n % 10)
			n /= 10
			i -= 1
		}
	}
	copy(r._buf.buf[r._cl_off:][:BODY_CL_DIGITS], dig[:])

	resize(&r._buf.buf, r._body_off + body_len)
	r._body_off = 0
	r._cl_off = -1
	r._body_max = 0

	when HTTP_PHASE_STATS {
		phase_add(0, 0, 0, 0, 0, phase_now() - t0_build, 0)
	}
}

/*
Sets the status code with the safety of being able to do this after writing (part of) the body.

If the heading is not yet written (cmd-based body_set path), only the status field is updated
and will be formatted at materialize/send time. If the heading is already in the buffer
(body_reserve / response_writer), the three status digits are patched in place.
*/
response_status :: proc(r: ^Response, status: Status) {
	if r.status == status { return }

	r.status = status

	// Heading already on the wire buffer (reserve / chunked writer): patch status digits.
	// Cmd-only path: buffer empty, field update is enough until materialize.
	if r._heading_written && bytes.buffer_length(&r._buf) > 0 {
		OFFSET :: len("HTTP/1.1 ")

		status_int_str := status_string(r.status)
		if len(status_int_str) < 4 {
			status_int_str = "500 "
		} else {
			status_int_str = status_int_str[0:4]
		}

		copy(r._buf.buf[OFFSET:OFFSET + 4], status_int_str)
	}
}

// HTTP/1.1 chunked transfer framing (RFC 9112). Empty chunk is a no-op (final
// terminator is _http_write_chunk_end only). Used by Response_Stream and Response_Writer.
@(private)
_http_write_chunk :: proc(b: ^bytes.Buffer, chunk: []byte) {
	plen := i64(len(chunk))
	if plen == 0 {
		return
	}

	// size hex + \r\n + data + \r\n
	bytes.buffer_grow(b, 16 + len(chunk) + 4)
	size_buf := _dynamic_unwritten(b.buf)
	size := strconv.write_int(size_buf, plen, 16)
	_dynamic_add_len(&b.buf, len(size))

	bytes.buffer_write_string(b, "\r\n")
	bytes.buffer_write(b, chunk)
	bytes.buffer_write_string(b, "\r\n")
}

@(private)
_http_write_chunk_end :: proc(b: ^bytes.Buffer) {
	bytes.buffer_write_string(b, "0\r\n\r\n")
}

// ---------------------------------------------------------------------------
// Phase 5 + D0: Response_Stream — chunked bodies with progressive multi-CQE flush
// ---------------------------------------------------------------------------
//
// Streaming is a different lifetime from the body command planner (G5):
//
//   headers / status (mutable) → response_begin_stream → stream_write* → stream_end
//
// Body middleware does NOT run on stream data. Any rewrite of body intent must
// happen before begin_stream (headers only after that are frozen with the heading).
//
// Mutual exclusion with body_set / body_* cmds / body_reserve / response_writer.
//
// D0 wire model:
//   - Transfer-Encoding: chunked; heading written once at begin
//   - stream_write appends framed chunks into resp_buf (may run while a Stream
//     send is in flight — flush always copies to stream_send_buf)
//   - stream_flush submits unsent bytes as Wire_Kind.Stream when wire idle
//   - stream_end writes the final 0-chunk, sets stream_ending, flushes; clean
//     only after the last Stream CQE (not the oneshot respond path)
// Oneshot still works: never mid-flush → stream_end ending+flush all at once.
// plan_wire_* counters are not incremented; stream_responses_total is.
// Session (D1) owns the wire after sse_start — public stream_* assert if attached.

Response_Stream :: struct {
	r:     ^Response,
	ended: bool,
}

/*
Begin a chunked response stream. Writes the HTTP heading immediately (headers
and status freeze). Mutually exclusive with body cmds, body_reserve, and
response_writer.

Body middleware is not applied to stream bytes — set headers before calling.

Call stream_write / stream_flush as needed, then stream_end (sends the response).
Do not call body_set after begin_stream. stream_end owns the send — do not respond again.
*/
response_begin_stream :: proc(r: ^Response, loc := #caller_location) -> Response_Stream {
	assert(!r.sent, "response has already been sent", loc)
	assert(!r._session_attached, "session attached; cannot begin_stream", loc)
	assert(!r._streaming, "response stream already started", loc)
	assert(!r._heading_written, "heading already written; cannot begin_stream", loc)
	assert(r._cmd_count == 0, "body cmds already set; cannot begin_stream", loc)
	assert(r._body_off == 0, "body_reserve in progress; cannot begin_stream", loc)
	assert(bytes.buffer_length(&r._buf) == 0, "response body already started", loc)

	// Wire is always HTTP chunked framing. Force TE and drop Content-Length:
	// dual CL+TE can desync keep-alive parsers (RFC 9112 §6.1); a pre-set TE
	// other than chunked would mislabel the body. Match response_writer_init.
	headers_set_unsafe(&r.headers, "transfer-encoding", "chunked")
	if headers_has_unsafe(r.headers, "content-length") {
		headers_delete_unsafe(&r.headers, "content-length")
	}

	_response_write_heading(r, -1)
	r._streaming = true
	r._stream_ended = false

	return Response_Stream {
		r     = r,
		ended = false,
	}
}

// Alias for response_begin_stream (G5 sketch name).
begin_stream :: response_begin_stream

// Append data as one HTTP chunk into the response wire buffer. Empty data is a no-op.
// Safe while a progressive Stream send is in flight (append-only past stream_sent).
stream_write :: proc(s: ^Response_Stream, data: []byte, loc := #caller_location) {
	assert(s != nil && s.r != nil, "nil Response_Stream", loc)
	assert(!s.r._session_attached, "session owns stream; use effects", loc)
	assert(!s.ended && !s.r._stream_ended, "stream already ended", loc)
	assert(s.r._streaming, "stream not started", loc)
	assert(!s.r.sent, "response has already been sent", loc)
	if len(data) == 0 {
		return
	}
	_http_write_chunk(&s.r._buf, data)
	// Keep Connection.resp_buf in sync with any reallocation.
	if s.r._conn != nil {
		s.r._conn.resp_buf = s.r._buf.buf
	}
}

/*
Flush unsent stream bytes to the wire (progressive multi-CQE).

When the wire is free, copies resp_buf[stream_sent:] into stream_send_buf and
submits Wire_Kind.Stream. When a Stream send is already in flight, sets
stream_flush_pending (CQE reflush). Without a worker (unit tests), coalesce only.
*/
stream_flush :: proc(s: ^Response_Stream, loc := #caller_location) {
	assert(s != nil && s.r != nil, "nil Response_Stream", loc)
	assert(!s.r._session_attached, "session owns stream; use effects", loc)
	assert(!s.ended && !s.r._stream_ended, "stream already ended", loc)
	assert(s.r._streaming, "stream not started", loc)
	assert(!s.r.sent, "response has already been sent", loc)
	_stream_flush_response(s.r, loc)
}

/*
Finish the stream: final 0-chunk, stream_ending, progressive flush.

stream_end *is* the send — do not call respond again (second respond asserts).
A second stream_end asserts on s.ended / r._stream_ended.

HEAD: body bytes may already be in the buffer; stripped before flush (same as
Response_Writer / body_reserve).

Increments stream_responses_total (not plan_wire_*) once per successful end.
Does not use the oneshot respond() path — clean_request_loop runs after the
last Stream CQE when stream_ending and all bytes are delivered.
*/
stream_end :: proc(s: ^Response_Stream, loc := #caller_location) {
	assert(s != nil && s.r != nil, "nil Response_Stream", loc)
	assert(!s.r._session_attached, "session owns stream; use effects / effect_end", loc)
	assert(!s.ended && !s.r._stream_ended, "stream already ended", loc)
	assert(s.r._streaming, "stream not started", loc)
	assert(!s.r.sent, "response has already been sent", loc)

	r := s.r
	conn := r._conn
	assert(conn != nil, "stream_end without connection", loc)

	_http_write_chunk_end(&r._buf)
	s.ended = true
	r._stream_ended = true
	stream_inc_responses()

	// HEAD: drop body, keep heading (same as response_send_got_body).
	if _response_is_head(conn) {
		_response_strip_body_keep_heading(r)
	}

	// Progressive terminal path (oneshot = ending+flush with no prior mid-flush).
	r.sent = true
	conn.slot.stream_open = true
	conn.slot.stream_ending = true
	// D0 default: stream end → Will_Close (no keep-alive reuse of stream conns).
	headers_set_close(&r.headers)
	_ = connection_set_state(conn, .Will_Close)

	conn.resp_buf = r._buf.buf
	_stream_flush_response(r, loc)
}

// stream_close is an alias for stream_end.
stream_close :: stream_end

// Host: flush progressive stream for r (public stream_flush or session apply).
// Copies unsent resp_buf into stream_send_buf before submit (never alias resp_buf).
@(private)
_stream_flush_response :: proc(r: ^Response, loc := #caller_location) {
	conn := r._conn
	if conn == nil {
		return
	}
	// Sync growth of the response buffer header copy.
	conn.resp_buf = r._buf.buf

	// Unit tests without a worker thread: coalesce only.
	if td == nil {
		return
	}
	assert_has_td(loc)
	_stream_try_submit(conn)
}

// Submit unsent stream bytes if wire idle; else mark flush_pending.
// On first successful arm, fire on_respond once (TTFB / access log).
// Ciphered / TLS: encrypt from resp_buf view via tls_host_stream_try_submit (no pool slabs).
@(private)
_stream_try_submit :: proc(conn: ^Connection) {
	assert_has_td()
	if conn.state >= .Closing {
		return
	}

	// Keep resp_buf synced from response binding when present.
	r := &conn.slot.res
	if r._buf.buf != nil {
		conn.resp_buf = r._buf.buf
	}

	// PR6: progressive stream over TLS H1 — peer expects ciphertext.
	// Same entry as clear Stream (ws_start / sse_start / begin_stream); no plain-send bypass.
	if conn.ciphered || conn.tls_ssl != nil {
		tls_host_stream_try_submit(conn)
		return
	}

	unsent := len(conn.resp_buf) - conn.slot.stream_sent
	if unsent <= 0 {
		if conn.slot.stream_ending {
			_stream_finish(conn)
		}
		return
	}

	if conn.wire.kind != .None {
		conn.slot.stream_flush_pending = true
		return
	}

	conn.slot.stream_open = true

	// First flush: on_respond once (heading final, body may still be streaming).
	if !conn.slot.stream_respond_fired {
		conn.slot.stream_respond_fired = true
		_response_fire_respond_hooks(r)
	}

	// Clear-H1: copy next chunk into a fixed pool slab (never alias resp_buf).
	// Cap per CQE at STREAM_BUF_SIZE so large bodies are multi-CQE by design.
	to_send := conn.resp_buf[conn.slot.stream_sent:]
	slab := stream_pool_take()
	if slab == nil {
		// Admission fail: keep data, mark pending, try later.
		conn.slot.stream_flush_pending = true
		sync.atomic_add(&session_metrics_backpressure, 1)
		return
	}
	n := min(len(to_send), len(slab))
	copy(slab[:n], to_send[:n])
	conn.slot.stream_send_slab = slab
	conn.slot.stream_send_len = n

	// Explicitly inactive multi-op queue so a prior path cannot leak exec_n.
	conn.wire.exec_i = 0
	conn.wire.exec_n = 0
	conn.wire.pending_send = slab[:n]
	if len(conn.wire.pending_send) == 0 {
		stream_pool_put(slab)
		conn.slot.stream_send_slab = nil
		conn.slot.stream_send_len = 0
		return
	}
	if err := host_submit_send(conn); err != .None {
		stream_pool_put(slab)
		conn.slot.stream_send_slab = nil
		conn.slot.stream_send_len = 0
		conn.wire.pending_send = nil
		_wire_fail(conn, "submit_send (stream) failed: %v", err)
		return
	}
	// host_submit_send sets .Send; progressive completion routes on .Stream.
	conn.wire.kind = .Stream
}

// Drop fully delivered prefix from resp_buf so long sessions do not retain history.
// Only when wire is idle (no Stream pending).
@(private)
_stream_compact_delivered :: proc(conn: ^Connection) {
	if conn.wire.kind != .None {
		return
	}
	if conn.slot.stream_sent <= 0 {
		return
	}
	// Compact when any prefix is delivered (sessions should not keep history).
	// Non-session progressive streams still thrash less: only if >= 1 KiB or ending.
	if conn.slot.session == nil && conn.slot.stream_sent < 1024 && !conn.slot.stream_ending {
		return
	}
	n := len(conn.resp_buf)
	if conn.slot.stream_sent >= n {
		clear(&conn.resp_buf)
		conn.slot.stream_sent = 0
	} else {
		// memmove unsent to front
		unsent := n - conn.slot.stream_sent
		copy(conn.resp_buf[:unsent], conn.resp_buf[conn.slot.stream_sent:][:unsent])
		resize(&conn.resp_buf, unsent)
		conn.slot.stream_sent = 0
	}
	// Sync Response buffer view.
	r := &conn.slot.res
	if r._buf.buf.allocator.procedure != nil {
		r._buf.buf = conn.resp_buf
	}
	// Soft shrink oversized capacity for session streams (target ≤ 64 KiB).
	if conn.slot.session != nil && cap(conn.resp_buf) > 64 * 1024 && len(conn.resp_buf) < 16 * 1024 {
		// Reallocate smaller (keep content).
		small := make([dynamic]u8, len(conn.resp_buf), 16 * 1024, conn.server.conn_allocator)
		copy(small[:], conn.resp_buf[:])
		delete(conn.resp_buf)
		conn.resp_buf = small
		r._buf.buf = conn.resp_buf
	}
}

// After last stream byte delivered (and stream_ending): tear down session if any, clean.
@(private)
_stream_finish :: proc(conn: ^Connection) {
	// Session terminal path may still need destroy (End already set ending).
	if conn.slot.session != nil {
		_session_destroy(conn, after_wire = true)
	}
	_stream_pin_disarm(conn)
	conn.slot.stream_open = false
	conn.slot.stream_ending = false
	conn.slot.stream_sent = 0
	conn.slot.stream_flush_pending = false
	conn.slot.stream_respond_fired = false
	conn.tls_stream_plain_n = 0
	_stream_pool_abandon(conn)
	conn.wire.pending_send = nil
	conn.wire.kind = .None
	clean_request_loop(conn)
}

// Soft shrink permanent resp_buf after session heading is in place (follow-up pin).
@(private)
_stream_shrink_resp_for_session :: proc(conn: ^Connection) {
	if conn == nil || conn.server == nil {
		return
	}
	cap_target := conn.server.opts.stream_resp_shrink_cap
	if cap_target <= 0 {
		cap_target = 16 * 1024
	}
	n := len(conn.resp_buf)
	if cap(conn.resp_buf) <= cap_target {
		return
	}
	// Keep content; reduce capacity to max(cap_target, n).
	want := max(cap_target, n)
	if want >= cap(conn.resp_buf) {
		return
	}
	small := make([dynamic]u8, n, want, conn.server.conn_allocator)
	if n > 0 {
		copy(small[:], conn.resp_buf[:n])
	}
	delete(conn.resp_buf)
	conn.resp_buf = small
	r := &conn.slot.res
	if r._buf.buf.allocator.procedure != nil {
		r._buf.buf = conn.resp_buf
	}
}

// PIN hangup (clear-H1): intentionally disabled without portable recv cancel.
// Arming a 1-byte recv while waiting for External/Timer creates a hang (cannot send
// until peer activity, and peer data becomes Client_Gone). Peer death is detected via:
//   - stream send error (Client_Gone)
//   - Idle_Timeout watchdog
// Ciphered Open: _session_arm_hangup_watch arms CT recv instead (peer FIN / close_notify).
// Re-enable clear PIN only with IORING_ASYNC_CANCEL (or equivalent) to drop PIN before send.
@(private)
_stream_pin_arm :: proc(conn: ^Connection) {
	_ = conn
}

@(private)
_stream_pin_disarm :: proc(conn: ^Connection) {
	conn.slot.stream_pin_armed = false
}

// After stream mid-idle (or session attach): arm peer-close watch.
// Ciphered long-lived → tls_host_arm_recv (single-flight via tls_ct_recv_inflight);
// clear → PIN no-op (see _stream_pin_arm).
@(private)
_session_arm_hangup_watch :: proc(conn: ^Connection) {
	if conn == nil || conn.state >= .Closing {
		return
	}
	if _conn_wire_in_flight(conn) {
		return
	}
	// CT hangup only for long-lived Open+ssl (session or progressive stream).
	if _session_hangup_uses_tls_ct(conn) {
		if conn.slot.session == nil && !conn.slot.stream_open {
			return
		}
		if td == nil {
			return
		}
		if !tls_host_arm_recv(conn) {
			// CQ-M1: do not silently drop hangup watch on long-lived.
			log.errorf("TLS: hangup CT arm failed fd=%v", conn.socket)
		}
		return
	}
	_stream_pin_arm(conn)
}

// Pure gate: ciphered Open with SSL (no ring). Used by hangup arm + tests.
@(private)
_session_hangup_uses_tls_ct :: proc(conn: ^Connection) -> bool {
	return conn != nil &&
		conn.ciphered &&
		conn.tls_ssl != nil &&
		conn.tls_pipe.state == .Open
}

Response_Writer :: struct {
	r:     ^Response,
	// The writer you can write to.
	w:     io.Writer,
	// A dynamic wrapper over the `buffer` given in `response_writer_init`, doesn't allocate.
	buf:   [dynamic]byte,
	// If destroy or close has been called.
	ended: bool,
}

/*
Initialize a writer you can use to write responses. Use the `body_set` procedure group if you have
a string or byte slice. For SSE / explicit chunked streaming prefer response_begin_stream.

The buffer can be used to avoid very small writes, like the ones when you use the json package
(each write in the json package is only a few bytes). You are allowed to pass nil which will disable
buffering.

NOTE: You need to call io.destroy to signal the end of the body, OR io.close to send the response.
Mutually exclusive with body cmds, body_reserve, and Response_Stream.
*/
response_writer_init :: proc(rw: ^Response_Writer, r: ^Response, buffer: []byte) -> io.Writer {
	assert(r._cmd_count == 0, "body cmds already set; cannot response_writer_init")
	assert(!r._streaming, "response stream started; cannot response_writer_init")
	assert(!r._heading_written, "heading already written; cannot response_writer_init")
	assert(r._body_off == 0, "body_reserve in progress; cannot response_writer_init")
	// Same TE/CL rules as response_begin_stream (chunked framing; no dual headers).
	headers_set_unsafe(&r.headers, "transfer-encoding", "chunked")
	if headers_has_unsafe(r.headers, "content-length") {
		headers_delete_unsafe(&r.headers, "content-length")
	}
	_response_write_heading(r, -1)

	rw.buf = slice.into_dynamic(buffer)
	rw.r   = r

	rw.w = io.Stream{
		procedure = proc(stream_data: rawptr, mode: io.Stream_Mode, p: []byte, offset: i64, whence: io.Seek_From) -> (n: i64, err: io.Error) {
			rw := (^Response_Writer)(stream_data)
			b := &rw.r._buf

			#partial switch mode {
			case .Flush:
				assert(!rw.ended)

				_http_write_chunk(b, rw.buf[:])
				clear(&rw.buf)
				return 0, nil

			case .Destroy:
				assert(!rw.ended)

				// Write what is left.
				_http_write_chunk(b, rw.buf[:])
				_http_write_chunk_end(b)

				rw.ended = true
				return 0, nil

			case .Close:
				// Write what is left.
				_http_write_chunk(b, rw.buf[:])

				if !rw.ended {
					_http_write_chunk_end(b)
					rw.ended = true
				}

				// Send the response.
				respond(rw.r)
				return 0, nil

			case .Write:
				assert(!rw.ended)

				// No space, first write rw.buf, then check again for space, if still no space,
				// fully write the given p.
				if len(rw.buf) + len(p) > cap(rw.buf) {
					_http_write_chunk(b, rw.buf[:])
					clear(&rw.buf)

					if len(p) > cap(rw.buf) {
						_http_write_chunk(b, p)
					} else {
						append(&rw.buf, ..p)
					}
				} else {
					// Space, append bytes to the buffer.
					append(&rw.buf, ..p)
				}

				return i64(len(p)), .None

			case .Query:
				return io.query_utility({.Write, .Flush, .Destroy, .Close})
			}
			return 0, .Empty
		},
		data = rw,
	}
	return rw.w
}

/*
Writes the response status and headers to the buffer.

This is automatically called before writing anything to the Response.body or before calling a procedure
that sends the response.

You can pass `content_length < 0` to omit the content-length header, note that this header is
required on most responses, but there are things like transfer-encodings that could leave it out.
*/
_response_write_heading :: proc(r: ^Response, content_length: int) {
	if r._heading_written { return }
	r._heading_written = true

	MIN             :: len("HTTP/1.1 200 \r\ndate: \r\ncontent-length: 1000\r\n") + DATE_LENGTH
	AVG_HEADER_SIZE :: 20
	// Heading only here (body appended by caller); content_length is for the header field, not buffer.
	reserve_size := MIN + (AVG_HEADER_SIZE * headers_count(r.headers)) + 32
	if content_length > 0 {
		// Keep prior growth hint when body follows immediately via body_set.
		reserve_size += min(content_length, 1 << 20)
	}
	bytes.buffer_grow(&r._buf, reserve_size)

	// Format heading on stack, then append to the wire buffer.
	hscratch: [512]byte
	hlen := _response_format_heading(r, content_length, hscratch[:])
	assert(hlen > 0 && hlen <= len(hscratch))
	bytes.buffer_write(&r._buf, hscratch[:hlen])
}

// Format status-line + headers into out; returns bytes written (no body).
@(private)
_response_format_heading :: proc(r: ^Response, content_length: int, out: []byte) -> int {
	hlen, _ := _response_format_heading_ex(r, content_length, out, cl_placeholder = false)
	return hlen
}

// Like _response_format_heading but with fixed-width zero CL for body_reserve.
// Returns (bytes written, offset of first CL digit or -1).
@(private)
_response_format_heading_reserved :: proc(r: ^Response, out: []byte) -> (hlen: int, cl_off: int) {
	return _response_format_heading_ex(r, 0, out, cl_placeholder = true)
}

@(private)
_response_format_heading_ex :: proc(
	r: ^Response,
	content_length: int,
	out: []byte,
	cl_placeholder: bool,
) -> (
	hlen: int,
	cl_off: int,
) {
	cl_off = -1
	conn := r._conn
	b := strings.builder_from_bytes(out)

	// According to RFC 7230 3.1.2 the reason phrase is insignificant,
	// because not doing so (and the fact that a status code is always length 3), we can change
	// the status code when we are already writing a body by just addressing the 3 bytes directly.
	status_int_str := status_string(r.status)
	if len(status_int_str) < 4 {
		status_int_str = "500 "
	} else {
		status_int_str = status_int_str[0:4]
	}

	strings.write_string(&b, "HTTP/1.1 ")
	strings.write_string(&b, status_int_str)
	strings.write_string(&b, "\r\n")

	// Per RFC 9910 6.6.1 a Date header must be added in 2xx, 3xx, 4xx responses.
	if r.status >= .OK && r.status <= .Internal_Server_Error && !headers_has_unsafe(r.headers, "date") {
		strings.write_string(&b, "date: ")
		strings.write_string(&b, server_date(conn.server))
		strings.write_string(&b, "\r\n")
	}

	if !headers_has_unsafe(r.headers, "content-length") && response_needs_content_length(r, conn) {
		if cl_placeholder {
			strings.write_string(&b, "content-length: ")
			cl_off = strings.builder_len(b)
			for _ in 0 ..< BODY_CL_DIGITS {
				strings.write_byte(&b, '0')
			}
			strings.write_string(&b, "\r\n")
		} else if content_length > -1 {
			if content_length == 0 {
				strings.write_string(&b, "content-length: 0\r\n")
			} else {
				strings.write_string(&b, "content-length: ")
				assert(content_length < 1000000000000000000 && content_length > -1000000000000000000)
				buf: [20]byte
				strings.write_string(&b, strconv.write_int(buf[:], i64(content_length), 10))
				strings.write_string(&b, "\r\n")
			}
		}
	}

	hdr_w := io.to_writer(strings.to_stream(&b))
	for header, value in r.headers._kv {
		strings.write_string(&b, header) // already sanitized keys
		strings.write_string(&b, ": ")
		write_escaped_newlines(hdr_w, value)
		strings.write_string(&b, "\r\n")
	}

	for cookie in r.cookies {
		cookie_write(hdr_w, cookie)
		strings.write_string(&b, "\r\n")
	}

	strings.write_string(&b, "\r\n")
	return strings.builder_len(b), cl_off
}

// Sends the response over the connection.
// Frees the allocator (should be a request scoped allocator).
// Closes the connection or starts the handling of the next request.
@(private)
response_send :: proc(r: ^Response, conn: ^Connection, loc := #caller_location) {
	assert(!r.sent, "response has already been sent", loc)
	ex := response_slot(r)
	if ex == nil {
		ex = &conn.slot
	}
	assert(!r._session_attached && ex.session == nil, "session attached; cannot respond", loc)
	assert(!ex.stream_open || r._stream_ended, "progressive stream open; use stream_end", loc)
	// Note: on_respond hooks fire in response_send_got_body after body discard
	// may adjust status — so access logs see the status that will hit the wire.
	r.sent = true

	check_body :: proc(res: rawptr, body: Body, err: Body_Error) {
		res := cast(^Response)res
		will_close: bool

		if err != nil {
			// Any read error should close the connection.
			response_status(res, body_error_status(err))
			headers_set_close(&res.headers)
			will_close = true
		}

		response_send_got_body(res, will_close)
	}

	// PR8 H2 oneshot: request body is already fully framed (or empty). Skip H1
	// scanner discard; body() still works via Request._pre_body for handlers.
	if conn.h2_active {
		response_send_got_body(r, false)
		return
	}

	// RFC 7230 6.3: A server MUST read
	// the entire request message body or close the connection after sending
	// its response, since otherwise the remaining data on a persistent
	// connection would be misinterpreted as the next request.
	if !response_must_close(&conn.loop.req, r) {

		// Body has been drained during handling.
		if _, got_body := conn.loop.req._body_ok.?; got_body {
			response_send_got_body(r, false)
		} else {
			body(&conn.loop.req, Max_Post_Handler_Discard_Bytes, r, check_body)
		}

	} else {
		response_send_got_body(r, true)
	}
}

// True when this response is for a HEAD (or redirect_head_to_get synthetic GET).
@(private)
_response_is_head :: proc(conn: ^Connection) -> bool {
	if conn.loop.req.is_head {
		return true
	}
	if line, ok := conn.loop.req.line.?; ok {
		return line.method == .Head
	}
	return false
}

// Truncate wire buffer to the HTTP heading only (end of header block). Used for HEAD
// on body_reserve / chunked paths where the body was already written into _buf.
@(private)
_response_strip_body_keep_heading :: proc(r: ^Response) {
	buf := r._buf.buf[:]
	// Responses we format always end the header block with \r\n\r\n.
	for i := 0; i + 3 < len(buf); i += 1 {
		if buf[i] == '\r' && buf[i + 1] == '\n' && buf[i + 2] == '\r' && buf[i + 3] == '\n' {
			resize(&r._buf.buf, i + 4)
			return
		}
	}
	// Malformed / empty: leave buffer alone rather than invent a strip point.
}

// True when wire send may use plan_body (Writev multi-buffer / Sendfile stream)
// instead of materialize-only.
// Safe default false: Server_Opts.plan_optimize opt-in (Default_Server_Opts = false).
// Also true per-request when Handler_Profile.prefer_gather or prefer_sendfile is set —
// that alone enables optimize wire even if the server left plan_optimize off.
@(private)
_response_wire_use_optimize :: proc(r: ^Response) -> bool {
	if r == nil {
		return false
	}
	if r._profile.prefer_gather || r._profile.prefer_sendfile {
		return true
	}
	if r._conn != nil && r._conn.server != nil && r._conn.server.opts.plan_optimize {
		return true
	}
	return false
}

// Phase 3: plan is a pure Writev (memory bodies only) that the multi-buffer executor can run.
// Sendfile / Copy_Into / multi-op / unknown → false (caller materializes or uses file path).
@(private)
_plan_is_writev_wire :: proc(plan: Plan_Result) -> bool {
	if plan.materialized || plan.op_count != 1 {
		return false
	}
	if plan.ops[0].kind != .Writev {
		return false
	}
	// Body iovecs must fit Wire_State.exec_bufs (heading + bodies).
	if int(plan.ops[0].iov_count) + 1 > PLAN_MAX_EXEC_BUFS {
		return false
	}
	return true
}

// Phase 4: plan ends with Sendfile and optional Write_Slice/Writev prefix (headers / mem).
// Known file length required. Caller streams file; does not full-materialize into resp_buf.
@(private)
_plan_is_sendfile_wire :: proc(plan: Plan_Result) -> bool {
	if plan.materialized || plan.op_count < 1 {
		return false
	}
	last := plan.ops[plan.op_count - 1]
	if last.kind != .Sendfile {
		return false
	}
	if last.file_length < 0 {
		return false
	}
	// Prefix ops: only Write_Slice (headers) and/or Writev (headers+mem).
	for i in 0 ..< plan.op_count - 1 {
		k := plan.ops[i].kind
		if k != .Write_Slice && k != .Writev {
			return false
		}
	}
	return true
}

// Sum known Static/Bytes lengths; false if any File or unknown length.
@(private)
_cmds_mem_body_len :: proc(cmds: []Response_Cmd) -> (body_len: int, ok: bool) {
	body_len = 0
	for c in cmds {
		switch c.kind {
		case .Static, .Bytes:
			n := len(c.bytes)
			if i64(body_len) + i64(n) > i64(max(int)) {
				return 0, false
			}
			body_len += n
		case .File:
			return 0, false
		}
	}
	return body_len, true
}

// Phase 3 Writev wire: heading in resp_buf; body slices borrowed from cmds.
// Prefers Linux IORING_OP_WRITEV (plan_wire_kernel_writev); falls back to sequential
// multi-buffer submit_send (plan_wire_multi_send) when kernel path is unavailable.
// Returns true if the send was submitted (or cleaned for empty). Caller must not
// also materialize. On false, heading was not written — caller may materialize.
//
// LIFETIME: body slices are NOT copied. Data behind Static/Bytes must remain valid
// until the final send CQE (after respond returns). Safe: string literals, #load,
// request temp_allocator (reset only in clean_request_loop after send completes).
// UNSAFE: stack buffers, heap freed by the handler after respond — use materialize
// (plan_optimize off) or copy into resp_buf / temp before body_*.
@(private)
_response_send_writev :: proc(r: ^Response, cmds: []Response_Cmd) -> bool {
	assert(!r._heading_written)
	assert(len(cmds) > 0)
	conn := r._conn
	assert(conn != nil)

	body_len, ok := _cmds_mem_body_len(cmds)
	if !ok {
		return false
	}

	// Collect non-empty body slices (empty Static is a no-op on the wire).
	bodies: [PLAN_MAX_BODY_CMDS][]u8
	n_body := 0
	for c in cmds {
		if (c.kind == .Static || c.kind == .Bytes) && len(c.bytes) > 0 {
			if n_body >= PLAN_MAX_BODY_CMDS {
				return false
			}
			// Borrowed until final send CQE; see LIFETIME comment above.
			bodies[n_body] = c.bytes
			n_body += 1
		}
	}
	// heading + bodies must fit fixed exec_bufs.
	if 1 + n_body > PLAN_MAX_EXEC_BUFS {
		return false
	}

	t0_build: u64
	when HTTP_PHASE_STATS {
		t0_build = phase_now()
	}

	_response_write_heading(r, body_len)

	// HEAD: headers + Content-Length only; do not queue body slices (RFC 9110 §9.3.2).
	// Mechanism is single-buffer (exec_n=0) — count materialize, not writev.
	if _response_is_head(conn) {
		when HTTP_PHASE_STATS {
			phase_add(0, 0, 0, 0, 0, phase_now() - t0_build, 0)
		}
		conn.resp_buf = r._buf.buf
		buf := bytes.buffer_to_bytes(&r._buf)
		if len(buf) == 0 {
			// First arm only: HEAD headers path (single buffer / empty).
			plan_wire_inc_materialize()
			clean_request_loop(conn)
			return true
		}
		conn.wire.exec_n = 0
		conn.wire.exec_i = 0
		conn.wire.pending_send = buf
		if err := host_submit_send(conn); err != .None {
			_wire_fail(conn, "submit_send failed: %v", err)
			return true
		}
		// First arm only: HEAD is headers-only single buffer.
		plan_wire_inc_materialize()
		return true
	}

	conn.resp_buf = r._buf.buf
	heading := bytes.buffer_to_bytes(&r._buf)

	when HTTP_PHASE_STATS {
		phase_add(0, 0, 0, 0, 0, phase_now() - t0_build, 0)
	}

	if !_conn_arm_mem_queue(conn, heading, bodies[:n_body]) {
		// Degenerate: nothing to send (empty heading + empty bodies).
		_conn_clear_exec(conn)
		// First arm only: empty multi_send path.
		plan_wire_inc_multi_send()
		clean_request_loop(conn)
		return true
	}

	mech, submit_ok := _conn_submit_mem_queue(conn)
	if !submit_ok {
		_wire_fail(conn, "mem queue submit failed fd=%v", conn.socket)
		return true
	}
	// First arm only: count which mechanism was armed (not mid-stream fallback).
	switch mech {
	case .Kernel_Writev:
		plan_wire_inc_kernel_writev()
	case .Multi_Send:
		plan_wire_inc_multi_send()
	case .None:
		// Unreachable when submit_ok.
	}
	return true
}

// Phase 4 Sendfile wire: heading (+ optional mem Writev) then kernel sendfile(2)
// or chunked pread+send of the file region. Does NOT load the full file into resp_buf.
// Counters: plan_wire_sendfile (kernel) or plan_wire_copy_into (chunked fallback),
// plus kernel_writev/multi_send when a mem prefix is gathered.
// Returns true if path handled the response (submitted / cleaned / closed).
// false → heading not written; caller may materialize.
//
// Ownership: File fd in cmds must stay open until final CQE (handler/app owns fd).
@(private)
_response_send_file_region :: proc(r: ^Response, cmds: []Response_Cmd, plan: Plan_Result) -> bool {
	assert(!r._heading_written)
	assert(len(cmds) > 0)
	assert(_plan_is_sendfile_wire(plan))
	conn := r._conn
	assert(conn != nil)

	// Locate the single file op (last Sendfile).
	sf := plan.ops[plan.op_count - 1]
	assert(sf.kind == .Sendfile)
	if sf.file_length < 0 {
		return false
	}

	// Body length for Content-Length = sum of known mem + file.
	body_len: int
	if plan.total_body < 0 {
		return false
	}
	if i64(int(plan.total_body)) != plan.total_body {
		log.errorf("file region body length does not fit int: %d", plan.total_body)
		return false
	}
	body_len = int(plan.total_body)

	// Collect non-empty mem body slices for optional Writev prefix.
	bodies: [PLAN_MAX_BODY_CMDS][]u8
	n_mem_body := 0
	for c in cmds {
		if (c.kind == .Static || c.kind == .Bytes) && len(c.bytes) > 0 {
			if n_mem_body >= PLAN_MAX_BODY_CMDS {
				return false
			}
			bodies[n_mem_body] = c.bytes
			n_mem_body += 1
		}
	}
	// heading + mem bodies must fit exec_bufs when mixed.
	if 1 + n_mem_body > PLAN_MAX_EXEC_BUFS {
		return false
	}

	t0_build: u64
	when HTTP_PHASE_STATS {
		t0_build = phase_now()
	}

	_response_write_heading(r, body_len)

	// Owned File cmds: transfer close to wire when streaming; close immediately on HEAD.
	file_owned := false
	for c in cmds {
		if c.kind == .File && c.fd == sf.fd && .Owned in c.flags {
			file_owned = true
			break
		}
	}

	// HEAD: headers + Content-Length only; do not stream file (RFC 9110 §9.3.2).
	if _response_is_head(conn) {
		when HTTP_PHASE_STATS {
			phase_add(0, 0, 0, 0, 0, phase_now() - t0_build, 0)
		}
		if file_owned {
			_response_close_owned_file_cmds(cmds)
		}
		conn.resp_buf = r._buf.buf
		buf := bytes.buffer_to_bytes(&r._buf)
		_conn_clear_file_send(conn)
		conn.wire.exec_n = 0
		conn.wire.exec_i = 0
		if len(buf) == 0 {
			// First arm only: file HEAD empty body.
			plan_wire_inc_materialize()
			clean_request_loop(conn)
			return true
		}
		conn.wire.pending_send = buf
		if err := host_submit_send(conn); err != .None {
			_wire_fail(conn, "submit_send (file HEAD) failed: %v", err)
			return true
		}
		// First arm only: HEAD is headers-only single buffer, not file stream.
		plan_wire_inc_materialize()
		return true
	}

	// Zero-length file: headers only (or headers + mem with empty file).
	conn.resp_buf = r._buf.buf
	heading := bytes.buffer_to_bytes(&r._buf)

	// Arm file-region state (even for length 0 so finish path is uniform).
	conn.wire.file_send_fd = sf.fd
	conn.wire.file_send_off = sf.file_offset
	conn.wire.file_send_remaining = sf.file_length
	conn.wire.file_send_close = file_owned
	// Zero-length file: clear immediately after arming if no body to stream.
	// Keep fd marker only while remaining > 0 OR we still need post-header continue.
	if sf.file_length == 0 {
		// No file bytes; still may have mem prefix. Clear file cursor (closes if owned).
		_conn_clear_file_send(conn)
	}

	// Build optional mem prefix queue: [heading, mem…] then file stream after exec finishes.
	has_writev_prefix := false
	for i in 0 ..< plan.op_count - 1 {
		if plan.ops[i].kind == .Writev {
			has_writev_prefix = true
			break
		}
	}

	when HTTP_PHASE_STATS {
		phase_add(0, 0, 0, 0, 0, phase_now() - t0_build, 0)
	}

	if has_writev_prefix || n_mem_body > 0 {
		// Mixed: gather heading + mem, then file region after exec finishes.
		if !_conn_arm_mem_queue(conn, heading, bodies[:n_mem_body]) {
			// No mem/heading bytes — start file immediately if any.
			conn.wire.exec_n = 0
			conn.wire.exec_i = 0
			_ = _conn_file_region_start_or_finish(conn)
			// _conn_file_region_start_or_finish counts sendfile or copy_into (or clean).
			return true
		}
		mech, submit_ok := _conn_submit_mem_queue(conn)
		if !submit_ok {
			_wire_fail(conn, "submit_send (file prefix) failed fd=%v", conn.socket)
			return true
		}
		// First arm only: mem-prefix mechanism (file body counted later at file arm).
		switch mech {
		case .Kernel_Writev:
			plan_wire_inc_kernel_writev()
		case .Multi_Send:
			plan_wire_inc_multi_send()
		case .None:
		}
		return true
	}

	// Pure file: send heading first, then kernel sendfile or chunked on host_on_wire.
	conn.wire.exec_n = 0
	conn.wire.exec_i = 0
	if len(heading) == 0 {
		// Degenerate headers empty — start file or finish (counts sendfile/copy_into).
		_ = _conn_file_region_start_or_finish(conn)
		return true
	}

	conn.wire.pending_send = heading
	// file_send_remaining already set; after heading CQE, host_on_wire starts file region.
	if err := host_submit_send(conn); err != .None {
		_wire_fail(conn, "submit_send (file headers) failed: %v", err)
		return true
	}
	// File mechanism (sendfile or copy_into) counted on first file arm after heading CQE.
	// No early copy_into here — avoids lying when kernel sendfile wins.
	return true
}

// Materialize cmds into _buf as one Write_Slice payload (Phase 1–3 fallback).
// Not used when body_reserve / response_writer already wrote the heading into _buf.
//
// Hot path (TFB plaintext/size ladder): single Static/Bytes with known length —
// one exact buffer grow, heading into resp_buf, one body memcpy. Skips
// plan_body_materialize_only + buffer_write bookkeeping tax.
@(private)
_response_materialize_cmds :: proc(r: ^Response) {
	assert(!r._heading_written)
	assert(r._cmd_count > 0)

	cmds := r._cmds[:r._cmd_count]

	// Fast path: single Static/Bytes body, small/medium only.
	// Large bodies (e.g. 1MiB) keep the classic grow+buffer_write path — bastion
	// measured a s1m RPS regression with exact-size resize+copy under multi-worker load.
	MATERIALIZE_FAST_MAX :: 256 * 1024
	if r._cmd_count == 1 {
		c := cmds[0]
		if (c.kind == .Static || c.kind == .Bytes) && len(c.bytes) <= MATERIALIZE_FAST_MAX {
			body_len := len(c.bytes)
			t0_build: u64
			when HTTP_PHASE_STATS {
				t0_build = phase_now()
			}
			hscratch: [512]byte
			hlen := _response_format_heading(r, body_len, hscratch[:])
			assert(hlen > 0 && hlen <= len(hscratch))
			need := hlen + body_len
			if cap(r._buf.buf) < need {
				reserve(&r._buf.buf, need)
			}
			resize(&r._buf.buf, need)
			copy(r._buf.buf[0:hlen], hscratch[:hlen])
			r._heading_written = true
			if !_response_is_head(r._conn) && body_len > 0 {
				copy(r._buf.buf[hlen:][:body_len], c.bytes)
			} else if _response_is_head(r._conn) {
				resize(&r._buf.buf, hlen)
			}
			when HTTP_PHASE_STATS {
				phase_add(0, 0, 0, 0, 0, phase_now() - t0_build, 0)
			}
			return
		}
	}

	plan := plan_body_materialize_only(cmds)
	assert(plan.materialized && plan.op_count == 1 && plan.ops[0].kind == .Write_Slice)

	// Content-Length: sum of known lengths. Materialize requires known body size.
	// Validate *before* writing the heading so a bad File.length cannot emit a wrong CL
	// and then assert mid-materialize (or worse under -disable-assert).
	body_len: int
	assert(plan.total_body >= 0, "materialize requires known body length (set File.length)")
	// Prefer recompute from cmds so a planner bug cannot poison CL.
	body_len = 0
	for c in cmds {
		n, ok := cmd_known_length(c)
		assert(ok, "materialize requires known body length (set File.length)")
		assert(n >= 0)
		// Overflow guard: body must fit in int (buffer length).
		assert(i64(body_len) + n <= i64(max(int)))
		body_len += int(n)
	}
	assert(i64(body_len) == plan.total_body, "plan total_body mismatch vs cmd lengths")

	t0_build: u64
	when HTTP_PHASE_STATS {
		t0_build = phase_now()
	}

	_response_write_heading(r, body_len)

	// HEAD: headers + Content-Length only; do not copy/read body (RFC 9110 §9.3.2).
	// Close Owned File cmds immediately — no stream/materialize read will take ownership.
	if _response_is_head(r._conn) {
		_response_close_owned_file_cmds(cmds)
		when HTTP_PHASE_STATS {
			phase_add(0, 0, 0, 0, 0, phase_now() - t0_build, 0)
		}
		return
	}

	for c in cmds {
		switch c.kind {
		case .Static, .Bytes:
			bytes.buffer_write(&r._buf, c.bytes)
		case .File:
			_response_materialize_file(r, c)
		}
	}

	when HTTP_PHASE_STATS {
		phase_add(0, 0, 0, 0, 0, phase_now() - t0_build, 0)
	}
}

// Close File cmds marked Owned (after HEAD headers-only or failed arm before wire transfer).
@(private)
_response_close_owned_file_cmds :: proc(cmds: []Response_Cmd) {
	when ODIN_OS != .Windows {
		for c in cmds {
			if c.kind == .File && .Owned in c.flags && c.fd >= 0 {
				_ = posix.close(posix.FD(c.fd))
			}
		}
	}
}

// Public: abandon staged body cmds that own File fds without transferring to the wire.
// Clears the response cmd buffer. Used by middleware tests and callers that prepare then cancel.
response_close_owned_body_files :: proc(r: ^Response) {
	if r == nil || r._cmd_count == 0 {
		return
	}
	_response_close_owned_file_cmds(r._cmds[:r._cmd_count])
	r._cmd_count = 0
}

// Introspection for tests / advanced middleware (body cmd buffer is otherwise private).
response_body_cmd_count :: proc(r: ^Response) -> int {
	if r == nil {
		return 0
	}
	return r._cmd_count
}

response_body_cmd :: proc(r: ^Response, i: int) -> (cmd: Response_Cmd, ok: bool) {
	if r == nil || i < 0 || i >= r._cmd_count {
		return {}, false
	}
	return r._cmds[i], true
}

response_prefer_sendfile :: proc(r: ^Response) -> bool {
	return r != nil && r._profile.prefer_sendfile
}

// Sync pread of a File cmd region into the response wire buffer (Phase 1 only).
// fd must remain open and the region readable until this returns (send copies into resp_buf).
// Owned fds are always closed before return (success, empty region, or error) so a failed
// Sendfile-wire → materialize fallback cannot leak static middleware fds.
@(private)
_response_materialize_file :: proc(r: ^Response, cmd: Response_Cmd) {
	assert(cmd.kind == .File)
	assert(cmd.length >= 0, "Phase 1 file materialize needs known length")
	// Guard against -disable-assert + length=-1 (int(-1) would grow absurdly / UB).
	if cmd.length < 0 {
		log.errorf("body_file materialize rejected unknown length (fd=%d)", cmd.fd)
		// Still close Owned so callers cannot leak on bad length.
		if .Owned in cmd.flags && cmd.fd >= 0 {
			when ODIN_OS != .Windows {
				_ = posix.close(posix.FD(cmd.fd))
			}
		}
		return
	}
	n := int(cmd.length)
	owned := .Owned in cmd.flags
	fd := cmd.fd
	// Close Owned once on every exit path (including assert failure under -disable-assert).
	defer {
		if owned && fd >= 0 {
			when ODIN_OS != .Windows {
				_ = posix.close(posix.FD(fd))
			}
		}
	}
	if n == 0 {
		return
	}
	// length that does not fit int (32-bit hosts / huge files): refuse.
	if i64(n) != cmd.length {
		log.errorf("body_file materialize length does not fit int: %d", cmd.length)
		assert(false, "file body length too large for materialize buffer")
		return
	}

	bytes.buffer_grow(&r._buf, n)
	dst := _dynamic_unwritten(r._buf.buf)
	assert(len(dst) >= n)

	when ODIN_OS == .Windows {
		// Host HTTP path is POSIX/Linux; Windows ring exists but this host is not wired.
		// Avoid referencing posix.pread (not available). Fail closed rather than wrong data.
		_ = dst
		log.errorf("body_file materialize: pread not available on Windows (fd=%d)", cmd.fd)
		assert(false, "body_file materialize unsupported on Windows in Phase 1")
		return
	} else {
		total := 0
		off := cmd.offset
		for total < n {
			got := posix.pread(
				posix.FD(cmd.fd),
				raw_data(dst[total:n]),
				c.size_t(n - total),
				posix.off_t(off),
			)
			if got < 0 {
				if posix.errno() == .EINTR {
					continue
				}
				log.errorf("body_file materialize pread failed: %v", posix.errno())
				assert(false, "file body pread failed during materialize")
				return
			}
			if got == 0 {
				assert(false, "file body short/EOF during materialize")
				return
			}
			total += int(got)
			off += i64(got)
		}
		_dynamic_add_len(&r._buf.buf, n)
	}
}

@(private)
response_send_got_body :: proc(r: ^Response, will_close: bool) {
	conn := r._conn

	if will_close {
		if !connection_set_state(r._conn, .Will_Close) { return }
	}

	// Middleware on_respond (LIFO): status is final (including body-discard errors).
	// Hooks must not call respond. One-shot clear inside fire.
	_response_fire_respond_hooks(r)

	// PR8 H2 oneshot: never assemble H1 status-line / Content-Length wire.
	// Body middleware runs; h2_host maps status/headers/body → HPACK + DATA.
	if conn != nil && conn.h2_active {
		if r._streaming {
			assert(r._stream_ended, "stream_end required before respond when streaming")
		}
		if r._cmd_count > 0 {
			_response_apply_body_middleware(r)
		}
		h2_host_send_response(conn, r)
		return
	}

	// Wire assembly (Phase 3–5):
	//  1) Heading already written (body_reserve / Response_Writer / Response_Stream)
	//     → single-buffer send as-is (stream path does not use plan_body).
	//  2) Body cmds → middleware → plan (optimize when plan_optimize|prefer_gather|prefer_sendfile):
	//       pure Writev          → kernel WRITEV (Linux) or multi-buffer sequential sends
	//       Write_Slice+Sendfile → heading then kernel sendfile or chunked pread stream
	//       else                 → materialize into resp_buf + one Write_Slice
	//  3) Empty buffer, no cmds → heading with Content-Length 0.
	// HEAD: headers only (no file/body stream).
	// Stream: begin_stream freezes heading; stream_end must finish before respond.
	if r._streaming {
		assert(r._stream_ended, "stream_end required before respond when streaming")
	}
	if !r._heading_written {
		if r._cmd_count > 0 {
			_response_apply_body_middleware(r)
		}
		if r._cmd_count > 0 {
			cmds := r._cmds[:r._cmd_count]
			used_opt := false
			// Ciphered: materialize only — no Writev/Sendfile (PT must pass SSL_write).
			if _response_wire_use_optimize(r) && !(conn != nil && conn.ciphered) {
				plan := plan_body(cmds, plan_policy(r))
				// Kernel/multi gather only pays off for ≥2 body segments (assembled).
				// Single Static+heading writev crashed under load on bastion — materialize.
				n_mem := 0
				for c in cmds {
					if c.kind == .Static || c.kind == .Bytes {
						if len(c.bytes) > 0 {
							n_mem += 1
						}
					}
				}
				if _plan_is_writev_wire(plan) && n_mem >= 2 {
					if _response_send_writev(r, cmds) {
						used_opt = true
					}
				} else if _plan_is_sendfile_wire(plan) {
					if _response_send_file_region(r, cmds, plan) {
						used_opt = true
					}
				}
			}
			if used_opt {
				return
			}
			_response_materialize_cmds(r)
			// First arm only: full materialize into single pending_send.
			plan_wire_inc_materialize()
		} else if bytes.buffer_length(&r._buf) == 0 {
			_response_write_heading(r, 0)
		}
	} else if _response_is_head(conn) {
		// body_reserve / response_writer already put body bytes in _buf — drop them for HEAD.
		_response_strip_body_keep_heading(r)
	}

	// Single-buffer path: full response in resp_buf, one pending_send.
	// Do NOT reset scrap arena or drop resp_buf while pending_send still points
	// at response bytes (host_on_wire clears pending_send before clean_request_loop).
	// Sync growth: r._buf.buf is a header copy that may reallocate on write.
	// Explicitly inactive multi-op queue so a prior writev path cannot leak exec_n.
	_conn_clear_exec(conn)
	conn.resp_buf = r._buf.buf
	buf := bytes.buffer_to_bytes(&r._buf)
	if len(buf) == 0 {
		clean_request_loop(conn)
		return
	}

	// PR5 ciphered: window plain through SSL_write → CT drain → multi-CQE send.
	// Clear-H1: single host_submit_send of full body.
	if conn.ciphered && conn.tls_ssl != nil {
		conn.tls_plain_rest = buf
		tls_host_flush_response(conn)
		return
	}

	conn.wire.pending_send = buf
	if err := host_submit_send(conn); err != .None {
		// No CQE will clear this; leaving wire.kind set would make connection_close
		// defer forever (close_on_io).
		_wire_fail(conn, "submit_send failed: %v", err)
	}
}

// Response has been sent, clean up and close/handle next.
// Invariant: pending_send / exec queue already cleared (host_on_wire path).
@(private)
clean_request_loop :: proc(conn: ^Connection, close: Maybe(bool) = nil) {
	t0_reset: u64
	when HTTP_PHASE_STATS {
		t0_reset = phase_now()
	}
	context.temp_allocator = virtual.arena_allocator(&conn.temp_allocator)

	// Middleware on_complete (LIFO): wire done, request arena still live.
	_response_fire_complete_hooks(&conn.slot.res)

	// Ensure multi-buffer / file-send queue is inactive before reusing conn.
	// Must nil exec_bufs (not only exec_n) so keep-alive cannot retain dangling
	// body/heading slice refs across temp reset / next request.
	_conn_clear_exec(conn)

	// Progressive stream + session markers (D0/D1). Session should already be
	// destroyed in _stream_finish; clear residual state for keep-alive reuse.
	conn.slot.stream_open = false
	conn.slot.stream_ending = false
	conn.slot.stream_sent = 0
	conn.slot.stream_flush_pending = false
	conn.slot.stream_respond_fired = false
	conn.slot.stream_send_slab = nil
	conn.slot.stream_send_len = 0
	conn.slot.stream_pin_armed = false
	conn.tls_stream_plain_n = 0
	// Do not free session here — _stream_finish / connection_close own that.
	// Orphan sse_alloc pad (no session): free so keep-alive does not hold heap.
	if conn.slot.session == nil {
		stream_slot_free_pad(&conn.slot)
	}

	// Request scrap: reset or re-attach if session detach returned the slot.
	if conn.temp_slot < 0 {
		_ = conn_temp_attach(conn)
	} else {
		conn_temp_reset(conn)
	}
	when HTTP_PHASE_STATS {
		phase_add(0, 0, 0, 0, 0, 0, phase_now() - t0_reset)
	}

	// Pool-aware reset: restore full RECV window (incl. non-pooled opts.recv_buf_size).
	scanner_prepare(conn)

	client := conn.loop.req.client
	conn.loop.req = {}
	conn.loop.req.client = client

	// Keep permanent response capacity; drop only request-scoped Response fields.
	// Sync any growth that happened after last explicit sync (empty body path, etc.).
	if conn.slot.res._buf.buf != nil {
		conn.resp_buf = conn.slot.res._buf.buf
	}
	clear(&conn.resp_buf)
	conn.slot.res = {}

	if c, ok := close.?; (ok && c) || conn.state == .Will_Close {
		connection_close(conn)
	} else {
		if !connection_set_state(conn, .Idle) { return }
		conn_handle_req(conn, context.temp_allocator)
	}
}

// A server MUST NOT send a Content-Length header field in any response
// with a status code of 1xx (Informational) or 204 (No Content).  A
// server MUST NOT send a Content-Length header field in any 2xx
// (Successful) response to a CONNECT request.
@(private)
response_needs_content_length :: proc(r: ^Response, conn: ^Connection) -> bool {
	if status_is_informational(r.status) || r.status == .No_Content {
		return false
	}

	if status_is_success(r.status) {
		line, _ := conn.loop.req.line.?
		if line.method == .Connect {
			return false
		}
	}

	return true
}

// Determines if the connection needs to be closed after sending the response.
@(private)
response_must_close :: proc(req: ^Request, res: ^Response) -> bool {
	// If the request we are responding to indicates it is closing the connection, close our side too.
	if req, req_has := headers_get_unsafe(req.headers, "connection"); req_has && req == "close" {
		return true
	}

	// If we are responding with a close connection header, make sure we close.
	if res, res_has := headers_get_unsafe(res.headers, "connection"); res_has && res == "close" {
		return true
	}

	// If the body was tried to be received, but failed, close.
	if body_ok, got_body := req._body_ok.?; got_body && !body_ok {
		headers_set_close(&res.headers)
		return true
	}

	// If the connection's state indicates closing, close.
	if res._conn.state >= .Will_Close {
		headers_set_close(&res.headers)
		return true
	}

	// HTTP 1.0 does not have persistent connections.
	line := req.line.?
	if line.version == {1, 0} {
		return true
	}

	return false
}
