// D0/D1 Session + SSE pure tests (no full server / sockets).
package http

import "core:bytes"
import "core:strings"
import "core:testing"
import "core:time"

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
	conn.loop.res = res
	conn.loop.res._conn = &conn
	// Note: res on stack; re-bind after copy into conn.loop
	conn.loop.res._conn = &conn
	wire := make([dynamic]u8, 0, 1024, context.allocator)
	defer delete(wire)
	conn.loop.res._buf.buf = wire
	conn.loop.res._buf.buf.allocator = context.allocator
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
	conn.session = &st
	conn.loop.res._session_attached = true
	conn.loop.res._streaming = true
	conn.loop.res._heading_written = true

	// Pre-seed a minimal heading so buffer is non-empty.
	append(&conn.loop.res._buf.buf, ..transmute([]u8)string("HTTP/1.1 200 OK\r\n\r\n"))
	conn.resp_buf = conn.loop.res._buf.buf

	sess := st.public
	effs := sse_drive_for_test(&sess, Session_Event{kind = .Start})
	testing.expect_value(t, effs.n, u8(2))
	testing.expect_value(t, effs.items[0].kind, Effect_Kind.Sse_Data)
	testing.expect_value(t, effs.items[1].kind, Effect_Kind.End)
	// End path sets ending; without worker flush is coalesce-only.
	testing.expect(t, conn.stream_ending || st.ending)
	// SSE data was chunked into the response buffer.
	body := string(conn.loop.res._buf.buf[:])
	testing.expect(t, strings.contains(body, "data: hi"))
	// Tear down without free (stack state).
	conn.session = nil
	conn.loop.res._session_attached = false
}

@(test)
test_session_status_nil :: proc(t: ^testing.T) {
	s: Session
	testing.expect(t, !session_status(s))
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
