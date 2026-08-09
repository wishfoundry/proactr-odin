package huffman

import "core:slice"
import "core:testing"

@(test)
test_known_vector :: proc(t: ^testing.T) {
	// RFC 7541 C.4.1: "www.example.com" Huffman-encodes to these 12 bytes.
	// If the table transcription or encoder is wrong, this fails.
	data := transmute([]u8)string("www.example.com")
	enc := make([]u8, encoded_len(data))
	defer delete(enc)
	n := encode(enc, data)
	want := []u8{0xf1, 0xe3, 0xc2, 0xe5, 0xf2, 0x3a, 0x6b, 0xa0, 0xab, 0x90, 0xf4, 0xff}
	testing.expect_value(t, n, len(want))
	testing.expect(t, slice.equal(enc[:n], want), "www.example.com huffman vector mismatch")
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
