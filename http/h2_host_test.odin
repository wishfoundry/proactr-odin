// PR8/PR9 H2 host — unit tests (no TLS / ring required).
//
// Run: odin test http -define:ODIN_TEST_THREADS=1 -o:none
package http

import "core:mem/virtual"
import "core:sync"
import "core:testing"

import http2 "../http2"

// Package-level counters (Odin procs cannot capture test locals).
// Shared with h2_m_gates_test.odin (package-private, not file-private).
// Tests that use these must take _h2_test_counter_mu (parallel test runners race otherwise).
@(private)
_h2_test_counter_mu: sync.Mutex
@(private)
_h2_test_n_calls: int
@(private)
_h2_test_n_hold: int
@(private)
_h2_test_n_ok: int

@(private)
_h2_test_counters_begin :: proc() {
	sync.mutex_lock(&_h2_test_counter_mu)
	_h2_test_n_calls = 0
	_h2_test_n_hold = 0
	_h2_test_n_ok = 0
}

@(private)
_h2_test_counters_end :: proc() {
	sync.mutex_unlock(&_h2_test_counter_mu)
}

// Minimal worker + scrap arena so respond / server_date / dispatch work offline.
@(private)
h2_test_install_worker :: proc(st: ^Server_Thread, server: ^Server = nil) {
	st.state = .Serving
	st.server = server
	td = st
	server_date_refresh()
}

@(private)
h2_test_uninstall_worker :: proc() {
	td = nil
}

// Offline Connection ready for h2_host_dispatch_available + oneshot respond.
// Caller must free via h2_test_conn_teardown.
@(private)
h2_test_conn_setup :: proc(
	conn: ^Connection,
	s: ^Server,
	temp_region: []u8,
) -> bool {
	conn.server = s
	conn.state = .Idle
	conn.h2_active = true
	conn.temp_slot = 0 // skip conn_temp_attach pool
	if virtual.arena_init_buffer(&conn.temp_allocator, temp_region) != nil {
		return false
	}
	http2.conn_init(&conn.h2, true, context.allocator)
	conn.h2_out.allocator = context.allocator
	return h2_host_ensure_slots(conn)
}

@(private)
h2_test_conn_teardown :: proc(conn: ^Connection) {
	http2.conn_destroy(&conn.h2)
	delete(conn.h2_out)
	if conn.resp_buf != nil {
		delete(conn.resp_buf)
		conn.resp_buf = nil
	}
	if conn.h2_slots != nil {
		free(conn.h2_slots)
		conn.h2_slots = nil
	}
}

@(private)
_h2_test_handler_count_ok :: proc(req: ^Request, res: ^Response) {
	_ = req
	_h2_test_n_calls += 1
	respond_plain(res, "ok")
}

@(private)
_h2_test_handler_path_body :: proc(req: ^Request, res: ^Response) {
	path := "/"
	if line, ok := req.line.?; ok {
		if p, pok := line.target.(string); pok {
			path = p
		}
	}
	respond_plain(res, path)
}

@(private = "file")
_h2_test_handler_count_one :: proc(req: ^Request, res: ^Response) {
	_ = req
	_h2_test_n_calls += 1
	respond_plain(res, "one")
}

@(private = "file")
_h2_test_handler_count_x :: proc(req: ^Request, res: ^Response) {
	_ = req
	_h2_test_n_calls += 1
	respond_plain(res, "x")
}

@(private = "file")
_h2_test_handler_hold_or_ok :: proc(req: ^Request, res: ^Response) {
	path := ""
	if line, ok := req.line.?; ok {
		if p, pok := line.target.(string); pok {
			path = p
		}
	}
	if path == "/hold" {
		_h2_test_n_hold += 1
		// Fake long-lived attach: keep slot without oneshot respond/end_sent.
		res._session_attached = true
		return
	}
	_h2_test_n_ok += 1
	respond_plain(res, "go")
}

@(test)
test_h2_request_from_headers_get :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	hdrs := []http2.Header {
		{name = ":method", value = "GET"},
		{name = ":scheme", value = "https"},
		{name = ":authority", value = "example.com"},
		{name = ":path", value = "/hello?x=1"},
		{name = "user-agent", value = "h2-test"},
	}
	req: Request
	ok := h2_request_from_headers(&req, hdrs, nil, context.temp_allocator)
	testing.expect(t, ok, "build GET request")

	line, lok := req.line.?
	testing.expect(t, lok)
	testing.expect_value(t, line.method, Method.Get)
	testing.expect_value(t, line.version, Version{1, 1})
	testing.expect_value(t, line.target.(string), "/hello?x=1")
	testing.expect_value(t, req.url.path, "/hello")
	host, hok := headers_get_unsafe(req.headers, "host")
	testing.expect(t, hok)
	testing.expect_value(t, host, "example.com")
	ua, uok := headers_get_unsafe(req.headers, "user-agent")
	testing.expect(t, uok)
	testing.expect_value(t, ua, "h2-test")
	// Pseudos must not appear as regular headers.
	testing.expect(t, !headers_has_unsafe(req.headers, ":method"))
	testing.expect(t, !headers_has_unsafe(req.headers, ":path"))
}

@(test)
test_h2_request_from_headers_post_body :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	hdrs := []http2.Header {
		{name = ":method", value = "POST"},
		{name = ":scheme", value = "https"},
		{name = ":authority", value = "api.local"},
		{name = ":path", value = "/echo"},
		{name = "content-type", value = "text/plain"},
	}
	payload := transmute([]u8)string("payload")
	req: Request
	ok := h2_request_from_headers(&req, hdrs, payload, context.temp_allocator)
	testing.expect(t, ok)

	line := req.line.?
	testing.expect_value(t, line.method, Method.Post)
	pre, pok := req._pre_body.?
	testing.expect(t, pok)
	testing.expect_value(t, string(pre), "payload")
	cl, cok := headers_get_unsafe(req.headers, "content-length")
	testing.expect(t, cok)
	testing.expect_value(t, cl, "7")
}

// body() delivers H2 pre-buffered payload without scanner I/O.
@(test)
test_h2_pre_body_api :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	hdrs := []http2.Header {
		{name = ":method", value = "POST"},
		{name = ":scheme", value = "https"},
		{name = ":authority", value = "api.local"},
		{name = ":path", value = "/echo"},
	}
	req: Request
	testing.expect(t, h2_request_from_headers(&req, hdrs, transmute([]u8)string("xyz"), context.temp_allocator))

	Body_Cap :: struct {
		got: string,
		err: Body_Error,
	}
	cap: Body_Cap
	body(&req, -1, &cap, proc(user: rawptr, b: Body, err: Body_Error) {
		c := cast(^Body_Cap)user
		c.err = err
		c.got = string(b)
	})
	testing.expect(t, cap.err == nil)
	testing.expect_value(t, cap.got, "xyz")
	okb, has := req._body_ok.?
	testing.expect(t, has && okb)
}

@(test)
test_h2_request_from_headers_rejects_missing_pseudos :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	req: Request
	// No :method
	ok := h2_request_from_headers(&req, []http2.Header{{name = ":path", value = "/"}, {name = ":authority", value = "h"}}, nil)
	testing.expect(t, !ok)
	// No host / :authority
	ok2 := h2_request_from_headers(&req, []http2.Header{{name = ":method", value = "GET"}, {name = ":path", value = "/"}}, nil)
	testing.expect(t, !ok2)
}

@(test)
test_h2_response_headers_from_status :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	r: Response
	r.status = .OK
	headers_init(&r.headers, context.temp_allocator)
	headers_set_unsafe(&r.headers, "content-type", "text/plain")
	headers_set_unsafe(&r.headers, "connection", "close") // hop-by-hop — must drop

	out: [dynamic]http2.Header
	out.allocator = context.temp_allocator
	h2_response_headers_from(&r, &out)

	testing.expect(t, len(out) >= 2)
	testing.expect_value(t, out[0].name, ":status")
	testing.expect_value(t, out[0].value, "200")
	found_ct := false
	found_conn := false
	for h in out {
		if h.name == "content-type" {
			found_ct = true
			testing.expect_value(t, h.value, "text/plain")
		}
		if h.name == "connection" {
			found_conn = true
		}
	}
	testing.expect(t, found_ct)
	testing.expect(t, !found_conn, "connection hop-by-hop must not be on H2 response")
}

// Offline glue: feed preface+SETTINGS+HEADERS GET into engine + host helpers
// (no TLS / ring). Verifies request build + response header map + frame round-trip.
@(test)
test_h2_host_offline_dispatch_get :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	conn: Connection
	conn.state = .Idle
	conn.h2_active = true
	http2.conn_init(&conn.h2, true, context.allocator)
	defer http2.conn_destroy(&conn.h2)
	conn.h2_out.allocator = context.allocator
	defer delete(conn.h2_out)

	// Client wire: preface + SETTINGS + HEADERS GET /
	client: http2.Http2_Connection
	http2.conn_init(&client, false, context.allocator)
	defer http2.conn_destroy(&client)
	c_out: [dynamic]u8
	defer delete(c_out)
	http2.conn_send_preface(&client, &c_out)
	req_h := []http2.Header {
		{name = ":method", value = "GET"},
		{name = ":scheme", value = "https"},
		{name = ":authority", value = "example.com"},
		{name = ":path", value = "/"},
	}
	_ = http2.conn_send_request(&client, &c_out, req_h)

	// Server preface SETTINGS into out; feed client bytes.
	http2.conn_send_preface(&conn.h2, &conn.h2_out)
	testing.expect_value(t, http2.conn_feed(&conn.h2, c_out[:], &conn.h2_out), http2.H2_Error.None)

	// Host: on_pt is just conn_feed (already done); take + build Request.
	sid, hdrs, body, ok := http2.conn_take_request(&conn.h2)
	testing.expect(t, ok, "take GET request")
	testing.expect_value(t, sid, u32(1))

	testing.expect(t, h2_host_ensure_slots(&conn), "lazy multi-slot for offline glue")
	defer free(conn.h2_slots)
	slot_i, sok := h2_host_slot_alloc(&conn, sid)
	testing.expect(t, sok)
	testing.expect_value(t, conn.h2_slot_sids[slot_i], sid)

	req: Request
	testing.expect(t, h2_request_from_headers(&req, hdrs, body, context.temp_allocator))
	line := req.line.?
	testing.expect_value(t, line.method, Method.Get)
	testing.expect_value(t, line.target.(string), "/")

	// Mock handler result → H2 frames (same path as h2_host_send_response core).
	r: Response
	r.status = .OK
	headers_init(&r.headers, context.temp_allocator)
	headers_set_unsafe(&r.headers, "content-type", "text/plain")
	rh: [dynamic]http2.Header
	rh.allocator = context.temp_allocator
	h2_response_headers_from(&r, &rh)
	http2.conn_send_response(&conn.h2, &conn.h2_out, sid, rh[:], transmute([]u8)string("pong"))

	// Client consumes response (skip SETTINGS etc. by feeding all server out).
	c2: [dynamic]u8
	defer delete(c2)
	testing.expect_value(t, http2.conn_feed(&client, conn.h2_out[:], &c2), http2.H2_Error.None)
	rhdrs, rbody, done := http2.conn_response(&client, sid)
	testing.expect(t, done)
	st := ""
	for h in rhdrs {
		if h.name == ":status" {
			st = h.value
		}
	}
	testing.expect_value(t, st, "200")
	testing.expect_value(t, string(rbody), "pong")

	h2_host_slot_free(&conn, slot_i)
	testing.expect(t, !conn.h2_slot_used[slot_i])
}

@(test)
test_h2_host_slot_slab_structure :: proc(t: ^testing.T) {
	// Multi-slot slab after ensure (mirrors h2_host_on_open); serial alloc/free sans TLS.
	conn: Connection
	conn.state = .Idle
	testing.expect(t, conn.h2_slots == nil, "lazy: nil before ensure/open")
	testing.expect(t, h2_host_ensure_slots(&conn))
	defer free(conn.h2_slots)
	for i in 0 ..< H2_SLOT_CAP {
		testing.expect(t, !conn.h2_slot_used[i])
	}
	i0, ok0 := h2_host_slot_alloc(&conn, 1)
	testing.expect(t, ok0)
	testing.expect_value(t, i0, u8(0))
	testing.expect(t, conn.h2_slot_used[0])
	testing.expect_value(t, conn.h2_slot_sids[0], u32(1))
	testing.expect(t, conn.h2_slots[0].conn == &conn)

	i1, ok1 := h2_host_slot_alloc(&conn, 3)
	testing.expect(t, ok1)
	testing.expect_value(t, i1, u8(1))

	fi, fok := h2_host_slot_find(&conn, 3)
	testing.expect(t, fok)
	testing.expect_value(t, fi, u8(1))

	h2_host_slot_free(&conn, i0)
	testing.expect(t, !conn.h2_slot_used[0])
	testing.expect_value(t, conn.h2_slot_sids[0], u32(0))

	// Reuse slot 0
	i2, ok2 := h2_host_slot_alloc(&conn, 5)
	testing.expect(t, ok2)
	testing.expect_value(t, i2, u8(0))
}

// Fail-closed: connection without H2 open must not pay multi-slot slab.
@(test)
test_h2_slots_lazy_nil_without_open :: proc(t: ^testing.T) {
	conn: Connection
	// Zero Connection (clear-H1 / TLS-H1 path): no h2_active, no slab.
	testing.expect(t, !conn.h2_active)
	testing.expect(t, conn.h2_slots == nil)
	// slot_alloc must fail closed without slab.
	_, ok := h2_host_slot_alloc(&conn, 1)
	testing.expect(t, !ok)
}

// Fail-closed: protocol error on feed appends a real GOAWAY frame (type 0x7) to h2_out.
@(test)
test_h2_host_feed_protocol_error_emits_goaway :: proc(t: ^testing.T) {
	conn: Connection
	conn.state = .Idle
	conn.h2_active = true
	http2.conn_init(&conn.h2, true, context.allocator)
	defer http2.conn_destroy(&conn.h2)
	conn.h2_out.allocator = context.allocator
	defer delete(conn.h2_out)

	// Wrong client preface → Protocol; host must write GOAWAY before close.
	bad := transmute([]u8)string("NOT * HTTP/2.0\r\n\r\nSM\r\n\r\n")
	h2_host_on_pt(&conn, bad)

	testing.expect(t, conn.state >= .Closing, "offline close marks Closing")
	found_goaway := false
	pos := 0
	for pos + http2.FRAME_HEADER_LEN <= len(conn.h2_out) {
		length := u32(conn.h2_out[pos]) << 16 | u32(conn.h2_out[pos + 1]) << 8 | u32(conn.h2_out[pos + 2])
		typ := conn.h2_out[pos + 3]
		if typ == http2.FRAME_GOAWAY {
			found_goaway = true
			// Payload is last_sid(4) + error_code(4); expect PROTOCOL_ERROR (0x1).
			if length >= 8 && pos + http2.FRAME_HEADER_LEN + 8 <= len(conn.h2_out) {
				code := u32(conn.h2_out[pos + 13]) << 24 |
					u32(conn.h2_out[pos + 14]) << 16 |
					u32(conn.h2_out[pos + 15]) << 8 |
					u32(conn.h2_out[pos + 16])
				testing.expect_value(t, code, http2.H2_PROTOCOL_ERROR)
			}
			break
		}
		pos += http2.FRAME_HEADER_LEN + int(length)
	}
	testing.expect(t, found_goaway, "h2_out must contain FRAME_GOAWAY after feed error")
}

// Fail-closed: engine _fail path (fail_code set) also emits GOAWAY with that code.
@(test)
test_h2_host_feed_fail_code_emits_goaway :: proc(t: ^testing.T) {
	conn: Connection
	conn.state = .Idle
	conn.h2_active = true
	http2.conn_init(&conn.h2, true, context.allocator)
	defer http2.conn_destroy(&conn.h2)
	conn.h2_out.allocator = context.allocator
	defer delete(conn.h2_out)

	// Valid preface + SETTINGS, then DATA on stream 0 → PROTOCOL_ERROR via _fail.
	c_out: [dynamic]u8
	defer delete(c_out)
	client: http2.Http2_Connection
	http2.conn_init(&client, false, context.allocator)
	defer http2.conn_destroy(&client)
	http2.conn_send_preface(&client, &c_out)
	// Append illegal DATA (stream_id=0): 9-byte header + 0 payload.
	// length=0, type=DATA(0), flags=0, stream=0
	append(&c_out, 0, 0, 0, http2.FRAME_DATA, 0, 0, 0, 0, 0)

	h2_host_on_pt(&conn, c_out[:])
	testing.expect(t, conn.state >= .Closing)

	found_goaway := false
	pos := 0
	for pos + http2.FRAME_HEADER_LEN <= len(conn.h2_out) {
		length := u32(conn.h2_out[pos]) << 16 | u32(conn.h2_out[pos + 1]) << 8 | u32(conn.h2_out[pos + 2])
		typ := conn.h2_out[pos + 3]
		if typ == http2.FRAME_GOAWAY {
			found_goaway = true
			break
		}
		pos += http2.FRAME_HEADER_LEN + int(length)
	}
	testing.expect(t, found_goaway, "GOAWAY required when fail_code set")
	testing.expect(t, conn.h2.fail_code != 0 || found_goaway)
}

@(test)
test_h2_serial_busy_blocks_second_take :: proc(t: ^testing.T) {
	// Serial mode: when serial_busy, dispatch_available no-ops even if requests ready.
	defer free_all(context.temp_allocator)

	s: Server
	s.conn_allocator = context.allocator
	s.opts = Default_Server_Opts
	s.opts.h2_serial_dispatch = true
	// Handler that would panic if invoked twice unexpectedly — we never call it
	// because we only check the busy gate.
	s.handler = handler(proc(req: ^Request, res: ^Response) {
		_ = req
		_ = res
	})

	conn: Connection
	conn.server = &s
	conn.state = .Idle
	conn.h2_active = true
	conn.h2_serial_busy = true // simulate in-flight exchange
	conn.h2_dispatch_sid = 1
	http2.conn_init(&conn.h2, true, context.allocator)
	defer http2.conn_destroy(&conn.h2)
	conn.h2_out.allocator = context.allocator
	defer delete(conn.h2_out)

	// Should return immediately without take/handler.
	h2_host_dispatch_available(&conn)
	testing.expect(t, conn.h2_serial_busy)
	testing.expect_value(t, conn.h2_dispatch_sid, u32(1))
}

// Concurrent default: h2_serial_busy alone must not block takes (slots free).
@(test)
test_h2_concurrent_ignores_stale_serial_busy :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	_h2_test_counters_begin()
	defer _h2_test_counters_end()
	st: Server_Thread
	h2_test_install_worker(&st)
	defer h2_test_uninstall_worker()

	s: Server
	s.conn_allocator = context.allocator
	s.opts = Default_Server_Opts
	s.opts.h2_serial_dispatch = false
	s.handler = handler(_h2_test_handler_count_ok)

	conn: Connection
	temp: [64 * 1024]u8
	testing.expect(t, h2_test_conn_setup(&conn, &s, temp[:]))
	defer h2_test_conn_teardown(&conn)
	// Stale serial_busy must not gate concurrent dispatch.
	conn.h2_serial_busy = true
	conn.h2_dispatch_sid = 99

	client: http2.Http2_Connection
	http2.conn_init(&client, false, context.allocator)
	defer http2.conn_destroy(&client)
	c_out: [dynamic]u8
	defer delete(c_out)
	http2.conn_send_preface(&client, &c_out)
	req_h := []http2.Header {
		{name = ":method", value = "GET"},
		{name = ":scheme", value = "https"},
		{name = ":authority", value = "example.com"},
		{name = ":path", value = "/"},
	}
	_ = http2.conn_send_request(&client, &c_out, req_h)

	http2.conn_send_preface(&conn.h2, &conn.h2_out)
	testing.expect_value(t, http2.conn_feed(&conn.h2, c_out[:], &conn.h2_out), http2.H2_Error.None)

	h2_host_dispatch_available(&conn)
	testing.expect_value(t, _h2_test_n_calls, 1)
}

@(test)
test_default_opts_h2_serial_false :: proc(t: ^testing.T) {
	// Product concurrent unary is the default; true is eng/debug single-flight.
	testing.expect(t, !Default_Server_Opts.h2_serial_dispatch)
}

// Offline: two concurrent GET streams → two responses in h2_out (PR9).
@(test)
test_h2_host_concurrent_two_get_streams :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	st: Server_Thread
	h2_test_install_worker(&st)
	defer h2_test_uninstall_worker()

	s: Server
	s.conn_allocator = context.allocator
	s.opts = Default_Server_Opts
	s.opts.h2_serial_dispatch = false
	s.handler = handler(_h2_test_handler_path_body)

	conn: Connection
	temp: [128 * 1024]u8
	testing.expect(t, h2_test_conn_setup(&conn, &s, temp[:]))
	defer h2_test_conn_teardown(&conn)

	client: http2.Http2_Connection
	http2.conn_init(&client, false, context.allocator)
	defer http2.conn_destroy(&client)
	c_out: [dynamic]u8
	defer delete(c_out)
	http2.conn_send_preface(&client, &c_out)
	req_a := []http2.Header {
		{name = ":method", value = "GET"},
		{name = ":scheme", value = "https"},
		{name = ":authority", value = "example.com"},
		{name = ":path", value = "/a"},
	}
	req_b := []http2.Header {
		{name = ":method", value = "GET"},
		{name = ":scheme", value = "https"},
		{name = ":authority", value = "example.com"},
		{name = ":path", value = "/b"},
	}
	sid1 := http2.conn_send_request(&client, &c_out, req_a)
	sid2 := http2.conn_send_request(&client, &c_out, req_b)
	testing.expect_value(t, sid1, u32(1))
	testing.expect_value(t, sid2, u32(3))

	http2.conn_send_preface(&conn.h2, &conn.h2_out)
	testing.expect_value(t, http2.conn_feed(&conn.h2, c_out[:], &conn.h2_out), http2.H2_Error.None)

	// Concurrent: both ready requests dispatched without waiting for finish.
	h2_host_dispatch_available(&conn)

	used := 0
	for i in 0 ..< H2_SLOT_CAP {
		if conn.h2_slot_used[i] {
			used += 1
		}
	}
	testing.expect_value(t, used, 2)

	// Client sees both responses in the shared out buffer.
	c2: [dynamic]u8
	defer delete(c2)
	testing.expect_value(t, http2.conn_feed(&client, conn.h2_out[:], &c2), http2.H2_Error.None)
	rh1, rb1, d1 := http2.conn_response(&client, sid1)
	rh2, rb2, d2 := http2.conn_response(&client, sid2)
	testing.expect(t, d1, "response stream 1")
	testing.expect(t, d2, "response stream 3")
	st1, st2 := "", ""
	for h in rh1 {
		if h.name == ":status" {
			st1 = h.value
		}
	}
	for h in rh2 {
		if h.name == ":status" {
			st2 = h.value
		}
	}
	testing.expect_value(t, st1, "200")
	testing.expect_value(t, st2, "200")
	// Bodies match paths (order of take is map-iteration; both present).
	got_a := string(rb1) == "/a" || string(rb2) == "/a"
	got_b := string(rb1) == "/b" || string(rb2) == "/b"
	testing.expect(t, got_a && got_b, "both /a and /b bodies")
}

// Serial mode: one in-flight oneshot even when two complete requests are ready.
@(test)
test_h2_host_serial_single_flight_two_ready :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	_h2_test_counters_begin()
	defer _h2_test_counters_end()
	st: Server_Thread
	h2_test_install_worker(&st)
	defer h2_test_uninstall_worker()

	s: Server
	s.conn_allocator = context.allocator
	s.opts = Default_Server_Opts
	s.opts.h2_serial_dispatch = true
	s.handler = handler(_h2_test_handler_count_one)

	conn: Connection
	temp: [64 * 1024]u8
	testing.expect(t, h2_test_conn_setup(&conn, &s, temp[:]))
	defer h2_test_conn_teardown(&conn)

	client: http2.Http2_Connection
	http2.conn_init(&client, false, context.allocator)
	defer http2.conn_destroy(&client)
	c_out: [dynamic]u8
	defer delete(c_out)
	http2.conn_send_preface(&client, &c_out)
	req_h := []http2.Header {
		{name = ":method", value = "GET"},
		{name = ":scheme", value = "https"},
		{name = ":authority", value = "example.com"},
		{name = ":path", value = "/"},
	}
	_ = http2.conn_send_request(&client, &c_out, req_h)
	_ = http2.conn_send_request(&client, &c_out, req_h)

	http2.conn_send_preface(&conn.h2, &conn.h2_out)
	testing.expect_value(t, http2.conn_feed(&conn.h2, c_out[:], &conn.h2_out), http2.H2_Error.None)

	h2_host_dispatch_available(&conn)
	// Out not drained offline → exchange still in flight → second not taken.
	testing.expect_value(t, _h2_test_n_calls, 1)
	testing.expect(t, conn.h2_serial_busy)
	used := 0
	for i in 0 ..< H2_SLOT_CAP {
		if conn.h2_slot_used[i] {
			used += 1
		}
	}
	testing.expect_value(t, used, 1)
}

// Free slot after finish allows a third concurrent stream.
@(test)
test_h2_host_free_slot_after_finish_allows_third :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	_h2_test_counters_begin()
	defer _h2_test_counters_end()
	st: Server_Thread
	h2_test_install_worker(&st)
	defer h2_test_uninstall_worker()

	s: Server
	s.conn_allocator = context.allocator
	s.opts = Default_Server_Opts
	s.opts.h2_serial_dispatch = false
	s.handler = handler(_h2_test_handler_count_x)

	conn: Connection
	temp: [128 * 1024]u8
	testing.expect(t, h2_test_conn_setup(&conn, &s, temp[:]))
	defer h2_test_conn_teardown(&conn)

	client: http2.Http2_Connection
	http2.conn_init(&client, false, context.allocator)
	defer http2.conn_destroy(&client)
	c_out: [dynamic]u8
	defer delete(c_out)
	http2.conn_send_preface(&client, &c_out)
	req_h := []http2.Header {
		{name = ":method", value = "GET"},
		{name = ":scheme", value = "https"},
		{name = ":authority", value = "example.com"},
		{name = ":path", value = "/"},
	}
	_ = http2.conn_send_request(&client, &c_out, req_h)
	_ = http2.conn_send_request(&client, &c_out, req_h)

	http2.conn_send_preface(&conn.h2, &conn.h2_out)
	testing.expect_value(t, http2.conn_feed(&conn.h2, c_out[:], &conn.h2_out), http2.H2_Error.None)
	h2_host_dispatch_available(&conn)
	testing.expect_value(t, _h2_test_n_calls, 2)

	// Simulate drain (TLS/offline harness consumed frames).
	clear(&conn.h2_out)
	h2_host_maybe_finish_exchange(&conn)
	used_after := 0
	for i in 0 ..< H2_SLOT_CAP {
		if conn.h2_slot_used[i] {
			used_after += 1
		}
	}
	testing.expect_value(t, used_after, 0)

	// Third stream after free.
	c3: [dynamic]u8
	defer delete(c3)
	_ = http2.conn_send_request(&client, &c3, req_h)
	testing.expect_value(t, http2.conn_feed(&conn.h2, c3[:], &conn.h2_out), http2.H2_Error.None)
	h2_host_dispatch_available(&conn)
	testing.expect_value(t, _h2_test_n_calls, 3)
	testing.expect(t, conn.h2_slot_used[0] || conn.h2_slot_used[1])
}

// Long-lived hold on one slot must not block concurrent take of another stream.
@(test)
test_h2_host_long_lived_slot_allows_other_stream :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	_h2_test_counters_begin()
	defer _h2_test_counters_end()
	st: Server_Thread
	h2_test_install_worker(&st)
	defer h2_test_uninstall_worker()

	s: Server
	s.conn_allocator = context.allocator
	s.opts = Default_Server_Opts
	s.opts.h2_serial_dispatch = false
	s.handler = handler(_h2_test_handler_hold_or_ok)

	conn: Connection
	temp: [128 * 1024]u8
	testing.expect(t, h2_test_conn_setup(&conn, &s, temp[:]))
	defer h2_test_conn_teardown(&conn)

	client: http2.Http2_Connection
	http2.conn_init(&client, false, context.allocator)
	defer http2.conn_destroy(&client)
	c_out: [dynamic]u8
	defer delete(c_out)
	http2.conn_send_preface(&client, &c_out)
	hold_h := []http2.Header {
		{name = ":method", value = "GET"},
		{name = ":scheme", value = "https"},
		{name = ":authority", value = "example.com"},
		{name = ":path", value = "/hold"},
	}
	ok_h := []http2.Header {
		{name = ":method", value = "GET"},
		{name = ":scheme", value = "https"},
		{name = ":authority", value = "example.com"},
		{name = ":path", value = "/ok"},
	}
	_ = http2.conn_send_request(&client, &c_out, hold_h)
	_ = http2.conn_send_request(&client, &c_out, ok_h)

	http2.conn_send_preface(&conn.h2, &conn.h2_out)
	testing.expect_value(t, http2.conn_feed(&conn.h2, c_out[:], &conn.h2_out), http2.H2_Error.None)
	h2_host_dispatch_available(&conn)

	testing.expect_value(t, _h2_test_n_hold, 1)
	testing.expect_value(t, _h2_test_n_ok, 1)
	// Hold slot still used (no end_sent); ok oneshot may still be used until drain.
	held := false
	for i in 0 ..< H2_SLOT_CAP {
		if conn.h2_slot_used[i] && conn.h2_slots[i].res._session_attached {
			held = true
		}
	}
	testing.expect(t, held, "long-lived slot retained")
}

// Document Connection size: h2_slots is a pointer (lazy), not embedded [8]Stream_Slot.
// Measured (amd64): Connection ~4.5 KiB; Stream_Slot ~2 KiB; [8]slab ~16 KiB; ptr 8 B
// → clear/TLS-H1 Connections save ~16 KiB vs embedded multi-slot (MEM-M1).
@(test)
test_h2_slots_pointer_not_embedded_tax :: proc(t: ^testing.T) {
	testing.expect_value(t, size_of(^[H2_SLOT_CAP]Stream_Slot), size_of(rawptr))
	// Full slab is large relative to a pointer (Response-bearing slots).
	testing.expect(t, size_of([H2_SLOT_CAP]Stream_Slot) > 8 * 1024)
	testing.expect(t, size_of(Stream_Slot) > 512)
	testing.expect(t, size_of(Connection) > 1024)
}

// ---------------------------------------------------------------------------
// PR9 M6: SSE multi-slot offline (HEADERS + DATA; RST → Client_Gone)
// ---------------------------------------------------------------------------

// Scan h2_out for DATA frames; return whether sid appeared with non-empty payload.
@(private)
h2_test_out_has_data_sid :: proc(buf: []u8, want_sid: u32) -> bool {
	pos := 0
	for pos + http2.FRAME_HEADER_LEN <= len(buf) {
		length := u32(buf[pos]) << 16 | u32(buf[pos + 1]) << 8 | u32(buf[pos + 2])
		typ := buf[pos + 3]
		sid := u32(buf[pos + 5]) << 24 | u32(buf[pos + 6]) << 16 | u32(buf[pos + 7]) << 8 | u32(buf[pos + 8])
		sid &= 0x7fff_ffff
		if typ == http2.FRAME_DATA && sid == want_sid && length > 0 {
			return true
		}
		pos += http2.FRAME_HEADER_LEN + int(length)
	}
	return false
}

@(private)
h2_test_out_has_headers_sid :: proc(buf: []u8, want_sid: u32) -> bool {
	pos := 0
	for pos + http2.FRAME_HEADER_LEN <= len(buf) {
		length := u32(buf[pos]) << 16 | u32(buf[pos + 1]) << 8 | u32(buf[pos + 2])
		typ := buf[pos + 3]
		flags := buf[pos + 4]
		sid := u32(buf[pos + 5]) << 24 | u32(buf[pos + 6]) << 16 | u32(buf[pos + 7]) << 8 | u32(buf[pos + 8])
		sid &= 0x7fff_ffff
		// HEADERS without END_STREAM for SSE open.
		if typ == http2.FRAME_HEADERS && sid == want_sid && (flags & http2.FLAG_END_STREAM) == 0 {
			return true
		}
		pos += http2.FRAME_HEADER_LEN + int(length)
	}
	return false
}

// Offline: two SSE sessions on one mock h2 conn; effect_sse_data both → DATA on both sids.
@(test)
test_h2_sse_two_sessions_data_frames :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	server: Server
	server.conn_allocator = context.allocator
	server.opts = Default_Server_Opts
	st: Server_Thread
	h2_test_install_worker(&st, &server)
	defer {
		if st.session_scratch_block != nil {
			delete(st.session_scratch_block)
			st.session_scratch_block = nil
		}
		h2_test_uninstall_worker()
	}

	conn: Connection
	conn.server = &server
	conn.state = .Idle
	conn.h2_active = true
	http2.conn_init(&conn.h2, true, context.allocator)
	defer http2.conn_destroy(&conn.h2)
	conn.h2_out.allocator = context.allocator
	defer delete(conn.h2_out)
	testing.expect(t, h2_host_ensure_slots(&conn))
	defer free(conn.h2_slots)

	// Open two server streams (client-initiated odd ids) so conn_send_headers can target them.
	// Minimal: create streams via taking fake complete requests is heavy; use engine stream map
	// by feeding a client preface + two GETs, then attach SSE without full handler.
	client: http2.Http2_Connection
	http2.conn_init(&client, false, context.allocator)
	defer http2.conn_destroy(&client)
	c_out: [dynamic]u8
	defer delete(c_out)
	http2.conn_send_preface(&client, &c_out)
	req_a := []http2.Header {
		{name = ":method", value = "GET"},
		{name = ":scheme", value = "https"},
		{name = ":authority", value = "example.com"},
		{name = ":path", value = "/sse-a"},
	}
	req_b := []http2.Header {
		{name = ":method", value = "GET"},
		{name = ":scheme", value = "https"},
		{name = ":authority", value = "example.com"},
		{name = ":path", value = "/sse-b"},
	}
	sid1 := http2.conn_send_request(&client, &c_out, req_a)
	sid2 := http2.conn_send_request(&client, &c_out, req_b)
	testing.expect_value(t, sid1, u32(1))
	testing.expect_value(t, sid2, u32(3))

	http2.conn_send_preface(&conn.h2, &conn.h2_out)
	testing.expect_value(t, http2.conn_feed(&conn.h2, c_out[:], &conn.h2_out), http2.H2_Error.None)

	// Take both requests and bind slots (serial take loop).
	i1, ok1 := h2_host_slot_alloc(&conn, sid1)
	testing.expect(t, ok1)
	i2, ok2 := h2_host_slot_alloc(&conn, sid2)
	testing.expect(t, ok2)
	// Drain take_request so streams are marked delivered.
	for {
		_, _, _, tok := http2.conn_take_request(&conn.h2)
		if !tok {
			break
		}
	}

	slot_a := &conn.h2_slots[i1]
	slot_b := &conn.h2_slots[i2]
	response_init(&slot_a.res, &conn, context.allocator, slot_a)
	response_init(&slot_b.res, &conn, context.allocator, slot_b)
	// Capture header maps for free (slot_free zeros res without deleting maps).
	hdr_a := &slot_a.res.headers
	hdr_b := &slot_b.res.headers
	defer {
		delete(hdr_a._kv)
		delete(hdr_b._kv)
	}

	on_sse :: proc(sess: ^Session, ev: Session_Event, user: rawptr) -> Effects {
		_ = sess
		_ = user
		if ev.kind == .Start {
			return effects_of(effect_sse_data("hello"))
		}
		return {}
	}

	s1 := sse_start(&slot_a.res, on_sse)
	s2 := sse_start(&slot_b.res, on_sse)
	testing.expect(t, session_status(s1))
	testing.expect(t, session_status(s2))
	testing.expect(t, slot_a.session != nil)
	testing.expect(t, slot_b.session != nil)
	testing.expect(t, slot_a.session != slot_b.session)

	// HEADERS (no END_STREAM) + DATA from Start for both sids.
	testing.expect(t, h2_test_out_has_headers_sid(conn.h2_out[:], sid1), "HEADERS sid1")
	testing.expect(t, h2_test_out_has_headers_sid(conn.h2_out[:], sid2), "HEADERS sid2")
	testing.expect(t, h2_test_out_has_data_sid(conn.h2_out[:], sid1), "DATA sid1")
	testing.expect(t, h2_test_out_has_data_sid(conn.h2_out[:], sid2), "DATA sid2")

	// Explicit mid-session data on both (multi-slot apply).
	st_a := slot_a.session
	st_b := slot_b.session
	_session_apply_effects_st(st_a, effects_of(effect_sse_data("a2")))
	_session_apply_effects_st(st_b, effects_of(effect_sse_data("b2")))
	testing.expect(t, h2_test_out_has_data_sid(conn.h2_out[:], sid1))
	testing.expect(t, h2_test_out_has_data_sid(conn.h2_out[:], sid2))

	// Clean up sessions without slot_free (preserves header maps for defer free).
	if slot_a.session != nil {
		_session_destroy_st(slot_a.session, after_wire = false)
	}
	if slot_b.session != nil {
		_session_destroy_st(slot_b.session, after_wire = false)
	}
	conn.h2_slot_used[i1] = false
	conn.h2_slot_used[i2] = false
	conn.h2_slot_sids[i1] = 0
	conn.h2_slot_sids[i2] = 0
	// Defer will free current header maps (still on slot.res after destroy).
}

// Peer RST_STREAM on one sid → Client_Gone once; other SSE session survives.
@(test)
test_h2_sse_rst_client_gone_once :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	server: Server
	server.conn_allocator = context.allocator
	server.opts = Default_Server_Opts
	st: Server_Thread
	h2_test_install_worker(&st, &server)
	defer {
		if st.session_scratch_block != nil {
			delete(st.session_scratch_block)
			st.session_scratch_block = nil
		}
		h2_test_uninstall_worker()
	}

	conn: Connection
	conn.server = &server
	conn.state = .Idle
	conn.h2_active = true
	http2.conn_init(&conn.h2, true, context.allocator)
	defer http2.conn_destroy(&conn.h2)
	conn.h2_out.allocator = context.allocator
	defer delete(conn.h2_out)
	testing.expect(t, h2_host_ensure_slots(&conn))
	defer free(conn.h2_slots)

	client: http2.Http2_Connection
	http2.conn_init(&client, false, context.allocator)
	defer http2.conn_destroy(&client)
	c_out: [dynamic]u8
	defer delete(c_out)
	http2.conn_send_preface(&client, &c_out)
	req_h := []http2.Header {
		{name = ":method", value = "GET"},
		{name = ":scheme", value = "https"},
		{name = ":authority", value = "example.com"},
		{name = ":path", value = "/sse"},
	}
	// Two streams.
	sid1 := http2.conn_send_request(&client, &c_out, req_h)
	sid2 := http2.conn_send_request(&client, &c_out, req_h)
	http2.conn_send_preface(&conn.h2, &conn.h2_out)
	testing.expect_value(t, http2.conn_feed(&conn.h2, c_out[:], &conn.h2_out), http2.H2_Error.None)

	i1, _ := h2_host_slot_alloc(&conn, sid1)
	i2, _ := h2_host_slot_alloc(&conn, sid2)
	for {
		_, _, _, tok := http2.conn_take_request(&conn.h2)
		if !tok do break
	}

	slot1 := &conn.h2_slots[i1]
	slot2 := &conn.h2_slots[i2]
	response_init(&slot1.res, &conn, context.allocator, slot1)
	response_init(&slot2.res, &conn, context.allocator, slot2)

	// Count Client_Gone deliveries via user cookie.
	Gone_Count :: struct {
		n: int,
	}
	gc1, gc2: Gone_Count

	on1 :: proc(sess: ^Session, ev: Session_Event, user: rawptr) -> Effects {
		_ = sess
		if ev.kind == .Start {
			return effects_of(effect_sse_comment("open"))
		}
		if ev.kind == .Client_Gone {
			c := cast(^Gone_Count)user
			c.n += 1
			return effects_of(effect_abort())
		}
		return {}
	}
	on2 :: proc(sess: ^Session, ev: Session_Event, user: rawptr) -> Effects {
		_ = sess
		if ev.kind == .Start {
			return effects_of(effect_sse_comment("open"))
		}
		if ev.kind == .Client_Gone {
			c := cast(^Gone_Count)user
			c.n += 1
			return effects_of(effect_abort())
		}
		return {}
	}

	_ = sse_start(&slot1.res, on1, Session_Hooks{user = &gc1})
	_ = sse_start(&slot2.res, on2, Session_Hooks{user = &gc2})
	testing.expect(t, slot1.session != nil && slot2.session != nil)
	testing.expect(t, slot1.session.started && slot2.session.started)

	// Snapshot maps after attach (abort/slot_free zeros res without free).
	hdr1 := slot1.res.headers._kv
	hdr2 := slot2.res.headers._kv
	defer {
		delete(hdr1)
		delete(hdr2)
	}

	// Peer RST stream 1 only.
	rst: [dynamic]u8
	defer delete(rst)
	http2.rst_stream_write(&rst, sid1, http2.H2_CANCEL)
	h2_host_on_pt(&conn, rst[:])

	// Session 1 gone once; session 2 still live.
	testing.expect_value(t, gc1.n, 1)
	testing.expect_value(t, gc2.n, 0)
	testing.expect(t, slot1.session == nil, "RST frees slot1 session")
	testing.expect(t, slot2.session != nil, "slot2 survives")

	// Poll again — must not re-fire Client_Gone on slot1 (session already gone).
	h2_host_poll_session_resets(&conn)
	testing.expect_value(t, gc1.n, 1)

	if slot2.session != nil {
		_session_destroy_st(slot2.session, after_wire = false)
	}
	conn.h2_slot_used[i2] = false
	conn.h2_slot_sids[i2] = 0
}

// PR10: simulated server shutdown emits GOAWAY NO_ERROR once; idle → Closing offline.
@(test)
test_h2_host_graceful_goaway_drain_no_error :: proc(t: ^testing.T) {
	s: Server
	s.conn_allocator = context.allocator
	s.opts = Default_Server_Opts

	conn: Connection
	region := make([]u8, 64 * 1024)
	defer delete(region)
	testing.expect(t, h2_test_conn_setup(&conn, &s, region))
	defer h2_test_conn_teardown(&conn)

	// Pretend a prior stream set last_peer_sid.
	conn.h2.last_peer_sid = 5
	conn.state = .Idle

	h2_host_on_server_closing(&conn)

	testing.expect(t, conn.h2_goaway_drain)
	testing.expect(t, conn.h2.goaway_sent)
	testing.expect_value(t, conn.h2.goaway_sent_code, http2.H2_NO_ERROR)
	testing.expect_value(t, conn.h2.goaway_sent_last, u32(5))
	testing.expect(t, conn.state == .Closing, "idle drain closes offline")

	found := false
	pos := 0
	for pos + http2.FRAME_HEADER_LEN <= len(conn.h2_out) {
		length := u32(conn.h2_out[pos]) << 16 | u32(conn.h2_out[pos + 1]) << 8 | u32(conn.h2_out[pos + 2])
		typ := conn.h2_out[pos + 3]
		if typ == http2.FRAME_GOAWAY {
			found = true
			if length >= 8 && pos + http2.FRAME_HEADER_LEN + 8 <= len(conn.h2_out) {
				code := u32(conn.h2_out[pos + 13]) << 24 |
					u32(conn.h2_out[pos + 14]) << 16 |
					u32(conn.h2_out[pos + 15]) << 8 |
					u32(conn.h2_out[pos + 16])
				testing.expect_value(t, code, http2.H2_NO_ERROR)
			}
			break
		}
		pos += http2.FRAME_HEADER_LEN + int(length)
	}
	testing.expect(t, found, "h2_out contains GOAWAY NO_ERROR")

	// Second call is idempotent (no extra GOAWAY).
	n1 := len(conn.h2_out)
	// Reset state so helper can run without early exit on Closing.
	// (already Closing — on_server_closing no-ops)
	h2_host_on_server_closing(&conn)
	testing.expect_value(t, len(conn.h2_out), n1)
}

// PR10: after graceful GOAWAY, new peer stream is REFUSED; prior stream not killed.
@(test)
test_h2_host_after_goaway_new_stream_refused :: proc(t: ^testing.T) {
	conn: Connection
	conn.state = .Idle
	conn.h2_active = true
	http2.conn_init(&conn.h2, true, context.allocator)
	defer http2.conn_destroy(&conn.h2)
	conn.h2_out.allocator = context.allocator
	defer delete(conn.h2_out)
	conn.h2.preface_seen = true
	// Tight stream window so response body stays pending (drain not idle).
	conn.h2.send_window = 10
	conn.h2.peer_settings.initial_window_size = 10

	peer: http2.Http2_Connection
	http2.conn_init(&peer, false, context.allocator)
	defer http2.conn_destroy(&peer)
	peer_out: [dynamic]u8
	defer delete(peer_out)
	_ = http2.conn_send_request(
		&peer,
		&peer_out,
		[]http2.Header{
			{name = ":method", value = "GET"},
			{name = ":scheme", value = "http"},
			{name = ":authority", value = "x"},
			{name = ":path", value = "/hold"},
		},
		nil,
	)
	h2_host_on_pt(&conn, peer_out[:])
	s1, ok1 := conn.h2.streams[1]
	testing.expect(t, ok1, "stream 1 opened")

	// Buffer a large body so stream stays open under tight windows.
	http2.conn_send_headers(&conn.h2, &conn.h2_out, 1, []http2.Header{{name = ":status", value = "200"}}, false)
	body := make([]u8, 50)
	defer delete(body)
	_ = http2.conn_send_body(&conn.h2, &conn.h2_out, 1, body, true)
	testing.expect(t, http2.conn_has_pending_body(&conn.h2) || http2.stream_pending_len(s1) > 0)
	clear(&conn.h2_out)

	// Graceful GOAWAY (simulated shutdown) — not idle while pending remains.
	h2_host_on_server_closing(&conn)
	testing.expect(t, conn.h2.goaway_sent)
	testing.expect(t, conn.h2_goaway_drain)
	testing.expect(t, !h2_host_goaway_drain_idle(&conn), "pending body blocks drain idle")
	testing.expect(t, conn.state != .Closing, "drain waits for prior stream")

	// New stream 3 after GOAWAY.
	clear(&conn.h2_out)
	clear(&peer_out)
	_ = http2.conn_send_request(
		&peer,
		&peer_out,
		[]http2.Header{
			{name = ":method", value = "GET"},
			{name = ":scheme", value = "http"},
			{name = ":authority", value = "x"},
			{name = ":path", value = "/new"},
		},
		nil,
	)
	h2_host_on_pt(&conn, peer_out[:])

	// RST REFUSED for stream 3.
	saw_rst := false
	pos := 0
	for pos + http2.FRAME_HEADER_LEN <= len(conn.h2_out) {
		length := u32(conn.h2_out[pos]) << 16 | u32(conn.h2_out[pos + 1]) << 8 | u32(conn.h2_out[pos + 2])
		typ := conn.h2_out[pos + 3]
		sid := u32(conn.h2_out[pos + 5]) << 24 | u32(conn.h2_out[pos + 6]) << 16 |
			u32(conn.h2_out[pos + 7]) << 8 | u32(conn.h2_out[pos + 8])
		sid &= 0x7fff_ffff
		if typ == http2.FRAME_RST_STREAM && sid == 3 {
			saw_rst = true
		}
		pos += http2.FRAME_HEADER_LEN + int(length)
	}
	testing.expect(t, saw_rst, "new stream after GOAWAY gets RST")

	// Stream 1 not failed.
	if s, ok := conn.h2.streams[1]; ok {
		testing.expect(t, !s.failed, "prior stream not failed")
	}
	// Stream 3 not opened (refused after HPACK decode only).
	_, ok3 := conn.h2.streams[3]
	testing.expect(t, !ok3, "refused stream not opened")
}

// PR10 soft admission: multi-slot full → RST_STREAM(REFUSED_STREAM); conn not Closing.
@(test)
test_h2_host_slot_full_refused_stream :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	st: Server_Thread
	h2_test_install_worker(&st)
	defer h2_test_uninstall_worker()

	s: Server
	s.conn_allocator = context.allocator
	s.opts = Default_Server_Opts
	s.opts.h2_serial_dispatch = false
	s.handler = handler(_h2_test_handler_count_ok)

	conn: Connection
	temp: [64 * 1024]u8
	testing.expect(t, h2_test_conn_setup(&conn, &s, temp[:]))
	defer h2_test_conn_teardown(&conn)

	// Fill every multi-slot entry (simulate CAP long-lived holds).
	for i in 0 ..< H2_SLOT_CAP {
		conn.h2_slot_used[i] = true
		conn.h2_slot_sids[i] = u32(100 + i)
	}
	testing.expect(t, !h2_host_has_free_slot(&conn))

	client: http2.Http2_Connection
	http2.conn_init(&client, false, context.allocator)
	defer http2.conn_destroy(&client)
	c_out: [dynamic]u8
	defer delete(c_out)
	http2.conn_send_preface(&client, &c_out)
	req_h := []http2.Header {
		{name = ":method", value = "GET"},
		{name = ":scheme", value = "https"},
		{name = ":authority", value = "example.com"},
		{name = ":path", value = "/overflow"},
	}
	sid := http2.conn_send_request(&client, &c_out, req_h)
	testing.expect(t, sid != 0)

	http2.conn_send_preface(&conn.h2, &conn.h2_out)
	// Keep preface SETTINGS noise out of the RST scan baseline.
	clear(&conn.h2_out)
	testing.expect_value(t, http2.conn_feed(&conn.h2, c_out[:], &conn.h2_out), http2.H2_Error.None)
	// Drop auto SETTINGS ACK etc.; dispatch will write RST into h2_out.
	clear(&conn.h2_out)

	h2_host_dispatch_available(&conn)

	// Connection must stay open (not Closing).
	testing.expect(t, conn.state < .Closing, "slot full must not close connection")

	// RST_STREAM(REFUSED_STREAM) for the refused sid.
	saw_rst := false
	pos := 0
	for pos + http2.FRAME_HEADER_LEN <= len(conn.h2_out) {
		length := u32(conn.h2_out[pos]) << 16 | u32(conn.h2_out[pos + 1]) << 8 | u32(conn.h2_out[pos + 2])
		typ := conn.h2_out[pos + 3]
		frame_sid := u32(conn.h2_out[pos + 5]) << 24 | u32(conn.h2_out[pos + 6]) << 16 |
			u32(conn.h2_out[pos + 7]) << 8 | u32(conn.h2_out[pos + 8])
		frame_sid &= 0x7fff_ffff
		if typ == http2.FRAME_RST_STREAM && frame_sid == sid {
			if length >= 4 && pos + http2.FRAME_HEADER_LEN + 4 <= len(conn.h2_out) {
				code := u32(conn.h2_out[pos + 9]) << 24 |
					u32(conn.h2_out[pos + 10]) << 16 |
					u32(conn.h2_out[pos + 11]) << 8 |
					u32(conn.h2_out[pos + 12])
				testing.expect_value(t, code, http2.H2_REFUSED_STREAM)
			}
			saw_rst = true
		}
		pos += http2.FRAME_HEADER_LEN + int(length)
	}
	testing.expect(t, saw_rst, "REFUSED_STREAM when multi-slot full")

	// Taken stream must not re-deliver.
	_, _, _, again := http2.conn_take_request(&conn.h2)
	testing.expect(t, !again, "refused stream not re-taken")
}

// PR10 soft admission: sse_start over cap on H2 → 503 HEADERS END_STREAM, invalid Session.
@(test)
test_h2_sse_start_soft_reject_over_cap :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	server: Server
	server.conn_allocator = context.allocator
	server.opts = Default_Server_Opts
	server.opts.max_sessions_per_worker = 1
	server.opts.thread_count = 1

	prev_live := sync.atomic_load(&session_metrics_live)
	prev_rej := sync.atomic_load(&session_metrics_admission_reject)
	sync.atomic_store(&session_metrics_live, 1)
	defer sync.atomic_store(&session_metrics_live, prev_live)

	conn: Connection
	conn.server = &server
	conn.state = .Idle
	conn.h2_active = true
	http2.conn_init(&conn.h2, true, context.allocator)
	defer http2.conn_destroy(&conn.h2)
	conn.h2_out.allocator = context.allocator
	defer delete(conn.h2_out)
	testing.expect(t, h2_host_ensure_slots(&conn))
	defer free(conn.h2_slots)

	client: http2.Http2_Connection
	http2.conn_init(&client, false, context.allocator)
	defer http2.conn_destroy(&client)
	c_out: [dynamic]u8
	defer delete(c_out)
	http2.conn_send_preface(&client, &c_out)
	req := []http2.Header {
		{name = ":method", value = "GET"},
		{name = ":scheme", value = "https"},
		{name = ":authority", value = "example.com"},
		{name = ":path", value = "/sse"},
	}
	sid := http2.conn_send_request(&client, &c_out, req)
	http2.conn_send_preface(&conn.h2, &conn.h2_out)
	testing.expect_value(t, http2.conn_feed(&conn.h2, c_out[:], &conn.h2_out), http2.H2_Error.None)

	i, ok := h2_host_slot_alloc(&conn, sid)
	testing.expect(t, ok)
	for {
		_, _, _, tok := http2.conn_take_request(&conn.h2)
		if !tok {
			break
		}
	}
	slot := &conn.h2_slots[i]
	response_init(&slot.res, &conn, context.allocator, slot)
	defer delete(slot.res.headers._kv)
	clear(&conn.h2_out)

	on_sse :: proc(sess: ^Session, ev: Session_Event, user: rawptr) -> Effects {
		_ = sess
		_ = ev
		_ = user
		return effects_of(effect_sse_data("nope"))
	}

	s := sse_start(&slot.res, on_sse)
	testing.expect_value(t, s.id, u32(0))
	testing.expect(t, !session_status(s))
	testing.expect_value(t, slot.res.status, Status.Service_Unavailable)
	testing.expect(t, slot.res.sent)
	testing.expect(t, slot.session == nil)
	testing.expect(t, sync.atomic_load(&session_metrics_admission_reject) > prev_rej)

	// 503 HEADERS with END_STREAM for this sid.
	saw_headers_es := false
	pos := 0
	for pos + http2.FRAME_HEADER_LEN <= len(conn.h2_out) {
		length := u32(conn.h2_out[pos]) << 16 | u32(conn.h2_out[pos + 1]) << 8 | u32(conn.h2_out[pos + 2])
		typ := conn.h2_out[pos + 3]
		flags := conn.h2_out[pos + 4]
		frame_sid := u32(conn.h2_out[pos + 5]) << 24 | u32(conn.h2_out[pos + 6]) << 16 |
			u32(conn.h2_out[pos + 7]) << 8 | u32(conn.h2_out[pos + 8])
		frame_sid &= 0x7fff_ffff
		if typ == http2.FRAME_HEADERS && frame_sid == sid && (flags & http2.FLAG_END_STREAM) != 0 {
			saw_headers_es = true
		}
		pos += http2.FRAME_HEADER_LEN + int(length)
	}
	testing.expect(t, saw_headers_es, "503 HEADERS END_STREAM on soft reject")
}
