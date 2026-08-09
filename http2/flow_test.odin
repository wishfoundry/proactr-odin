package http2

import "core:slice"
import "core:testing"

import "../hpack"

// Drive a 25-byte response body through a 10-byte send window and prove the
// engine sends only what the window allows, buffers the rest, and drains it as
// WINDOW_UPDATE frames arrive — final frame carrying END_STREAM.
@(test)
test_h2_flow_control :: proc(t: ^testing.T) {
	srv: Http2_Connection
	conn_init(&srv, true)
	defer conn_destroy(&srv)

	out: [dynamic]u8
	defer delete(out)

	// --- Bring up: client preface + the peer's SETTINGS (INITIAL_WINDOW_SIZE=10) ---
	in_buf: [dynamic]u8
	defer delete(in_buf)
	append(&in_buf, ..transmute([]u8)string(CLIENT_PREFACE))
	sp := [?]u8{u8(SETTINGS_INITIAL_WINDOW_SIZE >> 8), u8(SETTINGS_INITIAL_WINDOW_SIZE), 0, 0, 0, 10}
	frame_write(&in_buf, FRAME_SETTINGS, 0, 0, sp[:])
	testing.expect_value(t, conn_feed(&srv, in_buf[:], &out), H2_Error.None)
	testing.expect_value(t, srv.peer_settings.initial_window_size, u32(10))

	// --- Client opens stream 1 (bodyless GET) ---
	req_block: [dynamic]u8
	defer delete(req_block)
	hpack.encode(&req_block, []Header{{name = ":method", value = "GET"}, {name = ":scheme", value = "http"}, {name = ":authority", value = "x"}, {name = ":path", value = "/"}})
	hbuf: [dynamic]u8
	defer delete(hbuf)
	frame_write(&hbuf, FRAME_HEADERS, FLAG_END_HEADERS | FLAG_END_STREAM, 1, req_block[:])
	clear(&out)
	testing.expect_value(t, conn_feed(&srv, hbuf[:], &out), H2_Error.None)

	s, ok := srv.streams[1]
	testing.expect(t, ok, "stream 1 exists")
	testing.expect_value(t, s.send_window, i64(10)) // inherited the peer's initial window

	// --- Server streams a 25-byte body: only 10 go out, 15 buffer ---
	body := make([]u8, 25)
	defer delete(body)
	for i in 0 ..< 25 do body[i] = u8('A') + u8(i)

	clear(&out)
	conn_send_headers(&srv, &out, 1, []Header{{name = ":status", value = "200"}}, false)
	buffered := conn_send_body(&srv, &out, 1, body, true /* end_stream */)
	testing.expect_value(t, buffered, 15)

	// out = HEADERS, then DATA(10) with no END_STREAM.
	hf, _, c1, e1 := frame_decode(out[:])
	testing.expect_value(t, e1, Frame_Error.None)
	testing.expect_value(t, hf.type, FRAME_HEADERS)
	d1, _, _, e2 := frame_decode(out[c1:])
	testing.expect_value(t, e2, Frame_Error.None)
	testing.expect_value(t, d1.type, FRAME_DATA)
	testing.expect_value(t, d1.length, u32(10))
	testing.expect(t, d1.flags & FLAG_END_STREAM == 0, "not END_STREAM yet")

	// --- WINDOW_UPDATE(+10) → 10 more bytes drain ---
	wu: [dynamic]u8
	defer delete(wu)
	window_update_write(&wu, 1, 10)
	clear(&out)
	testing.expect_value(t, conn_feed(&srv, wu[:], &out), H2_Error.None)
	d2, _, _, e3 := frame_decode(out[:])
	testing.expect_value(t, e3, Frame_Error.None)
	testing.expect_value(t, d2.type, FRAME_DATA)
	testing.expect_value(t, d2.length, u32(10))
	testing.expect(t, d2.flags & FLAG_END_STREAM == 0, "still 5 to go")
	testing.expect_value(t, stream_pending_len(s), 5)

	// --- WINDOW_UPDATE(+100) → final 5 bytes + END_STREAM ---
	clear(&wu)
	window_update_write(&wu, 1, 100)
	clear(&out)
	testing.expect_value(t, conn_feed(&srv, wu[:], &out), H2_Error.None)
	d3, p3, _, e4 := frame_decode(out[:])
	testing.expect_value(t, e4, Frame_Error.None)
	testing.expect_value(t, d3.type, FRAME_DATA)
	testing.expect_value(t, d3.length, u32(5))
	testing.expect(t, d3.flags & FLAG_END_STREAM != 0, "END_STREAM on the final frame")
	testing.expect_value(t, stream_pending_len(s), 0)
	testing.expect(t, slice.equal(p3, body[20:25]), "final 5 bytes are the tail of the body")
}

// Inbound flow control: receiving DATA must emit WINDOW_UPDATE grants
// (connection + stream) or a real peer stalls after one 65535-byte window —
// exactly how google.com behaved before this was added.
@(test)
test_h2_inbound_window_replenish :: proc(t: ^testing.T) {
	cli: Http2_Connection
	conn_init(&cli, false)
	defer conn_destroy(&cli)

	out: [dynamic]u8
	defer delete(out)

	// Open stream 1 (a request) — DATA on a never-opened stream is now an
	// idle-stream protocol error.
	scratch: [dynamic]u8
	defer delete(scratch)
	conn_send_request(&cli, &scratch, []Header{{name = ":method", value = "GET"}, {name = ":scheme", value = "http"}, {name = ":authority", value = "x"}, {name = ":path", value = "/"}})

	// Peer sends 100 bytes of DATA on stream 1, no END_STREAM.
	in_buf: [dynamic]u8
	defer delete(in_buf)
	chunk := make([]u8, 100)
	defer delete(chunk)
	frame_write(&in_buf, FRAME_DATA, 0, 1, chunk)
	testing.expect_value(t, conn_feed(&cli, in_buf[:], &out), H2_Error.None)

	// Expect WINDOW_UPDATE(conn, +100) then WINDOW_UPDATE(stream 1, +100).
	w1, p1, c1, e1 := frame_decode(out[:])
	testing.expect_value(t, e1, Frame_Error.None)
	testing.expect_value(t, w1.type, FRAME_WINDOW_UPDATE)
	testing.expect_value(t, w1.stream_id, u32(0))
	testing.expect_value(t, get_u32(p1), u32(100))
	w2, p2, _, e2 := frame_decode(out[c1:])
	testing.expect_value(t, e2, Frame_Error.None)
	testing.expect_value(t, w2.type, FRAME_WINDOW_UPDATE)
	testing.expect_value(t, w2.stream_id, u32(1))
	testing.expect_value(t, get_u32(p2), u32(100))

	// END_STREAM DATA: connection-level grant only — the stream is done.
	clear(&in_buf)
	clear(&out)
	frame_write(&in_buf, FRAME_DATA, FLAG_END_STREAM, 1, chunk[:10])
	testing.expect_value(t, conn_feed(&cli, in_buf[:], &out), H2_Error.None)
	w3, _, c3, e3 := frame_decode(out[:])
	testing.expect_value(t, e3, Frame_Error.None)
	testing.expect_value(t, w3.type, FRAME_WINDOW_UPDATE)
	testing.expect_value(t, w3.stream_id, u32(0))
	testing.expect_value(t, len(out), c3) // nothing after the conn-level grant
}

// Backpressure drain: the server's response loop (serverx/listener.odin)
// sends a body larger than both windows, sees it partially buffered, then
// drains by feeding WINDOW_UPDATEs until conn_has_pending_body is false and
// the stream's END_STREAM has been emitted. This is the unit-level proof
// that the _serve_h2_conn drain loop terminates.
@(test)
test_h2_response_drains_under_backpressure :: proc(t: ^testing.T) {
	srv: Http2_Connection
	conn_init(&srv, true)
	defer conn_destroy(&srv)
	srv.preface_seen = true

	// Tight windows: 10 bytes each on the stream and connection. A 50-byte
	// body can't fit in one shot — most of it will buffer.
	srv.peer_settings.initial_window_size = 10
	body := make([]u8, 50, context.temp_allocator)
	for i in 0..<50 do body[i] = u8(i)

	out: [dynamic]u8
	defer delete(out)

	// First send: only 10 bytes escape (min of stream win 10, conn win 65535,
	// 16384 frame cap). The other 40 buffer.
	buffered := conn_send_body(&srv, &out, 1, body, true)
	testing.expect_value(t, buffered, 40)
	testing.expect(t, conn_has_pending_body(&srv), "pending body present while windows are full")

	// Drain loop: feed WINDOW_UPDATEs (stream + conn) until the engine has
	// no pending body. This mirrors _serve_h2_conn's drain while-loop.
	updates := 0
	for conn_has_pending_body(&srv) && updates < 20 {
		clear(&out)
		wu: [dynamic]u8
		defer delete(wu)
		window_update_write(&wu, 1, 20)  // +20 on the stream
		window_update_write(&wu, 0, 20)  // +20 on the connection
		testing.expect_value(t, conn_feed(&srv, wu[:], &out), H2_Error.None)
		updates += 1
	}

	// Fully drained — no more pending bytes.
	testing.expect(t, !conn_has_pending_body(&srv), "body fully drained after WINDOW_UPDATEs")

	// The stream's END_STREAM must have been emitted (end_sent true). Look
	// up the stream we created (sid 1). Not yet delivered → not reaped.
	s, ok := srv.streams[1]
	testing.expect(t, ok)
	testing.expect(t, s.end_sent, "END_STREAM emitted once pending drained")

	free_all(context.temp_allocator)
}

// conn_send_response must use the flow-aware path (CQ-M1): a body larger than
// the peer window buffers rather than dumping one unbounded DATA frame.
@(test)
test_h2_send_response_respects_window :: proc(t: ^testing.T) {
	srv: Http2_Connection
	conn_init(&srv, true)
	defer conn_destroy(&srv)
	srv.preface_seen = true
	srv.peer_settings.initial_window_size = 10

	// Open stream 1 (empty GET) so send_window inherits peer initial size.
	in_buf: [dynamic]u8
	defer delete(in_buf)
	req_block: [dynamic]u8
	defer delete(req_block)
	hpack.encode(&req_block, []Header{
		{name = ":method", value = "GET"},
		{name = ":scheme", value = "http"},
		{name = ":authority", value = "x"},
		{name = ":path", value = "/"},
	})
	frame_write(&in_buf, FRAME_HEADERS, FLAG_END_HEADERS | FLAG_END_STREAM, 1, req_block[:])
	out: [dynamic]u8
	defer delete(out)
	testing.expect_value(t, conn_feed(&srv, in_buf[:], &out), H2_Error.None)

	s, ok := srv.streams[1]
	testing.expect(t, ok)
	testing.expect_value(t, s.send_window, i64(10))

	body := make([]u8, 25)
	defer delete(body)
	for i in 0 ..< 25 do body[i] = u8('A') + u8(i)

	clear(&out)
	conn_send_response(&srv, &out, 1, []Header{{name = ":status", value = "200"}}, body)

	// HEADERS + DATA(10); 15 bytes remain in pending (flow path, not dump).
	hf, _, c1, e1 := frame_decode(out[:])
	testing.expect_value(t, e1, Frame_Error.None)
	testing.expect_value(t, hf.type, FRAME_HEADERS)
	d1, _, _, e2 := frame_decode(out[c1:])
	testing.expect_value(t, e2, Frame_Error.None)
	testing.expect_value(t, d1.type, FRAME_DATA)
	testing.expect_value(t, d1.length, u32(10))
	testing.expect(t, d1.flags & FLAG_END_STREAM == 0, "not END_STREAM until drained")
	testing.expect_value(t, stream_pending_len(s), 15)
	testing.expect(t, conn_has_pending_body(&srv), "send_response buffered under tight window")
}

// MAX_CONCURRENT_STREAMS refuse must still HPACK-decode the refused block so
// the decoder table stays in sync (CQ-M2). A later request may index an entry
// the refused stream inserted.
@(test)
test_h2_refuse_still_decodes_hpack :: proc(t: ^testing.T) {
	srv: Http2_Connection
	conn_init(&srv, true)
	defer conn_destroy(&srv)
	srv.preface_seen = true
	srv.local_settings.max_concurrent_streams = 1

	out: [dynamic]u8
	defer delete(out)
	in_buf: [dynamic]u8
	defer delete(in_buf)

	// Stream 1: accepted empty GET — holds the sole concurrent slot.
	req1: [dynamic]u8
	defer delete(req1)
	hpack.encode(&req1, []Header{
		{name = ":method", value = "GET"},
		{name = ":scheme", value = "https"},
		{name = ":authority", value = "x"},
		{name = ":path", value = "/"},
	})
	frame_write(&in_buf, FRAME_HEADERS, FLAG_END_HEADERS | FLAG_END_STREAM, 1, req1[:])
	testing.expect_value(t, conn_feed(&srv, in_buf[:], &out), H2_Error.None)
	testing.expect_value(t, srv.open_streams, 1)

	// Stream 3: over limit. Header block uses Literal with Incremental Indexing
	// so a successful decode inserts into the dynamic table.
	clear(&in_buf)
	clear(&out)
	req3: [dynamic]u8
	defer delete(req3)
	hpack.encode(&req3, []Header{
		{name = ":method", value = "GET"},
		{name = ":scheme", value = "https"},
		{name = ":authority", value = "x"},
		{name = ":path", value = "/"},
	})
	// 0x40 = Literal Header Field with Incremental Indexing — New Name.
	name := "x-proactr-tag"
	value := "sync-value"
	append(&req3, 0x40)
	append(&req3, u8(len(name)))
	append(&req3, ..transmute([]u8)name)
	append(&req3, u8(len(value)))
	append(&req3, ..transmute([]u8)value)
	frame_write(&in_buf, FRAME_HEADERS, FLAG_END_HEADERS | FLAG_END_STREAM, 3, req3[:])
	testing.expect_value(t, conn_feed(&srv, in_buf[:], &out), H2_Error.None)

	// RST_STREAM(REFUSED_STREAM) on stream 3; connection survives; table grew.
	saw_rst := false
	pos := 0
	for {
		fh, payload, consumed, fe := frame_decode(out[pos:])
		if fe != .None do break
		if fh.type == FRAME_RST_STREAM && fh.stream_id == 3 {
			testing.expect_value(t, get_u32(payload[:4]), H2_REFUSED_STREAM)
			saw_rst = true
		}
		pos += consumed
	}
	testing.expect(t, saw_rst, "REFUSED_STREAM for over-limit new stream")
	testing.expect_value(t, srv.open_streams, 1)
	testing.expect(t, srv.dec.count >= 1, "refused block still indexed into HPACK table")
	// Stream 3 must not be deliverable.
	{
		// Drain stream 1 first if present, ensure 3 never appears.
		sid, _, _, ok := conn_take_request(&srv)
		testing.expect(t, ok)
		testing.expect_value(t, sid, u32(1))
		sid2, _, _, ok2 := conn_take_request(&srv)
		testing.expect(t, !ok2, "refused stream is not delivered")
	}

	// Finish stream 1 so concurrent budget frees.
	clear(&out)
	conn_send_headers(&srv, &out, 1, []Header{{name = ":status", value = "200"}}, true)
	testing.expect_value(t, srv.open_streams, 0)

	// Stream 5: Indexed Header Field referencing dynamic index 62 (first
	// dynamic entry = the x-proactr-tag from the refused stream). If refuse
	// skipped HPACK, this would be COMPRESSION_ERROR.
	clear(&in_buf)
	clear(&out)
	req5: [dynamic]u8
	defer delete(req5)
	hpack.encode(&req5, []Header{
		{name = ":method", value = "GET"},
		{name = ":scheme", value = "https"},
		{name = ":authority", value = "x"},
		{name = ":path", value = "/"},
	})
	append(&req5, 0xBE) // Indexed index 62 (0x80 | 62)
	frame_write(&in_buf, FRAME_HEADERS, FLAG_END_HEADERS | FLAG_END_STREAM, 5, req5[:])
	testing.expect_value(t, conn_feed(&srv, in_buf[:], &out), H2_Error.None)

	sid5, hdrs, _, ok5 := conn_take_request(&srv)
	testing.expect(t, ok5, "stream 5 accepted after concurrent slot free")
	testing.expect_value(t, sid5, u32(5))
	found := false
	for h in hdrs {
		if h.name == "x-proactr-tag" {
			testing.expect_value(t, h.value, "sync-value")
			found = true
		}
	}
	testing.expect(t, found, "dynamic-table index from refused stream resolved")
	free_all(context.temp_allocator)
}

// PR9 PERF-M1: when ≥2 streams already have pending, any flush uses RR quanta
// (not sole-stream drain of residual connection window).
@(test)
test_h2_flush_multi_pending_always_rr :: proc(t: ^testing.T) {
	srv: Http2_Connection
	conn_init(&srv, true)
	defer conn_destroy(&srv)
	srv.preface_seen = true
	srv.send_window = 0 // force both full-buffer first
	srv.peer_settings.initial_window_size = 65535

	out: [dynamic]u8
	defer delete(out)
	in_buf: [dynamic]u8
	defer delete(in_buf)
	for i in 0 ..< 2 {
		sid := u32(i * 2 + 1) // 1, 3
		clear(&in_buf)
		req_block: [dynamic]u8
		req_block.allocator = context.temp_allocator
		hpack.encode(&req_block, []Header{
			{name = ":method", value = "GET"},
			{name = ":scheme", value = "http"},
			{name = ":authority", value = "x"},
			{name = ":path", value = "/"},
		})
		frame_write(&in_buf, FRAME_HEADERS, FLAG_END_HEADERS | FLAG_END_STREAM, sid, req_block[:])
		testing.expect_value(t, conn_feed(&srv, in_buf[:], &out), H2_Error.None)
		clear(&out)
	}

	body := make([]u8, 40)
	defer delete(body)
	for i in 0 ..< 40 do body[i] = u8(i)

	_ = conn_send_body(&srv, &out, 1, body, true)
	_ = conn_send_body(&srv, &out, 3, body, true)
	testing.expect(t, stream_pending_len(srv.streams[1]) == 40 && stream_pending_len(srv.streams[3]) == 40)

	// Residual conn credit with both already pending: flush via send_body path
	// must RR (DATA for both), not dump all residual onto stream 1 alone.
	clear(&out)
	srv.send_window = 16
	_ = conn_send_body(&srv, &out, 1, nil, false) // trigger multi-pending flush

	d1, d3 := 0, 0
	pos := 0
	for pos + FRAME_HEADER_LEN <= len(out) {
		fh, _, consumed, fe := frame_decode(out[pos:])
		if fe != .None do break
		if fh.type == FRAME_DATA {
			if fh.stream_id == 1 do d1 += int(fh.length)
			if fh.stream_id == 3 do d3 += int(fh.length)
		}
		pos += consumed
	}
	testing.expect(t, d1 > 0 && d3 > 0, "multi-pending flush RR both streams")
	testing.expect(t, d1 + d3 <= 16, "total DATA ≤ residual conn credit")
	testing.expect(t, srv.flush_rr > 0, "flush_rr advanced on multi-pending")
	free_all(context.temp_allocator)
}

// PR9 M3: fair RR — two streams with pending under a tight shared conn window;
// conn WINDOW_UPDATE must progress both (not starve the second in map order).
@(test)
test_h2_flush_rr_two_pending_streams :: proc(t: ^testing.T) {
	srv: Http2_Connection
	conn_init(&srv, true)
	defer conn_destroy(&srv)
	srv.preface_seen = true
	// Shared conn window only 10; each stream window large so conn is the bottleneck.
	srv.send_window = 10
	srv.peer_settings.initial_window_size = 65535

	// Open two streams via empty GETs so stream windows exist.
	out: [dynamic]u8
	defer delete(out)
	in_buf: [dynamic]u8
	defer delete(in_buf)
	for i in 0 ..< 2 {
		sid := u32(i * 2 + 1) // 1, 3
		clear(&in_buf)
		req_block: [dynamic]u8
		req_block.allocator = context.temp_allocator
		hpack.encode(&req_block, []Header{
			{name = ":method", value = "GET"},
			{name = ":scheme", value = "http"},
			{name = ":authority", value = "x"},
			{name = ":path", value = "/"},
		})
		frame_write(&in_buf, FRAME_HEADERS, FLAG_END_HEADERS | FLAG_END_STREAM, sid, req_block[:])
		testing.expect_value(t, conn_feed(&srv, in_buf[:], &out), H2_Error.None)
		clear(&out)
	}

	s1, ok1 := srv.streams[1]
	s3, ok3 := srv.streams[3]
	testing.expect(t, ok1 && ok3)

	body := make([]u8, 40)
	defer delete(body)
	for i in 0 ..< 40 do body[i] = u8(i)

	// Both bodies larger than conn window → both buffer after first send.
	// Send stream 1 first: takes the full 10-byte conn window.
	conn_send_headers(&srv, &out, 1, []Header{{name = ":status", value = "200"}}, false)
	b1 := conn_send_body(&srv, &out, 1, body, true)
	testing.expect(t, b1 > 0)
	// Conn window is 0; stream 3 send buffers everything.
	clear(&out)
	conn_send_headers(&srv, &out, 3, []Header{{name = ":status", value = "200"}}, false)
	b3 := conn_send_body(&srv, &out, 3, body, true)
	testing.expect_value(t, b3, 40) // nothing flushed (conn window empty)
	testing.expect(t, stream_pending_len(s1) > 0 && stream_pending_len(s3) > 0)

	// Conn WINDOW_UPDATE(+20): fair RR must emit DATA for both sids, not only s1.
	clear(&out)
	wu: [dynamic]u8
	defer delete(wu)
	window_update_write(&wu, 0, 20)
	testing.expect_value(t, conn_feed(&srv, wu[:], &out), H2_Error.None)

	saw1, saw3 := false, false
	pos := 0
	for pos + FRAME_HEADER_LEN <= len(out) {
		fh, _, consumed, fe := frame_decode(out[pos:])
		if fe != .None do break
		if fh.type == FRAME_DATA {
			if fh.stream_id == 1 do saw1 = true
			if fh.stream_id == 3 do saw3 = true
		}
		pos += consumed
	}
	testing.expect(t, saw1 && saw3, "RR flush progresses both pending streams")
	// Cursor advanced (non-zero after multi-stream flush).
	testing.expect(t, srv.flush_rr > 0, "flush_rr cursor advanced")
	free_all(context.temp_allocator)
}

// PR9 M5: without WINDOW_UPDATE, total DATA on the wire is O(window), not O(sum bodies).
@(test)
test_h2_peak_wire_o_window_two_large_bodies :: proc(t: ^testing.T) {
	srv: Http2_Connection
	conn_init(&srv, true)
	defer conn_destroy(&srv)
	srv.preface_seen = true
	// Tight stream + conn windows.
	srv.peer_settings.initial_window_size = 10
	srv.send_window = 10

	out: [dynamic]u8
	defer delete(out)
	in_buf: [dynamic]u8
	defer delete(in_buf)
	for i in 0 ..< 2 {
		sid := u32(i * 2 + 1) // 1, 3
		clear(&in_buf)
		req_block: [dynamic]u8
		req_block.allocator = context.temp_allocator
		hpack.encode(&req_block, []Header{
			{name = ":method", value = "GET"},
			{name = ":scheme", value = "http"},
			{name = ":authority", value = "x"},
			{name = ":path", value = "/"},
		})
		frame_write(&in_buf, FRAME_HEADERS, FLAG_END_HEADERS | FLAG_END_STREAM, sid, req_block[:])
		testing.expect_value(t, conn_feed(&srv, in_buf[:], &out), H2_Error.None)
		clear(&out)
	}

	body := make([]u8, 100)
	defer delete(body)
	for i in 0 ..< 100 do body[i] = u8('A')

	conn_send_headers(&srv, &out, 1, []Header{{name = ":status", value = "200"}}, false)
	_ = conn_send_body(&srv, &out, 1, body, true)
	conn_send_headers(&srv, &out, 3, []Header{{name = ":status", value = "200"}}, false)
	_ = conn_send_body(&srv, &out, 3, body, true)

	// Sum of DATA payload lengths without further WINDOW_UPDATE ≤ initial conn window (10).
	data_total := 0
	pos := 0
	for pos + FRAME_HEADER_LEN <= len(out) {
		fh, _, consumed, fe := frame_decode(out[pos:])
		if fe != .None do break
		if fh.type == FRAME_DATA {
			data_total += int(fh.length)
		}
		pos += consumed
	}
	testing.expect(t, data_total <= 10, "wire DATA O(conn window), not O(sum bodies)")
	// Pending holds remainder (producer/backpressure path); both streams still buffered.
	testing.expect(t, conn_has_pending_body(&srv))
	free_all(context.temp_allocator)
}

// Closed+delivered streams must leave the map (F16: unbounded map inverted
// H2 RPS under concurrency — WINDOW_UPDATE scanned every historical stream).
@(test)
test_h2_reaps_closed_streams :: proc(t: ^testing.T) {
	srv: Http2_Connection
	conn_init(&srv, true)
	defer conn_destroy(&srv)
	srv.preface_seen = true
	srv.local_settings.max_concurrent_streams = 250

	out: [dynamic]u8
	defer delete(out)
	in_buf: [dynamic]u8
	defer delete(in_buf)

	// 64 sequential empty GETs on increasing odd stream ids.
	for i in 0 ..< 64 {
		sid := u32(i * 2 + 1)
		clear(&in_buf)
		req_block: [dynamic]u8
		req_block.allocator = context.temp_allocator
		hpack.encode(&req_block, []Header{
			{name = ":method", value = "GET"},
			{name = ":scheme", value = "https"},
			{name = ":authority", value = "x"},
			{name = ":path", value = "/"},
		})
		frame_write(&in_buf, FRAME_HEADERS, FLAG_END_HEADERS | FLAG_END_STREAM, sid, req_block[:])
		testing.expect_value(t, conn_feed(&srv, in_buf[:], &out), H2_Error.None)
		clear(&out)

		got_sid, _, _, ok := conn_take_request(&srv)
		testing.expect(t, ok, "take request")
		testing.expect_value(t, got_sid, sid)
		// Empty response: END_STREAM on HEADERS → closed + reaped.
		conn_send_headers(&srv, &out, sid, []Header{{name = ":status", value = "200"}}, true)
		clear(&out)
	}

	testing.expect_value(t, len(srv.streams), 0)
	testing.expect_value(t, srv.open_streams, 0)
	// New stream after GC must still be accepted (id > last_peer_sid).
	clear(&in_buf)
	req_block: [dynamic]u8
	req_block.allocator = context.temp_allocator
	hpack.encode(&req_block, []Header{
		{name = ":method", value = "GET"},
		{name = ":scheme", value = "https"},
		{name = ":authority", value = "x"},
		{name = ":path", value = "/"},
	})
	frame_write(&in_buf, FRAME_HEADERS, FLAG_END_HEADERS | FLAG_END_STREAM, 129, req_block[:])
	testing.expect_value(t, conn_feed(&srv, in_buf[:], &out), H2_Error.None)
	sid, _, _, ok := conn_take_request(&srv)
	testing.expect(t, ok)
	testing.expect_value(t, sid, u32(129))
	free_all(context.temp_allocator)
}

// PR10: conn_send_goaway emits FRAME_GOAWAY with NO_ERROR and last_peer_sid.
@(test)
test_h2_conn_send_goaway_no_error :: proc(t: ^testing.T) {
	srv: Http2_Connection
	conn_init(&srv, true)
	defer conn_destroy(&srv)
	srv.preface_seen = true

	out: [dynamic]u8
	defer delete(out)
	in_buf: [dynamic]u8
	defer delete(in_buf)

	// Open stream 1 so last_peer_sid = 1.
	req_block: [dynamic]u8
	req_block.allocator = context.temp_allocator
	hpack.encode(&req_block, []Header{
		{name = ":method", value = "GET"},
		{name = ":scheme", value = "http"},
		{name = ":authority", value = "x"},
		{name = ":path", value = "/"},
	})
	frame_write(&in_buf, FRAME_HEADERS, FLAG_END_HEADERS | FLAG_END_STREAM, 1, req_block[:])
	testing.expect_value(t, conn_feed(&srv, in_buf[:], &out), H2_Error.None)
	testing.expect_value(t, srv.last_peer_sid, u32(1))
	clear(&out)

	conn_send_goaway(&srv, &out, H2_NO_ERROR)
	testing.expect(t, srv.goaway_sent)
	testing.expect_value(t, srv.goaway_sent_last, u32(1))
	testing.expect_value(t, srv.goaway_sent_code, H2_NO_ERROR)

	// Idempotent: second send does not append another GOAWAY.
	n1 := len(out)
	conn_send_goaway(&srv, &out, H2_PROTOCOL_ERROR)
	testing.expect_value(t, len(out), n1)
	testing.expect_value(t, srv.goaway_sent_code, H2_NO_ERROR) // still first code

	found := false
	pos := 0
	for pos + FRAME_HEADER_LEN <= len(out) {
		fh, payload, consumed, fe := frame_decode(out[pos:])
		if fe != .None do break
		if fh.type == FRAME_GOAWAY {
			found = true
			testing.expect(t, len(payload) >= 8)
			last := get_u32(payload[:4]) & 0x7fff_ffff
			code := get_u32(payload[4:8])
			testing.expect_value(t, last, u32(1))
			testing.expect_value(t, code, H2_NO_ERROR)
			break
		}
		pos += consumed
	}
	testing.expect(t, found, "GOAWAY frame in out")
	free_all(context.temp_allocator)
}

// PR10: after local GOAWAY, new stream is REFUSED; prior stream still flushes.
@(test)
test_h2_goaway_refuses_new_stream_keeps_prior :: proc(t: ^testing.T) {
	srv: Http2_Connection
	conn_init(&srv, true)
	defer conn_destroy(&srv)
	srv.preface_seen = true
	// Tight windows so stream 1 response stays pending across GOAWAY + refuse.
	srv.send_window = 10
	srv.peer_settings.initial_window_size = 10

	out: [dynamic]u8
	defer delete(out)
	in_buf: [dynamic]u8
	defer delete(in_buf)

	// Stream 1 complete request.
	req_block: [dynamic]u8
	req_block.allocator = context.temp_allocator
	hpack.encode(&req_block, []Header{
		{name = ":method", value = "GET"},
		{name = ":scheme", value = "http"},
		{name = ":authority", value = "x"},
		{name = ":path", value = "/a"},
	})
	frame_write(&in_buf, FRAME_HEADERS, FLAG_END_HEADERS | FLAG_END_STREAM, 1, req_block[:])
	testing.expect_value(t, conn_feed(&srv, in_buf[:], &out), H2_Error.None)
	clear(&out)

	sid1, _, _, ok1 := conn_take_request(&srv)
	testing.expect(t, ok1 && sid1 == 1)

	// Start response body on stream 1 (still pending under tight window).
	body := make([]u8, 40)
	defer delete(body)
	for i in 0 ..< 40 do body[i] = u8('A')
	conn_send_headers(&srv, &out, 1, []Header{{name = ":status", value = "200"}}, false)
	_ = conn_send_body(&srv, &out, 1, body, true)
	testing.expect(t, conn_has_pending_body(&srv))
	clear(&out)

	// Graceful GOAWAY at last_peer_sid=1.
	conn_send_goaway(&srv, &out, H2_NO_ERROR)
	clear(&out)

	// New stream 3 after GOAWAY → REFUSED_STREAM, not delivered.
	clear(&in_buf)
	req_block2: [dynamic]u8
	req_block2.allocator = context.temp_allocator
	hpack.encode(&req_block2, []Header{
		{name = ":method", value = "GET"},
		{name = ":scheme", value = "http"},
		{name = ":authority", value = "x"},
		{name = ":path", value = "/b"},
	})
	frame_write(&in_buf, FRAME_HEADERS, FLAG_END_HEADERS | FLAG_END_STREAM, 3, req_block2[:])
	testing.expect_value(t, conn_feed(&srv, in_buf[:], &out), H2_Error.None)

	saw_rst := false
	pos := 0
	for pos + FRAME_HEADER_LEN <= len(out) {
		fh, payload, consumed, fe := frame_decode(out[pos:])
		if fe != .None do break
		if fh.type == FRAME_RST_STREAM && fh.stream_id == 3 {
			saw_rst = true
			if len(payload) >= 4 {
				testing.expect_value(t, get_u32(payload[:4]), H2_REFUSED_STREAM)
			}
		}
		pos += consumed
	}
	testing.expect(t, saw_rst, "new stream after GOAWAY gets RST REFUSED_STREAM")

	_, _, _, ok3 := conn_take_request(&srv)
	testing.expect(t, !ok3, "refused stream not delivered")

	// Prior stream 1 still pending — not failed/closed by GOAWAY refuse of stream 3.
	s1, ok_s := srv.streams[1]
	testing.expect(t, ok_s, "prior stream still in map")
	testing.expect(t, !s1.failed, "prior stream not failed")
	testing.expect(t, !s1.closed, "prior stream not closed")
	testing.expect(t, stream_pending_len(s1) > 0, "prior stream still has pending body")

	// Drain remaining body for stream 1 with WINDOW_UPDATE.
	clear(&out)
	wu: [dynamic]u8
	defer delete(wu)
	window_update_write(&wu, 0, 100)
	window_update_write(&wu, 1, 100)
	testing.expect_value(t, conn_feed(&srv, wu[:], &out), H2_Error.None)
	// Prior stream must not have been failed by the refused stream path.
	if s, ok := srv.streams[1]; ok {
		testing.expect(t, !s.failed, "prior stream not failed after refuse of new")
	} else {
		// Fully drained + reaped is also fine (not killed mid-flight).
		testing.expect(t, !conn_has_pending_body(&srv))
	}
	free_all(context.temp_allocator)
}

// PR10: interactive stream gets more DATA frames than bulk under tight window.
@(test)
test_h2_flush_interactive_weight_vs_bulk :: proc(t: ^testing.T) {
	srv: Http2_Connection
	conn_init(&srv, true)
	defer conn_destroy(&srv)
	srv.preface_seen = true
	// Tight per-frame path: large stream windows, small conn window.
	// weight_interactive=3, weight_bulk=1 → interactive gets 3 frames/turn.
	srv.weight_interactive = 3
	srv.weight_bulk = 1
	srv.send_window = 0 // buffer both first
	srv.peer_settings.initial_window_size = 65535
	// Cap frame size so quanta are visible as separate frames.
	srv.peer_settings.max_frame_size = 8

	out: [dynamic]u8
	defer delete(out)
	in_buf: [dynamic]u8
	defer delete(in_buf)
	for i in 0 ..< 2 {
		sid := u32(i * 2 + 1) // 1, 3
		clear(&in_buf)
		req_block: [dynamic]u8
		req_block.allocator = context.temp_allocator
		hpack.encode(&req_block, []Header{
			{name = ":method", value = "GET"},
			{name = ":scheme", value = "http"},
			{name = ":authority", value = "x"},
			{name = ":path", value = "/"},
		})
		frame_write(&in_buf, FRAME_HEADERS, FLAG_END_HEADERS | FLAG_END_STREAM, sid, req_block[:])
		testing.expect_value(t, conn_feed(&srv, in_buf[:], &out), H2_Error.None)
		clear(&out)
	}

	body := make([]u8, 64)
	defer delete(body)
	for i in 0 ..< 64 do body[i] = u8(i)

	// Stream 1 = bulk, stream 3 = interactive (SSE-like).
	_ = conn_send_body(&srv, &out, 1, body, true)
	_ = conn_send_body(&srv, &out, 3, body, true)
	conn_stream_set_interactive(&srv, 3, true)
	testing.expect(t, srv.streams[3].interactive)
	testing.expect(t, !srv.streams[1].interactive)
	testing.expect(t, stream_pending_len(srv.streams[1]) == 64 && stream_pending_len(srv.streams[3]) == 64)

	// Residual credit: 24 bytes → with max_frame=8, up to 3 frames of 8.
	// One RR pass: start at lowest id. Bulk (1) gets 1 frame (8), interactive (3)
	// gets 3 frames but only 16 credit left → 16 bytes. Interactive > bulk.
	clear(&out)
	srv.send_window = 24
	srv.flush_rr = 0
	_ = conn_send_body(&srv, &out, 1, nil, false) // trigger multi-pending RR

	d1, d3 := 0, 0
	f1, f3 := 0, 0
	pos := 0
	for pos + FRAME_HEADER_LEN <= len(out) {
		fh, _, consumed, fe := frame_decode(out[pos:])
		if fe != .None do break
		if fh.type == FRAME_DATA {
			if fh.stream_id == 1 {
				d1 += int(fh.length)
				f1 += 1
			}
			if fh.stream_id == 3 {
				d3 += int(fh.length)
				f3 += 1
			}
		}
		pos += consumed
	}
	testing.expect(t, d1 > 0 && d3 > 0, "both streams get DATA under residual credit")
	testing.expect(t, d1 + d3 <= 24, "total ≤ conn window")
	// Interactive should receive strictly more payload (weight 3 vs 1).
	testing.expect(t, d3 > d1, "interactive gets more DATA than bulk under tight window")
	// And at least as many frames as bulk (weight quanta).
	testing.expect(t, f3 >= f1, "interactive ≥ bulk DATA frames")
	free_all(context.temp_allocator)
}

// Bulk cursor: large body must drain with O(1) consume (pending_off), not front-delete.
// After partial flush, remaining == stream_pending_len; after full drain pending is empty.
@(test)
test_h2_pending_cursor_large_body :: proc(t: ^testing.T) {
	srv: Http2_Connection
	conn_init(&srv, true)
	defer conn_destroy(&srv)
	srv.preface_seen = true
	// Default max frame 16KiB; stream/conn windows large enough for full oneshot.
	srv.send_window = 1 << 20
	srv.peer_settings.initial_window_size = 1 << 20
	srv.peer_settings.max_frame_size = 16 * 1024

	out: [dynamic]u8
	defer delete(out)
	in_buf: [dynamic]u8
	defer delete(in_buf)
	req_block: [dynamic]u8
	defer delete(req_block)
	hpack.encode(&req_block, []Header{
		{name = ":method", value = "GET"},
		{name = ":scheme", value = "http"},
		{name = ":authority", value = "x"},
		{name = ":path", value = "/big"},
	})
	frame_write(&in_buf, FRAME_HEADERS, FLAG_END_HEADERS | FLAG_END_STREAM, 1, req_block[:])
	testing.expect_value(t, conn_feed(&srv, in_buf[:], &out), H2_Error.None)
	clear(&out)

	// 256 KiB body → many DATA frames under 16KiB max frame.
	body := make([]u8, 256 * 1024)
	defer delete(body)
	for i in 0 ..< len(body) do body[i] = u8(i)

	// Tight stream window: only 32 KiB first → 2 frames, rest buffered with cursor.
	s, ok := srv.streams[1]
	testing.expect(t, ok)
	s.send_window = 32 * 1024
	srv.send_window = 32 * 1024

	conn_send_headers(&srv, &out, 1, []Header{{name = ":status", value = "200"}}, false)
	buffered := conn_send_body(&srv, &out, 1, body, true)
	testing.expect(t, buffered == len(body) - 32*1024, "32KiB flushed, rest pending")
	testing.expect_value(t, stream_pending_len(s), len(body) - 32*1024)
	// Cursor advanced O(1); dead prefix still in the array until full drain/compact.
	testing.expect_value(t, s.pending_off, 32 * 1024)
	testing.expect_value(t, len(s.pending), len(body))

	// Grant remaining window → full drain + clear.
	clear(&out)
	wu: [dynamic]u8
	defer delete(wu)
	// Stream + connection WINDOW_UPDATE for residual body.
	window_update_write(&wu, 0, u32(len(body))) // conn
	window_update_write(&wu, 1, u32(len(body))) // stream
	testing.expect_value(t, conn_feed(&srv, wu[:], &out), H2_Error.None)
	testing.expect_value(t, stream_pending_len(s), 0)
	testing.expect_value(t, s.pending_off, 0)
	testing.expect(t, len(s.pending) == 0, "fully drained pending buffer cleared")
	testing.expect(t, s.end_sent, "END_STREAM after full drain")
	free_all(context.temp_allocator)
}
