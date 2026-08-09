package hpack

import "core:slice"
import "core:testing"

@(test)
test_hpack_indexed_static :: proc(t: ^testing.T) {
	// RFC 7541 §6.1: :method GET is static index 2 → 0x82 (0x80 | 2).
	buf: [dynamic]u8
	defer delete(buf)
	encode(&buf, []Header{{":method", "GET"}}, use_huffman = false)
	testing.expect(t, slice.equal(buf[:], []u8{0x82}), ":method GET -> 0x82")
}

@(test)
test_hpack_roundtrip :: proc(t: ^testing.T) {
	hs := []Header {
		{":method", "GET"},            // indexed static
		{":scheme", "https"},          // indexed static
		{":path", "/"},                // indexed static
		{":authority", "example.com"}, // literal w/ static name ref
		{"user-agent", "proactr-h2"},  // literal w/ static name ref
		{"x-custom", "some value 123"}, // literal name + literal value
		{"accept", "*/*"},
	}
	huff_modes := []bool{false, true}
	for use_huff in huff_modes {
		buf: [dynamic]u8
		defer delete(buf)
		encode(&buf, hs, use_huffman = use_huff)

		dt: HPackDynamicTable
		init(&dt)
		defer destroy(&dt)
		out: [dynamic]Header
		defer {headers_destroy(out[:]); delete(out)}

		err := decode(&dt, buf[:], &out)
		testing.expect_value(t, err, Hpack_Error.None)
		testing.expect_value(t, len(out), len(hs))
		for h, i in hs {
			testing.expect_value(t, out[i].name, h.name)
			testing.expect_value(t, out[i].value, h.value)
		}
	}
}

@(test)
test_hpack_dynamic_table :: proc(t: ^testing.T) {
	// A peer using incremental indexing: encode "Literal With Incremental
	// Indexing" by hand (0x40 | name_idx... ), then a follow-up Indexed ref to
	// the new dynamic entry (index 62). Decoder must track the dynamic table.
	dt: HPackDynamicTable
	init(&dt)
	defer destroy(&dt)

	// Block 1: Literal w/ Incremental Indexing, literal name "x-trace" value "abc".
	b1: [dynamic]u8
	defer delete(b1)
	append(&b1, 0x40) // 01000000: incremental, name index 0 (literal name)
	encode_str_raw(&b1, "x-trace")
	encode_str_raw(&b1, "abc")

	out1: [dynamic]Header
	defer {headers_destroy(out1[:]); delete(out1)}
	testing.expect_value(t, decode(&dt, b1[:], &out1), Hpack_Error.None)
	testing.expect_value(t, len(out1), 1)
	testing.expect_value(t, out1[0].name, "x-trace")
	testing.expect_value(t, out1[0].value, "abc")
	testing.expect_value(t, len(dt.entries), 1) // added to dynamic table

	// Block 2: Indexed Header Field referencing dynamic index 62 (first dynamic).
	b2 := []u8{0x80 | 62}
	out2: [dynamic]Header
	defer {headers_destroy(out2[:]); delete(out2)}
	testing.expect_value(t, decode(&dt, b2, &out2), Hpack_Error.None)
	testing.expect_value(t, len(out2), 1)
	testing.expect_value(t, out2[0].name, "x-trace")
	testing.expect_value(t, out2[0].value, "abc")
}

// raw (non-Huffman) string literal helper for hand-built test blocks.
@(private = "file")
encode_str_raw :: proc(dst: ^[dynamic]u8, s: string) {
	append(dst, u8(len(s)))
	append(dst, ..transmute([]u8)s)
}

// ---------------------------------------------------------------------------
// RFC 7541 Appendix C known-answer vectors (decode-focused)
// ---------------------------------------------------------------------------

@(test)
test_c1_prefix_int :: proc(t: ^testing.T) {
	// C.1.1: value 10 with 5-bit prefix → 0x0a
	buf: [dynamic]u8
	defer delete(buf)
	prefix_int_encode(&buf, 10, 5, 0)
	testing.expect(t, slice.equal(buf[:], []u8{0x0a}))

	// C.1.2: 1337 with 5-bit prefix → 0x1f 0x9a 0x0a
	clear(&buf)
	prefix_int_encode(&buf, 1337, 5, 0)
	testing.expect(t, slice.equal(buf[:], []u8{0x1f, 0x9a, 0x0a}))

	// C.1.3: 42 on an octet boundary (8-bit prefix) → 0x2a
	clear(&buf)
	prefix_int_encode(&buf, 42, 8, 0)
	testing.expect(t, slice.equal(buf[:], []u8{0x2a}))

	v, n, err := prefix_int_decode([]u8{0x1f, 0x9a, 0x0a}, 5)
	testing.expect_value(t, err, Hpack_Error.None)
	testing.expect_value(t, v, u64(1337))
	testing.expect_value(t, n, 3)
}

@(test)
test_c2_1_literal_with_indexing :: proc(t: ^testing.T) {
	// custom-key: custom-header
	wire := []u8{
		0x40, 0x0a, 0x63, 0x75, 0x73, 0x74, 0x6f, 0x6d, 0x2d, 0x6b, 0x65, 0x79,
		0x0d, 0x63, 0x75, 0x73, 0x74, 0x6f, 0x6d, 0x2d, 0x68, 0x65, 0x61, 0x64, 0x65, 0x72,
	}
	dt: HPackDynamicTable
	init(&dt)
	defer destroy(&dt)
	out: [dynamic]Header
	defer {headers_destroy(out[:]); delete(out)}
	testing.expect_value(t, decode(&dt, wire, &out), Hpack_Error.None)
	testing.expect_value(t, len(out), 1)
	testing.expect_value(t, out[0].name, "custom-key")
	testing.expect_value(t, out[0].value, "custom-header")
	testing.expect_value(t, len(dt.entries), 1)
	testing.expect_value(t, dt.size, 55)
}

@(test)
test_c3_request_series :: proc(t: ^testing.T) {
	// RFC 7541 C.3 request examples without Huffman (shared dynamic table).
	dt: HPackDynamicTable
	init(&dt)
	defer destroy(&dt)

	// C.3.1
	c31 := []u8{
		0x82, 0x86, 0x84, 0x41, 0x0f,
		0x77, 0x77, 0x77, 0x2e, 0x65, 0x78, 0x61, 0x6d, 0x70, 0x6c, 0x65, 0x2e, 0x63, 0x6f, 0x6d,
	}
	out1: [dynamic]Header
	defer {headers_destroy(out1[:]); delete(out1)}
	testing.expect_value(t, decode(&dt, c31, &out1), Hpack_Error.None)
	testing.expect_value(t, len(out1), 4)
	testing.expect_value(t, out1[0].name, ":method");    testing.expect_value(t, out1[0].value, "GET")
	testing.expect_value(t, out1[1].name, ":scheme");    testing.expect_value(t, out1[1].value, "http")
	testing.expect_value(t, out1[2].name, ":path");      testing.expect_value(t, out1[2].value, "/")
	testing.expect_value(t, out1[3].name, ":authority"); testing.expect_value(t, out1[3].value, "www.example.com")
	testing.expect_value(t, dt.size, 57)
	testing.expect_value(t, len(dt.entries), 1)

	// C.3.2
	c32 := []u8{
		0x82, 0x86, 0x84, 0xbe, 0x58, 0x08,
		0x6e, 0x6f, 0x2d, 0x63, 0x61, 0x63, 0x68, 0x65,
	}
	out2: [dynamic]Header
	defer {headers_destroy(out2[:]); delete(out2)}
	testing.expect_value(t, decode(&dt, c32, &out2), Hpack_Error.None)
	testing.expect_value(t, len(out2), 5)
	testing.expect_value(t, out2[3].name, ":authority");     testing.expect_value(t, out2[3].value, "www.example.com")
	testing.expect_value(t, out2[4].name, "cache-control"); testing.expect_value(t, out2[4].value, "no-cache")
	testing.expect_value(t, dt.size, 110)
	testing.expect_value(t, len(dt.entries), 2)

	// C.3.3
	c33 := []u8{
		0x82, 0x87, 0x85, 0xbf, 0x40, 0x0a,
		0x63, 0x75, 0x73, 0x74, 0x6f, 0x6d, 0x2d, 0x6b, 0x65, 0x79,
		0x0c,
		0x63, 0x75, 0x73, 0x74, 0x6f, 0x6d, 0x2d, 0x76, 0x61, 0x6c, 0x75, 0x65,
	}
	out3: [dynamic]Header
	defer {headers_destroy(out3[:]); delete(out3)}
	testing.expect_value(t, decode(&dt, c33, &out3), Hpack_Error.None)
	testing.expect_value(t, len(out3), 5)
	testing.expect_value(t, out3[1].name, ":scheme"); testing.expect_value(t, out3[1].value, "https")
	testing.expect_value(t, out3[2].name, ":path");   testing.expect_value(t, out3[2].value, "/index.html")
	testing.expect_value(t, out3[4].name, "custom-key"); testing.expect_value(t, out3[4].value, "custom-value")
	testing.expect_value(t, dt.size, 164)
	testing.expect_value(t, len(dt.entries), 3)
}

@(test)
test_c4_request_series_huffman :: proc(t: ^testing.T) {
	// RFC 7541 C.4 same headers as C.3 with Huffman coding.
	dt: HPackDynamicTable
	init(&dt)
	defer destroy(&dt)

	c41 := []u8{
		0x82, 0x86, 0x84, 0x41, 0x8c,
		0xf1, 0xe3, 0xc2, 0xe5, 0xf2, 0x3a, 0x6b, 0xa0, 0xab, 0x90, 0xf4, 0xff,
	}
	out1: [dynamic]Header
	defer {headers_destroy(out1[:]); delete(out1)}
	testing.expect_value(t, decode(&dt, c41, &out1), Hpack_Error.None)
	testing.expect_value(t, len(out1), 4)
	testing.expect_value(t, out1[3].value, "www.example.com")
	testing.expect_value(t, dt.size, 57)

	c42 := []u8{0x82, 0x86, 0x84, 0xbe, 0x58, 0x86, 0xa8, 0xeb, 0x10, 0x64, 0x9c, 0xbf}
	out2: [dynamic]Header
	defer {headers_destroy(out2[:]); delete(out2)}
	testing.expect_value(t, decode(&dt, c42, &out2), Hpack_Error.None)
	testing.expect_value(t, len(out2), 5)
	testing.expect_value(t, out2[4].value, "no-cache")
	testing.expect_value(t, dt.size, 110)

	c43 := []u8{
		0x82, 0x87, 0x85, 0xbf, 0x40, 0x88,
		0x25, 0xa8, 0x49, 0xe9, 0x5b, 0xa9, 0x7d, 0x7f,
		0x89,
		0x25, 0xa8, 0x49, 0xe9, 0x5b, 0xb8, 0xe8, 0xb4, 0xbf,
	}
	out3: [dynamic]Header
	defer {headers_destroy(out3[:]); delete(out3)}
	testing.expect_value(t, decode(&dt, c43, &out3), Hpack_Error.None)
	testing.expect_value(t, len(out3), 5)
	testing.expect_value(t, out3[4].name, "custom-key")
	testing.expect_value(t, out3[4].value, "custom-value")
	testing.expect_value(t, dt.size, 164)
}
