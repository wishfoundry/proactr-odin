package quic

// RFC 9000 §19.8 — STREAM frames
// RFC 9000 §19.9-§19.14 — flow control frames (MAX_DATA, MAX_STREAM_DATA,
//                         RESET_STREAM, STOP_SENDING, STREAMS_BLOCKED,
//                         DATA_BLOCKED, STREAM_DATA_BLOCKED)
// STREAM frame type byte layout (bits 0x08 | 0OLF):
//   bit 2 (0x04): OFF  — Offset field present when set
//   bit 1 (0x02): LEN  — Length field present when set
//   bit 0 (0x01): FIN  — Final byte of the stream when set
// The wire format is:
//   type (1 byte, 0x08..0x0f)
//   stream_id (varint)
//   [offset (varint)]  — present iff OFF
//   [length (varint)]  — present iff LEN; when absent, the frame extends to
//                        the end of the packet payload
//   data (length bytes, or rest of packet if LEN absent)
// We ship with LEN always set when encoding so callers don't have to track
// packet-boundary arithmetic. OFF is set whenever the offset is non-zero.

STREAM_FRAME_TYPE_BASE :: u8(0x08)
STREAM_FLAG_FIN  :: u8(0x01)
STREAM_FLAG_LEN  :: u8(0x02)
STREAM_FLAG_OFF  :: u8(0x04)

// Flow control frame types.
FRAME_TYPE_RESET_STREAM        :: u8(0x04)
FRAME_TYPE_STOP_SENDING        :: u8(0x05)
FRAME_TYPE_MAX_DATA            :: u8(0x10)
FRAME_TYPE_MAX_STREAM_DATA     :: u8(0x11)
FRAME_TYPE_MAX_STREAMS_BIDI    :: u8(0x12)
FRAME_TYPE_MAX_STREAMS_UNI     :: u8(0x13)
FRAME_TYPE_DATA_BLOCKED        :: u8(0x14)
FRAME_TYPE_STREAM_DATA_BLOCKED :: u8(0x15)
FRAME_TYPE_STREAMS_BLOCKED_BI  :: u8(0x16)
FRAME_TYPE_STREAMS_BLOCKED_UNI :: u8(0x17)

// --- Decoded STREAM frame view ---

Stream_Frame :: struct {
	stream_id: u64,
	offset:    u64,
	fin:       bool,
	data:      []u8, // slice into the caller's buffer, valid for the lifetime of the packet
}

// --- Decoded flow-control frame views ---

Max_Stream_Data_Frame :: struct {
	stream_id: u64,
	max_data:  u64,
}

Max_Data_Frame :: struct {
	max_data: u64,
}

Reset_Stream_Frame :: struct {
	stream_id:    u64,
	error_code:   u64,
	final_size:   u64,
}

Stop_Sending_Frame :: struct {
	stream_id:  u64,
	error_code: u64,
}

// --- Decoders ---

// Decode a STREAM frame. `type_byte` is the frame type (0x08..0x0f).
// `buf` starts at the byte immediately after the type byte.
// Returns the decoded frame and number of bytes consumed from `buf` (not
// including the type byte itself).
decode_stream_frame :: proc(type_byte: u8, buf: []u8) -> (frame: Stream_Frame, n: int, ok: bool) {
	pos := 0

	frame.fin = (type_byte & STREAM_FLAG_FIN) != 0
	has_len := (type_byte & STREAM_FLAG_LEN) != 0
	has_off := (type_byte & STREAM_FLAG_OFF) != 0

	id, id_n, id_ok := varint_decode(buf[pos:])
	if !id_ok do return {}, 0, false
	frame.stream_id = id
	pos += id_n

	if has_off {
		off, off_n, off_ok := varint_decode(buf[pos:])
		if !off_ok do return {}, 0, false
		frame.offset = off
		pos += off_n
	}

	if has_len {
		length, len_n, len_ok := varint_decode(buf[pos:])
		if !len_ok do return {}, 0, false
		pos += len_n
		if pos + int(length) > len(buf) do return {}, 0, false
		frame.data = buf[pos : pos + int(length)]
		pos += int(length)
	} else {
		// Implicit length: frame extends to the end of the packet.
		frame.data = buf[pos:]
		pos = len(buf)
	}

	return frame, pos, true
}

decode_max_stream_data :: proc(buf: []u8) -> (frame: Max_Stream_Data_Frame, n: int, ok: bool) {
	sid, sn, sok := varint_decode(buf)
	if !sok do return {}, 0, false
	md, mn, mok := varint_decode(buf[sn:])
	if !mok do return {}, 0, false
	return Max_Stream_Data_Frame{stream_id = sid, max_data = md}, sn + mn, true
}

decode_max_data :: proc(buf: []u8) -> (frame: Max_Data_Frame, n: int, ok: bool) {
	md, mn, mok := varint_decode(buf)
	if !mok do return {}, 0, false
	return Max_Data_Frame{max_data = md}, mn, true
}

decode_reset_stream :: proc(buf: []u8) -> (frame: Reset_Stream_Frame, n: int, ok: bool) {
	sid, sn, sok := varint_decode(buf)
	if !sok do return {}, 0, false
	pos := sn
	ec, en, eok := varint_decode(buf[pos:])
	if !eok do return {}, 0, false
	pos += en
	fs, fn, fok := varint_decode(buf[pos:])
	if !fok do return {}, 0, false
	pos += fn
	return Reset_Stream_Frame{stream_id = sid, error_code = ec, final_size = fs}, pos, true
}

decode_stop_sending :: proc(buf: []u8) -> (frame: Stop_Sending_Frame, n: int, ok: bool) {
	sid, sn, sok := varint_decode(buf)
	if !sok do return {}, 0, false
	pos := sn
	ec, en, eok := varint_decode(buf[pos:])
	if !eok do return {}, 0, false
	pos += en
	return Stop_Sending_Frame{stream_id = sid, error_code = ec}, pos, true
}

// Generic "skip one varint" helper for the frame types we parse-and-ignore
// (DATA_BLOCKED, STREAM_DATA_BLOCKED, STREAMS_BLOCKED, MAX_STREAMS).
// Each of these has a single varint field; consume it and move on.
decode_skip_one_varint :: proc(buf: []u8) -> (n: int, ok: bool) {
	_, vn, vok := varint_decode(buf)
	if !vok do return 0, false
	return vn, true
}

// STREAM_DATA_BLOCKED has two varints (stream_id + max_stream_data).
decode_skip_two_varints :: proc(buf: []u8) -> (n: int, ok: bool) {
	_, vn1, vok1 := varint_decode(buf)
	if !vok1 do return 0, false
	_, vn2, vok2 := varint_decode(buf[vn1:])
	if !vok2 do return 0, false
	return vn1 + vn2, true
}

// --- Encoders ---

// Encode a STREAM frame with the given stream_id, offset, and payload.
// Always uses LEN flag so callers don't need to know packet-boundary state.
// Sets OFF flag iff offset > 0. Sets FIN flag iff fin is true.
// Returns bytes written, or -1 on overflow.
encode_stream_frame :: proc(
	buf:       []u8,
	stream_id: u64,
	offset:    u64,
	data:      []u8,
	fin:       bool,
) -> int {
	type_byte := STREAM_FRAME_TYPE_BASE | STREAM_FLAG_LEN
	if offset > 0 do type_byte |= STREAM_FLAG_OFF
	if fin       do type_byte |= STREAM_FLAG_FIN

	n := 0
	if len(buf) < 1 do return -1
	buf[n] = type_byte
	n += 1

	w := varint_encode(buf[n:], stream_id)
	if w < 0 do return -1
	n += w

	if offset > 0 {
		w = varint_encode(buf[n:], offset)
		if w < 0 do return -1
		n += w
	}

	w = varint_encode(buf[n:], u64(len(data)))
	if w < 0 do return -1
	n += w

	if n + len(data) > len(buf) do return -1
	copy(buf[n:], data)
	return n + len(data)
}

encode_max_stream_data :: proc(buf: []u8, stream_id: u64, max_data: u64) -> int {
	n := 0
	if len(buf) < 1 do return -1
	buf[n] = FRAME_TYPE_MAX_STREAM_DATA
	n += 1
	w := varint_encode(buf[n:], stream_id); if w < 0 do return -1; n += w
	w  = varint_encode(buf[n:], max_data);  if w < 0 do return -1; n += w
	return n
}

encode_max_data :: proc(buf: []u8, max_data: u64) -> int {
	n := 0
	if len(buf) < 1 do return -1
	buf[n] = FRAME_TYPE_MAX_DATA
	n += 1
	w := varint_encode(buf[n:], max_data); if w < 0 do return -1; n += w
	return n
}

// Encode MAX_STREAMS for either bidi (0x12) or uni (0x13) — RFC 9000
// absolute cap on streams the peer is allowed to initiate.
encode_max_streams :: proc(buf: []u8, is_uni: bool, max_count: u64) -> int {
	n := 0
	if len(buf) < 1 do return -1
	buf[n] = FRAME_TYPE_MAX_STREAMS_UNI if is_uni else FRAME_TYPE_MAX_STREAMS_BIDI
	n += 1
	w := varint_encode(buf[n:], max_count); if w < 0 do return -1; n += w
	return n
}
