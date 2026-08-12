package client

import "core:testing"

import http "../http"
import "../http2"

// Sans-I/O: client.H2_Session looped against a server-role Http2_Connection
// (same engine server.H2_Session wraps). Pattern matches examples/byo_h2_session
// and tests/unit/server/session_h2_test.odin (mirrored roles).
// clientx (package cycle).
@(test)
test_h2_client_session_loopback_get :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	server: http2.Http2_Connection
	http2.conn_init(&server, true)
	defer http2.conn_destroy(&server)

	s_out: [dynamic]u8
	defer delete(s_out)
	http2.conn_send_preface(&server, &s_out)

	client: H2_Session
	h2_client_session_init(&client)
	defer h2_client_session_destroy(&client)

	req := Request {
		method = "GET",
		target = Target{scheme = "https", host = "example.com", path = "/"},
	}
	sid := h2_client_session_send_request(&client, &req)

	got := false
	for _ in 0 ..< 16 {
		if len(client.out) > 0 {
			testing.expect_value(
				t,
				http2.conn_feed(&server, client.out[:], &s_out),
				http2.H2_Error.None,
			)
			clear(&client.out)
		}
		// Dispatch every completed request (server role).
		for {
			rsid, req_headers, _, ok := http2.conn_take_request(&server)
			if !ok do break
			_ = req_headers
			http2.conn_send_response(
				&server, &s_out, rsid,
				[]Header{{name = ":status", value = "200"}, {name = "content-type", value = "text/plain"}},
				transmute([]u8)string("ok"),
			)
		}
		if len(s_out) > 0 {
			testing.expect_value(
				t,
				h2_client_session_feed(&client, s_out[:]),
				http2.H2_Error.None,
			)
			clear(&s_out)
		}
		if res, ok := h2_client_session_take_response(&client, sid); ok {
			defer response_destroy(&res)
			testing.expect_value(t, res.status, Status.OK)
			testing.expect_value(t, res.version, ProtocolVersion.Http2)
			testing.expect_value(t, string(res.body[:]), "ok")
			got = true
			break
		}
		if _, failed := h2_client_session_stream_failed(&client, sid); failed {
			testing.expect(t, false, "stream failed before response")
			return
		}
	}
	testing.expect(t, got, "client session received response over in-memory loop")
}

// Explicit pseudo-headers path (send_headers) + raw response view.
@(test)
test_h2_client_session_send_headers :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	server: http2.Http2_Connection
	http2.conn_init(&server, true)
	defer http2.conn_destroy(&server)

	s_out: [dynamic]u8
	defer delete(s_out)
	http2.conn_send_preface(&server, &s_out)

	client: H2_Session
	h2_client_session_init(&client)
	defer h2_client_session_destroy(&client)

	sid := h2_client_session_send_headers(&client, {
		{name = ":method", value = "GET"},
		{name = ":scheme", value = "https"},
		{name = ":authority", value = "localhost"},
		{name = ":path", value = "/x"},
	})

	got := false
	for _ in 0 ..< 16 {
		if len(client.out) > 0 {
			_ = http2.conn_feed(&server, client.out[:], &s_out)
			clear(&client.out)
		}
		for {
			rsid, _, _, ok := http2.conn_take_request(&server)
			if !ok do break
			http2.conn_send_response(
				&server, &s_out, rsid,
				[]Header{{name = ":status", value = "200"}},
				transmute([]u8)string("hi"),
			)
		}
		if len(s_out) > 0 {
			_ = h2_client_session_feed(&client, s_out[:])
			clear(&s_out)
		}
		if rh, rb, done := h2_client_session_response(&client, sid); done {
			status := ""
			for h in rh do if h.name == ":status" do status = h.value
			testing.expect_value(t, status, "200")
			testing.expect_value(t, string(rb), "hi")
			got = true
			break
		}
	}
	testing.expect(t, got, "send_headers + response completed")
}
