package client

import "core:testing"

import http "../http"
import "../http3"
import "../qpack"
import "../quic"

// Sans-I/O: client.H3_Session looped against a server-role Http3_Connection
// over in-memory QUIC (same pattern as http3 test_h3_loopback_request_response
// and client session_h2_test). No UDP sockets.

@(private = "file")
h3_tp :: proc() -> quic.Transport_Params {
	return quic.Transport_Params {
		max_idle_timeout                    = 30_000,
		max_udp_payload_size                = 1472,
		initial_max_data                    = 10 * 1024 * 1024,
		initial_max_stream_data_bidi_local  = 1 * 1024 * 1024,
		initial_max_stream_data_bidi_remote = 1 * 1024 * 1024,
		initial_max_stream_data_uni         = 1 * 1024 * 1024,
		initial_max_streams_bidi            = 16,
		initial_max_streams_uni             = 16,
		ack_delay_exponent                  = 3,
		max_ack_delay                       = 25,
		active_connection_id_limit          = 2,
		max_datagram_frame_size             = 65527,
		disable_active_migration            = true,
	}
}

// Stand up two connected quic.Conns via the in-memory handshake dance.
@(private = "file")
loopback_connect :: proc() -> (client_conn, server_conn: ^quic.Conn) {
	alpn := [3]u8{2, 'h', '3'}
	client_conn, _ = quic.conn_new("localhost", alpn[:], h3_tp())
	quic.conn_disable_verify(client_conn)
	server_conn, _ = quic.conn_new_server(
		transmute([]u8)string(http3.TEST_CERT_PEM),
		transmute([]u8)string(http3.TEST_KEY_PEM),
		h3_tp(),
	)

	quic.conn_start_handshake(client_conn)
	pkt: [2048]u8
	cn, _ := quic.conn_build_initial_packet(client_conn, pkt[:])
	quic.conn_on_udp_recv(server_conn, pkt[:cn])

	s_init: [2048]u8
	si, _ := quic.conn_build_initial_packet(server_conn, s_init[:])
	s_hs: [2048]u8
	sh, _ := quic.conn_build_handshake_packet(server_conn, s_hs[:])
	quic.conn_on_udp_recv(client_conn, s_init[:si])
	quic.conn_on_udp_recv(client_conn, s_hs[:sh])

	c_hs: [2048]u8
	ch, _ := quic.conn_build_handshake_packet(client_conn, c_hs[:])
	quic.conn_on_udp_recv(server_conn, c_hs[:ch])
	return
}

// Shuttle 1-RTT stream packets both directions until quiescent.
@(private = "file")
pump :: proc(a, b: ^quic.Conn) {
	buf: [2048]u8
	for _ in 0 ..< 64 {
		moved := false
		for {
			n, _, _ := quic.conn_build_stream_packet(a, buf[:])
			if n == 0 do break
			quic.conn_on_udp_recv(b, buf[:n])
			moved = true
		}
		for {
			n, _, _ := quic.conn_build_stream_packet(b, buf[:])
			if n == 0 do break
			quic.conn_on_udp_recv(a, buf[:n])
			moved = true
		}
		if !moved do break
	}
}

@(test)
test_h3_client_session_loopback_get :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	cc, sc := loopback_connect()
	defer quic.conn_free(cc)
	defer quic.conn_free(sc)
	testing.expect_value(t, cc.state, quic.Conn_State.Connected)
	testing.expect_value(t, sc.state, quic.Conn_State.Connected)

	client: H3_Session
	testing.expect_value(t, h3_client_session_init(&client, cc), http3.Http3_Error.None)
	defer h3_client_session_destroy(&client)

	server: http3.Http3_Connection
	testing.expect_value(t, http3.h3_conn_init(&server, sc, true), http3.Http3_Error.None)
	defer http3.h3_conn_destroy(&server)

	// SETTINGS exchange (you own poll_send / poll_recv — here in-memory pump).
	pump(cc, sc)
	testing.expect_value(t, h3_client_session_process(&client), http3.Http3_Error.None)
	testing.expect_value(t, http3.h3_conn_process(&server), http3.Http3_Error.None)
	testing.expect(t, h3_client_session_peer_settings_ready(&client), "client SETTINGS")
	testing.expect(t, server.peer_settings_received, "server SETTINGS")

	req := Request {
		method = "GET",
		target = Target{scheme = "https", host = "localhost", path = "/"},
	}
	rs, rerr := h3_client_session_send_request(&client, &req)
	testing.expect_value(t, rerr, http3.Http3_Error.None)

	pump(cc, sc)
	testing.expect_value(t, http3.h3_conn_process(&server), http3.Http3_Error.None)

	req_stream, got_headers, _, ok := http3.h3_next_request(&server)
	testing.expect(t, ok, "server received a request")
	method_ok, path_ok := false, false
	for hh in got_headers {
		if hh.name == ":method" && hh.value == "GET" do method_ok = true
		if hh.name == ":path" && hh.value == "/" do path_ok = true
	}
	testing.expect(t, method_ok, "decoded :method GET")
	testing.expect(t, path_ok, "decoded :path /")

	resp := []Header{{name = ":status", value = "200"}, {name = "content-type", value = "text/plain"}}
	serr := http3.h3_send_response(&server, req_stream, resp, transmute([]u8)string("ok"))
	testing.expect_value(t, serr, http3.Http3_Error.None)

	pump(cc, sc)
	testing.expect_value(t, h3_client_session_process(&client), http3.Http3_Error.None)

	res, done := h3_client_session_take_response(&client, rs)
	testing.expect(t, done, "client session received response")
	defer response_destroy(&res)
	testing.expect_value(t, res.status, Status.OK)
	testing.expect_value(t, res.version, ProtocolVersion.Http3)
	testing.expect_value(t, string(res.body[:]), "ok")
}

// Explicit pseudo-headers path (send_headers) + raw response view.
@(test)
test_h3_client_session_send_headers :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	cc, sc := loopback_connect()
	defer quic.conn_free(cc)
	defer quic.conn_free(sc)

	client: H3_Session
	testing.expect_value(t, h3_client_session_init(&client, cc), http3.Http3_Error.None)
	defer h3_client_session_destroy(&client)

	server: http3.Http3_Connection
	testing.expect_value(t, http3.h3_conn_init(&server, sc, true), http3.Http3_Error.None)
	defer http3.h3_conn_destroy(&server)

	pump(cc, sc)
	_ = h3_client_session_process(&client)
	_ = http3.h3_conn_process(&server)
	testing.expect(t, h3_client_session_peer_settings_ready(&client))

	rs, rerr := h3_client_session_send_headers(&client, {
		{name = ":method", value = "GET"},
		{name = ":scheme", value = "https"},
		{name = ":authority", value = "localhost"},
		{name = ":path", value = "/x"},
	})
	testing.expect_value(t, rerr, http3.Http3_Error.None)

	pump(cc, sc)
	_ = http3.h3_conn_process(&server)

	req_stream, _, _, ok := http3.h3_next_request(&server)
	testing.expect(t, ok, "server got request")
	_ = http3.h3_send_response(
		&server, req_stream,
		{{name = ":status", value = "200"}},
		transmute([]u8)string("hi"),
	)

	pump(cc, sc)
	_ = h3_client_session_process(&client)

	rh, rb, done := h3_client_session_response(&client, rs)
	testing.expect(t, done, "send_headers + response completed")
	status := ""
	for h in rh do if h.name == ":status" do status = h.value
	testing.expect_value(t, status, "200")
	testing.expect_value(t, string(rb), "hi")
}
