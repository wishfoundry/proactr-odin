package quic

// RFC 9000 §16 — Variable-Length Integer Encoding
//
// The two most-significant bits of the first byte encode the total length:
//
//   2MSB  | Length | Usable bits | Range
//   ------+--------+-------------+----------------------------
//   00    | 1      | 6           | 0 .. 63
//   01    | 2      | 14          | 0 .. 16383
//   10    | 4      | 30          | 0 .. 1_073_741_823
//   11    | 8      | 62          | 0 .. 4_611_686_018_427_387_903
//
// The length-tag bits are masked off when decoding; only the usable bits
// contribute to the integer value.

VARINT_MAX :: u64(0x3fff_ffff_ffff_ffff)

/// Returns the number of bytes required to encode v as a varint.
/// Panics in debug builds if v exceeds VARINT_MAX.
varint_len :: proc(v: u64) -> int {
	if v < 1 <<  6 do return 1
	if v < 1 << 14 do return 2
	if v < 1 << 30 do return 4
	return 8
}

/// Encodes v into buf as a varint. Returns the number of bytes written,
/// or -1 if buf is too small or v is out of range.
varint_encode :: proc(buf: []u8, v: u64) -> int {
	if v > VARINT_MAX do return -1

	switch {
	case v < 1 << 6:
		if len(buf) < 1 do return -1
		buf[0] = u8(v)
		return 1
	case v < 1 << 14:
		if len(buf) < 2 do return -1
		buf[0] = 0x40 | u8(v >> 8)
		buf[1] = u8(v)
		return 2
	case v < 1 << 30:
		if len(buf) < 4 do return -1
		buf[0] = 0x80 | u8(v >> 24)
		buf[1] = u8(v >> 16)
		buf[2] = u8(v >> 8)
		buf[3] = u8(v)
		return 4
	case:
		if len(buf) < 8 do return -1
		buf[0] = 0xc0 | u8(v >> 56)
		buf[1] = u8(v >> 48)
		buf[2] = u8(v >> 40)
		buf[3] = u8(v >> 32)
		buf[4] = u8(v >> 24)
		buf[5] = u8(v >> 16)
		buf[6] = u8(v >> 8)
		buf[7] = u8(v)
		return 8
	}
}

/// Decodes a varint from buf. Returns (value, bytes_consumed, true) on success,
/// or ({}, 0, false) if buf is too short for the encoded length.
varint_decode :: proc(buf: []u8) -> (value: u64, n: int, ok: bool) {
	if len(buf) == 0 do return 0, 0, false

	tag := buf[0] >> 6
	switch tag {
	case 0:
		return u64(buf[0] & 0x3f), 1, true
	case 1:
		if len(buf) < 2 do return 0, 0, false
		return u64(buf[0] & 0x3f) << 8 | u64(buf[1]), 2, true
	case 2:
		if len(buf) < 4 do return 0, 0, false
		return u64(buf[0] & 0x3f) << 24 |
		       u64(buf[1]) << 16 |
		       u64(buf[2]) << 8 |
		       u64(buf[3]), 4, true
	case 3:
		if len(buf) < 8 do return 0, 0, false
		return u64(buf[0] & 0x3f) << 56 |
		       u64(buf[1]) << 48 |
		       u64(buf[2]) << 40 |
		       u64(buf[3]) << 32 |
		       u64(buf[4]) << 24 |
		       u64(buf[5]) << 16 |
		       u64(buf[6]) << 8 |
		       u64(buf[7]), 8, true
	}
	return 0, 0, false
}
