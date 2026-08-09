package huffman

import "core:math/rand"
import "core:slice"
import "core:testing"

@(test)
test_known_vector :: proc(t: ^testing.T) {
	// RFC 7541 C.4.1: "www.example.com" Huffman-encodes to these 12 bytes.
	data := transmute([]u8)string("www.example.com")
	enc := make([]u8, encoded_len(data))
	defer delete(enc)
	n := encode(enc, data)
	want := []u8{0xf1, 0xe3, 0xc2, 0xe5, 0xf2, 0x3a, 0x6b, 0xa0, 0xab, 0x90, 0xf4, 0xff}
	testing.expect_value(t, n, len(want))
	testing.expect(t, slice.equal(enc[:n], want), "www.example.com huffman vector mismatch")

	dec: [dynamic]u8
	defer delete(dec)
	err := decode(&dec, enc[:n])
	testing.expect_value(t, err, Error.None)
	testing.expect(t, slice.equal(dec[:], data), "www.example.com decode mismatch")
}

@(test)
test_roundtrip :: proc(t: ^testing.T) {
	cases := []string {
		"",
		"no-cache",
		"www.example.com",
		"custom-key",
		"Mon, 21 Oct 2013 20:13:21 GMT",
		"\x00\x01\x02 the quick brown fox 0123456789 !@#$%^&*()_+",
	}
	for s in cases {
		data := transmute([]u8)s
		enc := make([]u8, encoded_len(data))
		defer delete(enc)
		n := encode(enc, data)
		testing.expect_value(t, n, len(enc))

		dec: [dynamic]u8
		defer delete(dec)
		err := decode(&dec, enc[:n])
		testing.expect_value(t, err, Error.None)
		testing.expect(t, slice.equal(dec[:], data), "huffman roundtrip mismatch")
	}
}

@(test)
test_all_bytes :: proc(t: ^testing.T) {
	data: [256]u8
	for i in 0 ..< 256 do data[i] = u8(i)
	enc := make([]u8, encoded_len(data[:]))
	defer delete(enc)
	n := encode(enc, data[:])

	dec: [dynamic]u8
	defer delete(dec)
	err := decode(&dec, enc[:n])
	testing.expect_value(t, err, Error.None)
	testing.expect(t, slice.equal(dec[:], data[:]), "all-bytes roundtrip mismatch")
}

@(test)
test_padding_valid :: proc(t: ^testing.T) {
	// Symbol '0' is 5 zero-bits (TABLE[0x30]); encode pads with 3 ones → 0x07.
	data := []u8{'0'}
	enc := make([]u8, encoded_len(data))
	defer delete(enc)
	n := encode(enc, data)
	testing.expect_value(t, n, 1)
	testing.expect_value(t, enc[0], u8(0x07))

	dec: [dynamic]u8
	defer delete(dec)
	testing.expect_value(t, decode(&dec, enc[:n]), Error.None)
	testing.expect(t, slice.equal(dec[:], data))

	// Empty input: no bits, valid.
	testing.expect_value(t, decode(&dec, []u8{}), Error.None)
}

@(test)
test_padding_invalid :: proc(t: ^testing.T) {
	// '0' code is 00000; zero padding instead of ones → Invalid_Padding.
	dec: [dynamic]u8
	defer delete(dec)
	testing.expect_value(t, decode(&dec, []u8{0x00}), Error.Invalid_Padding)

	// Eight 1-bits from root: incomplete all-ones path at depth 8 (>7) → Invalid_Padding.
	clear(&dec)
	testing.expect_value(t, decode(&dec, []u8{0xFF}), Error.Invalid_Padding)
}

@(test)
test_eos_in_input :: proc(t: ^testing.T) {
	// EOS is 30 one-bits. Four 0xFF = 32 ones completes EOS → error.
	dec: [dynamic]u8
	defer delete(dec)
	testing.expect_value(t, decode(&dec, []u8{0xFF, 0xFF, 0xFF, 0xFF}), Error.EOS_In_Input)

	// 30 ones then a 0: still completes EOS on the 30th one-bit.
	clear(&dec)
	testing.expect_value(t, decode(&dec, []u8{0xFF, 0xFF, 0xFF, 0xFE}), Error.EOS_In_Input)
}

@(test)
test_fsm_matches_slow :: proc(t: ^testing.T) {
	// On valid encodings, FSM and linear decode_slow must agree exactly.
	// On garbage, neither may succeed alone (if one returns None, both must).
	streams: [dynamic][]u8
	defer {
		for s in streams do delete(s)
		delete(streams)
	}

	push_enc :: proc(streams: ^[dynamic][]u8, data: []u8) {
		buf := make([]u8, max(1, encoded_len(data)))
		n := encode(buf, data)
		cp := make([]u8, n)
		copy(cp, buf[:n])
		delete(buf)
		append(streams, cp)
	}

	push_enc(&streams, []u8{})
	push_enc(&streams, transmute([]u8)string("www.example.com"))
	push_enc(&streams, transmute([]u8)string("no-cache"))
	push_enc(&streams, transmute([]u8)string("custom-key"))
	push_enc(&streams, transmute([]u8)string("Mon, 21 Oct 2013 20:13:21 GMT"))
	for i in 0 ..< 256 {
		push_enc(&streams, []u8{u8(i)})
	}

	all: [256]u8
	for i in 0 ..< 256 do all[i] = u8(i)
	push_enc(&streams, all[:])

	rand.reset_u64(0xC0FFEE)
	for _ in 0 ..< 64 {
		n := int(rand.uint32() % 64)
		data := make([]u8, n)
		for i in 0 ..< n do data[i] = u8(rand.uint32() & 0xFF)
		push_enc(&streams, data)
		delete(data)
	}

	// Known wire vectors / edge inputs (valid and invalid)
	append_copy :: proc(streams: ^[dynamic][]u8, src: []u8) {
		cp := make([]u8, len(src))
		copy(cp, src)
		append(streams, cp)
	}
	append_copy(&streams, []u8{0xf1, 0xe3, 0xc2, 0xe5, 0xf2, 0x3a, 0x6b, 0xa0, 0xab, 0x90, 0xf4, 0xff})
	append_copy(&streams, []u8{0x07})
	append_copy(&streams, []u8{0x00})
	append_copy(&streams, []u8{0xFF})
	append_copy(&streams, []u8{0xFF, 0xFF, 0xFF, 0xFF})
	append_copy(&streams, []u8{0xFF, 0xFF, 0xFF, 0xFE})

	for _ in 0 ..< 128 {
		n := int(rand.uint32() % 32)
		data := make([]u8, n)
		for i in 0 ..< n do data[i] = u8(rand.uint32() & 0xFF)
		append(&streams, data)
	}

	for src in streams {
		a: [dynamic]u8
		b: [dynamic]u8
		defer delete(a)
		defer delete(b)
		ea := decode(&a, src)
		eb := decode_slow(&b, src)
		if ea == .None || eb == .None {
			testing.expect_value(t, ea, Error.None)
			testing.expect_value(t, eb, Error.None)
			testing.expect(t, slice.equal(a[:], b[:]), "FSM vs slow output mismatch")
		}
		// Both failed: error kind may differ for dead prefixes (slow is coarser).
	}
}

@(test)
test_rfc_c4_no_cache :: proc(t: ^testing.T) {
	data := transmute([]u8)string("no-cache")
	enc := make([]u8, encoded_len(data))
	defer delete(enc)
	n := encode(enc, data)

	dec: [dynamic]u8
	defer delete(dec)
	testing.expect_value(t, decode(&dec, enc[:n]), Error.None)
	testing.expect(t, slice.equal(dec[:], data))

	clear(&dec)
	testing.expect_value(t, decode_slow(&dec, enc[:n]), Error.None)
	testing.expect(t, slice.equal(dec[:], data))
}
