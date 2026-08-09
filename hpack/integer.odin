// Prefix-integer codec (RFC 7541 §5.1) — HPACK wire form only.
// Extracted from the vapor/qpack shared primitive; no QPACK dependency.
package hpack

// Cap for prefix integers (indices, lengths, table-size updates). Larger values
// are protocol errors here: they cannot be useful sizes/indexes and would risk
// overflow or absurd allocations. 2^28 is well above any SETTINGS/header limit
// we accept and fits safely in int on 32- and 64-bit targets.
MAX_PREFIX_INT :: u64(1 << 28)

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
// and the number of bytes consumed. Rejects truncated input, continuation
// chains that would shift past our cap, and values above MAX_PREFIX_INT.
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
		// Next addend is (b & 0x7f) << m. Cap shifts so we never wrap u64 and
		// never accept values above MAX_PREFIX_INT.
		if m >= 28 do return 0, 0, .Bad_Integer
		addend := u64(b & 0x7f) << m
		// Saturating check: value + addend must stay within MAX_PREFIX_INT.
		if addend > MAX_PREFIX_INT || value > MAX_PREFIX_INT - addend {
			return 0, 0, .Bad_Integer
		}
		value += addend
		if b & 0x80 == 0 do break
		m += 7
		// After bumping m, another continuation byte would shift by m (>=7).
		// m > 28 already covered; m == 28 leaves only a zero addend usable.
		if m > 28 do return 0, 0, .Bad_Integer
	}
	if value > MAX_PREFIX_INT do return 0, 0, .Bad_Integer
	return value, consumed, .None
}
