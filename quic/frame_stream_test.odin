package quic

import "core:testing"

// --- STREAM frame encode/decode ---

@(test)
test_stream_frame_encode_minimal :: proc(t: ^testing.T) {
	// stream_id=0, offset=0, no FIN, small payload.
	buf: [64]u8
	payload := []u8{0xaa, 0xbb, 0xcc}
	n := encode_stream_frame(buf[:], 0, 0, payload, false)
	testing.expect(t, n > 0, "encode failed")

	// Type byte: 0x08 (STREAM) | 0x02 (LEN). Offset is 0 so OFF flag omitted.
	testing.expect_value(t, buf[0], u8(0x0a))

	frame, consumed, err := frame_decode(buf[:n])
	testing.expect_value(t, err, Frame_Error.None)
	testing.expect_value(t, consumed, n)

	sf, ok := frame.(Stream_Frame)
	testing.expect(t, ok, "expected Stream_Frame variant")
	testing.expect_value(t, sf.stream_id, u64(0))
	testing.expect_value(t, sf.offset, u64(0))
	testing.expect_value(t, sf.fin, false)
	testing.expect_value(t, len(sf.data), 3)
	testing.expect_value(t, sf.data[0], u8(0xaa))
}

@(test)
test_stream_frame_with_offset :: proc(t: ^testing.T) {
	buf: [64]u8
	payload := []u8{0x01, 0x02, 0x03, 0x04}
	n := encode_stream_frame(buf[:], 4, 1000, payload, false)
	testing.expect(t, n > 0)

	// Type byte should have both OFF and LEN flags.
	testing.expect_value(t, buf[0], u8(0x0e))

	frame, _, err := frame_decode(buf[:n])
	testing.expect_value(t, err, Frame_Error.None)
	sf := frame.(Stream_Frame)
	testing.expect_value(t, sf.stream_id, u64(4))
	testing.expect_value(t, sf.offset, u64(1000))
	testing.expect_value(t, sf.fin, false)
	testing.expect(t, slice_equal(sf.data, payload))
}

@(test)
test_stream_frame_with_fin :: proc(t: ^testing.T) {
	buf: [64]u8
	payload := []u8{0xff}
	n := encode_stream_frame(buf[:], 0, 0, payload, true)
	testing.expect(t, n > 0)
	testing.expect_value(t, buf[0], u8(0x0b)) // LEN + FIN

	frame, _, _ := frame_decode(buf[:n])
	sf := frame.(Stream_Frame)
	testing.expect_value(t, sf.fin, true)
}

@(test)
test_stream_frame_empty_with_fin :: proc(t: ^testing.T) {
	// A FIN-only frame with zero data is legal.
	buf: [16]u8
	n := encode_stream_frame(buf[:], 0, 100, []u8{}, true)
	testing.expect(t, n > 0)

	frame, _, err := frame_decode(buf[:n])
	testing.expect_value(t, err, Frame_Error.None)
	sf := frame.(Stream_Frame)
	testing.expect_value(t, sf.fin, true)
	testing.expect_value(t, len(sf.data), 0)
	testing.expect_value(t, sf.offset, u64(100))
}

// --- Flow control frame decoders ---

@(test)
test_max_stream_data_frame :: proc(t: ^testing.T) {
	buf: [16]u8
	n := encode_max_stream_data(buf[:], 0, 2_000_000)
	testing.expect(t, n > 0)

	frame, _, err := frame_decode(buf[:n])
	testing.expect_value(t, err, Frame_Error.None)
	f := frame.(Max_Stream_Data_Frame)
	testing.expect_value(t, f.stream_id, u64(0))
	testing.expect_value(t, f.max_data, u64(2_000_000))
}

@(test)
test_max_data_frame :: proc(t: ^testing.T) {
	buf: [16]u8
	n := encode_max_data(buf[:], 10_485_760)
	testing.expect(t, n > 0)

	frame, _, err := frame_decode(buf[:n])
	testing.expect_value(t, err, Frame_Error.None)
	f := frame.(Max_Data_Frame)
	testing.expect_value(t, f.max_data, u64(10_485_760))
}

@(test)
test_handshake_done_frame :: proc(t: ^testing.T) {
	buf := []u8{0x1e}
	frame, n, err := frame_decode(buf)
	testing.expect_value(t, err, Frame_Error.None)
	testing.expect_value(t, n, 1)
	_, ok := frame.(Handshake_Done_Frame)
	testing.expect(t, ok)
}

@(test)
test_data_blocked_parse_and_ignore :: proc(t: ^testing.T) {
	// DATA_BLOCKED (0x14) with a single varint max_data_limit of 10 (1-byte varint).
	buf := []u8{0x14, 10}
	frame, n, err := frame_decode(buf)
	testing.expect_value(t, err, Frame_Error.None)
	testing.expect_value(t, n, 2)
	_, ok := frame.(Unhandled_Frame)
	testing.expect(t, ok, "should decode as Unhandled_Frame")
}

@(test)
test_stream_frame_truncated :: proc(t: ^testing.T) {
	// Type byte 0x0e (STREAM + OFF + LEN) but only stream_id, no offset.
	buf := []u8{0x0e, 0x00}
	_, _, err := frame_decode(buf)
	testing.expect_value(t, err, Frame_Error.Truncated)
}

// --- Stream state machine ---

@(test)
test_stream_write_and_read :: proc(t: ^testing.T) {
	s := stream_new(0)
	defer stream_free(s)

	// Simulate receiving a STREAM frame with contiguous bytes.
	data := []u8{'h', 'e', 'l', 'l', 'o'}
	stream_on_stream_frame(s, Stream_Frame{
		stream_id = 0,
		offset    = 0,
		fin       = false,
		data      = data,
	})
	testing.expect_value(t, s.rx_next_offset, u64(5))

	// Read back.
	buf: [16]u8
	n, ok := stream_read(s, buf[:])
	testing.expect(t, ok)
	testing.expect_value(t, n, 5)
	testing.expect_value(t, string(buf[:n]), "hello")
}

@(test)
test_stream_out_of_order_reassembly :: proc(t: ^testing.T) {
	s := stream_new(0)
	defer stream_free(s)

	// Receive in reversed order: [10..15), [5..10), [0..5).
	stream_on_stream_frame(s, Stream_Frame{offset = 10, data = []u8{'w','o','r','l','d'}})
	testing.expect_value(t, s.rx_next_offset, u64(0))
	testing.expect_value(t, len(s.rx_fragments), 1)

	stream_on_stream_frame(s, Stream_Frame{offset = 5, data = []u8{' ','c','r','u','e'}})
	testing.expect_value(t, s.rx_next_offset, u64(0))
	testing.expect_value(t, len(s.rx_fragments), 2)

	// Now deliver the head — this should flush everything in order.
	stream_on_stream_frame(s, Stream_Frame{offset = 0, data = []u8{'h','e','l','l','o'}})
	testing.expect_value(t, s.rx_next_offset, u64(15))
	testing.expect_value(t, len(s.rx_fragments), 0)

	buf: [32]u8
	n, _ := stream_read(s, buf[:])
	testing.expect_value(t, n, 15)
	testing.expect_value(t, string(buf[:n]), "hello crueworld")
}

@(test)
test_stream_duplicate_ignored :: proc(t: ^testing.T) {
	s := stream_new(0)
	defer stream_free(s)

	stream_on_stream_frame(s, Stream_Frame{offset = 0, data = []u8{'a','b','c'}})
	// Send the same frame again — should be a no-op, not double-delivered.
	stream_on_stream_frame(s, Stream_Frame{offset = 0, data = []u8{'a','b','c'}})

	testing.expect_value(t, s.rx_next_offset, u64(3))
	buf: [8]u8
	n, _ := stream_read(s, buf[:])
	testing.expect_value(t, n, 3)
}

@(test)
test_stream_fin_closes_after_drain :: proc(t: ^testing.T) {
	s := stream_new(0)
	defer stream_free(s)

	stream_on_stream_frame(s, Stream_Frame{
		offset = 0,
		data   = []u8{'d','o','n','e'},
		fin    = true,
	})
	testing.expect_value(t, s.rx_closed, true)

	// Reader can still pull the buffered bytes.
	buf: [8]u8
	n, ok := stream_read(s, buf[:])
	testing.expect(t, ok)
	testing.expect_value(t, n, 4)

	// Next read returns 0 bytes + ok=false (EOF).
	n, ok = stream_read(s, buf[:])
	testing.expect_value(t, n, 0)
	testing.expect(t, !ok)
}

@(test)
test_stream_fin_with_gap_waits :: proc(t: ^testing.T) {
	s := stream_new(0)
	defer stream_free(s)

	// FIN arrives before the rest of the data — stream stays open until the
	// gap is filled.
	stream_on_stream_frame(s, Stream_Frame{
		offset = 5,
		data   = []u8{'w','o','r','l','d'},
		fin    = true,
	})
	testing.expect_value(t, s.rx_closed, false)

	stream_on_stream_frame(s, Stream_Frame{
		offset = 0,
		data   = []u8{'h','e','l','l','o'},
	})
	testing.expect_value(t, s.rx_closed, true)
	testing.expect_value(t, s.rx_next_offset, u64(10))
}

@(test)
test_stream_write_queues_bytes :: proc(t: ^testing.T) {
	s := stream_new(0)
	defer stream_free(s)

	stream_write(s, []u8{1, 2, 3})
	stream_write(s, []u8{4, 5})
	testing.expect_value(t, len(s.tx_buffered), 5)
	for i in 0..<5 {
		testing.expect_value(t, s.tx_buffered[i], u8(i + 1))
	}
}

@(test)
test_stream_flow_control_trigger :: proc(t: ^testing.T) {
	s := stream_new(0)
	defer stream_free(s)

	// Fresh stream — no reason to emit an update yet.
	testing.expect(t, !stream_needs_flow_control_update(s))

	// Advance past the half-window mark.
	s.rx_next_offset = DEFAULT_STREAM_WINDOW / 2 + 1
	testing.expect(t, stream_needs_flow_control_update(s))

	new_limit := stream_new_flow_control_limit(s)
	testing.expect(t, new_limit >= s.rx_next_offset + DEFAULT_STREAM_WINDOW / 2)
}

@(test)
test_stream_compact_preserves_offsets :: proc(t: ^testing.T) {
	// After ACK frees a prefix and stream_compact slides tx_buffered down,
	// the absolute offset bookkeeping (tx_abs_base, tx_next_offset) must stay
	// consistent so a retransmit of a still-in-flight range re-emits at the
	// correct wire offset.
	s := stream_new(0)
	defer stream_free(s)

	// Write 12 bytes, "send" them all, "ACK" the first 8, then compact.
	stream_write(s, []u8{0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11})
	s.tx_sent_off = 12
	s.tx_next_offset = 12

	// Simulate: packet carrying [0,8) is ACKed.
	_stream_advance_acked(s, Sent_Range{stream_id = 0, offset = 0, len = 8})
	// tx_acked_off should now be 8; compaction should reclaim [0,8).
	testing.expect_value(t, s.tx_acked_off, u64(0))    // compacted → reset to 0
	testing.expect_value(t, s.tx_abs_base, u64(8))     // absolute base advanced by 8
	testing.expect_value(t, len(s.tx_buffered), 4)     // only [8,12) remains
	testing.expect_value(t, s.tx_next_offset, u64(12)) // absolute offset unchanged
	// The remaining bytes are the un-ACKed tail.
	testing.expect_value(t, s.tx_buffered[0], u8(8))
	testing.expect_value(t, s.tx_buffered[3], u8(11))
}

@(test)
test_stream_requeue_after_partial_ack :: proc(t: ^testing.T) {
	// Bytes [0,8) ACKed, [8,12) lost and requeued. The requeue must rewind
	// tx_sent_off to the buffer index of offset 8 (= 0 after compaction),
	// and tx_next_offset back to the absolute offset 8.
	s := stream_new(0)
	defer stream_free(s)

	stream_write(s, []u8{0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11})
	s.tx_sent_off = 12
	s.tx_next_offset = 12
	// ACK [0,8) and compact (base → 8, buffer now holds [8,12)).
	_stream_advance_acked(s, Sent_Range{stream_id = 0, offset = 0, len = 8})

	// Now [8,12) is declared lost — requeue it. Absolute offset 8 maps to
	// buffer index (8 - tx_abs_base=8) = 0.
	_stream_requeue_range(s, Sent_Range{stream_id = 0, offset = 8, len = 4})
	testing.expect_value(t, s.tx_sent_off, u64(0))  // rewound to re-send
	testing.expect_value(t, s.tx_next_offset, u64(8)) // absolute offset restored

	// A redundant requeue (already rewound to 0) must NOT advance further.
	_stream_requeue_range(s, Sent_Range{stream_id = 0, offset = 8, len = 4})
	testing.expect_value(t, s.tx_sent_off, u64(0))
}

@(test)
test_stream_requeue_clears_tx_fin_sent :: proc(t: ^testing.T) {
	// Lost data+FIN must re-arm FIN emission; FIN-only requeue must too.
	s := stream_new(0)
	defer stream_free(s)

	stream_write(s, []u8{1, 2, 3, 4})
	s.tx_sent_off = 4
	s.tx_next_offset = 4
	s.tx_fin = true
	s.tx_fin_sent = true

	_stream_requeue_range(s, Sent_Range{
		stream_id = 0,
		offset    = 0,
		len       = 4,
		fin       = true,
	})
	testing.expect_value(t, s.tx_sent_off, u64(0))
	testing.expect(t, !s.tx_fin_sent)

	// FIN-only (len 0) requeue after a subsequent re-send of FIN.
	s.tx_sent_off = 4
	s.tx_next_offset = 4
	s.tx_fin_sent = true
	_stream_requeue_range(s, Sent_Range{
		stream_id = 0,
		offset    = 4,
		len       = 0,
		fin       = true,
	})
	testing.expect(t, !s.tx_fin_sent)
	// No data rewind needed when already at end.
	testing.expect_value(t, s.tx_sent_off, u64(4))
}
