package http2

import "core:testing"

@(private = "file")
find :: proc(hs: []Header, name: string) -> string {
	for h in hs do if h.name == name do return h.value
	return ""
}

// In-memory loopback: a client Http2_Connection and a server Http2_Connection exchange their byte
// streams directly (no socket), driving a full HTTP/2 GET -> 200 round-trip
// through preface, SETTINGS, HPACK, and the frame multiplexer.
@(test)
test_h2_loopback_request_response :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	client: Http2_Connection
	server: Http2_Connection
	conn_init(&client, false)
	conn_init(&server, true)
	defer conn_destroy(&client)
	defer conn_destroy(&server)

	c_out: [dynamic]u8
	s_out: [dynamic]u8
	defer delete(c_out)
	defer delete(s_out)

	conn_send_preface(&client, &c_out)
	req := []Header {
		{":method", "GET"},
		{":scheme", "https"},
		{":authority", "example.com"},
		{":path", "/"},
		{"user-agent", "vapor-http2"},
	}
	sid := conn_send_request(&client, &c_out, req)
	conn_send_preface(&server, &s_out)

	got := false
	for _ in 0 ..< 8 {
		if len(c_out) > 0 {
			testing.expect_value(t, conn_feed(&server, c_out[:], &s_out), H2_Error.None)
			clear(&c_out)
		}
		for {
			rsid, hdrs, _, ok := conn_take_request(&server)
			if !ok do break
			testing.expect_value(t, find(hdrs, ":method"), "GET")
			testing.expect_value(t, find(hdrs, ":path"), "/")
			resp := []Header{{":status", "200"}, {"content-type", "text/plain"}}
			conn_send_response(&server, &s_out, rsid, resp, transmute([]u8)string("hi from h2"))
		}
		if len(s_out) > 0 {
			testing.expect_value(t, conn_feed(&client, s_out[:], &c_out), H2_Error.None)
			clear(&s_out)
		}
		if rh, rb, done := conn_response(&client, sid); done {
			testing.expect_value(t, find(rh, ":status"), "200")
			testing.expect_value(t, string(rb), "hi from h2")
			got = true
			break
		}
	}
	testing.expect(t, got, "client received the response")
}

// Two requests on one connection get distinct client stream ids 1 and 3.
@(test)
test_h2_stream_ids :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	client: Http2_Connection
	conn_init(&client, false)
	defer conn_destroy(&client)
	out: [dynamic]u8
	defer delete(out)
	req := []Header{{":method", "GET"}, {":path", "/"}}
	s1 := conn_send_request(&client, &out, req)
	s2 := conn_send_request(&client, &out, req)
	testing.expect_value(t, s1, u32(1))
	testing.expect_value(t, s2, u32(3))
}
