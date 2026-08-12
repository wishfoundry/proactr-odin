// Package h3 implements the HTTP/3 application layer (RFC 9114) on top of the
// QUIC transport (`quic`), the stream facade (`webstream`), and QPACK (`qpack`).
package http3

// Frame decode errors (local; vapor used shared Frame_Error).
Frame_Error :: enum {
	None,
	Incomplete, // whole frame not buffered yet — read more bytes
	Malformed,  // structurally invalid
	Too_Large,  // advertised length exceeds allowed maximum
}


import "../quic"

// Frame types (RFC 9114 §7.2). Types are varints and may carry reserved/GREASE
// values, so the decoder returns a raw u64; these name the ones we handle.
FRAME_DATA         :: 0x00
FRAME_HEADERS      :: 0x01
FRAME_CANCEL_PUSH  :: 0x03
FRAME_SETTINGS     :: 0x04
FRAME_PUSH_PROMISE :: 0x05
FRAME_GOAWAY       :: 0x07
FRAME_MAX_PUSH_ID  :: 0x0d

// Unidirectional stream types (RFC 9114 §6.2 / §4.2 QPACK).
STREAM_TYPE_CONTROL       :: 0x00
STREAM_TYPE_PUSH          :: 0x01
STREAM_TYPE_QPACK_ENCODER :: 0x02
STREAM_TYPE_QPACK_DECODER :: 0x03

// SETTINGS identifiers (RFC 9114 §7.2.4.1 / RFC 9204 §5).
SETTINGS_QPACK_MAX_TABLE_CAPACITY :: 0x01
SETTINGS_MAX_FIELD_SECTION_SIZE   :: 0x06
SETTINGS_QPACK_BLOCKED_STREAMS    :: 0x07

// Sanity bound on a single frame's payload (DoS guard against a huge advertised
// Length). Callers may override per call.
DEFAULT_MAX_FRAME_LEN :: u64(1) << 20

Frame_Header :: struct {
	ftype:  u64,
	length: u64,
}

// Default SETTINGS for new connections: non-zero decoder table capacity so
// peers may use dynamic QPACK against us. Our encoder also uses dynamic inserts
// when the peer advertises capacity > 0 (see http3 connection).
// Zero capacity still means static-only (frame tests use Settings{} explicitly).
DEFAULT_QPACK_MAX_TABLE_CAPACITY :: u64(4096)

DEFAULT_SETTINGS :: Settings {
	qpack_max_table_capacity = DEFAULT_QPACK_MAX_TABLE_CAPACITY,
	qpack_blocked_streams    = 0, // no blocked-stream buffering
	max_field_section_size   = 0,
}

Settings :: struct {
	qpack_max_table_capacity: u64, // 0x01 — decoder table capacity we accept
	qpack_blocked_streams:    u64, // 0x07 — 0 = we never block on inserts
	max_field_section_size:   u64, // 0x06 — 0 = absent/unlimited
}

@(private)
put_varint :: proc(dst: ^[dynamic]u8, v: u64) {
	start := len(dst^)
	resize(dst, start + quic.varint_len(v))
	quic.varint_encode((dst^)[start:], v)
}


// Write a frame with an explicit type and pre-built payload.
frame_write :: proc(dst: ^[dynamic]u8, ftype: u64, payload: []u8) {
	put_varint(dst, ftype)
	put_varint(dst, u64(len(payload)))
	append(dst, ..payload)
}

frame_write_data :: proc(dst: ^[dynamic]u8, data: []u8) {
	frame_write(dst, FRAME_DATA, data)
}

// `qpack_block` is a QPACK-encoded field section (see package qpack).
frame_write_headers :: proc(dst: ^[dynamic]u8, qpack_block: []u8) {
	frame_write(dst, FRAME_HEADERS, qpack_block)
}

frame_write_settings :: proc(dst: ^[dynamic]u8, s: Settings) {
	// Always advertise QPACK capacity + blocked-streams (0 is meaningful:
	// static-only). max_field_section_size is omitted when 0 (0 would mean
	// "reject everything", not "unlimited").
	pairs: [3][2]u64
	n := 0
	pairs[n] = {SETTINGS_QPACK_MAX_TABLE_CAPACITY, s.qpack_max_table_capacity}; n += 1
	pairs[n] = {SETTINGS_QPACK_BLOCKED_STREAMS, s.qpack_blocked_streams};       n += 1
	if s.max_field_section_size > 0 {
		pairs[n] = {SETTINGS_MAX_FIELD_SECTION_SIZE, s.max_field_section_size}; n += 1
	}

	plen := 0
	for i in 0 ..< n do plen += quic.varint_len(pairs[i][0]) + quic.varint_len(pairs[i][1])

	put_varint(dst, FRAME_SETTINGS)
	put_varint(dst, u64(plen))
	for i in 0 ..< n {
		put_varint(dst, pairs[i][0])
		put_varint(dst, pairs[i][1])
	}
}

frame_write_goaway :: proc(dst: ^[dynamic]u8, id: u64) {
	put_varint(dst, FRAME_GOAWAY)
	put_varint(dst, u64(quic.varint_len(id)))
	put_varint(dst, id)
}

// Write a unidirectional stream's leading type varint (RFC 9114 §6.2).
stream_type_write :: proc(dst: ^[dynamic]u8, stype: u64) {
	put_varint(dst, stype)
}


// Decode just the Type+Length header. .Incomplete if the header bytes aren't
// all present yet.
frame_decode_header :: proc(buf: []u8) -> (h: Frame_Header, consumed: int, err: Frame_Error) {
	ftype, n1, ok1 := quic.varint_decode(buf)
	if !ok1 do return {}, 0, .Incomplete
	length, n2, ok2 := quic.varint_decode(buf[n1:])
	if !ok2 do return {}, 0, .Incomplete
	return Frame_Header{ftype, length}, n1 + n2, .None
}

// Decode a complete frame. `payload` is a slice INTO `buf` (no copy); `consumed`
// is the total frame size. .Incomplete when the full frame isn't buffered yet,
// so a stream reader can accumulate and retry.
frame_decode :: proc(
	buf: []u8, max_len := DEFAULT_MAX_FRAME_LEN,
) -> (h: Frame_Header, payload: []u8, consumed: int, err: Frame_Error) {
	hdr, hn := frame_decode_header(buf) or_return
	if hdr.length > max_len do return hdr, nil, 0, .Too_Large
	total := hn + int(hdr.length)
	if total > len(buf) do return hdr, nil, 0, .Incomplete
	return hdr, buf[hn:total], total, .None
}

// Parse a SETTINGS frame payload into known settings; unknown ids (incl GREASE)
// are ignored per RFC 9114 §7.2.4.1.
settings_decode :: proc(payload: []u8) -> (s: Settings, err: Frame_Error) {
	pos := 0
	for pos < len(payload) {
		id, n1, ok1 := quic.varint_decode(payload[pos:])
		if !ok1 do return {}, .Malformed
		pos += n1
		val, n2, ok2 := quic.varint_decode(payload[pos:])
		if !ok2 do return {}, .Malformed
		pos += n2
		switch id {
		case SETTINGS_QPACK_MAX_TABLE_CAPACITY: s.qpack_max_table_capacity = val
		case SETTINGS_QPACK_BLOCKED_STREAMS:    s.qpack_blocked_streams = val
		case SETTINGS_MAX_FIELD_SECTION_SIZE:   s.max_field_section_size = val
		}
	}
	return s, .None
}

// Parse a GOAWAY frame payload (a single varint id).
goaway_decode :: proc(payload: []u8) -> (id: u64, err: Frame_Error) {
	v, _, ok := quic.varint_decode(payload)
	if !ok do return 0, .Malformed
	return v, .None
}
