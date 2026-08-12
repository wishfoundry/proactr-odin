package quic

import "core:testing"

// RFC 9000 §A.1 — Sample Variable-Length Integer Decoding
// The RFC gives four test cases, one for each encoding length:
//   Bytes                            | Value
//   0xc2 0x19 0x7c 0x5e 0xff 0x14 0xe8 0x8c | 151_288_809_941_952_652
//   0x9d 0x7f 0x3e 0x7d                     | 494_878_333
//   0x7b 0xbd                               | 15_293
//   0x25                                    | 37
//   0x40 0x25                               | 37 (alternate 2-byte encoding)

@(test)
test_varint_rfc9000_a1_8byte :: proc(t: ^testing.T) {
	buf := []u8{0xc2, 0x19, 0x7c, 0x5e, 0xff, 0x14, 0xe8, 0x8c}
	value, n, ok := varint_decode(buf)
	testing.expect(t, ok)
	testing.expect_value(t, n, 8)
	testing.expect_value(t, value, u64(151_288_809_941_952_652))
}

@(test)
test_varint_rfc9000_a1_4byte :: proc(t: ^testing.T) {
	buf := []u8{0x9d, 0x7f, 0x3e, 0x7d}
	value, n, ok := varint_decode(buf)
	testing.expect(t, ok)
	testing.expect_value(t, n, 4)
	testing.expect_value(t, value, u64(494_878_333))
}

@(test)
test_varint_rfc9000_a1_2byte :: proc(t: ^testing.T) {
	buf := []u8{0x7b, 0xbd}
	value, n, ok := varint_decode(buf)
	testing.expect(t, ok)
	testing.expect_value(t, n, 2)
	testing.expect_value(t, value, u64(15_293))
}

@(test)
test_varint_rfc9000_a1_1byte :: proc(t: ^testing.T) {
	buf := []u8{0x25}
	value, n, ok := varint_decode(buf)
	testing.expect(t, ok)
	testing.expect_value(t, n, 1)
	testing.expect_value(t, value, u64(37))
}

@(test)
test_varint_rfc9000_a1_alt_2byte :: proc(t: ^testing.T) {
	// 37 can also be encoded as 2 bytes (non-minimal encoding is legal per RFC).
	buf := []u8{0x40, 0x25}
	value, n, ok := varint_decode(buf)
	testing.expect(t, ok)
	testing.expect_value(t, n, 2)
	testing.expect_value(t, value, u64(37))
}


@(test)
test_varint_encode_1byte_boundary :: proc(t: ^testing.T) {
	buf: [8]u8
	testing.expect_value(t, varint_encode(buf[:], 0), 1)
	testing.expect_value(t, buf[0], u8(0))
	testing.expect_value(t, varint_encode(buf[:], 63), 1)
	testing.expect_value(t, buf[0], u8(63))
}

@(test)
test_varint_encode_2byte_boundary :: proc(t: ^testing.T) {
	buf: [8]u8
	testing.expect_value(t, varint_encode(buf[:], 64), 2)
	testing.expect_value(t, varint_encode(buf[:], 16383), 2)
}

@(test)
test_varint_encode_4byte_boundary :: proc(t: ^testing.T) {
	buf: [8]u8
	testing.expect_value(t, varint_encode(buf[:], 16384), 4)
	testing.expect_value(t, varint_encode(buf[:], 1_073_741_823), 4)
}

@(test)
test_varint_encode_8byte_boundary :: proc(t: ^testing.T) {
	buf: [8]u8
	testing.expect_value(t, varint_encode(buf[:], 1_073_741_824), 8)
	testing.expect_value(t, varint_encode(buf[:], VARINT_MAX), 8)
}


@(test)
test_varint_roundtrip :: proc(t: ^testing.T) {
	cases := []u64{
		0, 1, 37, 63,
		64, 100, 15_293, 16_383,
		16_384, 100_000, 494_878_333, 1_073_741_823,
		1_073_741_824, 151_288_809_941_952_652, VARINT_MAX,
	}

	buf: [8]u8
	for v in cases {
		n := varint_encode(buf[:], v)
		testing.expect(t, n > 0, "encode failed")

		got, consumed, ok := varint_decode(buf[:n])
		testing.expect(t, ok, "decode failed")
		testing.expect_value(t, consumed, n)
		testing.expect_value(t, got, v)
	}
}


@(test)
test_varint_len_matches_encode :: proc(t: ^testing.T) {
	cases := []u64{0, 63, 64, 16_383, 16_384, 1_073_741_823, 1_073_741_824, VARINT_MAX}

	buf: [8]u8
	for v in cases {
		expected := varint_encode(buf[:], v)
		testing.expect_value(t, varint_len(v), expected)
	}
}


@(test)
test_varint_encode_out_of_range :: proc(t: ^testing.T) {
	buf: [8]u8
	testing.expect_value(t, varint_encode(buf[:], VARINT_MAX + 1), -1)
}

@(test)
test_varint_decode_truncated :: proc(t: ^testing.T) {
	// 8-byte encoding indicator, only 4 bytes present
	buf := []u8{0xc2, 0x19, 0x7c, 0x5e}
	_, _, ok := varint_decode(buf)
	testing.expect(t, !ok, "should have failed on truncated input")
}

@(test)
test_varint_decode_empty :: proc(t: ^testing.T) {
	buf: []u8
	_, _, ok := varint_decode(buf)
	testing.expect(t, !ok, "should have failed on empty input")
}
