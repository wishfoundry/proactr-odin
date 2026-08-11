package quic

// RFC 9000 §18 — Transport parameter encoding
// RFC 9221 §3   — max_datagram_frame_size parameter
// Each parameter is encoded as three varints/bytes:
//   Transport Parameter {
//     Parameter ID (i),
//     Length (i),
//     Value (Length),
//   }
// Most parameter values are themselves varints, which means the wire encoding
// for a simple integer parameter is:
//   [id_varint] [length_varint = len(value_varint)] [value_varint]
// This file implements encode/decode for the subset of parameters we send
// and receive for the zenoh DATAGRAM bridge. Other parameters from the RFC
// are silently skipped on decode (per §18.1 "An endpoint that receives an
// unknown transport parameter ignores it").

// RFC 9000 §18.2 + RFC 9221 §3 — parameter IDs we care about.
TP_ORIGINAL_DESTINATION_CID    :: 0x00
TP_MAX_IDLE_TIMEOUT            :: 0x01
TP_STATELESS_RESET_TOKEN       :: 0x02
TP_MAX_UDP_PAYLOAD_SIZE        :: 0x03
TP_INITIAL_MAX_DATA            :: 0x04
TP_INITIAL_MAX_STREAM_DATA_BIDI_LOCAL  :: 0x05
TP_INITIAL_MAX_STREAM_DATA_BIDI_REMOTE :: 0x06
TP_INITIAL_MAX_STREAM_DATA_UNI :: 0x07
TP_INITIAL_MAX_STREAMS_BIDI    :: 0x08
TP_INITIAL_MAX_STREAMS_UNI     :: 0x09
TP_ACK_DELAY_EXPONENT          :: 0x0a
TP_MAX_ACK_DELAY               :: 0x0b
TP_DISABLE_ACTIVE_MIGRATION    :: 0x0c
TP_PREFERRED_ADDRESS           :: 0x0d
TP_ACTIVE_CONNECTION_ID_LIMIT  :: 0x0e
TP_INITIAL_SOURCE_CID          :: 0x0f
TP_RETRY_SOURCE_CID            :: 0x10
TP_MAX_DATAGRAM_FRAME_SIZE     :: 0x20 // RFC 9221

// Transport parameter set we advertise to the peer and receive from it.
// Fields use zero as "absent" sentinel for integer parameters (the peer
// default per RFC 9000 §18.2 is 0 or an explicit default that we accept).
Transport_Params :: struct {
	// Connection IDs (opaque byte sequences).
	initial_source_cid:     []u8,  // required when sending
	original_destination_cid: []u8, // server -> client only
	retry_source_cid:       []u8,  // server -> client only

	// Integer parameters (always varint-encoded on the wire).
	max_idle_timeout:                u64, // milliseconds; 0 = disabled
	max_udp_payload_size:            u64, // bytes; default 65527
	initial_max_data:                u64,
	initial_max_stream_data_bidi_local:  u64,
	initial_max_stream_data_bidi_remote: u64,
	initial_max_stream_data_uni:     u64,
	initial_max_streams_bidi:        u64,
	initial_max_streams_uni:         u64,
	ack_delay_exponent:              u64, // default 3
	max_ack_delay:                   u64, // default 25 (ms)
	active_connection_id_limit:      u64, // default 2
	max_datagram_frame_size:         u64, // RFC 9221; 0 = DATAGRAMs disabled

	// Flag-only parameters (present = true, absent = false).
	disable_active_migration:        bool,
}

// Encode a parameter whose value is a single varint integer.
// Produces: [id_varint] [length_varint] [value_varint]
@(private)
_encode_varint_param :: proc(buf: []u8, id: u64, value: u64) -> int {
	id_len := varint_len(id)
	val_len := varint_len(value)
	len_len := varint_len(u64(val_len))
	total := id_len + len_len + val_len
	if len(buf) < total do return -1

	n := 0
	w := varint_encode(buf[n:], id);           if w < 0 do return -1; n += w
	w  = varint_encode(buf[n:], u64(val_len)); if w < 0 do return -1; n += w
	w  = varint_encode(buf[n:], value);        if w < 0 do return -1; n += w
	return n
}

// Encode a parameter whose value is a raw byte sequence (e.g. connection ID).
@(private)
_encode_bytes_param :: proc(buf: []u8, id: u64, value: []u8) -> int {
	id_len := varint_len(id)
	len_len := varint_len(u64(len(value)))
	total := id_len + len_len + len(value)
	if len(buf) < total do return -1

	n := 0
	w := varint_encode(buf[n:], id);                 if w < 0 do return -1; n += w
	w  = varint_encode(buf[n:], u64(len(value)));    if w < 0 do return -1; n += w
	copy(buf[n:], value); n += len(value)
	return n
}

// Encode a flag parameter (empty value).
@(private)
_encode_flag_param :: proc(buf: []u8, id: u64) -> int {
	id_len := varint_len(id)
	if len(buf) < id_len + 1 do return -1

	n := 0
	w := varint_encode(buf[n:], id); if w < 0 do return -1; n += w
	w  = varint_encode(buf[n:], 0);  if w < 0 do return -1; n += w
	return n
}

// Serialize a Transport_Params struct into buf. Returns the number of bytes
// written, or -1 on overflow. Only non-zero / non-empty fields are emitted.
transport_params_encode :: proc(buf: []u8, params: ^Transport_Params) -> int {
	n := 0

	if len(params.initial_source_cid) > 0 {
		w := _encode_bytes_param(buf[n:], TP_INITIAL_SOURCE_CID, params.initial_source_cid)
		if w < 0 do return -1
		n += w
	}

	if len(params.original_destination_cid) > 0 {
		w := _encode_bytes_param(buf[n:], TP_ORIGINAL_DESTINATION_CID, params.original_destination_cid)
		if w < 0 do return -1
		n += w
	}

	if params.max_idle_timeout != 0 {
		w := _encode_varint_param(buf[n:], TP_MAX_IDLE_TIMEOUT, params.max_idle_timeout)
		if w < 0 do return -1
		n += w
	}

	if params.max_udp_payload_size != 0 {
		w := _encode_varint_param(buf[n:], TP_MAX_UDP_PAYLOAD_SIZE, params.max_udp_payload_size)
		if w < 0 do return -1
		n += w
	}

	if params.initial_max_data != 0 {
		w := _encode_varint_param(buf[n:], TP_INITIAL_MAX_DATA, params.initial_max_data)
		if w < 0 do return -1
		n += w
	}

	if params.initial_max_stream_data_bidi_local != 0 {
		w := _encode_varint_param(buf[n:], TP_INITIAL_MAX_STREAM_DATA_BIDI_LOCAL, params.initial_max_stream_data_bidi_local)
		if w < 0 do return -1
		n += w
	}

	if params.initial_max_stream_data_bidi_remote != 0 {
		w := _encode_varint_param(buf[n:], TP_INITIAL_MAX_STREAM_DATA_BIDI_REMOTE, params.initial_max_stream_data_bidi_remote)
		if w < 0 do return -1
		n += w
	}

	if params.initial_max_stream_data_uni != 0 {
		w := _encode_varint_param(buf[n:], TP_INITIAL_MAX_STREAM_DATA_UNI, params.initial_max_stream_data_uni)
		if w < 0 do return -1
		n += w
	}

	if params.initial_max_streams_bidi != 0 {
		w := _encode_varint_param(buf[n:], TP_INITIAL_MAX_STREAMS_BIDI, params.initial_max_streams_bidi)
		if w < 0 do return -1
		n += w
	}

	if params.initial_max_streams_uni != 0 {
		w := _encode_varint_param(buf[n:], TP_INITIAL_MAX_STREAMS_UNI, params.initial_max_streams_uni)
		if w < 0 do return -1
		n += w
	}

	if params.ack_delay_exponent != 0 {
		w := _encode_varint_param(buf[n:], TP_ACK_DELAY_EXPONENT, params.ack_delay_exponent)
		if w < 0 do return -1
		n += w
	}

	if params.max_ack_delay != 0 {
		w := _encode_varint_param(buf[n:], TP_MAX_ACK_DELAY, params.max_ack_delay)
		if w < 0 do return -1
		n += w
	}

	if params.active_connection_id_limit != 0 {
		w := _encode_varint_param(buf[n:], TP_ACTIVE_CONNECTION_ID_LIMIT, params.active_connection_id_limit)
		if w < 0 do return -1
		n += w
	}

	if params.max_datagram_frame_size != 0 {
		w := _encode_varint_param(buf[n:], TP_MAX_DATAGRAM_FRAME_SIZE, params.max_datagram_frame_size)
		if w < 0 do return -1
		n += w
	}

	if params.disable_active_migration {
		w := _encode_flag_param(buf[n:], TP_DISABLE_ACTIVE_MIGRATION)
		if w < 0 do return -1
		n += w
	}

	return n
}

// Parse a transport parameters blob from the peer.
// `buf` should point at the full TLS extension payload. Unknown parameters
// are silently skipped per RFC 9000 §18.1.
transport_params_decode :: proc(buf: []u8, params: ^Transport_Params) -> bool {
	pos := 0
	for pos < len(buf) {
		id, id_n, id_ok := varint_decode(buf[pos:])
		if !id_ok do return false
		pos += id_n

		length, len_n, len_ok := varint_decode(buf[pos:])
		if !len_ok do return false
		pos += len_n

		if pos + int(length) > len(buf) do return false
		value := buf[pos : pos + int(length)]
		pos += int(length)

		// Decode known parameters; ignore everything else.
		switch id {
		case TP_INITIAL_SOURCE_CID:
			params.initial_source_cid = value
		case TP_ORIGINAL_DESTINATION_CID:
			params.original_destination_cid = value
		case TP_RETRY_SOURCE_CID:
			params.retry_source_cid = value

		case TP_MAX_IDLE_TIMEOUT:
			v, _, ok := varint_decode(value); if !ok do return false
			params.max_idle_timeout = v
		case TP_MAX_UDP_PAYLOAD_SIZE:
			v, _, ok := varint_decode(value); if !ok do return false
			params.max_udp_payload_size = v
		case TP_INITIAL_MAX_DATA:
			v, _, ok := varint_decode(value); if !ok do return false
			params.initial_max_data = v
		case TP_INITIAL_MAX_STREAM_DATA_BIDI_LOCAL:
			v, _, ok := varint_decode(value); if !ok do return false
			params.initial_max_stream_data_bidi_local = v
		case TP_INITIAL_MAX_STREAM_DATA_BIDI_REMOTE:
			v, _, ok := varint_decode(value); if !ok do return false
			params.initial_max_stream_data_bidi_remote = v
		case TP_INITIAL_MAX_STREAM_DATA_UNI:
			v, _, ok := varint_decode(value); if !ok do return false
			params.initial_max_stream_data_uni = v
		case TP_INITIAL_MAX_STREAMS_BIDI:
			v, _, ok := varint_decode(value); if !ok do return false
			params.initial_max_streams_bidi = v
		case TP_INITIAL_MAX_STREAMS_UNI:
			v, _, ok := varint_decode(value); if !ok do return false
			params.initial_max_streams_uni = v
		case TP_ACK_DELAY_EXPONENT:
			v, _, ok := varint_decode(value); if !ok do return false
			params.ack_delay_exponent = v
		case TP_MAX_ACK_DELAY:
			v, _, ok := varint_decode(value); if !ok do return false
			params.max_ack_delay = v
		case TP_ACTIVE_CONNECTION_ID_LIMIT:
			v, _, ok := varint_decode(value); if !ok do return false
			params.active_connection_id_limit = v
		case TP_MAX_DATAGRAM_FRAME_SIZE:
			v, _, ok := varint_decode(value); if !ok do return false
			params.max_datagram_frame_size = v

		case TP_DISABLE_ACTIVE_MIGRATION:
			params.disable_active_migration = true
		}
	}
	return true
}
