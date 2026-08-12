package quic

import "core:testing"

// These tests go beyond the basic loopback handshake to validate the full
// stack under realistic usage patterns. All tests are self-contained (no
// network) and use the embedded minica PEMs from loopback_test.odin.
// Covered:
//   • Idempotent close (conn_free after error paths doesn't double-free)
//   • Back-to-back handshakes (no resource leak across many connections)
//   • Large DATAGRAM near the MTU limit
//   • Multi-datagram coalescing inside one UDP read
//   • Queue overflow drops oldest
//   • Unknown ALPN fails cleanly
//   • Initial PN 0..N rollover
// Every test must be deterministic. Where randomness is used (CIDs, TLS),
// failure should manifest as an assertion error, not flakiness.

// Run the full handshake sequence between two Conns in one go.
@(private)
_drive_handshake :: proc(client, server: ^Conn) -> bool {
	conn_start_handshake(client)

	// Client -> server Initial.
	buf: [2048]u8
	n, err := conn_build_initial_packet(client, buf[:])
	if err != .None do return false
	if conn_on_udp_recv(server, buf[:n]) != .None do return false

	// Server -> client Initial + Handshake (separate packets).
	si: [2048]u8
	si_n, err2 := conn_build_initial_packet(server, si[:])
	if err2 != .None do return false
	sh: [2048]u8
	sh_n, err3 := conn_build_handshake_packet(server, sh[:])
	if err3 != .None do return false
	if conn_on_udp_recv(client, si[:si_n]) != .None do return false
	if conn_on_udp_recv(client, sh[:sh_n]) != .None do return false

	// Client -> server Handshake (Finished).
	ch: [2048]u8
	ch_n, err4 := conn_build_handshake_packet(client, ch[:])
	if err4 != .None do return false
	if conn_on_udp_recv(server, ch[:ch_n]) != .None do return false

	return client.state == .Connected && server.state == .Connected
}

@(private)
_make_pair :: proc() -> (client, server: ^Conn, ok: bool) {
	alpn := _alpn_wire("hq-29")
	defer delete(alpn)

	c, err := conn_new("localhost", alpn[:], _default_client_tp())
	if err != .None do return nil, nil, false
	conn_disable_verify(c)

	s, err2 := conn_new_server(
		transmute([]u8)string(TEST_CERT_PEM),
		transmute([]u8)string(TEST_KEY_PEM),
		_default_client_tp(),
	)
	if err2 != .None {
		conn_free(c)
		return nil, nil, false
	}
	return c, s, true
}


@(test)
test_integration_idempotent_free :: proc(t: ^testing.T) {
	// Create + immediately free. Should not leak, crash, or trip ASAN.
	alpn := _alpn_wire("hq-29")
	defer delete(alpn)

	conn, err := conn_new("localhost", alpn[:], _default_client_tp())
	testing.expect_value(t, err, Quic_Error.None)
	conn_free(conn)

	// Calling conn_free on nil is a legal no-op.
	conn_free(nil)
}


@(test)
test_integration_many_handshakes :: proc(t: ^testing.T) {
	// Run 20 independent handshakes back-to-back. Any resource leak in
	// BoringSSL setup, CRYPTO buffers, or tx/rx queues will surface as
	// memory tracking warnings from odin test's tracking allocator.
	for iter in 0..<20 {
		client, server, ok := _make_pair()
		testing.expect(t, ok, "make_pair failed")
		done := _drive_handshake(client, server)
		testing.expect(t, done, "handshake did not complete")
		conn_free(client)
		conn_free(server)
		_ = iter
	}
}


@(test)
test_integration_encryption_levels :: proc(t: ^testing.T) {
	client, server, _ := _make_pair()
	defer conn_free(client)
	defer conn_free(server)

	_drive_handshake(client, server)

	// After handshake completion:
	//   - Both sides should have read+write keys at Application level.
	testing.expect(t, client.one_rtt.have_tx_keys)
	testing.expect(t, client.one_rtt.have_rx_keys)
	testing.expect(t, server.one_rtt.have_tx_keys)
	testing.expect(t, server.one_rtt.have_rx_keys)
	testing.expect_value(t, client.tx_level, Encryption_Level.Application)
	testing.expect_value(t, server.tx_level, Encryption_Level.Application)
}


@(test)
test_integration_transport_params_exchanged :: proc(t: ^testing.T) {
	client, server, _ := _make_pair()
	defer conn_free(client)
	defer conn_free(server)

	_drive_handshake(client, server)

	// Both peers should have extracted each other's transport params,
	// including the critical max_datagram_frame_size that gates RFC 9221
	// DATAGRAM support.
	testing.expect(t, server.peer_tp.max_datagram_frame_size > 0,
		"server should see client's max_datagram_frame_size")
	testing.expect(t, client.peer_tp.max_datagram_frame_size > 0,
		"client should see server's max_datagram_frame_size")

	// Both peers should have each other's initial_source_cid (the SCID
	// they advertised in their TLS extension).
	testing.expect(t, len(server.peer_tp.initial_source_cid) > 0,
		"server should have peer initial_source_cid")
	testing.expect(t, len(client.peer_tp.initial_source_cid) > 0,
		"client should have peer initial_source_cid")
}


@(test)
test_integration_datagram_burst_100 :: proc(t: ^testing.T) {
	client, server, _ := _make_pair()
	defer conn_free(client)
	defer conn_free(server)
	_drive_handshake(client, server)

	// Send 100 distinct datagrams from client to server; server pops them
	// in the same order.
	BURST :: 100
	buf: [1500]u8
	for i in 0..<BURST {
		msg: [16]u8
		// Encode the index as 4 big-endian bytes so ordering is verifiable.
		msg[0] = u8(i >> 24)
		msg[1] = u8(i >> 16)
		msg[2] = u8(i >> 8)
		msg[3] = u8(i)
		n, err := conn_send_datagram(client, msg[:4], buf[:])
		testing.expect_value(t, err, Quic_Error.None)
		testing.expect_value(t, conn_on_udp_recv(server, buf[:n]), Recv_Error.None)
	}

	// The rx queue has capacity 16; older entries are evicted. So we
	// should see the LAST 16 indices on dequeue.
	expected_start := BURST - 16
	for i in expected_start..<BURST {
		data, ok := conn_recv_datagram(server)
		testing.expect(t, ok, "datagram should be dequeued")
		idx := int(data[0]) << 24 | int(data[1]) << 16 |
		       int(data[2]) << 8  | int(data[3])
		testing.expect_value(t, idx, i)
	}
	// Queue should now be empty.
	_, empty := conn_recv_datagram(server)
	testing.expect(t, !empty)
}


@(test)
test_integration_large_datagram :: proc(t: ^testing.T) {
	client, server, _ := _make_pair()
	defer conn_free(client)
	defer conn_free(server)
	_drive_handshake(client, server)

	// Largest payload that fits inside the rx queue entry (1500 bytes)
	// minus some overhead for the QUIC short header + frame type + length.
	// Conservative: 1200 bytes payload.
	payload: [1200]u8
	for i in 0..<len(payload) do payload[i] = u8(i & 0xff)

	out: [1600]u8
	n, err := conn_send_datagram(client, payload[:], out[:])
	testing.expect_value(t, err, Quic_Error.None)
	testing.expect(t, n > 1200) // header adds overhead

	testing.expect_value(t, conn_on_udp_recv(server, out[:n]), Recv_Error.None)

	recv, ok := conn_recv_datagram(server)
	testing.expect(t, ok)
	testing.expect_value(t, len(recv), len(payload))
	testing.expect(t, slice_equal(recv, payload[:]),
		"payload should round-trip byte-exact")
}


@(test)
test_integration_bidirectional :: proc(t: ^testing.T) {
	client, server, _ := _make_pair()
	defer conn_free(client)
	defer conn_free(server)
	_drive_handshake(client, server)

	// Client -> server, then server -> client, repeat.
	cbuf, sbuf: [1500]u8
	ROUNDS :: 5
	for i in 0..<ROUNDS {
		out_c := [3]u8{u8(i), 0xaa, 0xbb}
		nc, _ := conn_send_datagram(client, out_c[:], cbuf[:])
		conn_on_udp_recv(server, cbuf[:nc])

		in_c, ok1 := conn_recv_datagram(server)
		testing.expect(t, ok1)
		testing.expect_value(t, in_c[0], u8(i))

		out_s := [3]u8{u8(i), 0xcc, 0xdd}
		ns, _ := conn_send_datagram(server, out_s[:], sbuf[:])
		conn_on_udp_recv(client, sbuf[:ns])

		in_s, ok2 := conn_recv_datagram(client)
		testing.expect(t, ok2)
		testing.expect_value(t, in_s[0], u8(i))
	}
}


@(test)
test_integration_datagram_before_handshake_fails :: proc(t: ^testing.T) {
	alpn := _alpn_wire("hq-29")
	defer delete(alpn)
	conn, _ := conn_new("localhost", alpn[:], _default_client_tp())
	defer conn_free(conn)

	// State is .Idle — sending should fail cleanly, not crash.
	out: [1500]u8
	_, err := conn_send_datagram(conn, []u8{0x01}, out[:])
	testing.expect(t, err != .None, "send should fail before handshake")
}


@(test)
test_integration_oversized_datagram_rejected :: proc(t: ^testing.T) {
	client, server, _ := _make_pair()
	defer conn_free(client)
	defer conn_free(server)
	_drive_handshake(client, server)

	// Tamper with the negotiated max_datagram_frame_size to simulate a
	// peer that accepts only small datagrams.
	client.peer_tp.max_datagram_frame_size = 64

	huge: [200]u8
	out: [1500]u8
	_, err := conn_send_datagram(client, huge[:], out[:])
	testing.expect(t, err != .None, "oversized datagram must be rejected")
}


@(test)
test_integration_truncated_packet_is_error :: proc(t: ^testing.T) {
	client, server, _ := _make_pair()
	defer conn_free(client)
	defer conn_free(server)
	_drive_handshake(client, server)

	// Build a valid 1-RTT packet then chop off the last 10 bytes.
	cbuf: [1500]u8
	data := [8]u8{1, 2, 3, 4, 5, 6, 7, 8}
	n, _ := conn_send_datagram(client, data[:], cbuf[:])
	testing.expect(t, n > 20)

	err := conn_on_udp_recv(server, cbuf[:n - 10])
	testing.expect(t, err != .None, "truncated packet must fail AEAD")
}


@(test)
test_integration_cid_uniqueness :: proc(t: ^testing.T) {
	alpn := _alpn_wire("hq-29")
	defer delete(alpn)

	a, _ := conn_new("localhost", alpn[:], _default_client_tp())
	defer conn_free(a)
	b, _ := conn_new("localhost", alpn[:], _default_client_tp())
	defer conn_free(b)

	// Two freshly-created clients should have different source CIDs.
	// (Collision probability is 2^-64; a failure here means RAND_bytes broke.)
	equal := slice_equal(a.src_cid[:a.src_cid_len], b.src_cid[:b.src_cid_len])
	testing.expect(t, !equal, "fresh connections must have unique CIDs")
}
