package quic

import "core:testing"

// Loopback test for the multi-stream send path. Verifies that
// `conn_open_uni` allocates unidirectional streams with the right RFC
// 9000 ID pattern, that `_pick_next_send_stream` walks streams in
// ascending ID order, and that each stream's bytes arrive at the peer
// segregated.

@(test)
test_loopback_multistream_per_priority :: proc(t: ^testing.T) {
	// Server transport params: grant 8 uni streams + 1 MiB per uni.
	server_tp := _default_client_tp()
	server_tp.initial_max_streams_bidi    = 1
	server_tp.initial_max_streams_uni     = 8
	server_tp.initial_max_stream_data_uni = 1 * 1024 * 1024

	alpn := _alpn_wire("hq-29") // negotiation isn't what we're testing here
	defer delete(alpn)

	client_tp := _default_client_tp()
	client_tp.initial_max_streams_bidi    = 1
	client_tp.initial_max_streams_uni     = 8
	client_tp.initial_max_stream_data_uni = 1 * 1024 * 1024

	client, _ := conn_new("localhost", alpn[:], client_tp)
	defer conn_free(client)
	conn_disable_verify(client)

	server, _ := conn_new_server(
		transmute([]u8)string(TEST_CERT_PEM),
		transmute([]u8)string(TEST_KEY_PEM),
		server_tp,
	)
	defer conn_free(server)

	// Drive the TLS handshake.
	conn_start_handshake(client)
	pkt: [2048]u8
	cn, _ := conn_build_initial_packet(client, pkt[:])
	conn_on_udp_recv(server, pkt[:cn])
	s_init: [2048]u8
	s_init_len, _ := conn_build_initial_packet(server, s_init[:])
	s_hs: [2048]u8
	s_hs_len, _ := conn_build_handshake_packet(server, s_hs[:])
	conn_on_udp_recv(client, s_init[:s_init_len])
	conn_on_udp_recv(client, s_hs[:s_hs_len])
	c_hs: [2048]u8
	c_hs_len, _ := conn_build_handshake_packet(client, c_hs[:])
	conn_on_udp_recv(server, c_hs[:c_hs_len])

	testing.expect_value(t, client.state, Conn_State.Connected)
	testing.expect_value(t, server.state, Conn_State.Connected)

	// Open the control bidi + three uni streams. Verify the IDs follow
	// RFC 9000 §2.1: client-initiated bidi=0, client-initiated uni=2,6,10.
	ctl := conn_open_stream(client)
	ctl.tx_peer_max_data = DEFAULT_STREAM_WINDOW
	testing.expect_value(t, ctl.id, u64(0))

	uni_a := conn_open_uni(client)
	uni_b := conn_open_uni(client)
	uni_c := conn_open_uni(client)
	testing.expect(t, uni_a != nil && uni_b != nil && uni_c != nil,
		"three uni streams should open under an 8-stream budget")
	testing.expect_value(t, uni_a.id, u64(2))
	testing.expect_value(t, uni_b.id, u64(6))
	testing.expect_value(t, uni_c.id, u64(10))

	// Queue distinct payloads on each stream — different lengths help
	// catch any cross-stream byte mixing.
	stream_write(ctl,   transmute([]u8)string("CTL"))
	stream_write(uni_a, transmute([]u8)string("AA"))
	stream_write(uni_b, transmute([]u8)string("BBBB"))
	stream_write(uni_c, transmute([]u8)string("CCCCCC"))

	// Drain everything client-side into packets, deliver to the server.
	// Each call to conn_build_stream_packet emits at most one stream's
	// worth of data, so we loop until nothing's left to send.
	for {
		n, sent, _ := conn_build_stream_packet(client, pkt[:])
		if n == 0 do break
		_ = sent
		conn_on_udp_recv(server, pkt[:n])
	}

	// Each stream id should have lazily appeared in the server's registry.
	server_ctl := conn_get_stream(server, 0)
	server_a   := conn_get_stream(server, 2)
	server_b   := conn_get_stream(server, 6)
	server_c   := conn_get_stream(server, 10)
	testing.expect(t, server_ctl != nil && server_a != nil && server_b != nil && server_c != nil,
		"every client-side stream should materialize on the server")

	buf: [16]u8
	n0, _ := stream_read(server_ctl, buf[:])
	testing.expect_value(t, string(buf[:n0]), "CTL")
	n1, _ := stream_read(server_a,   buf[:])
	testing.expect_value(t, string(buf[:n1]), "AA")
	n2, _ := stream_read(server_b,   buf[:])
	testing.expect_value(t, string(buf[:n2]), "BBBB")
	n3, _ := stream_read(server_c,   buf[:])
	testing.expect_value(t, string(buf[:n3]), "CCCCCC")
}

// Verify the priority → stream lookup. In single-stream mode every
// priority routes back to the control bidi; in multi-stream mode each
// priority gets its own stream by open-order.
@(test)
test_conn_stream_for_priority_mapping :: proc(t: ^testing.T) {
	c: Conn
	c.is_server = false

	// Single-stream mode: no ALPN captured → every priority is stream 0.
	c.streams = make(map[u64]^Stream)
	defer { for _, s in c.streams { stream_free(s) }; delete(c.streams) }

	s0 := stream_new(0)
	c.streams[0] = s0
	for prio in 0..=7 {
		testing.expect(t, conn_stream_for_priority(&c, u8(prio)) == s0,
			"single-stream mode should route every priority to id 0")
	}

	// Multi-stream mode: stash the multi-stream ALPN and open three uni
	// streams. Priority 1 → first uni, etc.
	alpn := ALPN_MULTI_STREAM
	for i in 0..<len(alpn) do c.alpn_negotiated[i] = alpn[i]
	c.alpn_negotiated_len = len(alpn)

	// Simulate three opens — no peer to enforce limits, so allocate manually.
	c.peer_tp.initial_max_streams_uni = 8
	a := conn_open_uni(&c)
	b := conn_open_uni(&c)
	cc := conn_open_uni(&c)
	testing.expect(t, a != nil && b != nil && cc != nil)

	testing.expect(t, conn_stream_for_priority(&c, 0) == s0,
		"priority 0 stays on control bidi")
	testing.expect(t, conn_stream_for_priority(&c, 1) == a,
		"priority 1 maps to first uni stream")
	testing.expect(t, conn_stream_for_priority(&c, 2) == b)
	testing.expect(t, conn_stream_for_priority(&c, 3) == cc)
	testing.expect(t, conn_stream_for_priority(&c, 7) == nil,
		"priorities without an opened uni stream return nil")
}
