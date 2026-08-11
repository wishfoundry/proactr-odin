package http3

import "core:net"
import "core:testing"
import "core:time"

import "../qpack"
import "../quic"

// End-to-end HTTP/3 over REAL UDP sockets (loopback interface). Single-threaded:
// two non-blocking sockets, driven by h3sock.pump_quic_send / pump_quic_recv. Unlike the
// in-memory loopback, bytes actually traverse the kernel via sendto/recvfrom.
@(test)
test_h3_real_socket :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	lo := net.IP4_Address{127, 0, 0, 1}

	csock, ce := net.make_bound_udp_socket(lo, 0) // ephemeral ports
	testing.expect(t, ce == nil, "bind client socket")
	ssock, se := net.make_bound_udp_socket(lo, 0)
	testing.expect(t, se == nil, "bind server socket")
	defer net.close(csock)
	defer net.close(ssock)
	net.set_blocking(csock, false)
	net.set_blocking(ssock, false)

	cep, _ := net.bound_endpoint(csock)
	sep, _ := net.bound_endpoint(ssock)
	cep.address = lo
	sep.address = lo

	alpn := [3]u8{2, 'h', '3'}
	client, _ := quic.conn_new("localhost", alpn[:], h3_tp())
	quic.conn_disable_verify(client)
	client.socket = csock
	client.socket_owned = false // we close csock ourselves
	client.remote = sep
	defer quic.conn_free(client)

	server, _ := quic.conn_new_server(
		transmute([]u8)string(TEST_CERT_PEM),
		transmute([]u8)string(TEST_KEY_PEM),
		h3_tp(),
	)
	server.socket = ssock
	server.socket_owned = false
	server.remote = cep
	defer quic.conn_free(server)

	// --- Handshake over the sockets ---
	quic.conn_start_handshake(client)
	connected := false
	for _ in 0 ..< 500 {
		pump_quic_send(client)
		pump_quic_recv(server)
		pump_quic_send(server)
		pump_quic_recv(client)
		if client.state == .Connected && server.state == .Connected {
			connected = true
			break
		}
		time.sleep(time.Millisecond)
	}
	testing.expect(t, connected, "QUIC handshake completed over UDP sockets")

	// --- H3 bring-up + request/response ---
	hc: Http3_Connection
	hs: Http3_Connection
	h3_conn_init(&hc, client, false)
	h3_conn_init(&hs, server, true)
	defer h3_conn_destroy(&hc)
	defer h3_conn_destroy(&hs)

	req := []qpack.Header {
		{name = ":method", value = "GET"},
		{name = ":scheme", value = "https"},
		{name = ":authority", value = "localhost"},
		{name = ":path", value = "/"},
	}
	rs, _ := h3_send_request(&hc, req)

	got := false
	for _ in 0 ..< 500 {
		pump_quic_send(client)
		pump_quic_recv(server)
		h3_conn_process(&hs)
		if rsv, _, _, ok := h3_next_request(&hs); ok {
			h3_send_response(
				&hs, rsv,
				[]qpack.Header{{name = ":status", value = "200"}},
				transmute([]u8)string("hi from socket"),
			)
		}
		pump_quic_send(server)
		pump_quic_recv(client)
		h3_conn_process(&hc)
		if _, body, done := h3_response(&hc, rs); done {
			testing.expect_value(t, string(body), "hi from socket")
			got = true
			break
		}
		time.sleep(time.Millisecond)
	}
	testing.expect(t, got, "received H3 response over real sockets")
}

// 64 KiB body exercises multi-packet STREAM + congestion window + ACKs.
// Uses a hard iteration cap (no infinite spin) and work-conserving pumps.
@(test)
test_h3_real_socket_large_body :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	lo := net.IP4_Address{127, 0, 0, 1}

	csock, ce := net.make_bound_udp_socket(lo, 0)
	ssock, se := net.make_bound_udp_socket(lo, 0)
	testing.expect(t, ce == nil && se == nil)
	defer net.close(csock)
	defer net.close(ssock)
	net.set_blocking(csock, false)
	net.set_blocking(ssock, false)

	cep, _ := net.bound_endpoint(csock)
	sep, _ := net.bound_endpoint(ssock)
	cep.address = lo
	sep.address = lo

	alpn := [3]u8{2, 'h', '3'}
	client, _ := quic.conn_new("localhost", alpn[:], h3_tp())
	quic.conn_disable_verify(client)
	client.socket = csock
	client.socket_owned = false
	client.remote = sep
	defer quic.conn_free(client)

	server, _ := quic.conn_new_server(
		transmute([]u8)string(TEST_CERT_PEM),
		transmute([]u8)string(TEST_KEY_PEM),
		h3_tp(),
	)
	server.socket = ssock
	server.socket_owned = false
	server.remote = cep
	defer quic.conn_free(server)

	quic.conn_start_handshake(client)
	for _ in 0 ..< 500 {
		pump_quic_send(client)
		pump_quic_recv(server)
		pump_quic_send(server)
		pump_quic_recv(client)
		if client.state == .Connected && server.state == .Connected do break
		time.sleep(time.Millisecond)
	}
	testing.expect(t, client.state == .Connected && server.state == .Connected, "handshake")

	hc: Http3_Connection
	hs: Http3_Connection
	h3_conn_init(&hc, client, false)
	h3_conn_init(&hs, server, true)
	defer h3_conn_destroy(&hc)
	defer h3_conn_destroy(&hs)

	large := make([]u8, 65536, context.temp_allocator)
	for i in 0 ..< len(large) do large[i] = 'A'

	req := []qpack.Header {
		{name = ":method", value = "GET"},
		{name = ":scheme", value = "https"},
		{name = ":authority", value = "localhost"},
		{name = ":path", value = "/large"},
	}
	rs, _ := h3_send_request(&hc, req)

	got := false
	for round in 0 ..< 500 {
		pump_quic_recv(server)
		h3_conn_process(&hs)
		if rsv, _, _, ok := h3_next_request(&hs); ok {
			h3_send_response(&hs, rsv, []qpack.Header{{name = ":status", value = "200"}}, large)
		}
		pump_quic_send(server)

		pump_quic_recv(client)
		h3_conn_process(&hc)
		pump_quic_send(client)

		if _, body, done := h3_response(&hc, rs); done {
			testing.expect_value(t, len(body), 65536)
			got = true
			break
		}
		// Sleep only when both sides look idle (no unsent stream data).
		if !quic.conn_has_unsent_stream_data(server) && !quic.conn_has_unsent_stream_data(client) {
			time.sleep(time.Millisecond)
		}
		_ = round
	}
	testing.expect(t, got, "received 64KiB H3 body over real sockets")
}
