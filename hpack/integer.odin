// Prefix-integer codec (RFC 7541 §5.1) — HPACK wire form only.
// Extracted from the vapor/qpack shared primitive; no QPACK dependency.
package hpack

// Encode `value` with an `n`-bit prefix. `flags` holds the high (8-n) bits of
// the first byte already set (the representation pattern); they must not touch
// the low n bits.
prefix_int_encode :: proc(dst: ^[dynamic]u8, value: u64, n: uint, flags: u8) {
	max_prefix := u64(1 << n) - 1
	if value < max_prefix {
		append(dst, flags | u8(value))
		return
	}
	append(dst, flags | u8(max_prefix))
	v := value - max_prefix
	for v >= 128 {
		append(dst, u8(v & 0x7f) | 0x80)
		v >>= 7
	}
	append(dst, u8(v))
}

// Decode an `n`-bit-prefix integer from the front of `src`. Returns the value
// and the number of bytes consumed.
prefix_int_decode :: proc(src: []u8, n: uint) -> (value: u64, consumed: int, err: Hpack_Error) {
	if len(src) == 0 do return 0, 0, .Truncated
	mask := u64(1 << n) - 1
	value = u64(src[0]) & mask
	consumed = 1
	if value < mask do return value, consumed, .None

	m: uint = 0
	for {
		if consumed >= len(src) do return 0, 0, .Truncated
		b := src[consumed]
		consumed += 1
		value += u64(b & 0x7f) << m
		if b & 0x80 == 0 do break
		m += 7
		if m > 62 do return 0, 0, .Bad_Integer
	}
	return value, consumed, .None
}
