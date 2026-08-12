package quic

import "core:testing"


@(test)
test_frame_padding_encode :: proc(t: ^testing.T) {
	buf: [8]u8
	n := encode_padding(buf[:], 5)
	testing.expect_value(t, n, 5)
	for i in 0..<5 do testing.expect_value(t, buf[i], u8(0))
}

@(test)
test_frame_padding_decode_coalesces :: proc(t: ^testing.T) {
	// Five consecutive padding bytes must decode as a single coalesced frame.
	buf := []u8{0x00, 0x00, 0x00, 0x00, 0x00}
	frame, n, err := frame_decode(buf)
	testing.expect_value(t, err, Frame_Error.None)
	testing.expect_value(t, n, 5)
	pad, ok := frame.(Padding_Frame)
	testing.expect(t, ok, "expected Padding_Frame variant")
	testing.expect_value(t, pad.count, 5)
}


@(test)
test_frame_ping_roundtrip :: proc(t: ^testing.T) {
	buf: [4]u8
	n := encode_ping(buf[:])
	testing.expect_value(t, n, 1)
	testing.expect_value(t, buf[0], u8(0x01))

	frame, consumed, err := frame_decode(buf[:n])
	testing.expect_value(t, err, Frame_Error.None)
	testing.expect_value(t, consumed, 1)
	_, ok := frame.(Ping_Frame)
	testing.expect(t, ok, "expected Ping_Frame variant")
}


@(test)
test_frame_ack_simple_roundtrip :: proc(t: ^testing.T) {
	buf: [32]u8
	n := encode_ack_simple(buf[:], 1000, 50, 5)
	testing.expect(t, n > 0, "ack encode failed")

	frame, consumed, err := frame_decode(buf[:n])
	testing.expect_value(t, err, Frame_Error.None)
	testing.expect_value(t, consumed, n)

	ack, ok := frame.(Ack_Frame)
	testing.expect(t, ok, "expected Ack_Frame variant")
	testing.expect_value(t, ack.largest_acknowledged, u64(1000))
	testing.expect_value(t, ack.ack_delay, u64(50))
	testing.expect_value(t, ack.ack_range_count, u64(0))
	testing.expect_value(t, ack.first_ack_range, u64(5))
}

// Received-PN bookkeeping + the range-aware ACK encoder. Acking only the
// largest packet (the old behavior) makes a real peer retransmit every burst.
@(test)
test_pn_space_ranges_and_ack_encode :: proc(t: ^testing.T) {
	s: Pn_Space

	// Out-of-order arrivals: {1,2,3}, {7}, {5} — then 4 bridges 3..5.
	for pn in ([]u64{1, 2, 3, 7, 5}) do _pn_space_record_rx(&s, pn)
	testing.expect_value(t, s.rx_range_count, 3)
	_pn_space_record_rx(&s, 4)
	testing.expect_value(t, s.rx_range_count, 2)
	testing.expect_value(t, s.rx_ranges[0], [2]u64{1, 5})
	testing.expect_value(t, s.rx_ranges[1], [2]u64{7, 7})
	_pn_space_record_rx(&s, 6) // bridges everything
	testing.expect_value(t, s.rx_range_count, 1)
	testing.expect_value(t, s.rx_ranges[0], [2]u64{1, 7})
	_pn_space_record_rx(&s, 4) // duplicate is a no-op
	testing.expect_value(t, s.rx_range_count, 1)

	// Encode with a gap: ranges [1,7] and [20,22].
	_pn_space_record_rx(&s, 20)
	_pn_space_record_rx(&s, 21)
	_pn_space_record_rx(&s, 22)
	buf: [64]u8
	n := encode_ack_from_space(buf[:], &s, 0)
	testing.expect(t, n > 0, "ack encode failed")

	frame, consumed, err := frame_decode(buf[:n])
	testing.expect_value(t, err, Frame_Error.None)
	testing.expect_value(t, consumed, n)
	ack, ok := frame.(Ack_Frame)
	testing.expect(t, ok, "expected Ack_Frame variant")
	testing.expect_value(t, ack.largest_acknowledged, u64(22))
	testing.expect_value(t, ack.first_ack_range, u64(2)) // 22 down to 20
	testing.expect_value(t, ack.ack_range_count, u64(1)) // plus [1,7]
}


@(test)
test_frame_crypto_roundtrip :: proc(t: ^testing.T) {
	payload := []u8{0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08}
	buf: [64]u8

	n := encode_crypto(buf[:], 0, payload)
	// 1 type + 1 offset-varint + 1 length-varint + 8 data = 11
	testing.expect_value(t, n, 11)

	frame, consumed, err := frame_decode(buf[:n])
	testing.expect_value(t, err, Frame_Error.None)
	testing.expect_value(t, consumed, n)

	crypto, ok := frame.(Crypto_Frame)
	testing.expect(t, ok, "expected Crypto_Frame variant")
	testing.expect_value(t, crypto.offset, u64(0))
	testing.expect_value(t, len(crypto.data), 8)
	for i in 0..<8 do testing.expect_value(t, crypto.data[i], payload[i])
}

@(test)
test_frame_crypto_offset :: proc(t: ^testing.T) {
	payload := []u8{0xaa, 0xbb, 0xcc}
	buf: [32]u8
	n := encode_crypto(buf[:], 12345, payload)

	frame, _, err := frame_decode(buf[:n])
	testing.expect_value(t, err, Frame_Error.None)
	crypto := frame.(Crypto_Frame)
	testing.expect_value(t, crypto.offset, u64(12345))
}


@(test)
test_frame_connection_close_roundtrip :: proc(t: ^testing.T) {
	reason := transmute([]u8)string("bad dreams")
	buf: [64]u8
	n := encode_connection_close(buf[:], 0x0a, 0, reason)
	testing.expect(t, n > 0, "encode failed")

	frame, consumed, err := frame_decode(buf[:n])
	testing.expect_value(t, err, Frame_Error.None)
	testing.expect_value(t, consumed, n)

	cc, ok := frame.(Connection_Close_Frame)
	testing.expect(t, ok, "expected Connection_Close_Frame variant")
	testing.expect_value(t, cc.error_code, u64(0x0a))
	testing.expect_value(t, cc.frame_type, u64(0))
	testing.expect_value(t, cc.is_app, false)
	testing.expect_value(t, string(cc.reason), "bad dreams")
}


@(test)
test_frame_datagram_len_roundtrip :: proc(t: ^testing.T) {
	payload := []u8{0xde, 0xad, 0xbe, 0xef, 0xca, 0xfe}
	buf: [32]u8
	n := encode_datagram(buf[:], payload)
	// 1 type + 1 length-varint + 6 data = 8
	testing.expect_value(t, n, 8)

	frame, consumed, err := frame_decode(buf[:n])
	testing.expect_value(t, err, Frame_Error.None)
	testing.expect_value(t, consumed, n)

	dg, ok := frame.(Datagram_Frame)
	testing.expect(t, ok, "expected Datagram_Frame variant")
	testing.expect_value(t, len(dg.data), 6)
	for i in 0..<6 do testing.expect_value(t, dg.data[i], payload[i])
}

@(test)
test_frame_datagram_no_len :: proc(t: ^testing.T) {
	// Type 0x30 means "no length, extends to end of buffer".
	buf := []u8{0x30, 0xaa, 0xbb, 0xcc}
	frame, consumed, err := frame_decode(buf)
	testing.expect_value(t, err, Frame_Error.None)
	testing.expect_value(t, consumed, 4)

	dg := frame.(Datagram_Frame)
	testing.expect_value(t, len(dg.data), 3)
	testing.expect_value(t, dg.data[0], u8(0xaa))
	testing.expect_value(t, dg.data[1], u8(0xbb))
	testing.expect_value(t, dg.data[2], u8(0xcc))
}


@(test)
test_frame_decode_empty :: proc(t: ^testing.T) {
	buf: []u8
	_, _, err := frame_decode(buf)
	testing.expect_value(t, err, Frame_Error.Truncated)
}

@(test)
test_frame_decode_truncated_crypto :: proc(t: ^testing.T) {
	// CRYPTO frame declaring 10 bytes of data but only 3 present
	buf := []u8{0x06, 0x00, 0x0a, 0x01, 0x02, 0x03}
	_, _, err := frame_decode(buf)
	testing.expect_value(t, err, Frame_Error.Truncated)
}

@(test)
test_frame_decode_unknown_type :: proc(t: ^testing.T) {
	// Type 0x1a is PATH_CHALLENGE — not implemented.
	buf := []u8{0x1a, 0,0,0,0,0,0,0,0} // 8-byte data field
	_, _, err := frame_decode(buf)
	testing.expect_value(t, err, Frame_Error.Unknown_Type)
}


@(test)
test_frame_decode_sequence :: proc(t: ^testing.T) {
	// Encode PING + CRYPTO(offset=0, "abc") + PADDING(3) into one buffer,
	// decode and verify each frame in order.
	buf: [64]u8
	pos := 0

	n := encode_ping(buf[pos:]); testing.expect(t, n > 0); pos += n
	n  = encode_crypto(buf[pos:], 0, transmute([]u8)string("abc")); pos += n
	n  = encode_padding(buf[pos:], 3); pos += n

	// Decode frame 1: PING
	f1, n1, e1 := frame_decode(buf[:pos])
	testing.expect_value(t, e1, Frame_Error.None)
	_, is_ping := f1.(Ping_Frame)
	testing.expect(t, is_ping, "frame 1 should be PING")

	// Decode frame 2: CRYPTO
	f2, n2, e2 := frame_decode(buf[n1:pos])
	testing.expect_value(t, e2, Frame_Error.None)
	crypto, is_crypto := f2.(Crypto_Frame)
	testing.expect(t, is_crypto, "frame 2 should be CRYPTO")
	testing.expect_value(t, string(crypto.data), "abc")

	// Decode frame 3: PADDING (coalesced count=3)
	f3, n3, e3 := frame_decode(buf[n1+n2:pos])
	testing.expect_value(t, e3, Frame_Error.None)
	pad, is_pad := f3.(Padding_Frame)
	testing.expect(t, is_pad, "frame 3 should be PADDING")
	testing.expect_value(t, pad.count, 3)

	// Total bytes consumed should equal the position we wrote to.
	testing.expect_value(t, n1 + n2 + n3, pos)
}
