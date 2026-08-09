package http2

import "core:testing"

import "../hpack"

// Engine-level strictness pins (offline unit subset). Not a full h2spec
// harness or 145/146-class suite — regressions surface in `odin test` only.

@(private = "file")
server_conn :: proc() -> Http2_Connection {
	c: Http2_Connection
	conn_init(&c, true)
	c.preface_seen = true
	return c
}

@(private = "file")
feed :: proc(c: ^Http2_Connection, frames: []u8) -> (H2_Error, u32) {
	out: [dynamic]u8
	defer delete(out)
	err := conn_feed(c, frames, &out)
	return err, c.fail_code
}

@(private = "file")
request_block :: proc(headers: []Header, buf: ^[dynamic]u8) {
	hpack.encode(buf, headers)
}

@(private = "file")
GOOD_REQ := []Header{{name = ":method", value = "GET"}, {name = ":scheme", value = "http"}, {name = ":authority", value = "x"}, {name = ":path", value = "/"}}

@(test)
test_h2_strict_frame_rules :: proc(t: ^testing.T) {
	// DATA on an idle (never-opened) stream → PROTOCOL_ERROR.
	{
		c := server_conn()
		defer conn_destroy(&c)
		wire: [dynamic]u8
		defer delete(wire)
		frame_write(&wire, FRAME_DATA, 0, 1, []u8{1, 2, 3})
		err, code := feed(&c, wire[:])
		testing.expect_value(t, err, H2_Error.Protocol)
		testing.expect_value(t, code, H2_PROTOCOL_ERROR)
	}
	// Even-numbered (server-initiated) stream id from a client → PROTOCOL_ERROR.
	{
		c := server_conn()
		defer conn_destroy(&c)
		block: [dynamic]u8
		defer delete(block)
		request_block(GOOD_REQ, &block)
		wire: [dynamic]u8
		defer delete(wire)
		frame_write(&wire, FRAME_HEADERS, FLAG_END_HEADERS | FLAG_END_STREAM, 2, block[:])
		err, code := feed(&c, wire[:])
		testing.expect_value(t, err, H2_Error.Protocol)
		testing.expect_value(t, code, H2_PROTOCOL_ERROR)
	}
	// PING with a length other than 8 → FRAME_SIZE_ERROR.
	{
		c := server_conn()
		defer conn_destroy(&c)
		wire: [dynamic]u8
		defer delete(wire)
		frame_write(&wire, FRAME_PING, 0, 0, []u8{0, 0, 0})
		err, code := feed(&c, wire[:])
		testing.expect_value(t, err, H2_Error.Frame)
		testing.expect_value(t, code, H2_FRAME_SIZE_ERROR)
	}
	// SETTINGS_INITIAL_WINDOW_SIZE above 2^31-1 → FLOW_CONTROL_ERROR.
	{
		c := server_conn()
		defer conn_destroy(&c)
		wire: [dynamic]u8
		defer delete(wire)
		sp := [6]u8{0, u8(SETTINGS_INITIAL_WINDOW_SIZE), 0x80, 0, 0, 0}
		frame_write(&wire, FRAME_SETTINGS, 0, 0, sp[:])
		err, code := feed(&c, wire[:])
		testing.expect_value(t, err, H2_Error.Protocol)
		testing.expect_value(t, code, H2_FLOW_CONTROL_ERROR)
	}
	// WINDOW_UPDATE with increment 0 → PROTOCOL_ERROR.
	{
		c := server_conn()
		defer conn_destroy(&c)
		wire: [dynamic]u8
		defer delete(wire)
		frame_write(&wire, FRAME_WINDOW_UPDATE, 0, 0, []u8{0, 0, 0, 0})
		err, code := feed(&c, wire[:])
		testing.expect_value(t, err, H2_Error.Protocol)
		testing.expect_value(t, code, H2_PROTOCOL_ERROR)
	}
	// Stream-level window OVERFLOW is a stream error: RST_STREAM goes out,
	// the connection survives.
	{
		c := server_conn()
		defer conn_destroy(&c)
		block: [dynamic]u8
		defer delete(block)
		request_block(GOOD_REQ, &block)
		wire: [dynamic]u8
		defer delete(wire)
		frame_write(&wire, FRAME_HEADERS, FLAG_END_HEADERS | FLAG_END_STREAM, 1, block[:])
		big := [4]u8{0x7f, 0xff, 0xff, 0xff}
		frame_write(&wire, FRAME_WINDOW_UPDATE, 0, 1, big[:])
		frame_write(&wire, FRAME_WINDOW_UPDATE, 0, 1, big[:]) // overflows
		out: [dynamic]u8
		defer delete(out)
		testing.expect_value(t, conn_feed(&c, wire[:], &out), H2_Error.None)
		// Find the RST_STREAM among the replies.
		saw_rst := false
		pos := 0
		for {
			fh, payload, consumed, fe := frame_decode(out[pos:])
			if fe != .None do break
			if fh.type == FRAME_RST_STREAM && fh.stream_id == 1 {
				testing.expect_value(t, get_u32(payload[:4]), H2_FLOW_CONTROL_ERROR)
				saw_rst = true
			}
			pos += consumed
		}
		testing.expect(t, saw_rst, "stream window overflow answered with RST_STREAM(FLOW_CONTROL_ERROR)")
	}
}

@(test)
test_h2_strict_request_semantics :: proc(t: ^testing.T) {
	bad_requests := [][]Header{
		{{name = ":method", value = "GET"}, {name = ":scheme", value = "http"}, {name = ":authority", value = "x"}},                          // no :path
		{{name = ":method", value = "GET"}, {name = ":scheme", value = "http"}, {name = ":path", value = ""}},                                // empty :path
		{{name = ":method", value = "GET"}, {name = ":scheme", value = "http"}, {name = ":path", value = "/"}, {name = ":status", value = "200"}},           // response pseudo
		{{name = ":method", value = "GET"}, {name = ":scheme", value = "http"}, {name = ":path", value = "/"}, {name = "x-a", value = "1"}, {name = ":path", value = "/"}}, // pseudo after regular
		{{name = ":method", value = "GET"}, {name = ":scheme", value = "http"}, {name = ":path", value = "/"}, {name = "X-Upper", value = "1"}},             // uppercase name
		{{name = ":method", value = "GET"}, {name = ":scheme", value = "http"}, {name = ":path", value = "/"}, {name = "connection", value = "keep-alive"}}, // conn-specific
		{{name = ":method", value = "GET"}, {name = ":scheme", value = "http"}, {name = ":path", value = "/"}, {name = "te", value = "gzip"}},               // te != trailers
	}
	for bad in bad_requests {
		c := server_conn()
		defer conn_destroy(&c)
		block: [dynamic]u8
		defer delete(block)
		request_block(bad, &block)
		wire: [dynamic]u8
		defer delete(wire)
		frame_write(&wire, FRAME_HEADERS, FLAG_END_HEADERS | FLAG_END_STREAM, 1, block[:])
		err, code := feed(&c, wire[:])
		testing.expect_value(t, err, H2_Error.Protocol)
		testing.expect_value(t, code, H2_PROTOCOL_ERROR)
	}

	// content-length must match the delivered body.
	{
		c := server_conn()
		defer conn_destroy(&c)
		block: [dynamic]u8
		defer delete(block)
		request_block([]Header{{name = ":method", value = "POST"}, {name = ":scheme", value = "http"}, {name = ":path", value = "/"}, {name = "content-length", value = "5"}}, &block)
		wire: [dynamic]u8
		defer delete(wire)
		frame_write(&wire, FRAME_HEADERS, FLAG_END_HEADERS, 1, block[:])
		frame_write(&wire, FRAME_DATA, FLAG_END_STREAM, 1, []u8{1, 2, 3}) // 3 != 5
		err, code := feed(&c, wire[:])
		testing.expect_value(t, err, H2_Error.Protocol)
		testing.expect_value(t, code, H2_PROTOCOL_ERROR)
	}

	// HPACK: a dynamic table size update beyond SETTINGS_HEADER_TABLE_SIZE.
	{
		c := server_conn()
		defer conn_destroy(&c)
		// 001xxxxx prefix-5 integer: 0x3F + continuation for 8192 (> 4096).
		bad_update := []u8{0x3f, 0xe1, 0x3f}
		wire: [dynamic]u8
		defer delete(wire)
		frame_write(&wire, FRAME_HEADERS, FLAG_END_HEADERS | FLAG_END_STREAM, 1, bad_update)
		err, code := feed(&c, wire[:])
		testing.expect_value(t, err, H2_Error.Hpack)
		testing.expect_value(t, code, H2_COMPRESSION_ERROR)
	}
}
