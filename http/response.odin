package http

import "core:bytes"
import "core:c"
import "core:io"
import "core:log"
import "core:mem/virtual"
import "core:slice"
import "core:strconv"
import "core:strings"
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
	// Phase 5: Response_Stream path (mutually exclusive with body cmds / body_reserve).
	// Body middleware does NOT run on stream data; rewrite headers before begin_stream.
	_streaming:       bool,
	_stream_ended:    bool,
}

// response_init binds r to c.resp_buf (permanent, conn_allocator). Request temp
// arena is scrap only — never backs the response wire buffer.
// Capacity is retained across keep-alive requests; len is cleared each request.
@(private)
response_init :: proc(r: ^Response, c: ^Connection, allocator := context.allocator) {
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
	r._conn = c
	r.cookies = {}
	r.cookies.allocator = allocator
	headers_init(&r.headers, allocator)

	// Ensure permanent buffer has initial capacity; keep any grown capacity.
	// Size from Server_Opts.resp_buf_initial (resolved at listen; default HOST_RESP_BUF_INITIAL).
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
// Zero profile: server copy/iovec defaults; prefer_sendfile remains opt-in (see Handler_Profile).
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

// Base Plan_Context from connection/server/backend (no handler profile).
// Safe with nil conn (pure defaults + platform sendfile when POSIX).
// Safe off worker thread: thread-local td is nil → fixed_files stays false (no ring touch).
plan_context_for :: proc(conn: ^Connection) -> Plan_Context {
	ctx := plan_context_default()

	// Platform: plain TCP sendfile is OK on Linux/Darwin (no TLS in host yet).
	when ODIN_OS == .Linux || ODIN_OS == .Darwin {
		ctx.sendfile_ok = true
	} else {
		ctx.sendfile_ok = false
	}

	if conn != nil && conn.server != nil {
		opts := conn.server.opts
		if opts.plan_max_iovecs > 0 {
			ctx.max_iovecs = opts.plan_max_iovecs
		}
		// 0 → PLAN_DEFAULT_COPY_BUDGET (already in plan_context_default).
		if opts.plan_copy_budget > 0 {
			ctx.preferred_copy_budget = opts.plan_copy_budget
		}
		// plan_sendfile_ok: Default_Server_Opts true on posix; false disables.
		// Non-posix remains false from the when above.
		// Note: prefer_sendfile on the Response is still required for sendfile_ok after profile apply.
		when ODIN_OS == .Linux || ODIN_OS == .Darwin {
			ctx.sendfile_ok = opts.plan_sendfile_ok
		}
	}

	// fixed_files: registered fd table on this worker's proactr ring.
	// Field read only (no SQE). Only while the ring is live for handlers (Running/Closing).
	// Off-worker / tests: td is nil → leave false. Avoids Cleaning/Closed after ring_destroy.
	if td != nil && (td.state == .Running || td.state == .Closing) {
		ctx.fixed_files = proactr.ring_has_fixed_files(&td.ring)
	}

	// No TLS path yet; zero-copy send unknown.
	ctx.tls = false
	ctx.zero_copy_send = false
	return ctx
}

// Live Plan_Context for advanced handlers: server/conn/backend + Response profile bias.
// Response._profile is request-scoped (cleared in response_init); not atomic — same
// single-worker-per-conn model as the rest of Response.
plan_context :: proc(r: ^Response) -> Plan_Context {
	conn: ^Connection
	profile: Handler_Profile
	if r != nil {
		conn = r._conn
		profile = r._profile
	}
	return plan_context_apply_profile(plan_context_for(conn), profile)
}

// Optimize-policy plan for tests/handlers (shadow of what plan_optimize wire would choose).
// Applies body middleware to a *snapshot* of cmds (does not mutate Response; send applies once).
// Wire path uses plan_body when plan_optimize / prefer_gather; otherwise materialize-only.
response_plan_preview :: proc(r: ^Response) -> Plan_Result {
	if r == nil {
		return plan_body({}, plan_context(r))
	}
	ctx := plan_context(r)
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
// Ownership: the caller must keep `fd` open and the region readable until the response
// send fully completes (final send CQE / clean_request_loop). The host never closes the
// fd. With plan_optimize + prefer_sendfile the wire path streams via chunked pread
// (Phase 4); otherwise materialize preads the full region into resp_buf at send time.
// length must be known (>= 0) for both paths.
body_file :: proc(r: ^Response, fd: i32, offset: i64, length: i64, loc := #caller_location) {
	_response_append_cmd(r, cmd_file(fd, offset, length), loc)
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
// Phase 5: Response_Stream — SSE / long-lived chunked bodies (NOT Response_Cmd)
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
// Pragmatic Phase 5 wire model:
//   - Transfer-Encoding: chunked; heading written once at begin
//   - stream_write appends framed chunks into resp_buf
//   - stream_flush is a no-op coalesce point (no mid-body CQE submit yet)
//   - stream_end writes the final 0-chunk and submit_send once (same single-shot
//     path as body_reserve / Response_Writer)
// True continuous flush-to-wire / multi-CQE mid-body is a follow-up.
// plan_wire_* counters are not incremented; stream_responses_total is.

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
Do not call body_set after begin_stream. stream_end calls respond — do not respond again.
*/
response_begin_stream :: proc(r: ^Response, loc := #caller_location) -> Response_Stream {
	assert(!r.sent, "response has already been sent", loc)
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
stream_write :: proc(s: ^Response_Stream, data: []byte, loc := #caller_location) {
	assert(s != nil && s.r != nil, "nil Response_Stream", loc)
	assert(!s.ended && !s.r._stream_ended, "stream already ended", loc)
	assert(s.r._streaming, "stream not started", loc)
	assert(!s.r.sent, "response has already been sent", loc)
	if len(data) == 0 {
		return
	}
	_http_write_chunk(&s.r._buf, data)
}

/*
Flush checkpoint for streaming.

Phase 5 pragmatic: no-op. Chunks already live in resp_buf; stream_end submits
once. Future: may submit pending_send of current buffer when nothing in-flight.
*/
stream_flush :: proc(s: ^Response_Stream, loc := #caller_location) {
	assert(s != nil && s.r != nil, "nil Response_Stream", loc)
	assert(!s.ended && !s.r._stream_ended, "stream already ended", loc)
	assert(s.r._streaming, "stream not started", loc)
	assert(!s.r.sent, "response has already been sent", loc)
	// Coalesce only — no mid-body CQE submit in Phase 5.
}

/*
Finish the stream: final 0-chunk, then respond (single-buffer send).

stream_end *is* the send — do not call respond again (second respond asserts).
A second stream_end asserts on s.ended / r._stream_ended.

HEAD: body bytes may already be in the buffer; response_send strips them and
keeps the heading (same as Response_Writer / body_reserve).

Increments stream_responses_total (not plan_wire_*) once per successful end.
*/
stream_end :: proc(s: ^Response_Stream, loc := #caller_location) {
	assert(s != nil && s.r != nil, "nil Response_Stream", loc)
	assert(!s.ended && !s.r._stream_ended, "stream already ended", loc)
	assert(s.r._streaming, "stream not started", loc)
	assert(!s.r.sent, "response has already been sent", loc)

	_http_write_chunk_end(&s.r._buf)
	// Mark ended before respond so a re-entrant / mistaken second end fails
	// closed, and so response_send_got_body sees _stream_ended.
	s.ended = true
	s.r._stream_ended = true
	stream_inc_responses()
	respond(s.r, loc)
}

// stream_close is an alias for stream_end.
stream_close :: stream_end

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
	// Body iovecs must fit Connection.exec_bufs (heading + bodies).
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

// Phase 3 Writev-style wire: heading in resp_buf; body slices borrowed from cmds.
// Builds conn.exec_bufs = [heading, body1, …] and submits the first send.
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

	// Count non-empty body slices for the queue (empty Static is a no-op on the wire).
	n_body := 0
	for c in cmds {
		if (c.kind == .Static || c.kind == .Bytes) && len(c.bytes) > 0 {
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
			plan_wire_inc_materialize()
			clean_request_loop(conn)
			return true
		}
		conn.exec_n = 0
		conn.exec_i = 0
		conn.pending_send = buf
		if err := host_submit_send(conn); err != .None {
			log.errorf("submit_send failed: %v", err)
			conn.pending_send = nil
			connection_close(conn)
			return true
		}
		plan_wire_inc_materialize()
		return true
	}

	conn.resp_buf = r._buf.buf
	heading := bytes.buffer_to_bytes(&r._buf)
	if len(heading) == 0 && n_body == 0 {
		// Degenerate: nothing to send.
		_conn_clear_exec(conn)
		plan_wire_inc_writev()
		clean_request_loop(conn)
		when HTTP_PHASE_STATS {
			phase_add(0, 0, 0, 0, 0, phase_now() - t0_build, 0)
		}
		return true
	}

	// Build multi-buffer queue: [heading, body…] (skip empty heading only if bodies remain).
	bi := 0
	if len(heading) > 0 {
		conn.exec_bufs[0] = heading
		bi = 1
	}
	for c in cmds {
		#partial switch c.kind {
		case .Static, .Bytes:
			if len(c.bytes) == 0 {
				continue
			}
			// Borrowed until final send CQE; see LIFETIME comment above.
			conn.exec_bufs[bi] = c.bytes
			bi += 1
		}
	}
	conn.exec_n = bi
	conn.exec_i = 0

	// Skip leading empty buffers.
	for conn.exec_i < conn.exec_n && len(conn.exec_bufs[conn.exec_i]) == 0 {
		conn.exec_i += 1
	}
	if conn.exec_i >= conn.exec_n {
		_conn_clear_exec(conn)
		plan_wire_inc_writev()
		clean_request_loop(conn)
		when HTTP_PHASE_STATS {
			phase_add(0, 0, 0, 0, 0, phase_now() - t0_build, 0)
		}
		return true
	}

	conn.pending_send = conn.exec_bufs[conn.exec_i]
	if len(conn.pending_send) == 0 {
		// Should be unreachable after skip; fail closed (no CQE hang).
		_conn_clear_exec(conn)
		connection_close(conn)
		return true
	}

	when HTTP_PHASE_STATS {
		phase_add(0, 0, 0, 0, 0, phase_now() - t0_build, 0)
	}

	if err := host_submit_send(conn); err != .None {
		log.errorf("submit_send (writev queue) failed: %v", err)
		_conn_clear_exec(conn)
		connection_close(conn)
		return true
	}
	// Count only after a real SQE is posted (or empty complete above).
	plan_wire_inc_writev()
	return true
}

// Phase 4 Sendfile wire: heading (+ optional mem Writev) then chunked pread+send of file.
// Does NOT load the full file into resp_buf. Counts plan_wire_copy_into (portable stream).
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

	// Count non-empty mem body slices for optional Writev prefix.
	n_mem_body := 0
	for c in cmds {
		if (c.kind == .Static || c.kind == .Bytes) && len(c.bytes) > 0 {
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

	// HEAD: headers + Content-Length only; do not stream file (RFC 9110 §9.3.2).
	if _response_is_head(conn) {
		when HTTP_PHASE_STATS {
			phase_add(0, 0, 0, 0, 0, phase_now() - t0_build, 0)
		}
		conn.resp_buf = r._buf.buf
		buf := bytes.buffer_to_bytes(&r._buf)
		_conn_clear_file_send(conn)
		conn.exec_n = 0
		conn.exec_i = 0
		if len(buf) == 0 {
			plan_wire_inc_materialize()
			clean_request_loop(conn)
			return true
		}
		conn.pending_send = buf
		if err := host_submit_send(conn); err != .None {
			log.errorf("submit_send (file HEAD) failed: %v", err)
			conn.pending_send = nil
			connection_close(conn)
			return true
		}
		// HEAD is headers-only; count as materialize-style single buffer, not file stream.
		plan_wire_inc_materialize()
		return true
	}

	// Zero-length file: headers only (or headers + mem with empty file).
	conn.resp_buf = r._buf.buf
	heading := bytes.buffer_to_bytes(&r._buf)

	// Arm file-region state (even for length 0 so finish path is uniform).
	conn.file_send_fd = sf.fd
	conn.file_send_off = sf.file_offset
	conn.file_send_remaining = sf.file_length
	// Zero-length file: clear immediately after arming if no body to stream.
	// Keep fd marker only while remaining > 0 OR we still need post-header continue.
	if sf.file_length == 0 {
		// No file bytes; still may have mem prefix. Clear file cursor.
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
		// Mixed: multi-buffer heading + mem, then file_send_continue after exec finishes.
		bi := 0
		if len(heading) > 0 {
			conn.exec_bufs[0] = heading
			bi = 1
		}
		for c in cmds {
			#partial switch c.kind {
			case .Static, .Bytes:
				if len(c.bytes) == 0 {
					continue
				}
				conn.exec_bufs[bi] = c.bytes
				bi += 1
			}
		}
		conn.exec_n = bi
		conn.exec_i = 0
		for conn.exec_i < conn.exec_n && len(conn.exec_bufs[conn.exec_i]) == 0 {
			conn.exec_i += 1
		}
		if conn.exec_i >= conn.exec_n {
			// No mem/heading bytes — start file immediately if any.
			conn.exec_n = 0
			conn.exec_i = 0
			if conn.file_send_remaining > 0 {
				if !_conn_file_send_fill_chunk(conn) {
					_conn_clear_exec(conn)
					connection_close(conn)
					return true
				}
				if err := host_submit_send(conn); err != .None {
					log.errorf("submit_send (file region) failed: %v", err)
					_conn_clear_exec(conn)
					connection_close(conn)
					return true
				}
				plan_wire_inc_copy_into()
				return true
			}
			plan_wire_inc_copy_into()
			clean_request_loop(conn)
			return true
		}
		conn.pending_send = conn.exec_bufs[conn.exec_i]
		if err := host_submit_send(conn); err != .None {
			log.errorf("submit_send (file prefix) failed: %v", err)
			_conn_clear_exec(conn)
			connection_close(conn)
			return true
		}
		plan_wire_inc_copy_into()
		return true
	}

	// Pure file: send heading first, then file chunks on host_on_send.
	conn.exec_n = 0
	conn.exec_i = 0
	if len(heading) == 0 {
		// Degenerate headers empty — start file or finish.
		if conn.file_send_remaining > 0 {
			if !_conn_file_send_fill_chunk(conn) {
				_conn_clear_exec(conn)
				connection_close(conn)
				return true
			}
			if err := host_submit_send(conn); err != .None {
				log.errorf("submit_send (file region) failed: %v", err)
				_conn_clear_exec(conn)
				connection_close(conn)
				return true
			}
			plan_wire_inc_copy_into()
			return true
		}
		plan_wire_inc_copy_into()
		clean_request_loop(conn)
		return true
	}

	conn.pending_send = heading
	// file_send_remaining already set; after heading CQE, host_on_send continues file.
	if err := host_submit_send(conn); err != .None {
		log.errorf("submit_send (file headers) failed: %v", err)
		_conn_clear_exec(conn)
		connection_close(conn)
		return true
	}
	// Chunked pread+send path for Sendfile plan (not kernel sendfile).
	plan_wire_inc_copy_into()
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

	// Fast path: one in-memory body region (respond_plain / body_set).
	if r._cmd_count == 1 {
		c := cmds[0]
		if c.kind == .Static || c.kind == .Bytes {
			body_len := len(c.bytes)
			t0_build: u64
			when HTTP_PHASE_STATS {
				t0_build = phase_now()
			}
			// Exact capacity: heading ≤ 512 scratch + body (no 1MiB growth hint).
			hscratch: [512]byte
			hlen := _response_format_heading(r, body_len, hscratch[:])
			assert(hlen > 0 && hlen <= len(hscratch))
			need := hlen + body_len
			if cap(r._buf.buf) < need {
				reserve(&r._buf.buf, need)
			}
			// Write heading then body without intermediate buffer_write growth.
			resize(&r._buf.buf, need)
			copy(r._buf.buf[0:hlen], hscratch[:hlen])
			r._heading_written = true
			if !_response_is_head(r._conn) && body_len > 0 {
				copy(r._buf.buf[hlen:][:body_len], c.bytes)
			} else if _response_is_head(r._conn) {
				// HEAD: CL set in heading, no body bytes.
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
	if _response_is_head(r._conn) {
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

// Sync pread of a File cmd region into the response wire buffer (Phase 1 only).
// fd must remain open and the region readable until this returns (send copies into resp_buf).
@(private)
_response_materialize_file :: proc(r: ^Response, cmd: Response_Cmd) {
	assert(cmd.kind == .File)
	assert(cmd.length >= 0, "Phase 1 file materialize needs known length")
	// Guard against -disable-assert + length=-1 (int(-1) would grow absurdly / UB).
	if cmd.length < 0 {
		log.errorf("body_file materialize rejected unknown length (fd=%d)", cmd.fd)
		return
	}
	n := int(cmd.length)
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

	// Wire assembly (Phase 3–5):
	//  1) Heading already written (body_reserve / Response_Writer / Response_Stream)
	//     → single-buffer send as-is (stream path does not use plan_body).
	//  2) Body cmds → middleware → plan (optimize when plan_optimize|prefer_gather|prefer_sendfile):
	//       pure Writev          → multi-buffer sequential sends (heading + borrowed slices)
	//       Write_Slice+Sendfile → heading then chunked file stream (no full-file materialize)
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
			if _response_wire_use_optimize(r) {
				plan := plan_body(cmds, plan_context(r))
				if _plan_is_writev_wire(plan) {
					// Multi-buffer path submits itself (or clean_request_loop).
					if _response_send_writev(r, cmds) {
						used_opt = true
					}
					// false → heading not written; fall through to materialize
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
	// at response bytes (host_on_send clears pending_send before clean_request_loop).
	// Sync growth: r._buf.buf is a header copy that may reallocate on write.
	// Explicitly inactive multi-op queue so a prior writev path cannot leak exec_n.
	_conn_clear_exec(conn)
	conn.resp_buf = r._buf.buf
	buf := bytes.buffer_to_bytes(&r._buf)
	if len(buf) == 0 {
		clean_request_loop(conn)
		return
	}

	conn.pending_send = buf
	if err := host_submit_send(conn); err != .None {
		log.errorf("submit_send failed: %v", err)
		// No CQE will clear this; partial-send fail path already nils pending_send.
		// Leaving it set would make connection_close defer forever (close_on_io).
		conn.pending_send = nil
		connection_close(conn)
	}
}

// Response has been sent, clean up and close/handle next.
// Invariant: pending_send / exec queue already cleared (host_on_send or writev path).
@(private)
clean_request_loop :: proc(conn: ^Connection, close: Maybe(bool) = nil) {
	t0_reset: u64
	when HTTP_PHASE_STATS {
		t0_reset = phase_now()
	}
	context.temp_allocator = virtual.arena_allocator(&conn.temp_allocator)

	// Ensure multi-buffer / file-send queue is inactive before reusing conn.
	// Must nil exec_bufs (not only exec_n) so keep-alive cannot retain dangling
	// body/heading slice refs across temp reset / next request.
	_conn_clear_exec(conn)

	// Request scrap only (bump reset). Response lives in conn.resp_buf.
	// Safe: no pending_send / exec_bufs still referencing scrap or Static bodies.
	conn_temp_reset(conn)
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
	if conn.loop.res._buf.buf != nil {
		conn.resp_buf = conn.loop.res._buf.buf
	}
	clear(&conn.resp_buf)
	conn.loop.res = {}

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
