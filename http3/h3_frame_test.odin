package http3


import "core:slice"
import "core:testing"

@(test)
test_frame_data_wire :: proc(t: ^testing.T) {
	buf: [dynamic]u8
	defer delete(buf)
	frame_write_data(&buf, transmute([]u8)string("abc"))
	// DATA(0x00) Length(0x03) 'a' 'b' 'c'
	testing.expect(t, slice.equal(buf[:], []u8{0x00, 0x03, 'a', 'b', 'c'}), "DATA wire")

	h, payload, consumed, err := frame_decode(buf[:])
	testing.expect_value(t, err, Frame_Error.None)
	testing.expect_value(t, h.ftype, u64(FRAME_DATA))
	testing.expect_value(t, h.length, u64(3))
	testing.expect_value(t, consumed, 5)
	testing.expect_value(t, string(payload), "abc")
}

@(test)
test_frame_settings_wire :: proc(t: ^testing.T) {
	buf: [dynamic]u8
	defer delete(buf)
	frame_write_settings(&buf, Settings{}) // cap=0, blocked=0, no max_field
	// SETTINGS(0x04) Len(0x04) [id 0x01 val 0x00] [id 0x07 val 0x00]
	testing.expect(t, slice.equal(buf[:], []u8{0x04, 0x04, 0x01, 0x00, 0x07, 0x00}), "SETTINGS wire")

	h, payload, _, err := frame_decode(buf[:])
	testing.expect_value(t, err, Frame_Error.None)
	testing.expect_value(t, h.ftype, u64(FRAME_SETTINGS))
	s, serr := settings_decode(payload)
	testing.expect_value(t, serr, Frame_Error.None)
	testing.expect_value(t, s.qpack_max_table_capacity, u64(0))
	testing.expect_value(t, s.qpack_blocked_streams, u64(0))
}

@(test)
test_frame_settings_roundtrip :: proc(t: ^testing.T) {
	in_s := Settings{qpack_max_table_capacity = 4096, qpack_blocked_streams = 16, max_field_section_size = 65536}
	buf: [dynamic]u8
	defer delete(buf)
	frame_write_settings(&buf, in_s)

	_, payload, _, _ := frame_decode(buf[:])
	out, _ := settings_decode(payload)
	testing.expect_value(t, out.qpack_max_table_capacity, u64(4096))
	testing.expect_value(t, out.qpack_blocked_streams, u64(16))
	testing.expect_value(t, out.max_field_section_size, u64(65536))
}

@(test)
test_settings_ignores_unknown :: proc(t: ^testing.T) {
	// Hand-built payload: unknown id 0x21 (GREASE) val 0x09, then known 0x06 val 0x80 (= varint 0x4080).
	payload := []u8{0x21, 0x09, 0x06, 0x40, 0x80}
	s, err := settings_decode(payload)
	testing.expect_value(t, err, Frame_Error.None)
	testing.expect_value(t, s.max_field_section_size, u64(0x80)) // 2-byte varint 0x4080 -> 0x80
}

@(test)
test_frame_goaway :: proc(t: ^testing.T) {
	buf: [dynamic]u8
	defer delete(buf)
	frame_write_goaway(&buf, 0)
	h, payload, _, err := frame_decode(buf[:])
	testing.expect_value(t, err, Frame_Error.None)
	testing.expect_value(t, h.ftype, u64(FRAME_GOAWAY))
	id, ierr := goaway_decode(payload)
	testing.expect_value(t, ierr, Frame_Error.None)
	testing.expect_value(t, id, u64(0))
}

@(test)
test_frame_sequential :: proc(t: ^testing.T) {
	// Two frames back to back in one buffer (as they'd arrive on a stream).
	buf: [dynamic]u8
	defer delete(buf)
	frame_write_headers(&buf, transmute([]u8)string("HDR"))
	frame_write_data(&buf, transmute([]u8)string("BODY"))

	pos := 0
	h1, p1, c1, e1 := frame_decode(buf[pos:])
	testing.expect_value(t, e1, Frame_Error.None)
	testing.expect_value(t, h1.ftype, u64(FRAME_HEADERS))
	testing.expect_value(t, string(p1), "HDR")
	pos += c1

	h2, p2, c2, e2 := frame_decode(buf[pos:])
	testing.expect_value(t, e2, Frame_Error.None)
	testing.expect_value(t, h2.ftype, u64(FRAME_DATA))
	testing.expect_value(t, string(p2), "BODY")
	pos += c2
	testing.expect_value(t, pos, len(buf))
}

@(test)
test_frame_incomplete :: proc(t: ^testing.T) {
	buf: [dynamic]u8
	defer delete(buf)
	frame_write_data(&buf, transmute([]u8)string("hello"))
	// Truncate mid-payload — the whole frame isn't present.
	_, _, _, err := frame_decode(buf[:4])
	testing.expect_value(t, err, Frame_Error.Incomplete)
	// Truncate mid-header (only the type byte).
	_, _, _, err2 := frame_decode(buf[:1])
	testing.expect_value(t, err2, Frame_Error.Incomplete)
}

@(test)
test_frame_length_overflow :: proc(t: ^testing.T) {
	// Hand-build a header advertising a payload of 16 bytes, with a 8-byte cap.
	buf: [dynamic]u8
	defer delete(buf)
	put_varint(&buf, FRAME_DATA)
	put_varint(&buf, 16)
	_, _, _, err := frame_decode(buf[:], max_len = 8)
	testing.expect_value(t, err, Frame_Error.Too_Large)
}
