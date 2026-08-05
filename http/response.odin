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
	// body_reserve / response_writer already wrote it. Headers may still be set after body_*.
	_cmds:            [PLAN_MAX_BODY_CMDS]Response_Cmd,
	_cmd_count:       int,
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
	assert(!r._heading_written, "heading already written; cannot append body cmd", loc)
	assert(r._body_off == 0, "body_reserve in progress; cannot append body cmd", loc)
	assert(r._cmd_count < PLAN_MAX_BODY_CMDS, "too many body commands (PLAN_MAX_BODY_CMDS)", loc)
	r._cmds[r._cmd_count] = cmd
	r._cmd_count += 1
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

// Append a File body command (fd region). Does not read the file here; Phase 1 materialize
// may sync-read into resp_buf at send time (Phase 4 may use sendfile on the wire).
body_file :: proc(r: ^Response, fd: i32, offset: i64, length: i64, loc := #caller_location) {
	_response_append_cmd(r, cmd_file(fd, offset, length), loc)
}

/*
Prefer the procedure group `body_set`.

Appends a Static body command. Does not write the HTTP heading yet — headers and status
remain mutable until respond / plan / send. (body_reserve and response_writer still write
the heading immediately.)
*/
body_set_bytes :: proc(r: ^Response, byts: []byte, loc := #caller_location) {
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
Sets the response body by appending body command(s).

Unlike the pre-Phase-1 path, this does **not** freeze headers: you may still add headers
or change status until respond. Heading + body are materialised at send time into the
single-buffer Write_Slice path (plan_body_materialize_only).

For in-place fixed-CL bodies use body_reserve / body_commit.
For unknown size / io.Writer use response_writer_init (chunked; heading written early).
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
a string or byte slice.

The buffer can be used to avoid very small writes, like the ones when you use the json package
(each write in the json package is only a few bytes). You are allowed to pass nil which will disable
buffering.

NOTE: You need to call io.destroy to signal the end of the body, OR io.close to send the response.
*/
response_writer_init :: proc(rw: ^Response_Writer, r: ^Response, buffer: []byte) -> io.Writer {
	assert(r._cmd_count == 0, "body cmds already set; cannot response_writer_init")
	headers_set_unsafe(&r.headers, "transfer-encoding", "chunked")
	_response_write_heading(r, -1)

	rw.buf = slice.into_dynamic(buffer)
	rw.r   = r

	rw.w = io.Stream{
		procedure = proc(stream_data: rawptr, mode: io.Stream_Mode, p: []byte, offset: i64, whence: io.Seek_From) -> (n: i64, err: io.Error) {
			ws :: bytes.buffer_write_string
			write_chunk :: proc(b: ^bytes.Buffer, chunk: []byte) {
				plen := i64(len(chunk))
				if plen == 0 { return }

				log.debugf("response_writer chunk of size: %i", plen)

				bytes.buffer_grow(b, 16)
				size_buf := _dynamic_unwritten(b.buf)
				size := strconv.write_int(size_buf, plen, 16)
				_dynamic_add_len(&b.buf, len(size))

				ws(b, "\r\n")
				bytes.buffer_write(b, chunk)
				ws(b, "\r\n")
			}

			rw := (^Response_Writer)(stream_data)
			b := &rw.r._buf

			#partial switch mode {
			case .Flush:
				assert(!rw.ended)

				write_chunk(b, rw.buf[:])
				clear(&rw.buf)
				return 0, nil

			case .Destroy:
				assert(!rw.ended)

				// Write what is left.
				write_chunk(b, rw.buf[:])

				// Signals the end of the body.
				ws(b, "0\r\n\r\n")

				rw.ended = true
				return 0, nil

			case .Close:
				// Write what is left.
				write_chunk(b, rw.buf[:])

				if !rw.ended {
					// Signals the end of the body.
					ws(b, "0\r\n\r\n")
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
					write_chunk(b, rw.buf[:])
					clear(&rw.buf)

					if len(p) > cap(rw.buf) {
						write_chunk(b, p)
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

// Phase 1: plan_body_materialize_only + copy cmds into _buf as one Write_Slice payload.
// Not used when body_reserve / response_writer already wrote the heading into _buf.
@(private)
_response_materialize_cmds :: proc(r: ^Response) {
	assert(!r._heading_written)
	assert(r._cmd_count > 0)

	cmds := r._cmds[:r._cmd_count]
	plan := plan_body_materialize_only(cmds)
	assert(plan.materialized && plan.op_count == 1 && plan.ops[0].kind == .Write_Slice)

	// Content-Length: sum of known lengths. Phase 1 requires known body size.
	body_len: int
	if plan.total_body >= 0 {
		body_len = int(plan.total_body)
	} else {
		// Unknown file length — still require known size for CL materialize path.
		for c in cmds {
			n, ok := cmd_known_length(c)
			assert(ok, "Phase 1 materialize requires known body length (set File.length)")
			body_len += int(n)
		}
	}

	t0_build: u64
	when HTTP_PHASE_STATS {
		t0_build = phase_now()
	}

	_response_write_heading(r, body_len)

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
@(private)
_response_materialize_file :: proc(r: ^Response, cmd: Response_Cmd) {
	assert(cmd.kind == .File)
	assert(cmd.length >= 0, "Phase 1 file materialize needs known length")
	n := int(cmd.length)
	if n == 0 {
		return
	}

	bytes.buffer_grow(&r._buf, n)
	dst := _dynamic_unwritten(r._buf.buf)
	assert(len(dst) >= n)

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

@(private)
response_send_got_body :: proc(r: ^Response, will_close: bool) {
	conn := r._conn

	if will_close {
		if !connection_set_state(r._conn, .Will_Close) { return }
	}

	// Wire assembly (Phase 1):
	//  1) Heading already written (body_reserve after commit, or chunked writer) → send buffer as-is.
	//  2) Body cmds present → materialize-only plan into heading + body, one Write_Slice.
	//  3) Empty buffer, no cmds → heading with Content-Length 0.
	//  4) Buffer has content without heading_written is unexpected; treat as ready-to-send.
	if !r._heading_written {
		if r._cmd_count > 0 {
			_response_materialize_cmds(r)
		} else if bytes.buffer_length(&r._buf) == 0 {
			_response_write_heading(r, 0)
		}
	}

	// Build the full response buffer, then submit_send. Do NOT reset scrap arena
	// or drop resp_buf while pending_send still points at response bytes
	// (host_on_send clears pending_send before clean_request_loop).
	// Sync growth: r._buf.buf is a header copy that may reallocate on write.
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
// Invariant: pending_send is already nil (host_on_send clears it before clean).
@(private)
clean_request_loop :: proc(conn: ^Connection, close: Maybe(bool) = nil) {
	t0_reset: u64
	when HTTP_PHASE_STATS {
		t0_reset = phase_now()
	}
	context.temp_allocator = virtual.arena_allocator(&conn.temp_allocator)

	// Request scrap only (bump reset). Response lives in conn.resp_buf.
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
