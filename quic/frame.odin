package quic

// RFC 9000 §19 — QUIC frame encoding
// Frame types this package decodes:
//   0x00  PADDING             — fills remaining packet space
//   0x01  PING                — keepalive / ACK elicit
//   0x02  ACK                 — acknowledgement (no ECN)
//   0x04  RESET_STREAM        — abruptly terminate the send side of a stream
//   0x05  STOP_SENDING        — request peer to stop sending on a stream
//   0x06  CRYPTO              — TLS handshake bytes
//   0x08-0x0f  STREAM*        — RFC 9000 §19.8, STREAM frame family (8 variants)
//   0x10  MAX_DATA            — connection-level flow control credit
//   0x11  MAX_STREAM_DATA     — per-stream flow control credit
//   0x12-0x13  MAX_STREAMS_*  — stream-count limits (parse-and-ignore)
//   0x14  DATA_BLOCKED        — parse-and-ignore (diagnostic)
//   0x15  STREAM_DATA_BLOCKED — parse-and-ignore
//   0x16-0x17  STREAMS_BLOCKED_* — parse-and-ignore
//   0x1c  CONNECTION_CLOSE    — transport-level close
//   0x1d  CONNECTION_CLOSE_APP — application-level close
//   0x1e  HANDSHAKE_DONE      — parse-and-ignore (server->client, post handshake)
//   0x30-0x31  DATAGRAM       — RFC 9221, unreliable datagrams
// Frame types we still don't handle (parse as Unknown_Type):
//   0x03 ACK(ECN), 0x07 NEW_TOKEN, 0x18-0x19 NEW/RETIRE_CONNECTION_ID,
//   0x1a-0x1b PATH_CHALLENGE/RESPONSE.

Frame_Type :: enum u8 {
	Padding              = 0x00,
	Ping                 = 0x01,
	Ack                  = 0x02,
	Ack_Ecn              = 0x03,
	Reset_Stream         = 0x04,
	Stop_Sending         = 0x05,
	Crypto               = 0x06,
	New_Token            = 0x07,
	// STREAM base type — actual types are 0x08..0x0f based on FIN/LEN/OFF flags
	Stream_Base          = 0x08,
	Max_Data             = 0x10,
	Max_Stream_Data      = 0x11,
	Max_Streams_Bidi     = 0x12,
	Max_Streams_Uni      = 0x13,
	Data_Blocked         = 0x14,
	Stream_Data_Blocked  = 0x15,
	Streams_Blocked_Bidi = 0x16,
	Streams_Blocked_Uni  = 0x17,
	New_Connection_Id    = 0x18,
	Retire_Connection_Id = 0x19,
	Connection_Close     = 0x1c,
	Connection_Close_App = 0x1d,
	Handshake_Done       = 0x1e,
	Datagram             = 0x30,
	Datagram_Len         = 0x31,
}

Frame_Error :: enum {
	None,
	Truncated,
	Unknown_Type,
	Invalid_Range_Count,
}

// --- Decoded frame views (zero-copy where possible) ---

Crypto_Frame :: struct {
	offset: u64,
	data:   []u8, // slice into the caller's buffer
}

Ack_Range :: struct {
	gap:           u64, // packets between previous block and this one
	ack_range_len: u64, // number of packets in this block
}

Ack_Frame :: struct {
	largest_acknowledged: u64,
	ack_delay:            u64, // in microseconds after scaling
	first_ack_range:      u64,
	ack_range_count:      u64,
	// Decoded inclusive [lowest, highest] packet-number ranges that this ACK
	// covers, ascending. Built by frame_decode from largest_acknowledged +
	// first_ack_range + the (gap, range) pairs. Capped at MAX_ACK_RANGES;
	// overflow drops the LOWEST ranges (rare and least useful for loss
	// detection, which cares about the high end).
	ranges:     [MAX_ACK_RANGES][2]u64,
	range_count: int,
}

// Max ACK ranges we decode. Loss detection cares about the high end
// (largest acked → threshold loss below it), so 16 is plenty.
MAX_ACK_RANGES :: 16

Connection_Close_Frame :: struct {
	error_code:  u64,
	frame_type:  u64,   // 0 when type was Connection_Close_App
	is_app:      bool,
	reason:      []u8,  // slice into caller's buffer
}

Datagram_Frame :: struct {
	data: []u8, // slice into caller's buffer
}

// --- Decoded frame union ---

Frame :: union {
	Padding_Frame,
	Ping_Frame,
	Ack_Frame,
	Crypto_Frame,
	Connection_Close_Frame,
	Datagram_Frame,
	Stream_Frame,            // STREAM family (0x08..0x0f) — see frame_stream.odin
	Max_Stream_Data_Frame,   // 0x11 — flow control credit update
	Max_Data_Frame,          // 0x10 — connection-level flow control credit
	Reset_Stream_Frame,      // 0x04 — peer reset its send half of a stream
	Stop_Sending_Frame,      // 0x05 — peer wants us to stop sending on a stream
	Max_Streams_Frame,       // 0x12 / 0x13 — peer raised the cap on streams we can open
	Handshake_Done_Frame,    // 0x1e — server signals handshake is confirmed
	Unhandled_Frame,         // catch-all for types we parse-and-ignore
}

Handshake_Done_Frame :: struct{}

// MAX_STREAMS (RFC 9000 §19.11). `is_uni` distinguishes the two type
// codes (0x13 = uni, 0x12 = bidi). `max_count` is the new absolute cap
// on the stream-count we can open.
Max_Streams_Frame :: struct {
	is_uni:    bool,
	max_count: u64,
}

// Placeholder for frames we recognize but don't act on (MAX_STREAMS, DATA_BLOCKED, etc.)
Unhandled_Frame :: struct {
	type_byte: u8,
}

Padding_Frame :: struct {
	// Padding frames have no fields; this just marks the variant.
	// Consecutive padding bytes are coalesced into a single decoded frame
	// to avoid N allocations when a packet contains padding.
	count: int,
}

Ping_Frame :: struct{}

// --- Decode one frame from buf. Returns (frame, bytes_consumed, error).

frame_decode :: proc(buf: []u8) -> (frame: Frame, n: int, err: Frame_Error) {
	if len(buf) == 0 do return nil, 0, .Truncated

	// The frame type is a varint, but in practice all types we handle fit
	// in one byte. Read as varint to be spec-correct.
	type_v, type_n, type_ok := varint_decode(buf)
	if !type_ok do return nil, 0, .Truncated
	pos := type_n

	// STREAM family (0x08..0x0f) — matches before the named-type switch
	// because these 8 byte values aren't individual enum entries.
	if type_v >= 0x08 && type_v <= 0x0f {
		sf, sn, sok := decode_stream_frame(u8(type_v), buf[pos:])
		if !sok do return nil, 0, .Truncated
		return sf, pos + sn, .None
	}

	switch Frame_Type(type_v) {
	case .Padding:
		// Consecutive PADDING bytes coalesce. Most implementations emit
		// runs of 0x00 to pad packets to the minimum size.
		pad := Padding_Frame{count = 1}
		for pos < len(buf) && buf[pos] == 0x00 {
			pad.count += 1
			pos += 1
		}
		return pad, pos, .None

	case .Ping:
		return Ping_Frame{}, pos, .None

	case .Ack, .Ack_Ecn:
		largest, ln, lok := varint_decode(buf[pos:])
		if !lok do return nil, 0, .Truncated
		pos += ln

		delay, dn, dok := varint_decode(buf[pos:])
		if !dok do return nil, 0, .Truncated
		pos += dn

		range_count, rn, rok := varint_decode(buf[pos:])
		if !rok do return nil, 0, .Truncated
		pos += rn

		first_range, fn_, fok := varint_decode(buf[pos:])
		if !fok do return nil, 0, .Truncated
		pos += fn_

		// Build the inclusive [low, high] ranges covered by this ACK, walking
		// DOWNWARD from largest_acknowledged. first_ack_range is the count of
		// acknowledged packets immediately below `largest`; each subsequent
		// (gap, range) pair skips `gap+1` missing packets then covers `range+1`.
		ackf := Ack_Frame{
			largest_acknowledged = largest,
			ack_delay            = delay,
			ack_range_count      = range_count,
			first_ack_range      = first_range,
		}
		high := largest
		low := largest - first_range
		ackf.ranges[0] = {low, high}
		ackf.range_count = 1
		for _ in u64(0) ..< range_count {
			gap, gn, gok := varint_decode(buf[pos:])
			if !gok do return nil, 0, .Truncated
			pos += gn
			rng, rngn, rngok := varint_decode(buf[pos:])
			if !rngok do return nil, 0, .Truncated
			pos += rngn
			high = low - gap - 2
			low = high - rng
			if ackf.range_count < MAX_ACK_RANGES {
				ackf.ranges[ackf.range_count] = {low, high}
				ackf.range_count += 1
			}
		}

		// Skip ECN counts if present.
		if Frame_Type(type_v) == .Ack_Ecn {
			for _ in 0..<3 {
				_, en, eok := varint_decode(buf[pos:])
				if !eok do return nil, 0, .Truncated
				pos += en
			}
		}

		return ackf, pos, .None

	case .Crypto:
		offset, on, ook := varint_decode(buf[pos:])
		if !ook do return nil, 0, .Truncated
		pos += on

		length, ln, lok := varint_decode(buf[pos:])
		if !lok do return nil, 0, .Truncated
		pos += ln

		if pos + int(length) > len(buf) do return nil, 0, .Truncated
		data := buf[pos : pos + int(length)]
		pos += int(length)

		return Crypto_Frame{offset = offset, data = data}, pos, .None

	case .Connection_Close, .Connection_Close_App:
		is_app := Frame_Type(type_v) == .Connection_Close_App

		err_code, ecn, eok := varint_decode(buf[pos:])
		if !eok do return nil, 0, .Truncated
		pos += ecn

		frame_type: u64 = 0
		if !is_app {
			ft, ftn, ftok := varint_decode(buf[pos:])
			if !ftok do return nil, 0, .Truncated
			frame_type = ft
			pos += ftn
		}

		reason_len, rln, rlok := varint_decode(buf[pos:])
		if !rlok do return nil, 0, .Truncated
		pos += rln

		if pos + int(reason_len) > len(buf) do return nil, 0, .Truncated
		reason := buf[pos : pos + int(reason_len)]
		pos += int(reason_len)

		return Connection_Close_Frame{
			error_code = err_code,
			frame_type = frame_type,
			is_app     = is_app,
			reason     = reason,
		}, pos, .None

	case .Datagram:
		// No length — datagram extends to end of buffer.
		return Datagram_Frame{data = buf[pos:]}, len(buf), .None

	case .Datagram_Len:
		length, ln, lok := varint_decode(buf[pos:])
		if !lok do return nil, 0, .Truncated
		pos += ln

		if pos + int(length) > len(buf) do return nil, 0, .Truncated
		return Datagram_Frame{data = buf[pos : pos + int(length)]}, pos + int(length), .None

	case .Max_Stream_Data:
		f, mn, mok := decode_max_stream_data(buf[pos:])
		if !mok do return nil, 0, .Truncated
		return f, pos + mn, .None

	case .Max_Data:
		f, mn, mok := decode_max_data(buf[pos:])
		if !mok do return nil, 0, .Truncated
		return f, pos + mn, .None

	case .Reset_Stream:
		f, rn, rok := decode_reset_stream(buf[pos:])
		if !rok do return nil, 0, .Truncated
		return f, pos + rn, .None

	case .Stop_Sending:
		f, sn, sok := decode_stop_sending(buf[pos:])
		if !sok do return nil, 0, .Truncated
		return f, pos + sn, .None

	case .New_Token:
		// NEW_TOKEN: token_length(varint) + token(token_length bytes).
		tl, tln, tlok := varint_decode(buf[pos:])
		if !tlok do return nil, 0, .Truncated
		pos += tln
		if pos + int(tl) > len(buf) do return nil, 0, .Truncated
		pos += int(tl)
		return Unhandled_Frame{type_byte = 0x07}, pos, .None

	case .Handshake_Done:
		return Handshake_Done_Frame{}, pos, .None

	case .New_Connection_Id:
		// NEW_CONNECTION_ID: seq(varint) + retire_prior_to(varint) +
		// length(1 byte) + connection_id(length bytes) + reset_token(16 bytes).
		// Parse-and-ignore — we use the original CIDs for the session lifetime.
		seq_n: int; seq_ok: bool
		_, seq_n, seq_ok = varint_decode(buf[pos:])
		if !seq_ok do return nil, 0, .Truncated
		pos += seq_n
		rpt_n: int; rpt_ok: bool
		_, rpt_n, rpt_ok = varint_decode(buf[pos:])
		if !rpt_ok do return nil, 0, .Truncated
		pos += rpt_n
		if pos >= len(buf) do return nil, 0, .Truncated
		cid_len := int(buf[pos]); pos += 1
		if pos + cid_len + 16 > len(buf) do return nil, 0, .Truncated
		pos += cid_len + 16 // skip CID + stateless_reset_token
		return Unhandled_Frame{type_byte = 0x18}, pos, .None

	case .Retire_Connection_Id:
		// RETIRE_CONNECTION_ID: seq(varint). Parse-and-ignore.
		_, rn, rok := varint_decode(buf[pos:])
		if !rok do return nil, 0, .Truncated
		return Unhandled_Frame{type_byte = 0x19}, pos + rn, .None

	case .Max_Streams_Bidi, .Max_Streams_Uni:
		mx, mn, mok := varint_decode(buf[pos:])
		if !mok do return nil, 0, .Truncated
		return Max_Streams_Frame{is_uni = Frame_Type(type_v) == .Max_Streams_Uni, max_count = mx}, pos + mn, .None

	case .Data_Blocked, .Streams_Blocked_Bidi, .Streams_Blocked_Uni:
		sn, sok := decode_skip_one_varint(buf[pos:])
		if !sok do return nil, 0, .Truncated
		return Unhandled_Frame{type_byte = u8(type_v)}, pos + sn, .None

	case .Stream_Data_Blocked:
		sn, sok := decode_skip_two_varints(buf[pos:])
		if !sok do return nil, 0, .Truncated
		return Unhandled_Frame{type_byte = u8(type_v)}, pos + sn, .None

	case .Stream_Base:
		// Individual STREAM variants 0x08..0x0f are handled above the switch.
		// Bare 0x08 (no OFF, no LEN, no FIN) is a STREAM frame too — route it.
		sf, sn, sok := decode_stream_frame(u8(type_v), buf[pos:])
		if !sok do return nil, 0, .Truncated
		return sf, pos + sn, .None
	}

	return nil, 0, .Unknown_Type
}

// --- Encoders. Each returns bytes written, or -1 on buffer overflow. ---

encode_padding :: proc(buf: []u8, count: int) -> int {
	if len(buf) < count do return -1
	for i in 0..<count do buf[i] = 0x00
	return count
}

encode_ping :: proc(buf: []u8) -> int {
	if len(buf) < 1 do return -1
	buf[0] = u8(Frame_Type.Ping)
	return 1
}

// Encode a single-range ACK frame (no ECN, no additional ranges).
// This is the simplest form: acknowledge `largest`, going back `first_ack_range` packets.
encode_ack_simple :: proc(buf: []u8, largest: u64, ack_delay: u64, first_ack_range: u64) -> int {
	n := 0
	if n >= len(buf) do return -1
	buf[n] = u8(Frame_Type.Ack)
	n += 1

	w := varint_encode(buf[n:], largest);         if w < 0 do return -1; n += w
	w  = varint_encode(buf[n:], ack_delay);       if w < 0 do return -1; n += w
	w  = varint_encode(buf[n:], 0);               if w < 0 do return -1; n += w // ack_range_count
	w  = varint_encode(buf[n:], first_ack_range); if w < 0 do return -1; n += w
	return n
}

// Encode an ACK frame covering EVERYTHING the space has received, as
// [gap, range] pairs descending from the largest (RFC 9000 §19.3). Use this —
// not encode_ack_simple — on live connections: acking only the largest packet
// makes a real peer treat every burst as lost and retransmit it.
encode_ack_from_space :: proc(buf: []u8, s: ^Pn_Space, ack_delay: u64) -> int {
	if s.rx_range_count == 0 {
		return encode_ack_simple(buf, s.largest_rx_pn, ack_delay, 0)
	}
	n := 0
	if n >= len(buf) do return -1
	buf[n] = u8(Frame_Type.Ack)
	n += 1

	top := s.rx_ranges[s.rx_range_count - 1]
	w := varint_encode(buf[n:], top[1]);                    if w < 0 do return -1; n += w // largest
	w  = varint_encode(buf[n:], ack_delay);                 if w < 0 do return -1; n += w
	w  = varint_encode(buf[n:], u64(s.rx_range_count - 1)); if w < 0 do return -1; n += w
	w  = varint_encode(buf[n:], top[1] - top[0]);           if w < 0 do return -1; n += w // first range

	prev_smallest := top[0]
	for i := s.rx_range_count - 2; i >= 0; i -= 1 {
		r := s.rx_ranges[i]
		w = varint_encode(buf[n:], prev_smallest - r[1] - 2); if w < 0 do return -1; n += w // gap
		w = varint_encode(buf[n:], r[1] - r[0]);              if w < 0 do return -1; n += w // range len
		prev_smallest = r[0]
	}
	return n
}

encode_crypto :: proc(buf: []u8, offset: u64, data: []u8) -> int {
	n := 0
	if n >= len(buf) do return -1
	buf[n] = u8(Frame_Type.Crypto)
	n += 1

	w := varint_encode(buf[n:], offset);        if w < 0 do return -1; n += w
	w  = varint_encode(buf[n:], u64(len(data)));if w < 0 do return -1; n += w
	if n + len(data) > len(buf) do return -1
	copy(buf[n:], data)
	return n + len(data)
}

encode_connection_close :: proc(buf: []u8, error_code: u64, frame_type: u64, reason: []u8) -> int {
	n := 0
	if n >= len(buf) do return -1
	buf[n] = u8(Frame_Type.Connection_Close)
	n += 1

	w := varint_encode(buf[n:], error_code);        if w < 0 do return -1; n += w
	w  = varint_encode(buf[n:], frame_type);        if w < 0 do return -1; n += w
	w  = varint_encode(buf[n:], u64(len(reason)));  if w < 0 do return -1; n += w
	if n + len(reason) > len(buf) do return -1
	copy(buf[n:], reason)
	return n + len(reason)
}

// Encode a DATAGRAM frame with explicit length (type 0x31).
// We always use the length-prefixed form for simplicity; the peer must
// advertise max_datagram_frame_size > 0 in transport params.
encode_datagram :: proc(buf: []u8, data: []u8) -> int {
	n := 0
	if n >= len(buf) do return -1
	buf[n] = u8(Frame_Type.Datagram_Len)
	n += 1

	w := varint_encode(buf[n:], u64(len(data))); if w < 0 do return -1; n += w
	if n + len(data) > len(buf) do return -1
	copy(buf[n:], data)
	return n + len(data)
}
