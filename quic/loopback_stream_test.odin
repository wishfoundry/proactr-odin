package quic

import "core:testing"
import "core:time"

// End-to-end loopback test for QUIC streams.
//
// Creates a client + server Conn pair, drives the TLS 1.3 handshake through
// them, opens a bidi stream on the client side, and exchanges bytes over
// the stream via `stream_write` / `conn_build_stream_packet` /
// `conn_on_udp_recv` / `stream_read`.
//
// Companion to `test_loopback_handshake` and `test_loopback_datagram_roundtrip`
// which cover the handshake and DATAGRAM paths respectively.

@(test)
test_loopback_stream_roundtrip_small :: proc(t: ^testing.T) {
	alpn := _alpn_wire("hq-29") // unchanged — stream support is orthogonal to ALPN
	defer delete(alpn)

	client, _ := conn_new("localhost", alpn[:], _default_client_tp())
	defer conn_free(client)
	conn_disable_verify(client)

	server, _ := conn_new_server(
		transmute([]u8)string(TEST_CERT_PEM),
		transmute([]u8)string(TEST_KEY_PEM),
		_default_client_tp(),
	)
	defer conn_free(server)

	// Drive handshake (same sequence as test_loopback_handshake).
	conn_start_handshake(client)
	c_init: [2048]u8
	c_init_len, _ := conn_build_initial_packet(client, c_init[:])
	conn_on_udp_recv(server, c_init[:c_init_len])

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

	// Open the client stream. Server will lazy-create its own on first frame.
	client_stream := conn_open_stream(client)
	testing.expect(t, client_stream != nil)
	testing.expect(t, client_stream.id == 0)
	// Peer flow control default: 1 MiB
	client_stream.tx_peer_max_data = DEFAULT_STREAM_WINDOW

	// Client writes "hello stream" and flushes to a 1-RTT packet.
	msg := transmute([]u8)string("hello stream")
	stream_write(client_stream, msg)

	pkt: [2048]u8
	pkt_n, sent, berr := conn_build_stream_packet(client, pkt[:])
	testing.expect_value(t, berr, Quic_Error.None)
	testing.expect_value(t, sent, len(msg))
	testing.expect(t, pkt_n > len(msg)) // header + encryption overhead

	// Deliver to server.
	rerr := conn_on_udp_recv(server, pkt[:pkt_n])
	testing.expect_value(t, rerr, Recv_Error.None)

	// Server-side stream was lazy-created; read back.
	server_stream := conn_get_stream(server, 0)
	testing.expect(t, server_stream != nil, "server should have lazy-created stream")
	buf: [64]u8
	n, ok := stream_read(server_stream, buf[:])
	testing.expect(t, ok)
	testing.expect_value(t, n, len(msg))
	testing.expect_value(t, string(buf[:n]), "hello stream")

	// Verify loss tracking recorded the packet.
	testing.expect_value(t, len(client.loss_sent), 1)
	testing.expect_value(t, len(client_stream.tx_unacked), 1)
	testing.expect_value(t, client_stream.tx_next_offset, u64(len(msg)))
}

@(test)
test_loopback_stream_large_payload :: proc(t: ^testing.T) {
	// Write a 3000-byte payload — larger than our per-packet MAX_PLAINTEXT
	// budget (1400 bytes) so it takes 2-3 outgoing packets to drain.
	// The receiver must reassemble offsets correctly.
	alpn := _alpn_wire("hq-29")
	defer delete(alpn)

	client, _ := conn_new("localhost", alpn[:], _default_client_tp())
	defer conn_free(client)
	conn_disable_verify(client)

	server, _ := conn_new_server(
		transmute([]u8)string(TEST_CERT_PEM),
		transmute([]u8)string(TEST_KEY_PEM),
		_default_client_tp(),
	)
	defer conn_free(server)

	conn_start_handshake(client)
	pkt: [2048]u8
	c_init_n, _ := conn_build_initial_packet(client, pkt[:])
	conn_on_udp_recv(server, pkt[:c_init_n])

	s_init: [2048]u8
	s_init_len, _ := conn_build_initial_packet(server, s_init[:])
	s_hs: [2048]u8
	s_hs_len, _ := conn_build_handshake_packet(server, s_hs[:])
	conn_on_udp_recv(client, s_init[:s_init_len])
	conn_on_udp_recv(client, s_hs[:s_hs_len])

	c_hs: [2048]u8
	c_hs_len, _ := conn_build_handshake_packet(client, c_hs[:])
	conn_on_udp_recv(server, c_hs[:c_hs_len])

	cs := conn_open_stream(client)
	cs.tx_peer_max_data = DEFAULT_STREAM_WINDOW

	// Build a 3000-byte payload with a recognizable pattern.
	payload := make([]u8, 3000)
	defer delete(payload)
	for i in 0..<len(payload) {
		payload[i] = u8(i & 0xff)
	}

	stream_write(cs, payload)

	// Drain the stream in a loop — conn_build_stream_packet produces one
	// packet at a time, up to MAX_PLAINTEXT of stream data per packet.
	total_sent := 0
	packet_count := 0
	for total_sent < len(payload) {
		n, sent, err := conn_build_stream_packet(client, pkt[:])
		testing.expect_value(t, err, Quic_Error.None)
		if n == 0 do break
		conn_on_udp_recv(server, pkt[:n])
		total_sent += sent
		packet_count += 1
		if packet_count > 10 do break // safety
	}

	testing.expect(t, packet_count >= 2, "should have taken multiple packets")
	testing.expect_value(t, total_sent, len(payload))

	// Server assembles the full payload in its stream's rx_delivered.
	recv_buf := make([]u8, 4096)
	defer delete(recv_buf)
	n, _ := stream_read(conn_get_stream(server, 0), recv_buf[:])
	testing.expect_value(t, n, len(payload))
	for i in 0..<len(payload) {
		if recv_buf[i] != payload[i] {
			testing.expect(t, false, "payload byte mismatch")
			break
		}
	}
}

@(test)
test_loopback_stream_ack_clears_unacked :: proc(t: ^testing.T) {
	// Send some bytes, then echo an ACK back from the server side,
	// verify tx_unacked and loss_sent are cleared.
	alpn := _alpn_wire("hq-29")
	defer delete(alpn)

	client, _ := conn_new("localhost", alpn[:], _default_client_tp())
	defer conn_free(client)
	conn_disable_verify(client)

	server, _ := conn_new_server(
		transmute([]u8)string(TEST_CERT_PEM),
		transmute([]u8)string(TEST_KEY_PEM),
		_default_client_tp(),
	)
	defer conn_free(server)

	conn_start_handshake(client)
	pkt: [2048]u8
	c_init_n, _ := conn_build_initial_packet(client, pkt[:])
	conn_on_udp_recv(server, pkt[:c_init_n])

	s_init: [2048]u8
	s_init_len, _ := conn_build_initial_packet(server, s_init[:])
	s_hs: [2048]u8
	s_hs_len, _ := conn_build_handshake_packet(server, s_hs[:])
	conn_on_udp_recv(client, s_init[:s_init_len])
	conn_on_udp_recv(client, s_hs[:s_hs_len])

	c_hs: [2048]u8
	c_hs_len, _ := conn_build_handshake_packet(client, c_hs[:])
	conn_on_udp_recv(server, c_hs[:c_hs_len])

	cs := conn_open_stream(client)
	cs.tx_peer_max_data = DEFAULT_STREAM_WINDOW

	stream_write(cs, transmute([]u8)string("ack me"))
	cn, _, _ := conn_build_stream_packet(client, pkt[:])
	testing.expect(t, cn > 0)

	// At this point client has 1 unacked packet.
	testing.expect_value(t, len(client.loss_sent), 1)
	testing.expect_value(t, len(cs.tx_unacked), 1)

	// Deliver to server. Server ACKs next packet it sends.
	conn_on_udp_recv(server, pkt[:cn])

	// Server builds a packet — should include an ACK.
	ss := conn_get_stream(server, 0)
	ss.tx_peer_max_data = DEFAULT_STREAM_WINDOW
	stream_write(ss, transmute([]u8)string("got it"))
	sn, _, _ := conn_build_stream_packet(server, pkt[:])
	testing.expect(t, sn > 0)

	// Deliver to client. Client should process the ACK and clear unacked.
	conn_on_udp_recv(client, pkt[:sn])

	testing.expect_value(t, len(client.loss_sent), 0)
	testing.expect_value(t, len(cs.tx_unacked), 0)
}

@(test)
test_loopback_stream_bidirectional :: proc(t: ^testing.T) {
	alpn := _alpn_wire("hq-29")
	defer delete(alpn)

	client, _ := conn_new("localhost", alpn[:], _default_client_tp())
	defer conn_free(client)
	conn_disable_verify(client)

	server, _ := conn_new_server(
		transmute([]u8)string(TEST_CERT_PEM),
		transmute([]u8)string(TEST_KEY_PEM),
		_default_client_tp(),
	)
	defer conn_free(server)

	// Handshake.
	conn_start_handshake(client)
	pkt: [2048]u8

	c_init_n, _ := conn_build_initial_packet(client, pkt[:])
	conn_on_udp_recv(server, pkt[:c_init_n])

	s_init: [2048]u8
	s_init_len, _ := conn_build_initial_packet(server, s_init[:])
	s_hs: [2048]u8
	s_hs_len, _ := conn_build_handshake_packet(server, s_hs[:])
	conn_on_udp_recv(client, s_init[:s_init_len])
	conn_on_udp_recv(client, s_hs[:s_hs_len])

	c_hs: [2048]u8
	c_hs_len, _ := conn_build_handshake_packet(client, c_hs[:])
	conn_on_udp_recv(server, c_hs[:c_hs_len])

	// Both ends install their stream with the peer's default window.
	cs := conn_open_stream(client); cs.tx_peer_max_data = DEFAULT_STREAM_WINDOW

	// Client -> server
	stream_write(cs, transmute([]u8)string("ping"))
	cn, _, _ := conn_build_stream_packet(client, pkt[:])
	conn_on_udp_recv(server, pkt[:cn])

	buf: [32]u8
	n, _ := stream_read(conn_get_stream(server, 0), buf[:])
	testing.expect_value(t, string(buf[:n]), "ping")

	// Server -> client. Need to open server's send side too.
	// Our single-stream model stores the same Stream for both directions.
	ss := conn_get_stream(server, 0)
	ss.tx_peer_max_data = DEFAULT_STREAM_WINDOW

	stream_write(ss, transmute([]u8)string("pong"))
	sn, _, _ := conn_build_stream_packet(server, pkt[:])
	conn_on_udp_recv(client, pkt[:sn])

	// Client's stream now has the pong bytes in rx_delivered.
	n2, _ := stream_read(cs, buf[:])
	testing.expect_value(t, string(buf[:n2]), "pong")
}

@(test)
test_loopback_stream_retransmit_on_pto :: proc(t: ^testing.T) {
	// The whole point of the New Reno + retained-buffer work: a lost STREAM
	// packet is retransmitted on PTO and the payload still arrives.
	//
	// Setup is the loopback harness, but we DON'T deliver the first packet
	// (simulating loss). Then we advance the injected clock past the PTO
	// deadline, fire loss_check_pto, rebuild, and deliver the retransmit.
	alpn := _alpn_wire("hq-29")
	defer delete(alpn)

	client, _ := conn_new("localhost", alpn[:], _default_client_tp())
	defer conn_free(client)
	conn_disable_verify(client)

	server, _ := conn_new_server(
		transmute([]u8)string(TEST_CERT_PEM),
		transmute([]u8)string(TEST_KEY_PEM),
		_default_client_tp(),
	)
	defer conn_free(server)

	// Drive handshake (condensed, same as the other tests).
	conn_start_handshake(client)
	pkt: [2048]u8
	c_init_n, _ := conn_build_initial_packet(client, pkt[:])
	conn_on_udp_recv(server, pkt[:c_init_n])
	s_init: [2048]u8
	s_init_n, _ := conn_build_initial_packet(server, s_init[:])
	s_hs: [2048]u8
	s_hs_n, _ := conn_build_handshake_packet(server, s_hs[:])
	conn_on_udp_recv(client, s_init[:s_init_n])
	conn_on_udp_recv(client, s_hs[:s_hs_n])
	c_hs: [2048]u8
	c_hs_n, _ := conn_build_handshake_packet(client, c_hs[:])
	conn_on_udp_recv(server, c_hs[:c_hs_n])

	testing.expect_value(t, client.state, Conn_State.Connected)
	testing.expect_value(t, server.state, Conn_State.Connected)

	cs := conn_open_stream(client)
	cs.tx_peer_max_data = DEFAULT_STREAM_WINDOW

	// Inject the clock so we can fire PTO deterministically. Seed an RTT
	// sample so the PTO duration is a known value (not the 2·INITIAL_RTT
	// pre-sample default).
	seed_rtt_for_conn(client, 50 * time.Millisecond)
	// pto = srtt + max(4·rttvar, granularity) = 50ms + max(100ms,1ms) = 150ms.
	pto_ns := pto_duration(&client.cc, 0)

	// Freeze time at T0 for the send (so sent_at and the armed PTO deadline
	// are anchored to a known point).
	t0 := time.now()
	client.clock = t0

	stream_write(cs, transmute([]u8)string("lost then delivered"))
	cn, sent, _ := conn_build_stream_packet(client, pkt[:])
	testing.expect(t, cn > 0, "first packet built")
	testing.expect_value(t, sent, len("lost then delivered"))
	testing.expect_value(t, len(client.loss_sent), 1)
	cwnd_before_pto := client.cc.cwnd

	// *** SIMULATE LOSS: do NOT deliver pkt[:cn] to the server. ***

	// Advance the clock past the PTO deadline and fire the timer.
	client.clock = time.time_add(t0, pto_ns + time.Millisecond)
	fired := loss_check_pto(client)
	testing.expect(t, fired, "PTO should fire once past the deadline")

	// New Reno halves the window on PTO.
	testing.expect(t, client.cc.cwnd < cwnd_before_pto, "cwnd must shrink on PTO")
	// The lost range was re-queued: tx_sent_off rewound back to 0 so the
	// builder re-emits the bytes.
	testing.expect_value(t, cs.tx_sent_off, u64(0))

	// Rebuild — this is the retransmit (a new packet number).
	rt_n, rt_sent, _ := conn_build_stream_packet(client, pkt[:])
	testing.expect(t, rt_n > 0, "retransmit packet built")
	testing.expect_value(t, rt_sent, len("lost then delivered"))

	// Deliver the retransmit to the server.
	conn_on_udp_recv(server, pkt[:rt_n])

	// The payload arrives despite the original packet being "lost".
	ss := conn_get_stream(server, 0)
	testing.expect(t, ss != nil, "server lazy-creates the stream")
	buf: [64]u8
	n, ok := stream_read(ss, buf[:])
	testing.expect(t, ok)
	testing.expect_value(t, n, len("lost then delivered"))
	testing.expect_value(t, string(buf[:n]), "lost then delivered")

	// Clear the injected clock so teardown uses real time.
	client.clock = {}
}

@(private = "file")
seed_rtt_for_conn :: proc(conn: ^Conn, rtt: time.Duration) {
	// Seed the controller's RTT so pto_duration is a known function of the
	// sample rather than the 2·INITIAL_RTT pre-sample default.
	conn.cc.srtt = rtt
	conn.cc.rttvar = rtt / 2
	conn.cc.min_rtt = rtt
	conn.cc.have_rtt_sample = true
}
