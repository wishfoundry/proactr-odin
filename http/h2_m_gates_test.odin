// Existing coverage aliased here for the product bar:
//   M1 — concurrent unary ≥2  (also: test_h2_host_concurrent_two_get_streams)
//   M2 — concurrent deferred large bodies ≥2 + WINDOW_UPDATE drain
//   M3 — fair RR flush under equal windows (engine: test_h2_flush_rr_two_pending_streams)
//   M4 — duplex: flush does not unarm CT recv; send-complete arm path (count)
//   M5 — peak on-wire DATA O(window), not O(sum full bodies)
//   M6 — two concurrent SSE via dispatch+handler + RST Client_Gone (M6a+M6b)
//        (also: test_h2_sse_two_sessions_data_frames, test_h2_sse_rst_client_gone_once)
// Run: odin test http -define:ODIN_TEST_THREADS=1 -o:none
package http

import "core:testing"

import http2 "../http2"

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

@(private = "file")
m_gate_data_bytes_for_sid :: proc(buf: []u8, want_sid: u32) -> int {
	total := 0
	pos := 0
	for pos + http2.FRAME_HEADER_LEN <= len(buf) {
		length := u32(buf[pos]) << 16 | u32(buf[pos + 1]) << 8 | u32(buf[pos + 2])
		typ := buf[pos + 3]
		sid := u32(buf[pos + 5]) << 24 | u32(buf[pos + 6]) << 16 | u32(buf[pos + 7]) << 8 | u32(buf[pos + 8])
		sid &= 0x7fff_ffff
		if typ == http2.FRAME_DATA && sid == want_sid {
			total += int(length)
		}
		pos += http2.FRAME_HEADER_LEN + int(length)
	}
	return total
}

@(private = "file")
m_gate_total_data_bytes :: proc(buf: []u8) -> int {
	total := 0
	pos := 0
	for pos + http2.FRAME_HEADER_LEN <= len(buf) {
		length := u32(buf[pos]) << 16 | u32(buf[pos + 1]) << 8 | u32(buf[pos + 2])
		typ := buf[pos + 3]
		if typ == http2.FRAME_DATA {
			total += int(length)
		}
		pos += http2.FRAME_HEADER_LEN + int(length)
	}
	return total
}

@(private = "file")
m_gate_has_data_sid :: proc(buf: []u8, want_sid: u32) -> bool {
	return m_gate_data_bytes_for_sid(buf, want_sid) > 0
}

// ---------------------------------------------------------------------------
// M1 — Concurrent unary ≥2
// ---------------------------------------------------------------------------

// Alias gate: two concurrent GET streams → two 200 responses (product concurrent).
@(test)
test_m1_concurrent_unary_two_get :: proc(t: ^testing.T) {
	// Same offline harness as test_h2_host_concurrent_two_get_streams; named M1 product gate.
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

	http2.conn_send_preface(&conn.h2, &conn.h2_out)
	testing.expect_value(t, http2.conn_feed(&conn.h2, c_out[:], &conn.h2_out), http2.H2_Error.None)
	h2_host_dispatch_available(&conn)

	used := 0
	for i in 0 ..< H2_SLOT_CAP {
		if conn.h2_slot_used[i] do used += 1
	}
	testing.expect_value(t, used, 2)

	c2: [dynamic]u8
	defer delete(c2)
	testing.expect_value(t, http2.conn_feed(&client, conn.h2_out[:], &c2), http2.H2_Error.None)
	_, rb1, d1 := http2.conn_response(&client, sid1)
	_, rb2, d2 := http2.conn_response(&client, sid2)
	testing.expect(t, d1 && d2, "M1: both unary responses present")
	got_a := string(rb1) == "/a" || string(rb2) == "/a"
	got_b := string(rb1) == "/b" || string(rb2) == "/b"
	testing.expect(t, got_a && got_b, "M1: both path bodies")
}

// ---------------------------------------------------------------------------
// M2 — Concurrent deferred large bodies ≥2 + WINDOW_UPDATE drain
// ---------------------------------------------------------------------------

@(test)
test_m2_concurrent_deferred_large_bodies_window_update :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	// Engine offline: two streams, bodies > window; WINDOW_UPDATE drains both pending.
	srv: http2.Http2_Connection
	http2.conn_init(&srv, true, context.allocator)
	defer http2.conn_destroy(&srv)

	out: [dynamic]u8
	defer delete(out)

	client: http2.Http2_Connection
	http2.conn_init(&client, false, context.allocator)
	defer http2.conn_destroy(&client)
	c_out: [dynamic]u8
	defer delete(c_out)
	http2.conn_send_preface(&client, &c_out)
	req_h := []http2.Header {
		{name = ":method", value = "GET"},
		{name = ":scheme", value = "https"},
		{name = ":authority", value = "x"},
		{name = ":path", value = "/"},
	}
	sid1 := http2.conn_send_request(&client, &c_out, req_h)
	sid2 := http2.conn_send_request(&client, &c_out, req_h)
	// Server consumes client preface + SETTINGS + HEADERS (do not pre-set preface_seen).
	http2.conn_send_preface(&srv, &out)
	testing.expect_value(t, http2.conn_feed(&srv, c_out[:], &out), http2.H2_Error.None)
	clear(&out)

	s1, ok1 := srv.streams[sid1]
	s2, ok2 := srv.streams[sid2]
	testing.expect(t, ok1 && ok2)
	// Tight stream + conn windows for deferred body proof.
	s1.send_window = 10
	s2.send_window = 10
	srv.send_window = 10

	body := make([]u8, 50)
	defer delete(body)
	for i in 0 ..< 50 do body[i] = u8('B')

	http2.conn_send_headers(&srv, &out, sid1, []http2.Header{{name = ":status", value = "200"}}, false)
	b1 := http2.conn_send_body(&srv, &out, sid1, body, true)
	http2.conn_send_headers(&srv, &out, sid2, []http2.Header{{name = ":status", value = "200"}}, false)
	b2 := http2.conn_send_body(&srv, &out, sid2, body, true)
	testing.expect(t, b1 > 0 && b2 > 0, "M2: both bodies deferred under window")
	testing.expect(t, http2.conn_has_pending_body(&srv))

	// Drain both via stream + conn WINDOW_UPDATEs (engine + fair RR on conn credit).
	updates := 0
	for http2.conn_has_pending_body(&srv) && updates < 40 {
		clear(&out)
		wu: [dynamic]u8
		defer delete(wu)
		http2.window_update_write(&wu, sid1, 20)
		http2.window_update_write(&wu, sid2, 20)
		http2.window_update_write(&wu, 0, 40)
		testing.expect_value(t, http2.conn_feed(&srv, wu[:], &out), http2.H2_Error.None)
		updates += 1
	}
	testing.expect(t, !http2.conn_has_pending_body(&srv), "M2: both pending drained after WINDOW_UPDATE")
	testing.expect_value(t, http2.stream_pending_len(s1), 0)
	testing.expect_value(t, http2.stream_pending_len(s2), 0)
	testing.expect(t, s1.end_sent && s2.end_sent, "M2: END_STREAM both streams")
}

// ---------------------------------------------------------------------------
// M3 — Fair RR (engine cursor + both streams progress)
// ---------------------------------------------------------------------------

@(test)
test_m3_fair_rr_both_streams_progress :: proc(t: ^testing.T) {
	// Engine gate: see also test_h2_flush_rr_two_pending_streams in http2/flow_test.
	srv: http2.Http2_Connection
	http2.conn_init(&srv, true, context.allocator)
	defer http2.conn_destroy(&srv)

	out: [dynamic]u8
	defer delete(out)

	client: http2.Http2_Connection
	http2.conn_init(&client, false, context.allocator)
	defer http2.conn_destroy(&client)
	c_out: [dynamic]u8
	defer delete(c_out)
	http2.conn_send_preface(&client, &c_out)
	req_h := []http2.Header {
		{name = ":method", value = "GET"},
		{name = ":scheme", value = "https"},
		{name = ":authority", value = "x"},
		{name = ":path", value = "/"},
	}
	sid1 := http2.conn_send_request(&client, &c_out, req_h)
	sid2 := http2.conn_send_request(&client, &c_out, req_h)
	http2.conn_send_preface(&srv, &out)
	testing.expect_value(t, http2.conn_feed(&srv, c_out[:], &out), http2.H2_Error.None)
	clear(&out)

	s1 := srv.streams[sid1]
	s2 := srv.streams[sid2]
	s1.send_window = 100
	s2.send_window = 100
	srv.send_window = 0 // force full buffer, then RR on credit

	body := make([]u8, 30)
	defer delete(body)
	for i in 0 ..< 30 do body[i] = u8(i)

	// Queue both under zero conn window.
	_ = http2.conn_send_body(&srv, &out, sid1, body, true)
	_ = http2.conn_send_body(&srv, &out, sid2, body, true)
	testing.expect_value(t, http2.stream_pending_len(s1), 30)
	testing.expect_value(t, http2.stream_pending_len(s2), 30)

	// +16 conn credit: fair RR must emit DATA for both sids.
	clear(&out)
	wu: [dynamic]u8
	defer delete(wu)
	http2.window_update_write(&wu, 0, 16)
	testing.expect_value(t, http2.conn_feed(&srv, wu[:], &out), http2.H2_Error.None)

	d1 := m_gate_data_bytes_for_sid(out[:], sid1)
	d2 := m_gate_data_bytes_for_sid(out[:], sid2)
	testing.expect(t, d1 > 0 && d2 > 0, "M3: both streams got DATA under shared credit")
	testing.expect(t, d1 + d2 <= 16, "M3: total DATA ≤ conn credit")
	testing.expect(t, srv.flush_rr > 0, "M3: flush_rr advanced")
}

// ---------------------------------------------------------------------------
// M4 — Duplex: flush does not unarm recv; send-complete re-arms
// ---------------------------------------------------------------------------

@(test)
test_m4_duplex_flush_does_not_unarm_recv :: proc(t: ^testing.T) {
	// Offline duplex contract (not nil-SSL theater alone):
	// 1) flush_out never clears tls_ct_recv_inflight
	// 2) h2_host_on_send_complete always takes the arm path when Open
	//    (h2_test_arm_recv_count); tls_host_arm_recv may no-op without SSL/ring
	//    but the duplex call order is proven.
	server: Server
	server.conn_allocator = context.allocator
	server.opts = Default_Server_Opts

	conn: Connection
	conn.server = &server
	conn.state = .Idle
	conn.h2_active = true
	conn.tls_ssl = nil
	tls_pipe_init(&conn.tls_pipe)
	conn.tls_pipe.state = .Open // ciphered open state for arm path
	conn.tls_ct_recv_inflight = true // armed as if CT RECV outstanding
	conn.h2_out.allocator = context.allocator
	defer delete(conn.h2_out)
	append(&conn.h2_out, 1, 2, 3, 4) // residual plain frames

	h2_host_flush_out(&conn)
	// Offline (no SSL): early return; must NOT clear recv inflight.
	testing.expect(t, conn.tls_ct_recv_inflight, "M4: flush does not unarm CT recv")
	testing.expect(t, len(conn.h2_out) == 4)

	// Send-complete: handled + arm path taken (count) without requiring unarm first.
	before := h2_test_arm_recv_count
	conn.tls_ct_recv_inflight = true
	ok := h2_host_on_send_complete(&conn)
	testing.expect(t, ok, "M4: send-complete handled for h2_active")
	testing.expect(t, h2_test_arm_recv_count == before + 1, "M4: send-complete arms recv (duplex)")
	// Inflight flag stays true (arm_recv short-circuits when already inflight /
	// or no-ops without ssl — never forced false by send-complete).
	testing.expect(t, conn.tls_ct_recv_inflight, "M4: send-complete does not force unarm")

	// Closed pipe must not arm.
	before2 := h2_test_arm_recv_count
	conn.tls_pipe.state = .Closed
	_ = h2_host_on_send_complete(&conn)
	testing.expect(t, h2_test_arm_recv_count == before2, "M4: no arm when pipe not Open")
}

// ---------------------------------------------------------------------------
// M5 — Peak on-wire O(window)
// ---------------------------------------------------------------------------

@(test)
test_m5_peak_wire_o_window_not_o_sum_bodies :: proc(t: ^testing.T) {
	// See also test_h2_peak_wire_o_window_two_large_bodies in http2/flow_test.
	srv: http2.Http2_Connection
	http2.conn_init(&srv, true, context.allocator)
	defer http2.conn_destroy(&srv)

	out: [dynamic]u8
	defer delete(out)

	client: http2.Http2_Connection
	http2.conn_init(&client, false, context.allocator)
	defer http2.conn_destroy(&client)
	c_out: [dynamic]u8
	defer delete(c_out)
	http2.conn_send_preface(&client, &c_out)
	req_h := []http2.Header {
		{name = ":method", value = "GET"},
		{name = ":scheme", value = "https"},
		{name = ":authority", value = "x"},
		{name = ":path", value = "/"},
	}
	sid1 := http2.conn_send_request(&client, &c_out, req_h)
	sid2 := http2.conn_send_request(&client, &c_out, req_h)
	http2.conn_send_preface(&srv, &out)
	testing.expect_value(t, http2.conn_feed(&srv, c_out[:], &out), http2.H2_Error.None)
	clear(&out)

	// Force tight windows after streams exist.
	srv.streams[sid1].send_window = 8
	srv.streams[sid2].send_window = 8
	srv.send_window = 8

	big := make([]u8, 200)
	defer delete(big)
	for i in 0 ..< 200 do big[i] = u8('X')

	http2.conn_send_headers(&srv, &out, sid1, []http2.Header{{name = ":status", value = "200"}}, false)
	_ = http2.conn_send_body(&srv, &out, sid1, big, true)
	http2.conn_send_headers(&srv, &out, sid2, []http2.Header{{name = ":status", value = "200"}}, false)
	_ = http2.conn_send_body(&srv, &out, sid2, big, true)

	wire := m_gate_total_data_bytes(out[:])
	testing.expect(t, wire <= 8, "M5: wire DATA ≤ conn window (not O(sum full bodies))")
	// Pending may hold remainder (oneshot dump + backpressure signal); that is
	// intentional. Product claim is peak *on-wire* O(window).
	testing.expect(t, http2.conn_has_pending_body(&srv), "M5: remainder buffered pending WINDOW_UPDATE")
	pending_sum := http2.stream_pending_len(srv.streams[sid1]) + http2.stream_pending_len(srv.streams[sid2])
	testing.expect(t, pending_sum + wire == 400, "M5: body bytes conserved (wire + pending)")
}

// ---------------------------------------------------------------------------
// M6 — Two concurrent SSE via dispatch+handler + RST Client_Gone (M6a+M6b)
// ---------------------------------------------------------------------------

// Package-level gone cookies (handler procs cannot capture test locals).
@(private)
_h2_m6_gone_a: int
@(private)
_h2_m6_gone_b: int

@(private)
_h2_m6_on_sse :: proc(sess: ^Session, ev: Session_Event, user: rawptr) -> Effects {
	_ = sess
	if ev.kind == .Start {
		// Short session: Start data only (no Arm) — DATA frames prove multi-SSE.
		return effects_of(effect_sse_data("m6"))
	}
	if ev.kind == .Client_Gone {
		c := cast(^int)user
		c^ += 1
		return effects_of(effect_abort())
	}
	return {}
}

@(private)
_h2_m6_handler_sse :: proc(req: ^Request, res: ^Response) {
	path := "/"
	if line, ok := req.line.?; ok {
		if p, pok := line.target.(string); pok {
			path = p
		}
	}
	cookie: rawptr
	if path == "/sse-a" {
		cookie = &_h2_m6_gone_a
	} else {
		cookie = &_h2_m6_gone_b
	}
	_ = sse_start(res, _h2_m6_on_sse, Session_Hooks{user = cookie})
}

@(test)
test_m6_two_concurrent_sse_sessions :: proc(t: ^testing.T) {
	// M6a: two complete H2 GETs → dispatch_available → handler sse_start → DATA both sids
	// M6b: peer RST one stream → Client_Gone once; sibling session survives
	// (product gate through real host dispatch — not manual slot_alloc).
	defer free_all(context.temp_allocator)

	st: Server_Thread
	h2_test_install_worker(&st)
	defer {
		if st.session_scratch_block != nil {
			delete(st.session_scratch_block)
			st.session_scratch_block = nil
		}
		h2_test_uninstall_worker()
	}

	s: Server
	s.conn_allocator = context.allocator
	s.opts = Default_Server_Opts
	s.opts.h2_serial_dispatch = false
	s.handler = handler(_h2_m6_handler_sse)
	st.server = &s

	_h2_m6_gone_a = 0
	_h2_m6_gone_b = 0

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

	http2.conn_send_preface(&conn.h2, &conn.h2_out)
	testing.expect_value(t, http2.conn_feed(&conn.h2, c_out[:], &conn.h2_out), http2.H2_Error.None)
	h2_host_dispatch_available(&conn)

	// M6a: two slots hold distinct SSE sessions; Start effects wrote DATA both sids.
	used := 0
	sess_n := 0
	for i in 0 ..< H2_SLOT_CAP {
		if conn.h2_slot_used[i] {
			used += 1
			if conn.h2_slots[i].session != nil {
				sess_n += 1
			}
		}
	}
	testing.expect_value(t, used, 2)
	testing.expect_value(t, sess_n, 2)
	testing.expect(t, m_gate_has_data_sid(conn.h2_out[:], sid1), "M6a: DATA sid1 via dispatch+handler")
	testing.expect(t, m_gate_has_data_sid(conn.h2_out[:], sid2), "M6a: DATA sid2 via dispatch+handler")

	// Locate slots by sid for post-RST checks.
	i1, ok1 := h2_host_slot_find(&conn, sid1)
	i2, ok2 := h2_host_slot_find(&conn, sid2)
	testing.expect(t, ok1 && ok2)
	testing.expect(t, conn.h2_slots[i1].session != conn.h2_slots[i2].session)

	// M6b: peer RST stream 1 only → Client_Gone once; sibling lives.
	rst: [dynamic]u8
	defer delete(rst)
	http2.rst_stream_write(&rst, sid1, http2.H2_CANCEL)
	h2_host_on_pt(&conn, rst[:])

	testing.expect_value(t, _h2_m6_gone_a, 1)
	testing.expect_value(t, _h2_m6_gone_b, 0)
	// Abort frees slot1; slot2 session remains.
	_, still1 := h2_host_slot_find(&conn, sid1)
	testing.expect(t, !still1, "M6b: RST frees slot1")
	testing.expect(t, conn.h2_slots[i2].session != nil, "M6b: sibling session lives")

	// Re-poll must not double-fire Client_Gone on the gone stream.
	h2_host_poll_session_resets(&conn)
	testing.expect_value(t, _h2_m6_gone_a, 1)
	testing.expect_value(t, _h2_m6_gone_b, 0)

	// Clean sibling session (header maps zeroed with slot; small unit leak OK).
	if si, ok := h2_host_slot_find(&conn, sid2); ok {
		h2_host_slot_free(&conn, si)
	}
}
