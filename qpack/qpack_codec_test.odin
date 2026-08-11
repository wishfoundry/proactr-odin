package qpack

import "core:slice"
import "core:testing"

@(test)
test_prefix_int :: proc(t: ^testing.T) {
	Case :: struct {
		val: u64,
		n:   uint,
	}
	// Incl. RFC 7541 §C.1 examples (10/5-bit, 1337/5-bit, 42/8-bit) plus the
	// 6-bit boundary cases the static-table index path hits.
	cases := []Case {
		{10, 5}, {1337, 5}, {42, 8}, {0, 6}, {62, 6}, {63, 6}, {98, 6}, {1 << 40, 8},
	}
	for c in cases {
		buf: [dynamic]u8
		defer delete(buf)
		prefix_int_encode(&buf, c.val, c.n, 0)
		v, consumed, e := prefix_int_decode(buf[:], c.n)
		testing.expect_value(t, e, Qpack_Error.None)
		testing.expect_value(t, v, c.val)
		testing.expect_value(t, consumed, len(buf))
	}
}

@(test)
test_qpack_indexed_wire :: proc(t: ^testing.T) {
	// Static :method GET is index 17 → Indexed Field Line 0xC0|17 = 0xD1,
	// after the 2-byte static-only field section prefix.
	buf: [dynamic]u8
	defer delete(buf)
	qpack_encode_field_section(&buf, []Header{{name = ":method", value = "GET"}}, use_huffman = false)
	testing.expect(t, slice.equal(buf[:], []u8{0x00, 0x00, 0xD1}), "indexed :method GET wire")
}

@(test)
test_qpack_roundtrip :: proc(t: ^testing.T) {
	hs := []Header {
		{name = ":method", value = "GET"},                    // indexed static
		{name = ":scheme", value = "https"},                  // indexed static
		{name = ":path", value = "/index.html"},              // name-ref static + literal value
		{name = ":authority", value = "www.example.com"},     // name-ref static + literal value
		{name = "user-agent", value = "vapor-http/0.1 (test)"},// name-ref static + literal value
		{name = "accept", value = "*/*"},                     // indexed static
		{name = "x-custom-header", value = "some custom value 123"}, // literal name + literal value
		{name = "x-empty", value = ""},                       // literal name + empty value
	}
	huff_modes := []bool{false, true}
	for use_huff in huff_modes {
		buf: [dynamic]u8
		defer delete(buf)
		qpack_encode_field_section(&buf, hs, use_huffman = use_huff)

		out, ric, err := qpack_decode_field_section(buf[:])
		defer {
			headers_destroy(out[:])
			delete(out)
		}
		testing.expect_value(t, err, Qpack_Error.None)
		testing.expect_value(t, ric, u64(0))
		testing.expect_value(t, len(out), len(hs))
		for h, i in hs {
			testing.expect_value(t, out[i].name, h.name)
			testing.expect_value(t, out[i].value, h.value)
		}
	}
}

@(test)
test_qpack_rejects_dynamic :: proc(t: ^testing.T) {
	// Without a Dynamic_Table, a non-zero Required Insert Count is rejected.
	out, _, err := qpack_decode_field_section([]u8{0x01, 0x00})
	defer delete(out)
	testing.expect_value(t, err, Qpack_Error.Dynamic_Table_Unsupported)
}
