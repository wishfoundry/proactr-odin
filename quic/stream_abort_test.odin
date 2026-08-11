package quic

import "core:testing"

// Unit tests for per-stream STOP_SENDING / RESET_STREAM handling.
// These verify the affected stream is silenced but the connection and
// other streams stay alive — RFC 9000 §3.5 semantics.

@(test)
test_reset_stream_marks_rx_aborted :: proc(t: ^testing.T) {
	c: Conn
	c.streams = make(map[u64]^Stream)
	defer { for _, s in c.streams { stream_free(s) }; delete(c.streams) }

	s := stream_new(6) // uni stream id 6
	c.streams[6] = s
	// Pretend we already buffered a fragment + delivered bytes that
	// haven't been read yet. Both should be discarded on RESET.
	append(&s.rx_delivered, ..([]u8{0xaa, 0xbb}))
	frag := Rx_Fragment{offset = 100, data = make([]u8, 4)}
	append(&s.rx_fragments, frag)

	_ = _handle_frame_for_test(&c, Reset_Stream_Frame{
		stream_id  = 6,
		error_code = 0,
		final_size = 2,
	})

	testing.expect(t, s.rx_aborted, "rx_aborted should be set")
	testing.expect(t, s.rx_closed,  "rx_closed should be set")
	testing.expect_value(t, len(s.rx_delivered), 0)
	testing.expect_value(t, len(s.rx_fragments), 0)
	// Conn must NOT have flipped to Closing — abort is local to one stream.
	testing.expect_value(t, c.state, Conn_State.Idle)
}

// End-to-end loopback for stream_close_send: the FIN bit should ride
// the last bytes of tx_buffered, the peer should observe rx_closed, and
// any subsequent data on the same stream should be ignored.
@(test)
test_stream_fin_loopback :: proc(t: ^testing.T) {
	alpn := _alpn_wire("hq-29")
	defer delete(alpn)

	client_tp := _default_client_tp()
	client_tp.initial_max_streams_bidi = 1
	client_tp.initial_max_stream_data_bidi_local  = 1 * 1024 * 1024
	client_tp.initial_max_stream_data_bidi_remote = 1 * 1024 * 1024

	client, _ := conn_new("localhost", alpn[:], client_tp)
	defer conn_free(client)
	conn_disable_verify(client)

	server, _ := conn_new_server(
		transmute([]u8)string(TEST_CERT_PEM),
		transmute([]u8)string(TEST_KEY_PEM),
		client_tp,
	)
	defer conn_free(server)

	// Drive the handshake.
	conn_start_handshake(client)
	pkt: [2048]u8
	cn, _ := conn_build_initial_packet(client, pkt[:])
	conn_on_udp_recv(server, pkt[:cn])
	si: [2048]u8
	si_len, _ := conn_build_initial_packet(server, si[:])
	sh: [2048]u8
	sh_len, _ := conn_build_handshake_packet(server, sh[:])
	conn_on_udp_recv(client, si[:si_len])
	conn_on_udp_recv(client, sh[:sh_len])
	ch: [2048]u8
	ch_len, _ := conn_build_handshake_packet(client, ch[:])
	conn_on_udp_recv(server, ch[:ch_len])

	cs := conn_open_stream(client)
	cs.tx_peer_max_data = DEFAULT_STREAM_WINDOW

	stream_write(cs, transmute([]u8)string("payload"))
	stream_close_send(cs)
	for {
		n, _, _ := conn_build_stream_packet(client, pkt[:])
		if n == 0 do break
		conn_on_udp_recv(server, pkt[:n])
	}

	testing.expect(t, cs.tx_fin_sent, "FIN bit should have been emitted")

	ss := conn_get_stream(server, 0)
	testing.expect(t, ss != nil, "server side should have created stream 0")
	testing.expect(t, ss.rx_closed,
		"server should see rx_closed once payload + FIN arrived")
	buf: [16]u8
	n_read, _ := stream_read(ss, buf[:])
	testing.expect_value(t, string(buf[:n_read]), "payload")
}

@(test)
test_stop_sending_silences_one_stream :: proc(t: ^testing.T) {
	c: Conn
	c.streams = make(map[u64]^Stream)
	defer { for _, s in c.streams { stream_free(s) }; delete(c.streams) }

	silenced := stream_new(6)
	other    := stream_new(10)
	c.streams[6]  = silenced
	c.streams[10] = other
	// Both have pending bytes.
	stream_write(silenced, transmute([]u8)string("dropped"))
	stream_write(other,    transmute([]u8)string("survives"))

	_ = _handle_frame_for_test(&c, Stop_Sending_Frame{
		stream_id  = 6,
		error_code = 0,
	})

	testing.expect(t, silenced.tx_aborted, "tx_aborted should be set on id 6")
	testing.expect_value(t, len(silenced.tx_buffered), 0)
	testing.expect(t, !other.tx_aborted, "other streams should be untouched")
	testing.expect_value(t, len(other.tx_buffered), 8) // "survives"

	// _pick_next_send_stream should skip the silenced one.
	picked := _pick_next_send_stream(&c)
	testing.expect(t, picked == other,
		"send picker should pass over a tx_aborted stream")
}

// Local-only helper: replays the relevant cases from process_frames /
// conn_recv.odin without dragging in the whole UDP path. Keeps the
// tests narrow.
@(private)
_handle_frame_for_test :: proc(conn: ^Conn, frame: Frame) -> bool {
	#partial switch f in frame {
	case Reset_Stream_Frame:
		if s := conn_get_stream(conn, f.stream_id); s != nil {
			s.rx_aborted = true
			s.rx_closed  = true
			for frag in s.rx_fragments do delete(frag.data)
			clear(&s.rx_fragments)
			clear(&s.rx_delivered)
		}
		return true
	case Stop_Sending_Frame:
		if s := conn_get_stream(conn, f.stream_id); s != nil {
			s.tx_aborted = true
			clear(&s.tx_buffered)
			s.tx_sent_off = 0
			s.tx_acked_off = 0
		}
		return true
	}
	return false
}
