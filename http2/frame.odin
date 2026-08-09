// HTTP/2 framing (RFC 9113 §4–§6). Fixed 9-byte frame header followed by a
// type-specific payload, all big-endian:
//
//   Length(24) Type(8) Flags(8) R(1)+StreamID(31)  Payload(Length)
//
// Sans-I/O: encode/decode only; no sockets, TLS, or host wiring.
package http2

// Client connection preface (RFC 9113 §3.4) — sent before the first SETTINGS.
CLIENT_PREFACE :: "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"

FRAME_HEADER_LEN       :: 9
DEFAULT_MAX_FRAME_SIZE :: 16384

// Frame types (§6).
FRAME_DATA          :: u8(0x0)
FRAME_HEADERS       :: u8(0x1)
FRAME_PRIORITY      :: u8(0x2)
FRAME_RST_STREAM    :: u8(0x3)
FRAME_SETTINGS      :: u8(0x4)
FRAME_PUSH_PROMISE  :: u8(0x5)
FRAME_PING          :: u8(0x6)
FRAME_GOAWAY        :: u8(0x7)
FRAME_WINDOW_UPDATE :: u8(0x8)
FRAME_CONTINUATION  :: u8(0x9)

// Flags (meaning depends on frame type).
FLAG_ACK         :: u8(0x1) // SETTINGS, PING
FLAG_END_STREAM  :: u8(0x1) // DATA, HEADERS
FLAG_END_HEADERS :: u8(0x4) // HEADERS, CONTINUATION, PUSH_PROMISE
FLAG_PADDED      :: u8(0x8) // DATA, HEADERS, PUSH_PROMISE
FLAG_PRIORITY    :: u8(0x20) // HEADERS

Frame_Header :: struct {
	length:    u32,
	type:      u8,
	flags:     u8,
	stream_id: u32,
}

@(private)
put_u24 :: proc(dst: ^[dynamic]u8, v: u32) {
	append(dst, u8(v >> 16), u8(v >> 8), u8(v))
}

@(private)
put_u32 :: proc(dst: ^[dynamic]u8, v: u32) {
	append(dst, u8(v >> 24), u8(v >> 16), u8(v >> 8), u8(v))
}

@(private)
get_u32 :: proc(b: []u8) -> u32 {
	return u32(b[0]) << 24 | u32(b[1]) << 16 | u32(b[2]) << 8 | u32(b[3])
}

// Write a complete frame: header + payload.
frame_write :: proc(dst: ^[dynamic]u8, type, flags: u8, stream_id: u32, payload: []u8) {
	put_u24(dst, u32(len(payload)))
	append(dst, type, flags)
	put_u32(dst, stream_id & 0x7fff_ffff)
	append(dst, ..payload)
}

// Decode one complete frame. `payload` is a slice into `buf`; `consumed` is the
// total frame size. .Incomplete if the whole frame isn't buffered yet.
frame_decode :: proc(
	buf: []u8, max_frame := u32(DEFAULT_MAX_FRAME_SIZE),
) -> (h: Frame_Header, payload: []u8, consumed: int, err: Frame_Error) {
	if len(buf) < FRAME_HEADER_LEN do return {}, nil, 0, .Incomplete
	length := u32(buf[0]) << 16 | u32(buf[1]) << 8 | u32(buf[2])
	h = Frame_Header {
		length    = length,
		type      = buf[3],
		flags     = buf[4],
		stream_id = get_u32(buf[5:9]) & 0x7fff_ffff,
	}
	if length > max_frame do return h, nil, 0, .Too_Large
	total := FRAME_HEADER_LEN + int(length)
	if total > len(buf) do return h, nil, 0, .Incomplete
	return h, buf[FRAME_HEADER_LEN:total], total, .None
}

// ---- SETTINGS (§6.5) -------------------------------------------------------

// Build a SETTINGS frame advertising the values we care to change from default.
settings_write :: proc(dst: ^[dynamic]u8, s: Settings) {
	payload: [dynamic]u8
	payload.allocator = context.temp_allocator
	// Advertise our decoder table capacity so peer encoder stays within limit.
	put_setting(&payload, SETTINGS_HEADER_TABLE_SIZE, s.header_table_size)
	put_setting(&payload, SETTINGS_INITIAL_WINDOW_SIZE, s.initial_window_size)
	put_setting(&payload, SETTINGS_MAX_FRAME_SIZE, s.max_frame_size)
	if s.max_concurrent_streams > 0 {
		put_setting(&payload, SETTINGS_MAX_CONCURRENT_STREAMS, s.max_concurrent_streams)
	}
	put_setting(&payload, SETTINGS_ENABLE_PUSH, s.enable_push)
	if s.max_header_list_size > 0 {
		put_setting(&payload, SETTINGS_MAX_HEADER_LIST_SIZE, s.max_header_list_size)
	}
	frame_write(dst, FRAME_SETTINGS, 0, 0, payload[:])
}

settings_write_ack :: proc(dst: ^[dynamic]u8) {
	frame_write(dst, FRAME_SETTINGS, FLAG_ACK, 0, nil)
}

@(private)
put_setting :: proc(dst: ^[dynamic]u8, id: u16, val: u32) {
	append(dst, u8(id >> 8), u8(id))
	put_u32(dst, val)
}

// Parse a SETTINGS payload (sequence of 6-byte id+value pairs). Unknown ids are
// ignored per §6.5.2. `s` should start from the peer's current/known settings.
settings_decode :: proc(payload: []u8, s: ^Settings) -> Frame_Error {
	if len(payload) % 6 != 0 do return .Malformed
	for i := 0; i < len(payload); i += 6 {
		id := u16(payload[i]) << 8 | u16(payload[i + 1])
		val := get_u32(payload[i + 2:i + 6])
		switch id {
		case SETTINGS_HEADER_TABLE_SIZE:      s.header_table_size = val
		case SETTINGS_ENABLE_PUSH:            s.enable_push = val
		case SETTINGS_MAX_CONCURRENT_STREAMS: s.max_concurrent_streams = val
		case SETTINGS_INITIAL_WINDOW_SIZE:    s.initial_window_size = val
		case SETTINGS_MAX_FRAME_SIZE:         s.max_frame_size = val
		case SETTINGS_MAX_HEADER_LIST_SIZE:   s.max_header_list_size = val
		}
	}
	return .None
}

// ---- RST_STREAM (§6.4) -------------------------------------------------------

rst_stream_write :: proc(dst: ^[dynamic]u8, stream_id: u32, error_code: u32) {
	payload: [4]u8
	payload[0] = u8(error_code >> 24)
	payload[1] = u8(error_code >> 16)
	payload[2] = u8(error_code >> 8)
	payload[3] = u8(error_code)
	frame_write(dst, FRAME_RST_STREAM, 0, stream_id, payload[:])
}

// ---- GOAWAY (§6.8) ----------------------------------------------------------

// Graceful shutdown: streams at or below `last_sid` were (or will be)
// processed; everything above was not.
goaway_write :: proc(dst: ^[dynamic]u8, last_sid: u32, error_code: u32) {
	payload: [8]u8
	payload[0] = u8(last_sid >> 24) & 0x7f
	payload[1] = u8(last_sid >> 16)
	payload[2] = u8(last_sid >> 8)
	payload[3] = u8(last_sid)
	payload[4] = u8(error_code >> 24)
	payload[5] = u8(error_code >> 16)
	payload[6] = u8(error_code >> 8)
	payload[7] = u8(error_code)
	frame_write(dst, FRAME_GOAWAY, 0, 0, payload[:])
}

// ---- WINDOW_UPDATE (§6.9) --------------------------------------------------

window_update_write :: proc(dst: ^[dynamic]u8, stream_id: u32, increment: u32) {
	payload: [4]u8
	payload[0] = u8(increment >> 24) & 0x7f
	payload[1] = u8(increment >> 16)
	payload[2] = u8(increment >> 8)
	payload[3] = u8(increment)
	frame_write(dst, FRAME_WINDOW_UPDATE, 0, stream_id, payload[:])
}
