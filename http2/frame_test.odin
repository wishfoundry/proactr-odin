package http2

import "core:slice"
import "core:testing"

@(test)
test_frame_header_wire :: proc(t: ^testing.T) {
	// HEADERS frame, END_STREAM|END_HEADERS, stream 1, payload "abc".
	buf: [dynamic]u8
	defer delete(buf)
	frame_write(&buf, FRAME_HEADERS, FLAG_END_STREAM | FLAG_END_HEADERS, 1, transmute([]u8)string("abc"))
	// Length=3, Type=0x01, Flags=0x05, StreamID=1
	want := []u8{0, 0, 3, 0x01, 0x05, 0, 0, 0, 1, 'a', 'b', 'c'}
	testing.expect(t, slice.equal(buf[:], want), "HEADERS frame wire layout")

	h, payload, consumed, err := frame_decode(buf[:])
	testing.expect_value(t, err, Frame_Error.None)
	testing.expect_value(t, h.type, FRAME_HEADERS)
	testing.expect_value(t, h.flags, FLAG_END_STREAM | FLAG_END_HEADERS)
	testing.expect_value(t, h.stream_id, u32(1))
	testing.expect_value(t, h.length, u32(3))
	testing.expect_value(t, consumed, 12)
	testing.expect_value(t, string(payload), "abc")
}

@(test)
test_frame_incomplete :: proc(t: ^testing.T) {
	buf: [dynamic]u8
	defer delete(buf)
	frame_write(&buf, FRAME_DATA, 0, 1, transmute([]u8)string("hello"))
	_, _, _, e1 := frame_decode(buf[:5]) // mid-header
	testing.expect_value(t, e1, Frame_Error.Incomplete)
	_, _, _, e2 := frame_decode(buf[:10]) // header ok, payload short
	testing.expect_value(t, e2, Frame_Error.Incomplete)
}

@(test)
test_frame_too_large :: proc(t: ^testing.T) {
	// Craft a header claiming length > max_frame (16384 default).
	// Length = 20000 (0x4E20), type DATA, flags 0, stream 1.
	hdr := []u8{0x00, 0x4E, 0x20, FRAME_DATA, 0, 0, 0, 0, 1}
	_, _, _, err := frame_decode(hdr, 16384)
	testing.expect_value(t, err, Frame_Error.Too_Large)
}

@(test)
test_settings_roundtrip :: proc(t: ^testing.T) {
	in_s := default_settings()
	in_s.max_concurrent_streams = 100
	in_s.initial_window_size = 1 << 20

	buf: [dynamic]u8
	defer delete(buf)
	settings_write(&buf, in_s)

	h, payload, _, err := frame_decode(buf[:])
	testing.expect_value(t, err, Frame_Error.None)
	testing.expect_value(t, h.type, FRAME_SETTINGS)
	testing.expect_value(t, h.stream_id, u32(0))

	out := default_settings()
	testing.expect_value(t, settings_decode(payload, &out), Frame_Error.None)
	testing.expect_value(t, out.max_concurrent_streams, u32(100))
	testing.expect_value(t, out.initial_window_size, u32(1 << 20))
}

@(test)
test_settings_malformed :: proc(t: ^testing.T) {
	s := default_settings()
	testing.expect_value(t, settings_decode([]u8{0x00, 0x04, 0x00}, &s), Frame_Error.Malformed) // not a multiple of 6
}

@(test)
test_window_update :: proc(t: ^testing.T) {
	buf: [dynamic]u8
	defer delete(buf)
	window_update_write(&buf, 3, 65535)
	h, payload, _, err := frame_decode(buf[:])
	testing.expect_value(t, err, Frame_Error.None)
	testing.expect_value(t, h.type, FRAME_WINDOW_UPDATE)
	testing.expect_value(t, h.stream_id, u32(3))
	inc := get_u32(payload) & 0x7fff_ffff
	testing.expect_value(t, inc, u32(65535))
}

// Item 5: pre-reserve framed DATA capacity (payload + N×9 headers) in one grow.
@(test)
test_frame_dst_reserve_data :: proc(t: ^testing.T) {
	buf: [dynamic]u8
	defer delete(buf)
	// 100 bytes under max_frame=40 → 3 frames → 100 + 3*9 = 127.
	frame_dst_reserve_data(&buf, 100, 40)
	testing.expect(t, cap(buf) >= 127, "reserve covers payload + frame headers")
	// Writing must not reallocate (cap stable).
	c0 := cap(buf)
	p40: [40]u8
	p20: [20]u8
	frame_write(&buf, FRAME_DATA, 0, 1, p40[:])
	frame_write(&buf, FRAME_DATA, 0, 1, p40[:])
	frame_write(&buf, FRAME_DATA, FLAG_END_STREAM, 1, p20[:])
	testing.expect_value(t, cap(buf), c0)
	testing.expect_value(t, len(buf), 100 + 3*FRAME_HEADER_LEN)
}

@(test)
test_client_preface :: proc(t: ^testing.T) {
	// RFC 9113 §3.4 exact bytes.
	want := "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"
	testing.expect_value(t, CLIENT_PREFACE, want)
	testing.expect_value(t, len(CLIENT_PREFACE), 24)
}
