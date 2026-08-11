package quic

import "core:time"

// Phase 7c — post-handshake DATAGRAM send/receive via 1-RTT packets.
// After the TLS handshake completes, both sides have Application-level
// (1-RTT) rx/tx keys. Zenoh wire frames are wrapped in QUIC DATAGRAM frames
// (RFC 9221) and shipped inside short-header packets. zenoh handles all
// reliability and ordering at its own layer, so we don't retransmit
// datagrams — if a UDP packet is lost, zenoh re-sends the zenoh frame.

// Push a received DATAGRAM payload onto the bounded FIFO. Silently drops
// the oldest entry on overflow (matches zenoh's own ring-buffer semantics
// in zenoh/handlers.odin).
@(private)
_rx_datagram_push :: proc(conn: ^Conn, data: []u8) {
	if len(data) > len(conn.rx_datagrams[0]) do return // too big — drop

	slot: int
	if conn.rx_datagrams_count == len(conn.rx_datagrams) {
		// Full — evict oldest to make room.
		conn.rx_datagrams_head = (conn.rx_datagrams_head + 1) % len(conn.rx_datagrams)
		conn.rx_datagrams_count -= 1
	}
	slot = (conn.rx_datagrams_head + conn.rx_datagrams_count) % len(conn.rx_datagrams)
	copy(conn.rx_datagrams[slot][:], data)
	conn.rx_datagram_lens[slot] = len(data)
	conn.rx_datagrams_count += 1
}

// Pop the oldest received DATAGRAM. Returns a view into internal storage
// that is valid until the next conn_recv_datagram call.
conn_recv_datagram :: proc(conn: ^Conn) -> (data: []u8, ok: bool) {
	if conn.rx_datagrams_count == 0 do return nil, false
	slot := conn.rx_datagrams_head
	n := conn.rx_datagram_lens[slot]
	conn.rx_datagrams_head = (conn.rx_datagrams_head + 1) % len(conn.rx_datagrams)
	conn.rx_datagrams_count -= 1
	return conn.rx_datagrams[slot][:n], true
}

// Pick the next stream that has bytes to send, preferring lower stream IDs
// (control bidi first, then user-priority uni streams in priority order
// because we open them in ascending priority — see conn_open_uni).
@(private)
_pick_next_send_stream :: proc(conn: ^Conn) -> ^Stream {
	if len(conn.streams) == 0 do return nil

	// Linear scan — fine for ≤8 streams. A stream is eligible if it has
	// unsent payload (bytes buffered but not yet on the wire, including any
	// rewound for retransmit) OR has an unfinalized FIN bit to emit; tx-aborted
	// streams are skipped entirely.
	best: ^Stream
	for _, s in conn.streams {
		if s.tx_aborted do continue
		unsent := len(s.tx_buffered) > 0 && s.tx_sent_off < u64(len(s.tx_buffered))
		eligible := unsent || (s.tx_fin && !s.tx_fin_sent)
		if !eligible do continue
		if best == nil || s.id < best.id do best = s
	}
	return best
}

// Build a 1-RTT packet draining the highest-priority stream with pending
// data into a STREAM frame. Optionally piggybacks an ACK frame if one is owed.
// Records a Sent_Packet entry for loss tracking.
// Returns bytes written to `out` and the number of stream bytes consumed.
// A return value of (0, 0, .None) means "nothing to send right now" (not an
// error — the caller should just skip this tick).
conn_build_stream_packet :: proc(
	conn: ^Conn,
	out:  []u8,
) -> (n: int, stream_bytes_sent: int, err: Quic_Error) {
	if conn.state != .Connected do return 0, 0, .Handshake_Failed
	if !conn.one_rtt.have_tx_keys do return 0, 0, .Derive_Keys_Failed

	// Pick the next stream with pending data. Walk in ascending id order
	// so the control stream (0) drains before user-priority uni streams,
	// and within the uni streams we serve the lowest-id (highest-priority)
	// one first. The caller drives this in a loop in _quic_link_flush, so
	// each invocation emits at most one stream's worth of frames per
	// packet; later iterations pick up the remaining streams.
	s := _pick_next_send_stream(conn)
	has_ack         := conn.pn_one_rtt.ack_elicited && conn.pn_one_rtt.has_rx
	// FIN-only packets: stream has no unsent bytes but still owes a FIN frame
	// (RFC 9000 §2.3 / §19.8 empty STREAM with FIN).
	has_data        :=
		s != nil &&
		(s.tx_sent_off < u64(len(s.tx_buffered)) || (s.tx_fin && !s.tx_fin_sent))
	has_flow_update := conn.rx_max_data_pending || conn.rx_max_streams_uni_pending
	if !has_ack && !has_data && !has_flow_update do return 0, 0, .None
	// We may still want to send an ACK-only packet even without a stream
	// to send on. In that case `s` is nil and the stream-frame block below
	// is skipped.

	// Enforce flow control + congestion control. Per-stream window (peer's
	// MAX_STREAM_DATA), connection-level window (peer's MAX_DATA), AND the
	// congestion window (cwnd - bytes_in_flight) all apply; the tightest wins.
	// Without the cwnd term the stack would send as fast as the app produces,
	// which is congestion collapse on a lossy path.
	to_send := 0
	if s != nil {
		unsent := len(s.tx_buffered) - int(s.tx_sent_off)
		if unsent < 0 do unsent = 0
		per_stream := int(s.tx_peer_max_data) - int(s.tx_next_offset)
		if per_stream < 0 do per_stream = 0
		per_conn := int(conn.tx_peer_max_data) - int(conn.tx_data_sent)
		if per_conn < 0 do per_conn = 0
		cc_avail := int(send_budget(&conn.cc))
		to_send = min(unsent, min(per_stream, min(per_conn, cc_avail)))
	}

	// Leave room in the packet for: 1 byte first header byte + dcid +
	// 4-byte pn + optional ACK (~16 bytes) + STREAM frame header (~24 bytes)
	// + 16 bytes AEAD tag. Cap plaintext at 1400 bytes to be conservative.
	MAX_PLAINTEXT :: 1400
	plaintext: [MAX_PLAINTEXT]u8
	pos := 0

	if has_ack {
		w := encode_ack_from_space(plaintext[pos:], &conn.pn_one_rtt, 0)
		if w < 0 do return 0, 0, .Encrypt_Failed
		pos += w
		conn.pn_one_rtt.ack_elicited = false
	}

	// Piggyback MAX_STREAM_DATA updates for any stream past half-window.
	// We always check the stream we're about to send on first so it
	// always wins a slot, then sweep the rest of the registry. Capped at
	// MAX_STREAM_DATA_UPDATES_PER_PACKET so header overhead stays modest.
	MAX_STREAM_DATA_UPDATES_PER_PACKET :: 4
	updates_emitted := 0
	if s != nil && stream_needs_flow_control_update(s) {
		new_limit := stream_new_flow_control_limit(s)
		w := encode_max_stream_data(plaintext[pos:], s.id, new_limit)
		if w > 0 {
			pos += w
			updates_emitted += 1
		}
	}
	for _, other in conn.streams {
		if updates_emitted >= MAX_STREAM_DATA_UPDATES_PER_PACKET do break
		if other == s do continue
		if !stream_needs_flow_control_update(other) do continue
		new_limit := stream_new_flow_control_limit(other)
		w := encode_max_stream_data(plaintext[pos:], other.id, new_limit)
		if w > 0 {
			pos += w
			updates_emitted += 1
		}
	}

	// Piggyback a connection-level MAX_DATA update if rx accounting in
	// _handle_stream_frame marked one pending.
	if conn.rx_max_data_pending {
		w := encode_max_data(plaintext[pos:], conn.rx_our_max_data)
		if w > 0 {
			pos += w
			conn.rx_max_data_pending = false
		}
	}

	// Piggyback MAX_STREAMS_UNI when the peer is approaching the cap we
	// advertised — see conn_get_or_open_stream's accounting. We only
	// handle the uni direction today; bidi is for future bi-stream work.
	if conn.rx_max_streams_uni_pending {
		w := encode_max_streams(plaintext[pos:], true, conn.rx_uni_max_advertised)
		if w > 0 {
			pos += w
			conn.rx_max_streams_uni_pending = false
		}
	}

	stream_bytes_in_packet := 0
	stream_frame_offset := u64(0)
	emit_fin := false
	if s != nil && (to_send > 0 || (s.tx_fin && !s.tx_fin_sent)) {
		// How many bytes actually fit? Reserve ~30 bytes for the stream
		// frame header, then clamp.
		room := MAX_PLAINTEXT - pos - 30
		if room < 0 do room = 0
		if to_send > room do to_send = room

		// We can FIN in the same frame iff we're emitting the LAST unsent
		// byte in tx_buffered AND the caller closed the send side. Otherwise
		// the FIN gets its own (empty-data) frame on the next pick.
		unsent_total := len(s.tx_buffered) - int(s.tx_sent_off)
		emit_fin = s.tx_fin && !s.tx_fin_sent && to_send == unsent_total

		stream_frame_offset = s.tx_next_offset

		w := encode_stream_frame(
			plaintext[pos:],
			s.id,
			stream_frame_offset,
			s.tx_buffered[s.tx_sent_off : s.tx_sent_off + u64(to_send)],
			emit_fin,
		)
		if w < 0 do return 0, 0, .Encrypt_Failed
		pos += w
		stream_bytes_in_packet = to_send
		if emit_fin do s.tx_fin_sent = true
	}

	if pos == 0 do return 0, 0, .None // nothing to encode

	pn := conn.pn_one_rtt.next_tx_pn
	conn.pn_one_rtt.next_tx_pn += 1

	packet_len, ok := encrypt_one_rtt(
		out,
		conn.dst_cid[:conn.dst_cid_len],
		pn,
		4,
		plaintext[:pos],
		&conn.one_rtt.tx_keys,
	)
	if !ok do return 0, 0, .Encrypt_Failed

	conn.stats.stream_frames_sent += 1
	conn.stats.stream_bytes_sent += u64(stream_bytes_in_packet)
	conn.tx_data_sent += u64(stream_bytes_in_packet)

	// Advance the stream's send-side bookkeeping. Bytes stay in tx_buffered
	// until ACKed (so they can be retransmitted by rewinding tx_sent_off);
	// we only advance the "next to send" pointer and record the range as
	// in-flight for loss tracking.
	// FIN-only (stream_bytes == 0, emit_fin) is still ack-eliciting STREAM
	// and must enter loss recovery — otherwise a lost empty FIN is never
	// retransmitted (tx_fin_sent already true blocks re-emit).
	if stream_bytes_in_packet > 0 || emit_fin {
		range := Sent_Range{
			stream_id     = s.id,
			offset        = stream_frame_offset,
			len           = u64(stream_bytes_in_packet),
			packet_number = pn,
			fin           = emit_fin,
		}
		append(&s.tx_unacked, range)
		if stream_bytes_in_packet > 0 {
			s.tx_sent_off += u64(stream_bytes_in_packet)
			s.tx_next_offset += u64(stream_bytes_in_packet)
		}

		pkt := Sent_Packet{
			packet_number = pn,
			sent_at       = _now(conn),
			size          = packet_len,
			ack_eliciting = true,
		}
		append(&pkt.stream_ranges, range)
		loss_record_sent_packet(conn, pkt)
	}

	return packet_len, stream_bytes_in_packet, .None
}

// Build a 1-RTT packet containing a single DATAGRAM frame carrying `data`.
// Caller sends the result over UDP.
conn_send_datagram :: proc(
	conn: ^Conn,
	data: []u8,
	out:  []u8,
) -> (n: int, err: Quic_Error) {
	if conn.state != .Connected do return 0, .Handshake_Failed
	if !conn.one_rtt.have_tx_keys do return 0, .Derive_Keys_Failed

	// Refuse if the peer didn't negotiate DATAGRAM support.
	if conn.peer_tp.max_datagram_frame_size == 0 do return 0, .Encrypt_Failed
	if u64(len(data)) > conn.peer_tp.max_datagram_frame_size do return 0, .Encrypt_Failed

	// Plaintext: a single DATAGRAM frame (length-prefixed form).
	plaintext: [2048]u8
	pos := 0

	// Piggyback an ACK if owed.
	if conn.pn_one_rtt.ack_elicited && conn.pn_one_rtt.has_rx {
		w := encode_ack_from_space(plaintext[pos:], &conn.pn_one_rtt, 0)
		if w < 0 do return 0, .Encrypt_Failed
		pos += w
		conn.pn_one_rtt.ack_elicited = false
	}

	w := encode_datagram(plaintext[pos:], data)
	if w < 0 do return 0, .Encrypt_Failed
	pos += w

	pn := conn.pn_one_rtt.next_tx_pn
	conn.pn_one_rtt.next_tx_pn += 1

	packet_len, ok := encrypt_one_rtt(
		out,
		conn.dst_cid[:conn.dst_cid_len],
		pn,
		4, // pn_len
		plaintext[:pos],
		&conn.one_rtt.tx_keys,
	)
	if !ok do return 0, .Encrypt_Failed
	return packet_len, .None
}
