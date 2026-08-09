// D0/D1 Session + SSE pure tests (no full server / sockets).
package http

import "core:bytes"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"

import tls_server "../tls_server"

@(test)
test_effects_of_basic :: proc(t: ^testing.T) {
	e := effects_of(
		effect_sse_data("a"),
		effect_arm(1 * time.Second),
		effect_end(),
	)
	testing.expect_value(t, e.n, u8(3))
	testing.expect_value(t, e.items[0].kind, Effect_Kind.Sse_Data)
	testing.expect_value(t, e.items[0].data, "a")
	testing.expect_value(t, e.items[1].kind, Effect_Kind.Arm)
	testing.expect(t, e.items[1].delay_ns > 0)
	testing.expect_value(t, e.items[2].kind, Effect_Kind.End)
}

@(test)
test_effects_empty :: proc(t: ^testing.T) {
	e := effects_empty()
	testing.expect_value(t, e.n, u8(0))
	e2 := effects_of()
	testing.expect_value(t, e2.n, u8(0))
}

@(test)
test_effect_constructors :: proc(t: ^testing.T) {
	d := effect_sse_data("hello")
	testing.expect_value(t, d.kind, Effect_Kind.Sse_Data)
	testing.expect_value(t, d.data, "hello")

	ev := effect_sse_event("ping", "1")
	testing.expect_value(t, ev.kind, Effect_Kind.Sse_Event)
	testing.expect_value(t, ev.name, "ping")
	testing.expect_value(t, ev.data, "1")

	c := effect_sse_comment("hb")
	testing.expect_value(t, c.kind, Effect_Kind.Sse_Comment)
	testing.expect_value(t, c.data, "hb")

	c2 := effect_sse_comment()
	testing.expect_value(t, c2.data, "")

	testing.expect_value(t, effect_end().kind, Effect_Kind.End)
	testing.expect_value(t, effect_abort().kind, Effect_Kind.Abort)
}

@(test)
test_sse_format_data :: proc(t: ^testing.T) {
	b: [dynamic]u8
	defer delete(b)
	sse_format_data("hello", &b)
	testing.expect_value(t, string(b[:]), "data: hello\n\n")
}

@(test)
test_sse_format_data_multiline :: proc(t: ^testing.T) {
	b: [dynamic]u8
	defer delete(b)
	sse_format_data("a\nb", &b)
	testing.expect_value(t, string(b[:]), "data: a\ndata: b\n\n")
}

@(test)
test_sse_format_event :: proc(t: ^testing.T) {
	b: [dynamic]u8
	defer delete(b)
	sse_format_event("hello", "ok", &b)
	testing.expect_value(t, string(b[:]), "event: hello\ndata: ok\n\n")
}

@(test)
test_sse_format_comment :: proc(t: ^testing.T) {
	b: [dynamic]u8
	defer delete(b)
	sse_format_comment("keep-alive", &b)
	testing.expect_value(t, string(b[:]), ": keep-alive\n\n")

	clear(&b)
	sse_format_comment("", &b)
	testing.expect_value(t, string(b[:]), ":\n\n")
}

@(test)
test_sse_format_effect :: proc(t: ^testing.T) {
	b: [dynamic]u8
	defer delete(b)
	_sse_format_effect(&b, effect_sse_event("x", "y"))
	testing.expect_value(t, string(b[:]), "event: x\ndata: y\n\n")
}

@(test)
test_sse_http_chunk_framing :: proc(t: ^testing.T) {
	// Progressive stream uses the same _http_write_chunk helper.
	chunk := sse_http_chunk_string("ab")
	defer delete(chunk)
	testing.expect_value(t, chunk, "2\r\nab\r\n")
}

@(test)
test_stream_progressive_buffer_cursor :: proc(t: ^testing.T) {
	// Unit model of D0: stream_sent advances over resp_buf; flush region is a copy.
	resp := make([dynamic]u8, 0, 64)
	defer delete(resp)
	append(&resp, ..transmute([]u8)string("HEAD\r\n\r\n"))
	append(&resp, ..transmute([]u8)string("5\r\nhello\r\n"))

	stream_sent := 0
	// First flush: copy heading+chunk
	to_send := resp[stream_sent:]
	send_buf := make([]u8, len(to_send))
	defer delete(send_buf)
	copy(send_buf, to_send)
	testing.expect_value(t, string(send_buf), "HEAD\r\n\r\n5\r\nhello\r\n")
	// Simulate full CQE
	stream_sent += len(send_buf)
	testing.expect_value(t, stream_sent, len(resp))

	// Append while "in flight" would only grow past stream_sent
	append(&resp, ..transmute([]u8)string("5\r\nworld\r\n"))
	testing.expect(t, len(resp) > stream_sent)
	to_send2 := resp[stream_sent:]
	testing.expect_value(t, string(to_send2), "5\r\nworld\r\n")
}

@(test)
test_sse_drive_for_test_start_end :: proc(t: ^testing.T) {
	// Pure drive: attach a minimal Session_State and call on_event via sse_drive_for_test.
	// No worker / no real sockets — apply may no-op flush when td==nil.
	conn: Connection
	res: Response
	headers_init(&res.headers, context.allocator)
	defer delete(res.headers._kv)
	res.status = .OK
	headers_set_unsafe(&res.headers, "date", "Fri, 05 Feb 2023 09:01:10 GMT")
	conn.slot.conn = &conn
	conn.slot.res = res
	// Note: res on stack; re-bind after copy into conn.slot
	conn.slot.res._slot = &conn.slot
	conn.slot.res._conn = &conn
	wire := make([dynamic]u8, 0, 1024, context.allocator)
	defer delete(wire)
	conn.slot.res._buf.buf = wire
	conn.slot.res._buf.buf.allocator = context.allocator
	conn.resp_buf = wire

	// Fake server only for allocator identity (not used if we alloc Session_State on stack path).
	// Drive without sse_start: manually attach state.
	st: Session_State
	st.on_event = proc(sess: ^Session, ev: Session_Event, user: rawptr) -> Effects {
		_ = sess
		_ = user
		switch ev.kind {
		case .Start:
			return effects_of(effect_sse_data("hi"), effect_end())
		case .Timer, .External, .Client_Gone, .Idle_Timeout, .Writable:
			return {}
		}
		return {}
	}
	st.hooks = {}
	st.gen = 1
	st.public = Session{_conn = &conn, id = 1}
	conn.slot.session = &st
	conn.slot.res._session_attached = true
	conn.slot.res._streaming = true
	conn.slot.res._heading_written = true

	// Pre-seed a minimal heading so buffer is non-empty.
	append(&conn.slot.res._buf.buf, ..transmute([]u8)string("HTTP/1.1 200 OK\r\n\r\n"))
	conn.resp_buf = conn.slot.res._buf.buf

	sess := st.public
	effs := sse_drive_for_test(&sess, Session_Event{kind = .Start})
	testing.expect_value(t, effs.n, u8(2))
	testing.expect_value(t, effs.items[0].kind, Effect_Kind.Sse_Data)
	testing.expect_value(t, effs.items[1].kind, Effect_Kind.End)
	// End path sets ending; without worker flush is coalesce-only.
	testing.expect(t, conn.slot.stream_ending || st.ending)
	// SSE data was chunked into the response buffer.
	body := string(conn.slot.res._buf.buf[:])
	testing.expect(t, strings.contains(body, "data: hi"))
	// Tear down without free (stack state).
	conn.slot.session = nil
	conn.slot.res._session_attached = false
}

@(test)
test_session_status_nil :: proc(t: ^testing.T) {
	s: Session
	testing.expect(t, !session_status(s))
}

// Orphan sse_alloc (no sse_start): pad must free on exchange reset / conn recycle.
// Under odin test memory tracking this must not report a leak.
@(test)
test_sse_alloc_orphan_freed_on_reset :: proc(t: ^testing.T) {
	server: Server
	server.conn_allocator = context.allocator

	conn: Connection
	conn.server = &server
	conn.slot.conn = &conn
	wire_conn_init(&conn.wire_conn)

	res: Response
	res._conn = &conn
	res._slot = &conn.slot

	pad := sse_alloc(&res, 64)
	testing.expect(t, pad != nil)
	testing.expect(t, conn.slot.session_pad != nil)
	testing.expect_value(t, conn.slot.session_pad_size, 64)
	testing.expect(t, conn.slot.session == nil) // no sse_start

	// Same path as connection_destroy / free-list recycle.
	stream_slot_reset_exchange(&conn.slot, &conn)
	testing.expect(t, conn.slot.session_pad == nil)
	testing.expect_value(t, conn.slot.session_pad_size, 0)
	testing.expect(t, conn.slot.conn == &conn)
}

// Free pad helper alone (connection_close orphan branch without full close/ring).
@(test)
test_sse_alloc_orphan_freed_on_free_pad :: proc(t: ^testing.T) {
	server: Server
	server.conn_allocator = context.allocator

	conn: Connection
	conn.server = &server
	conn.slot.conn = &conn

	res: Response
	res._conn = &conn

	_ = sse_alloc(&res, 32)
	testing.expect(t, conn.slot.session_pad != nil)

	stream_slot_free_pad(&conn.slot)
	testing.expect(t, conn.slot.session_pad == nil)
	testing.expect_value(t, conn.slot.session_pad_size, 0)
	// Second call is a safe no-op.
	stream_slot_free_pad(&conn.slot)
}

// Destroy bumps slot.gen (sole ABA owner); st.gen stays attach snapshot.
// When wire_conn.q is set, seal units for the attach gen are removed.
@(test)
test_session_destroy_bumps_slot_gen :: proc(t: ^testing.T) {
	server: Server
	server.conn_allocator = context.allocator

	conn: Connection
	conn.server = &server
	conn.slot.conn = &conn
	conn.slot.gen = 1
	wire_conn_init(&conn.wire_conn)

	// Phase-2-style seal queue hung on wire_conn (clear-H1 normally leaves q nil).
	sq: Seal_Queue
	conn.wire_conn.q = &sq
	testing.expect(t, seal_q_push(&sq, Seal_Unit{slot_gen = 1}))
	testing.expect(t, seal_q_push(&sq, Seal_Unit{slot_gen = 9}))
	testing.expect_value(t, sq.len, 2)

	st := new(Session_State, context.allocator)
	st.allocator = context.allocator
	st.gen = 1
	st.public = Session{_conn = &conn, id = 1}
	conn.slot.session = st
	conn.slot.res._session_attached = true

	_session_destroy(&conn, after_wire = false)

	testing.expect(t, conn.slot.session == nil)
	testing.expect_value(t, conn.slot.gen, u32(2))
	testing.expect_value(t, sq.len, 1) // gen=1 removed; gen=9 kept
	testing.expect_value(t, sq.units[0].slot_gen, u32(9))
	testing.expect(t, !conn.slot.res._session_attached)
	// st was heap-allocated and freed by destroy (timer_pending_cqes == 0).
}

// PR10 soft admission: over session cap → 503, invalid Session, no panic.
@(test)
test_sse_start_soft_reject_over_cap :: proc(t: ^testing.T) {
	server: Server
	server.conn_allocator = context.allocator
	server.opts = Default_Server_Opts
	server.opts.max_sessions_per_worker = 1
	server.opts.thread_count = 1

	// Inflate live gauge so admission fails immediately.
	prev_live := sync.atomic_load(&session_metrics_live)
	prev_rej := sync.atomic_load(&session_metrics_admission_reject)
	sync.atomic_store(&session_metrics_live, 1)
	defer sync.atomic_store(&session_metrics_live, prev_live)

	conn: Connection
	conn.server = &server
	conn.slot.conn = &conn
	wire_conn_init(&conn.wire_conn)

	res: Response
	headers_init(&res.headers, context.allocator)
	defer delete(res.headers._kv)
	res._conn = &conn
	res._slot = &conn.slot
	res.status = .OK

	on_event :: proc(sess: ^Session, ev: Session_Event, user: rawptr) -> Effects {
		_ = sess
		_ = ev
		_ = user
		return {}
	}

	s := sse_start(&res, on_event)
	testing.expect_value(t, s.id, u32(0))
	testing.expect(t, !session_status(s))
	testing.expect_value(t, res.status, Status.Service_Unavailable)
	testing.expect(t, res.sent)
	testing.expect(t, conn.slot.session == nil)
	testing.expect(t, !res._session_attached)
	rej := sync.atomic_load(&session_metrics_admission_reject)
	testing.expect(t, rej > prev_rej, "admission_reject metric")
	// live must not have been incremented on reject.
	testing.expect_value(t, sync.atomic_load(&session_metrics_live), i64(1))
}

// PR10: ws_start soft-rejects over cap with 503 (not 101 attach).
@(test)
test_ws_start_soft_reject_over_cap :: proc(t: ^testing.T) {
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
	conn.slot.conn = &conn
	wire_conn_init(&conn.wire_conn)

	res: Response
	headers_init(&res.headers, context.allocator)
	defer delete(res.headers._kv)
	res._conn = &conn
	res._slot = &conn.slot
	res.status = .Switching_Protocols

	on_event :: proc(sess: ^Session, ev: Session_Event, user: rawptr) -> Effects {
		_ = sess
		_ = ev
		_ = user
		return {}
	}

	s := ws_start(&res, on_event)
	testing.expect_value(t, s.id, u32(0))
	testing.expect(t, !session_status(s))
	testing.expect_value(t, res.status, Status.Service_Unavailable)
	testing.expect(t, res.sent)
	testing.expect(t, conn.slot.session == nil)
	rej := sync.atomic_load(&session_metrics_admission_reject)
	testing.expect(t, rej > prev_rej)
}

@(test)
test_chunk_and_sse_compose :: proc(t: ^testing.T) {
	// Framing helpers compose: SSE frame then HTTP chunk (as apply does).
	frame: [dynamic]u8
	defer delete(frame)
	sse_format_data("x", &frame)
	b: bytes.Buffer
	defer delete(b.buf)
	_http_write_chunk(&b, frame[:])
	_http_write_chunk_end(&b)
	got := string(bytes.buffer_to_bytes(&b))
	// "data: x\n\n" is 9 bytes → hex 9
	testing.expect_value(t, got, "9\r\ndata: x\n\n\r\n0\r\n\r\n")
}

@(test)
test_ws_frame_text_header :: proc(t: ^testing.T) {
	frame: [dynamic]u8
	defer delete(frame)
	_ws_write_frame(&frame, 0x1, transmute([]u8)string("hi"))
	testing.expect(t, len(frame) >= 4)
	testing.expect_value(t, frame[0], u8(0x81))
	testing.expect_value(t, frame[1], u8(2))
	testing.expect_value(t, frame[2], u8('h'))
	testing.expect_value(t, frame[3], u8('i'))
}

@(test)
test_effect_ws_constructors :: proc(t: ^testing.T) {
	e := effect_ws_text("x")
	testing.expect_value(t, e.kind, Effect_Kind.Ws_Text)
	e = effect_ws_close(1001, "going")
	testing.expect_value(t, e.kind, Effect_Kind.Ws_Close)
	testing.expect_value(t, e.ws_code, u16(1001))
}

@(test)
test_stream_buf_size_default :: proc(t: ^testing.T) {
	testing.expect(t, STREAM_BUF_SIZE_DEFAULT == 8 * 1024)
	testing.expect(t, STREAM_BYTES_TOTAL_DEFAULT == 64 * 1024 * 1024)
}

// PR6: ciphered flag + session attach; effects apply into resp_buf (plain framing).
// No sockets / SSL — gen, apply, and hangup gate only (encrypt path needs tls_ssl + ring).
@(test)
test_session_ciphered_attach_ws_effects :: proc(t: ^testing.T) {
	server: Server
	server.conn_allocator = context.allocator

	conn: Connection
	conn.server = &server
	conn.slot.conn = &conn
	conn.slot.gen = 1
	wire_conn_init(&conn.wire_conn)
	tls_pipe_init(&conn.tls_pipe)
	testing.expect(t, connection_enable_ciphered(&conn))
	testing.expect(t, conn.ciphered)
	// Lightweight enable has no SSL — hangup uses CT only when Open+ssl.
	testing.expect(t, !_session_hangup_uses_tls_ct(&conn))

	headers_init(&conn.slot.res.headers, context.allocator)
	defer delete(conn.slot.res.headers._kv)

	wire := make([dynamic]u8, 0, 256, context.allocator)
	defer delete(wire)
	conn.slot.res._buf.buf = wire
	conn.slot.res._buf.buf.allocator = context.allocator
	conn.slot.res._conn = &conn
	conn.slot.res._slot = &conn.slot
	conn.slot.res._heading_written = true
	conn.slot.res._streaming = true
	conn.resp_buf = wire

	st: Session_State
	st.on_event = proc(sess: ^Session, ev: Session_Event, user: rawptr) -> Effects {
		_ = sess
		_ = user
		switch ev.kind {
		case .Start:
			// No End: avoids headers_set_close / Will_Close side effects without a worker.
			return effects_of(effect_ws_text("hi"))
		case .Timer, .External, .Client_Gone, .Idle_Timeout, .Writable:
			return {}
		}
		return {}
	}
	st.gen = 1
	st.proto = .Ws
	st.public = Session{_conn = &conn, id = 1}
	st.allocator = context.allocator
	conn.slot.session = &st
	conn.slot.res._session_attached = true

	sess := st.public
	effs := sse_drive_for_test(&sess, Session_Event{kind = .Start})
	testing.expect_value(t, effs.n, u8(1))
	testing.expect_value(t, effs.items[0].kind, Effect_Kind.Ws_Text)
	// WS frames land in resp_buf as plain (encrypt is tls_host_stream_try_submit with ssl).
	body := string(conn.slot.res._buf.buf[:])
	testing.expect(t, strings.contains(body, "hi"))
	// Frame opcode text (0x81) present — same apply path as clear H1.
	testing.expect(t, len(conn.slot.res._buf.buf) >= 2)
	testing.expect_value(t, conn.slot.res._buf.buf[0], u8(0x81))
	testing.expect(t, conn.ciphered) // flag unchanged through apply

	conn.slot.session = nil
	connection_disable_ciphered(&conn)
}

// Hangup gate: clear never uses TLS CT; ciphered+Open+ssl does (no ring required).
@(test)
test_session_hangup_uses_tls_ct_gate :: proc(t: ^testing.T) {
	c: Connection
	tls_pipe_init(&c.tls_pipe)
	testing.expect(t, !_session_hangup_uses_tls_ct(&c))

	testing.expect(t, connection_enable_ciphered(&c))
	// ciphered alone without SSL / Open is false.
	testing.expect(t, !_session_hangup_uses_tls_ct(&c))

	c.tls_pipe.state = .Open
	// Still no ssl pointer — gate stays false (arm would no-op / fail).
	testing.expect(t, !_session_hangup_uses_tls_ct(&c))

	// Non-nil opaque marker: gate is structural (does not call into OpenSSL).
	fake: int = 1
	c.tls_ssl = tls_server.Conn(rawptr(&fake))
	testing.expect(t, _session_hangup_uses_tls_ct(&c))

	c.tls_ssl = nil
	connection_disable_ciphered(&c)
	testing.expect(t, !_session_hangup_uses_tls_ct(&c))
}

// Ciphered session attach snapshot: gen + effects without sockets (SSE data).
@(test)
test_session_ciphered_sse_apply_gen :: proc(t: ^testing.T) {
	server: Server
	server.conn_allocator = context.allocator

	conn: Connection
	conn.server = &server
	conn.slot.conn = &conn
	conn.slot.gen = 3
	wire_conn_init(&conn.wire_conn)
	testing.expect(t, connection_enable_ciphered(&conn))

	headers_init(&conn.slot.res.headers, context.allocator)
	// destroy frees Session_State; headers live on conn.slot.res until we delete.
	defer delete(conn.slot.res.headers._kv)

	wire := make([dynamic]u8, 0, 256, context.allocator)
	defer delete(wire)
	conn.slot.res._buf.buf = wire
	conn.slot.res._buf.buf.allocator = context.allocator
	conn.slot.res._conn = &conn
	conn.slot.res._slot = &conn.slot
	conn.slot.res._heading_written = true
	conn.slot.res._streaming = true
	conn.resp_buf = wire
	append(&conn.slot.res._buf.buf, ..transmute([]u8)string("HTTP/1.1 200 OK\r\n\r\n"))
	conn.resp_buf = conn.slot.res._buf.buf

	st := new(Session_State, context.allocator)
	st.allocator = context.allocator
	st.on_event = proc(sess: ^Session, ev: Session_Event, user: rawptr) -> Effects {
		_ = sess
		_ = user
		if ev.kind == .Start {
			// Data only — End would headers_set_close without a real wire worker.
			return effects_of(effect_sse_data("z"))
		}
		return {}
	}
	st.gen = stream_slot_bump_gen(&conn.slot)
	st.proto = .Sse
	st.public = Session{_conn = &conn, id = st.gen}
	conn.slot.session = st
	conn.slot.res._session_attached = true

	sess := st.public
	effs := sse_drive_for_test(&sess, Session_Event{kind = .Start})
	testing.expect_value(t, effs.n, u8(1))
	body := string(conn.slot.res._buf.buf[:])
	testing.expect(t, strings.contains(body, "data: z"))
	testing.expect(t, conn.ciphered)
	testing.expect_value(t, st.gen, u32(4)) // bumped from 3

	// Destroy bumps slot.gen again (ABA); attach snapshot st.gen stays 4 until free.
	_session_destroy(&conn, after_wire = false)
	testing.expect(t, conn.slot.session == nil)
	testing.expect_value(t, conn.slot.gen, u32(5))
	connection_disable_ciphered(&conn)
}
