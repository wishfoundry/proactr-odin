package hpack

import "core:slice"
import "core:testing"

@(test)
test_hpack_indexed_static :: proc(t: ^testing.T) {
	// RFC 7541 §6.1: :method GET is static index 2 → 0x82 (0x80 | 2).
	buf: [dynamic]u8
	defer delete(buf)
	encode(&buf, []Header{{name = ":method", value = "GET"}}, use_huffman = false)
	testing.expect(t, slice.equal(buf[:], []u8{0x82}), ":method GET -> 0x82")
}

@(test)
test_hpack_roundtrip :: proc(t: ^testing.T) {
	hs := []Header {
		{name = ":method", value = "GET"},            // indexed static
		{name = ":scheme", value = "https"},          // indexed static
		{name = ":path", value = "/"},                // indexed static
		{name = ":authority", value = "example.com"}, // literal w/ static name ref
		{name = "user-agent", value = "proactr-h2"},  // literal w/ static name ref
		{name = "x-custom", value = "some value 123"}, // literal name + literal value
		{name = "accept", value = "*/*"},
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
	testing.expect_value(t, dt.count, 1) // added to dynamic table

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
	testing.expect_value(t, dt.count, 1)
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
	testing.expect_value(t, dt.count, 1)

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
	testing.expect_value(t, dt.count, 2)

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
	testing.expect_value(t, dt.count, 3)
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

// ---------------------------------------------------------------------------
// P0/P1 hardening tests
// ---------------------------------------------------------------------------

@(test)
test_prefix_int_overflow_and_truncated :: proc(t: ^testing.T) {
	// Truncated multi-byte integer (continuation with no following byte).
	_, _, err := prefix_int_decode([]u8{0x1f, 0xff}, 5) // 5-bit max, needs more
	// 0x1f means "at least max_prefix"; 0xff continues; missing final byte → Truncated
	// Actually 0xff has continuation bit set, so still truncated.
	testing.expect_value(t, err, Hpack_Error.Truncated)

	// Empty input.
	_, _, err = prefix_int_decode([]u8{}, 7)
	testing.expect_value(t, err, Hpack_Error.Truncated)

	// Long continuation chain that would exceed MAX_PREFIX_INT / shift cap.
	// 7-bit prefix all-ones (0x7f), then many 0xff continuation bytes.
	bomb: [dynamic]u8
	defer delete(bomb)
	append(&bomb, 0x7f)
	for _ in 0 ..< 20 {
		append(&bomb, 0xff)
	}
	append(&bomb, 0x00) // terminator (would be too late)
	_, _, err = prefix_int_decode(bomb[:], 7)
	testing.expect_value(t, err, Hpack_Error.Bad_Integer)

	// Value just above MAX_PREFIX_INT should fail. Encode a large value by hand:
	// With n=7, max_prefix=127. value = 127 + sum of 7-bit chunks.
	// Build value = MAX_PREFIX_INT + 1 via encoder then decode — encoder may
	// produce it; decoder must reject.
	clear(&bomb)
	prefix_int_encode(&bomb, MAX_PREFIX_INT + 1, 7, 0)
	_, _, err = prefix_int_decode(bomb[:], 7)
	testing.expect_value(t, err, Hpack_Error.Bad_Integer)

	// MAX_PREFIX_INT itself is accepted.
	clear(&bomb)
	prefix_int_encode(&bomb, MAX_PREFIX_INT, 7, 0)
	v, _, err2 := prefix_int_decode(bomb[:], 7)
	testing.expect_value(t, err2, Hpack_Error.None)
	testing.expect_value(t, v, MAX_PREFIX_INT)
}

@(test)
test_decode_string_huge_length :: proc(t: ^testing.T) {
	// Length prefix claims more bytes than remain → Truncated, no alloc blow-up.
	// Literal Without Indexing, name index 0, value length 1000 but short payload.
	dt: HPackDynamicTable
	init(&dt)
	defer destroy(&dt)
	out: [dynamic]Header
	defer {headers_destroy(out[:]); delete(out)}

	buf: [dynamic]u8
	defer delete(buf)
	append(&buf, 0x00) // Without Indexing, name index 0
	encode_str_raw(&buf, "n")
	prefix_int_encode(&buf, 1000, 7, 0x00) // value length 1000
	append(&buf, 0x41, 0x42) // only 2 payload bytes
	testing.expect_value(t, decode(&dt, buf[:], &out), Hpack_Error.Truncated)

	// Length > MAX_STRING_LEN → Bad_Integer (cap checked before reading payload).
	clear(&buf)
	clear(&out)
	append(&buf, 0x00)
	encode_str_raw(&buf, "n")
	prefix_int_encode(&buf, u64(MAX_STRING_LEN) + 1, 7, 0x00)
	testing.expect_value(t, decode(&dt, buf[:], &out), Hpack_Error.Bad_Integer)
}

@(test)
test_size_update_after_field :: proc(t: ^testing.T) {
	// Dynamic Table Size Update must appear before any header field.
	dt: HPackDynamicTable
	init(&dt)
	defer destroy(&dt)

	// Indexed :method GET (0x82), then size update 0x20 (max=0 with 5-bit).
	wire := []u8{0x82, 0x20}
	out: [dynamic]Header
	defer {headers_destroy(out[:]); delete(out)}
	testing.expect_value(t, decode(&dt, wire, &out), Hpack_Error.Bad_Size_Update)

	// Size update before fields is fine.
	clear(&out)
	wire2 := []u8{0x20, 0x82} // size=0, then :method GET
	testing.expect_value(t, decode(&dt, wire2, &out), Hpack_Error.None)
	testing.expect_value(t, len(out), 1)
	testing.expect_value(t, out[0].name, ":method")
	testing.expect_value(t, dt.max_size, 0)

	// Size update above SETTINGS limit.
	dt2: HPackDynamicTable
	init(&dt2, 100)
	defer destroy(&dt2)
	// 5-bit prefix: 0x3f = 31 + continuation for larger values.
	// Value 200 with 5-bit: max_prefix=31, so 0x3f then 200-31=169 = 0xa9 0x01?
	// Actually 169 = 0xa9 (128+41) with cont, then 41>>7... 169 = 0xA9, 0x01
	// 0x3f | flags 0x20 = 0x3f for size update pattern 001 + 5 bits all 1.
	upd: [dynamic]u8
	defer delete(upd)
	prefix_int_encode(&upd, 200, 5, 0x20)
	out2: [dynamic]Header
	defer {headers_destroy(out2[:]); delete(out2)}
	testing.expect_value(t, decode(&dt2, upd[:], &out2), Hpack_Error.Bad_Size_Update)
}

@(test)
test_ring_table_eviction_and_index_62 :: proc(t: ^testing.T) {
	// Small table forces eviction; newest entry is always relative 0 → wire 62.
	dt: HPackDynamicTable
	// Each entry: name 4 + value 1 + 32 overhead = 37. max_size 100 holds ~2.
	init(&dt, 100)
	defer destroy(&dt)

	for i in 0 ..< 10 {
		name_buf: [4]u8 = {'x', '-', u8('0' + (i / 10) % 10), u8('0' + i % 10)}
		insert(&dt, Header{name = string(name_buf[:]), value = "v"})
	}
	// Size budget ~100: only a few entries remain; newest is x-09.
	testing.expect(t, dt.count >= 1)
	testing.expect(t, dt.size <= dt.max_size)
	newest, ok := get(&dt, 0)
	testing.expect(t, ok)
	testing.expect_value(t, newest.name, "x-09")

	// Wire index 62 must resolve to most recent.
	h, ok2 := table_get(&dt, 62)
	testing.expect(t, ok2)
	testing.expect_value(t, h.name, "x-09")
	testing.expect_value(t, h.value, "v")

	// Insert one more and confirm ring still O(1)-correct.
	insert(&dt, Header{name = "final", value = "ok"})
	h, ok2 = table_get(&dt, 62)
	testing.expect(t, ok2)
	testing.expect_value(t, h.name, "final")

	// Many inserts to force ring growth + wrap.
	large: HPackDynamicTable
	init(&large, 4096)
	defer destroy(&large)
	for i in 0 ..< 200 {
		nb: [3]u8 = {'n', u8('a' + (i % 26)), u8('0' + (i / 26) % 10)}
		insert(&large, Header{name = string(nb[:]), value = "val"})
	}
	testing.expect(t, large.count > 0)
	_, ok3 := table_get(&large, 62)
	testing.expect(t, ok3)
}

@(test)
test_encoder_dynamic_table_reuse :: proc(t: ^testing.T) {
	// Two identical custom headers: second should be Indexed (shorter wire).
	enc: HPackEncoder
	encoder_init(&enc)
	defer encoder_destroy(&enc)

	hs := []Header{{name = "x-custom", value = "hello-world-value"}}
	b1: [dynamic]u8
	defer delete(b1)
	encode(&b1, hs, &enc, use_huffman = false)

	b2: [dynamic]u8
	defer delete(b2)
	encode(&b2, hs, &enc, use_huffman = false)

	testing.expect(t, len(b2) < len(b1), "second encode should be Indexed / smaller")
	// Indexed dynamic: single byte 0x80|62 = 0xBE for first dynamic entry if
	// nothing else was inserted — but static may not match; after first insert
	// relative 0 → index 62 → 0xBE.
	testing.expect(t, len(b2) == 1)
	testing.expect_value(t, b2[0], u8(0xBE))

	// Round-trip both blocks through a decoder that mirrors encoder state.
	dt: HPackDynamicTable
	init(&dt)
	defer destroy(&dt)
	out: [dynamic]Header
	defer {headers_destroy(out[:]); delete(out)}
	testing.expect_value(t, decode(&dt, b1[:], &out), Hpack_Error.None)
	testing.expect_value(t, decode(&dt, b2[:], &out), Hpack_Error.None)
	testing.expect_value(t, len(out), 2)
	testing.expect_value(t, out[0].name, "x-custom")
	testing.expect_value(t, out[1].value, "hello-world-value")
}

@(test)
test_encoder_never_indexed_cookie :: proc(t: ^testing.T) {
	enc: HPackEncoder
	encoder_init(&enc)
	defer encoder_destroy(&enc)

	buf: [dynamic]u8
	defer delete(buf)
	encode(&buf, []Header{{name = "cookie", value = "session=abc"}}, &enc, use_huffman = false)

	// Never Indexed with name index 32 (cookie static): pattern 0001 + 4-bit idx.
	// index 32 fits in 4 bits? max_prefix for 4-bit is 15, so 32 needs multi-byte.
	// First byte: 0x10 | 0x0f = 0x1f, then 32-15=17 = 0x11.
	testing.expect(t, len(buf) >= 1)
	testing.expect_value(t, buf[0] & 0xF0, u8(0x10)) // Never Indexed pattern
	// Must NOT have entered dynamic table.
	testing.expect_value(t, enc.dt.count, 0)

	// Decode and verify.
	dt: HPackDynamicTable
	init(&dt)
	defer destroy(&dt)
	out: [dynamic]Header
	defer {headers_destroy(out[:]); delete(out)}
	testing.expect_value(t, decode(&dt, buf[:], &out), Hpack_Error.None)
	testing.expect_value(t, len(out), 1)
	testing.expect_value(t, out[0].name, "cookie")
	testing.expect_value(t, out[0].value, "session=abc")
	testing.expect_value(t, dt.count, 0) // never indexed
}

@(test)
test_encoder_set_max_emits_size_update :: proc(t: ^testing.T) {
	enc: HPackEncoder
	encoder_init(&enc, 4096)
	defer encoder_destroy(&enc)

	encoder_set_max(&enc, 0)
	buf: [dynamic]u8
	defer delete(buf)
	encode(&buf, []Header{{name = ":method", value = "GET"}}, &enc, use_huffman = false)
	// Size update 0: 0x20, then Indexed :method GET 0x82.
	testing.expect(t, len(buf) >= 2)
	testing.expect_value(t, buf[0], u8(0x20))
	testing.expect_value(t, buf[1], u8(0x82))
	testing.expect_value(t, enc.dt.max_size, 0)
	testing.expect(t, !enc.has_pending_size)
}

@(test)
test_borrowed_static_headers_destroy_safe :: proc(t: ^testing.T) {
	// Indexed static must not be heap-freed (owned flags false).
	dt: HPackDynamicTable
	init(&dt)
	defer destroy(&dt)
	out: [dynamic]Header
	defer {headers_destroy(out[:]); delete(out)}
	testing.expect_value(t, decode(&dt, []u8{0x82}, &out), Hpack_Error.None)
	testing.expect_value(t, len(out), 1)
	testing.expect_value(t, out[0].name, ":method")
	testing.expect_value(t, out[0].value, "GET")
	// Pointer must alias static table entry 2 (:method GET); not owned.
	testing.expect(t, raw_data(out[0].name) == raw_data(HPACK_STATIC[1].name))
	testing.expect(t, raw_data(out[0].value) == raw_data(HPACK_STATIC[1].value))
	testing.expect(t, !out[0].name_owned)
	testing.expect(t, !out[0].value_owned)
	// headers_destroy in defer must not crash / free static storage.
}

@(test)
test_encode_nil_enc_unchanged :: proc(t: ^testing.T) {
	// enc == nil keeps static-only Literal Without Indexing for custom headers.
	buf: [dynamic]u8
	defer delete(buf)
	encode(&buf, []Header{{name = "x-custom", value = "v"}}, use_huffman = false)
	// Without Indexing (0000), name index 0: first byte 0x00.
	testing.expect_value(t, buf[0], u8(0x00))
}

// ---------------------------------------------------------------------------
// WOW blockers: ownership, list budget, size updates, oversize entry
// ---------------------------------------------------------------------------

@(test)
test_indexed_zero_bad_index :: proc(t: ^testing.T) {
	// RFC 7541 §6.1: index 0 is invalid → 0x80 alone is Bad_Index.
	dt: HPackDynamicTable
	init(&dt)
	defer destroy(&dt)
	out: [dynamic]Header
	defer {headers_destroy(out[:]); delete(out)}
	testing.expect_value(t, decode(&dt, []u8{0x80}, &out), Hpack_Error.Bad_Index)
	testing.expect_value(t, len(out), 0)
}

@(test)
test_oversize_entry_empties_table :: proc(t: ^testing.T) {
	// Entry larger than max_size: table is emptied and entry is not inserted
	// (RFC 7541 §4.4).
	dt: HPackDynamicTable
	init(&dt, 50) // tiny table
	defer destroy(&dt)

	// Seed one small entry first.
	insert(&dt, Header{name = "a", value = "b"})
	testing.expect(t, dt.count >= 1)

	// Oversize: name+value+32 > 50.
	// "xxxxxxxxxxxxxxxxxxxxxxxx" (24) + "yyyyyyyyyyyyyyyyyyyyyyyy" (24) + 32 = 80.
	insert(&dt, Header{name = "xxxxxxxxxxxxxxxxxxxxxxxx", value = "yyyyyyyyyyyyyyyyyyyyyyyy"})
	testing.expect_value(t, dt.count, 0)
	testing.expect_value(t, dt.size, 0)

	// Also via decode path (Literal With Incremental Indexing) on a fresh table.
	dt2: HPackDynamicTable
	init(&dt2, 40)
	defer destroy(&dt2)
	b: [dynamic]u8
	defer delete(b)
	append(&b, 0x40) // incremental, literal name
	encode_str_raw(&b, "long-name-that-is-big")
	encode_str_raw(&b, "long-value-also-big!!")
	// entry: 21 + 21 + 32 = 74 > 40
	out: [dynamic]Header
	defer {headers_destroy(out[:]); delete(out)}
	testing.expect_value(t, decode(&dt2, b[:], &out), Hpack_Error.None)
	testing.expect_value(t, len(out), 1) // still emitted to the list
	testing.expect_value(t, dt2.count, 0) // not in table
	testing.expect_value(t, dt2.size, 0)
}

@(test)
test_multiple_size_updates_at_start_ok :: proc(t: ^testing.T) {
	// Multiple Dynamic Table Size Updates before any field are allowed.
	dt: HPackDynamicTable
	init(&dt, 4096)
	defer destroy(&dt)

	// size=100, size=50, then :method GET
	wire: [dynamic]u8
	defer delete(wire)
	prefix_int_encode(&wire, 100, 5, 0x20)
	prefix_int_encode(&wire, 50, 5, 0x20)
	append(&wire, 0x82)

	out: [dynamic]Header
	defer {headers_destroy(out[:]); delete(out)}
	testing.expect_value(t, decode(&dt, wire[:], &out), Hpack_Error.None)
	testing.expect_value(t, dt.max_size, 50)
	testing.expect_value(t, len(out), 1)
	testing.expect_value(t, out[0].name, ":method")
}

@(test)
test_list_size_budget_exceeded :: proc(t: ^testing.T) {
	// Each field costs name+value+32. Budget of 40 admits one small field, not two.
	dt: HPackDynamicTable
	init(&dt)
	defer destroy(&dt)

	// Two indexed static: :method GET (6+3+32=41) alone exceeds budget 40.
	out: [dynamic]Header
	defer {headers_destroy(out[:]); delete(out)}
	testing.expect_value(t, decode(&dt, []u8{0x82}, &out, max_list_size = 40), Hpack_Error.List_Too_Large)

	// Budget large enough for one static field (41), not two (82).
	clear(&out)
	// :method GET then :scheme http — second exceeds.
	testing.expect_value(t, decode(&dt, []u8{0x82, 0x86}, &out, max_list_size = 50), Hpack_Error.List_Too_Large)
	// First field may have been appended before the second failed.
	testing.expect(t, len(out) <= 1)

	// Unlimited (0) accepts both.
	clear(&out)
	testing.expect_value(t, decode(&dt, []u8{0x82, 0x86}, &out, max_list_size = 0), Hpack_Error.None)
	testing.expect_value(t, len(out), 2)
}

@(test)
test_ownership_static_indexed_not_owned :: proc(t: ^testing.T) {
	// Explicit ownership: static indexed → flags false; literal → flags true.
	dt: HPackDynamicTable
	init(&dt)
	defer destroy(&dt)

	// Static indexed
	out: [dynamic]Header
	defer {headers_destroy(out[:]); delete(out)}
	testing.expect_value(t, decode(&dt, []u8{0x82}, &out), Hpack_Error.None)
	testing.expect(t, !out[0].name_owned && !out[0].value_owned)

	// Literal without indexing — both owned.
	b: [dynamic]u8
	defer delete(b)
	append(&b, 0x00)
	encode_str_raw(&b, "x-own")
	encode_str_raw(&b, "yes")
	clear(&out)
	testing.expect_value(t, decode(&dt, b[:], &out), Hpack_Error.None)
	testing.expect_value(t, len(out), 1)
	testing.expect(t, out[0].name_owned && out[0].value_owned)
	testing.expect_value(t, out[0].name, "x-own")
	testing.expect_value(t, out[0].value, "yes")
	// headers_destroy frees owned strings only — no crash on mixed list.
}

@(test)
test_encoder_decoder_roundtrip_both_sides :: proc(t: ^testing.T) {
	// Symmetric: encoder dynamic table on both encode sides; shared decoder state.
	enc: HPackEncoder
	encoder_init(&enc)
	defer encoder_destroy(&enc)

	dec: HPackDynamicTable
	init(&dec)
	defer destroy(&dec)

	hs1 := []Header{
		{name = ":method", value = "GET"},
		{name = ":path", value = "/"},
		{name = "x-trace", value = "abc"},
	}
	hs2 := []Header{
		{name = ":method", value = "GET"},
		{name = ":path", value = "/"},
		{name = "x-trace", value = "abc"}, // should be Indexed on second encode
	}

	b1: [dynamic]u8
	defer delete(b1)
	encode(&b1, hs1, &enc, use_huffman = false)

	b2: [dynamic]u8
	defer delete(b2)
	encode(&b2, hs2, &enc, use_huffman = false)
	testing.expect(t, len(b2) < len(b1), "second block should reuse dynamic entries")

	out: [dynamic]Header
	defer {headers_destroy(out[:]); delete(out)}
	testing.expect_value(t, decode(&dec, b1[:], &out), Hpack_Error.None)
	testing.expect_value(t, len(out), 3)
	testing.expect_value(t, decode(&dec, b2[:], &out), Hpack_Error.None)
	testing.expect_value(t, len(out), 6)
	testing.expect_value(t, out[2].name, "x-trace")
	testing.expect_value(t, out[5].value, "abc")
	// Encoder and decoder dynamic tables should agree on size/count.
	testing.expect_value(t, enc.dt.count, dec.count)
	testing.expect_value(t, enc.dt.size, dec.size)
}
