// Exchange — headers-first / body pull / cancel on an H1 Connection.
// Chunked TE is rejected (use request() for full framing including chunked).
package client

import "core:io"
import "core:mem"
import "core:strconv"
import "core:strings"
import "core:time"

Exchange :: struct {
	conn:       ^Connection,
	stream:     io.Stream,
	allocator:  mem.Allocator,
	status:     Status,
	headers:    OrderedHeaders,
	header_done: bool,
	body_done:  bool,
	cancelled:  bool,
	content_length: int, // -1 unknown/until close
	body_read:  int,     // bytes delivered via read_body
	// Leftover body bytes after headers in conn.h1_rx or temp
	pending:    []u8, // view into h1_rx or owned slice
	pending_owned: bool,
	max_body:   int,
	deadline:   time.Time,
}

// exchange_start begins an H1 request on c. Only H1 (negotiated) stream connections.
exchange_start :: proc(
	c: ^Connection,
	req: ^Request,
	allocator := context.allocator,
) -> (^Exchange, Http_Error) {
	if c == nil || req == nil {
		return nil, .Not_Configured
	}
	stream, ok := c.transport.(io.Stream)
	if !ok {
		return nil, .Unsupported_Version
	}
	if c.version != .Http1 && c.version != .Auto {
		// H2/H3: use request() or sessions; Exchange v1 is H1-only.
		return nil, .Unsupported_Version
	}
	if c.version == .Auto {
		// Treat as H1 pipe.
	}

	// Fill defaults like request().
	if len(req.method) == 0 do req.method = "GET"
	if len(req.target.host) == 0 do req.target.host = c.target.host
	if len(req.target.scheme) == 0 do req.target.scheme = c.target.scheme
	if req.target.port == 0 do req.target.port = c.target.port
	if len(req.target.path) == 0 do req.target.path = c.target.path

	// Send request using existing H1 writer path (blocking stream).
	// Reuse _h1_do write half by sending via internal helper.
	if e := _exchange_h1_send(c, stream, req); e != .None {
		return nil, e
	}

	ex := new(Exchange, allocator)
	ex.conn = c
	ex.stream = stream
	ex.allocator = allocator
	ex.content_length = -1
	ex.max_body = c.max_response_body
	ex.deadline = _request_deadline(c.timeout_ms)
	ex.headers.allocator = allocator
	return ex, .None
}

@(private)
_exchange_h1_send :: proc(c: ^Connection, stream: io.Stream, req: ^Request) -> Http_Error {
	// Build and write request (same framing as _h1_do start).
	_try_set_stream_sock_timeout(stream, _resolve_request_timeout(c.timeout_ms))
	if !c.h1_alive do return .Closed

	b: strings.Builder
	strings.builder_init(&b, context.temp_allocator)
	path := req.target.path if len(req.target.path) > 0 else "/"
	fmt_sbprintf_req :: proc(bb: ^strings.Builder, method, path: string) {
		strings.write_string(bb, method)
		strings.write_string(bb, " ")
		strings.write_string(bb, path)
		strings.write_string(bb, " HTTP/1.1\r\n")
	}
	fmt_sbprintf_req(&b, req.method if len(req.method) > 0 else "GET", path)
	strings.write_string(&b, "host: ")
	strings.write_string(&b, format_authority(req.target.scheme, req.target.host, req.target.port))
	strings.write_string(&b, "\r\n")
	if c.h1_keep_alive {
		strings.write_string(&b, "connection: keep-alive\r\n")
	} else {
		strings.write_string(&b, "connection: close\r\n")
	}
	if !_headers_has_ci(req.headers[:], "user-agent") {
		strings.write_string(&b, "user-agent: ")
		strings.write_string(&b, DEFAULT_USER_AGENT)
		strings.write_string(&b, "\r\n")
	}
	for h in req.headers {
		strings.write_string(&b, h.name)
		strings.write_string(&b, ": ")
		strings.write_string(&b, h.value)
		strings.write_string(&b, "\r\n")
	}
	if len(req.body) > 0 {
		strings.write_string(&b, "content-length: ")
		strings.write_int(&b, len(req.body))
		strings.write_string(&b, "\r\n")
	}
	strings.write_string(&b, "\r\n")
	req_s := strings.to_string(b)
	w := io.to_writer(stream)
	if _, e := io.write(w, transmute([]u8)req_s); e != .None {
		c.h1_alive = false
		return .Closed
	}
	if len(req.body) > 0 {
		if _, e := io.write(w, req.body); e != .None {
			c.h1_alive = false
			return .Closed
		}
	}
	return .None
}

// exchange_wait_headers reads status + headers (cloned). Idempotent if already done.
exchange_wait_headers :: proc(ex: ^Exchange) -> (status: Status, headers: OrderedHeaders, err: Http_Error) {
	if ex == nil do return {}, {}, .Closed
	if ex.cancelled do return {}, {}, .Closed
	if ex.header_done {
		return ex.status, ex.headers, .None
	}

	// Read into connection h1_rx until header end.
	clear(&ex.conn.h1_rx)
	ex.conn.h1_rx.allocator = ex.conn.allocator
	buf: [4096]u8
	r := io.to_reader(ex.stream)
	for {
		if _deadline_exceeded(ex.deadline) {
			ex.conn.h1_alive = false
			return {}, {}, .Timeout
		}
		if sep := _find_header_end(ex.conn.h1_rx[:]); sep >= 0 {
			if e := _exchange_parse_headers(ex, sep); e != .None {
				return {}, {}, e
			}
			// Body start after \r\n\r\n
			body_off := sep + 4
			if body_off < len(ex.conn.h1_rx) {
				ex.pending = ex.conn.h1_rx[body_off:]
			}
			ex.header_done = true
			// Clone headers for return (caller may use; exchange also keeps copy)
			return ex.status, ex.headers, .None
		}
		n, rerr := io.read(r, buf[:])
		if n > 0 {
			append(&ex.conn.h1_rx, ..buf[:n])
			if len(ex.conn.h1_rx) > 1024 * 1024 {
				return {}, {}, .Protocol
			}
			continue
		}
		if rerr != nil || n == 0 {
			ex.conn.h1_alive = false
			return {}, {}, .Closed
		}
	}
}

@(private)
_exchange_parse_headers :: proc(ex: ^Exchange, sep: int) -> Http_Error {
	head := string(ex.conn.h1_rx[:sep])
	lines := strings.split(head, "\r\n", context.temp_allocator)
	if len(lines) == 0 do return .Protocol
	sp := strings.index_byte(lines[0], ' ')
	if sp < 0 do return .Protocol
	rest := lines[0][sp + 1:]
	code_end := strings.index_byte(rest, ' ')
	code_str := rest if code_end < 0 else rest[:code_end]
	code, cok := strconv.parse_int(code_str)
	if !cok do return .Protocol
	ex.status = Status(code)
	ex.content_length = -1
	for line in lines[1:] {
		ci := strings.index_byte(line, ':')
		if ci < 0 do continue
		name := strings.trim_space(line[:ci])
		val := strings.trim_space(line[ci + 1:])
		append(
			&ex.headers,
			Header {
				name        = strings.clone(name, ex.allocator),
				value       = strings.clone(val, ex.allocator),
				name_owned  = true,
				value_owned = true,
			},
		)
		nl := strings.to_lower(name, context.temp_allocator)
		if nl == "content-length" {
			if n, ok := strconv.parse_int(val); ok {
				if n < 0 do return .Protocol
				if n > ex.max_body do return .Body_Too_Large
				ex.content_length = n
			}
		} else if nl == "transfer-encoding" {
			vl := strings.to_lower(val, context.temp_allocator)
			if strings.contains(vl, "chunked") {
				// v1 Exchange: no chunked streaming — collect path can use full _h1_do later
				return .Protocol
			}
		}
	}
	return .None
}

// exchange_read_body copies up to len(buf) body bytes. Returns n=0 when complete.
exchange_read_body :: proc(ex: ^Exchange, buf: []u8) -> (n: int, err: Http_Error) {
	if ex == nil || ex.cancelled do return 0, .Closed
	if !ex.header_done {
		_, _, e := exchange_wait_headers(ex)
		if e != .None do return 0, e
	}
	if ex.body_done do return 0, .None

	// Drain pending first.
	if len(ex.pending) > 0 {
		n = min(len(buf), len(ex.pending))
		copy(buf[:n], ex.pending[:n])
		ex.pending = ex.pending[n:]
		ex.body_read += n
		if ex.content_length >= 0 && ex.body_read >= ex.content_length {
			ex.body_done = true
		}
		if ex.body_read > ex.max_body {
			ex.conn.h1_alive = false
			return n, .Body_Too_Large
		}
		return n, .None
	}

	if ex.content_length >= 0 && ex.body_read >= ex.content_length {
		ex.body_done = true
		return 0, .None
	}

	if _deadline_exceeded(ex.deadline) {
		ex.conn.h1_alive = false
		return 0, .Timeout
	}
	r := io.to_reader(ex.stream)
	want := len(buf)
	if ex.content_length >= 0 {
		remain := ex.content_length - ex.body_read
		if remain < want do want = remain
	}
	got, rerr := io.read(r, buf[:want])
	if got > 0 {
		ex.body_read += got
		if ex.body_read > ex.max_body {
			ex.conn.h1_alive = false
			return got, .Body_Too_Large
		}
		if ex.content_length >= 0 && ex.body_read >= ex.content_length {
			ex.body_done = true
		}
		return got, .None
	}
	if rerr != nil || got == 0 {
		// EOF
		ex.body_done = true
		if ex.content_length >= 0 && ex.body_read < ex.content_length {
			ex.conn.h1_alive = false
			return 0, .Closed
		}
		return 0, .None
	}
	return 0, .None
}

exchange_cancel :: proc(ex: ^Exchange) {
	if ex == nil do return
	ex.cancelled = true
	ex.body_done = true
	if ex.conn != nil {
		ex.conn.h1_alive = false
	}
	// Stream left to close() of connection.
}

exchange_finish :: proc(ex: ^Exchange) {
	if ex == nil do return
	for h in ex.headers {
		if h.name_owned do delete(h.name, ex.allocator)
		if h.value_owned do delete(h.value, ex.allocator)
	}
	delete(ex.headers)
	free(ex, ex.allocator)
}

// exchange_collect reads remaining body into a full Response (coarse path).
exchange_collect :: proc(ex: ^Exchange, allocator := context.allocator) -> (Response, Http_Error) {
	if ex == nil do return {}, .Closed
	if !ex.header_done {
		_, _, e := exchange_wait_headers(ex)
		if e != .None {
			exchange_finish(ex)
			return {}, e
		}
	}
	res: Response
	res.status = ex.status
	res.version = .Http1
	res.headers.allocator = allocator
	res.body.allocator = allocator
	// Clone headers into result
	for h in ex.headers {
		append(
			&res.headers,
			Header {
				name        = strings.clone(h.name, allocator),
				value       = strings.clone(h.value, allocator),
				name_owned  = true,
				value_owned = true,
			},
		)
	}
	buf: [4096]u8
	for !ex.body_done && !ex.cancelled {
		n, err := exchange_read_body(ex, buf[:])
		if err != .None {
			response_destroy(&res, allocator)
			exchange_finish(ex)
			return {}, err
		}
		if n == 0 do break
		append(&res.body, ..buf[:n])
	}
	exchange_finish(ex)
	return res, .None
}
