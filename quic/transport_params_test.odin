package quic

import "core:testing"

@(test)
test_tp_empty :: proc(t: ^testing.T) {
	buf: [256]u8
	params: Transport_Params
	n := transport_params_encode(buf[:], &params)
	testing.expect_value(t, n, 0)

	decoded: Transport_Params
	ok := transport_params_decode(buf[:n], &decoded)
	testing.expect(t, ok)
}

@(test)
test_tp_single_varint :: proc(t: ^testing.T) {
	buf: [256]u8
	params := Transport_Params{
		max_idle_timeout = 30000,
	}
	n := transport_params_encode(buf[:], &params)
	testing.expect(t, n > 0, "encode failed")

	decoded: Transport_Params
	ok := transport_params_decode(buf[:n], &decoded)
	testing.expect(t, ok, "decode failed")
	testing.expect_value(t, decoded.max_idle_timeout, u64(30000))
}

@(test)
test_tp_all_integer_params :: proc(t: ^testing.T) {
	buf: [512]u8
	params := Transport_Params{
		max_idle_timeout                    = 30000,
		max_udp_payload_size                = 1472,
		initial_max_data                    = 10_485_760,
		initial_max_stream_data_bidi_local  = 1_048_576,
		initial_max_stream_data_bidi_remote = 1_048_576,
		initial_max_stream_data_uni         = 1_048_576,
		initial_max_streams_bidi            = 100,
		initial_max_streams_uni             = 100,
		ack_delay_exponent                  = 3,
		max_ack_delay                       = 25,
		active_connection_id_limit          = 2,
		max_datagram_frame_size             = 65535,
	}
	n := transport_params_encode(buf[:], &params)
	testing.expect(t, n > 0)

	decoded: Transport_Params
	ok := transport_params_decode(buf[:n], &decoded)
	testing.expect(t, ok)

	testing.expect_value(t, decoded.max_idle_timeout,                    u64(30000))
	testing.expect_value(t, decoded.max_udp_payload_size,                u64(1472))
	testing.expect_value(t, decoded.initial_max_data,                    u64(10_485_760))
	testing.expect_value(t, decoded.initial_max_stream_data_bidi_local,  u64(1_048_576))
	testing.expect_value(t, decoded.initial_max_stream_data_bidi_remote, u64(1_048_576))
	testing.expect_value(t, decoded.initial_max_stream_data_uni,         u64(1_048_576))
	testing.expect_value(t, decoded.initial_max_streams_bidi,            u64(100))
	testing.expect_value(t, decoded.initial_max_streams_uni,             u64(100))
	testing.expect_value(t, decoded.ack_delay_exponent,                  u64(3))
	testing.expect_value(t, decoded.max_ack_delay,                       u64(25))
	testing.expect_value(t, decoded.active_connection_id_limit,          u64(2))
	testing.expect_value(t, decoded.max_datagram_frame_size,             u64(65535))
}

@(test)
test_tp_connection_id :: proc(t: ^testing.T) {
	buf: [256]u8
	scid := []u8{0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08}
	params := Transport_Params{
		initial_source_cid = scid,
	}
	n := transport_params_encode(buf[:], &params)
	testing.expect(t, n > 0)

	decoded: Transport_Params
	ok := transport_params_decode(buf[:n], &decoded)
	testing.expect(t, ok)
	testing.expect_value(t, len(decoded.initial_source_cid), 8)
	testing.expect(t, slice_equal(decoded.initial_source_cid, scid))
}

@(test)
test_tp_disable_active_migration_flag :: proc(t: ^testing.T) {
	buf: [32]u8
	params := Transport_Params{
		disable_active_migration = true,
	}
	n := transport_params_encode(buf[:], &params)
	testing.expect(t, n > 0)

	decoded: Transport_Params
	ok := transport_params_decode(buf[:n], &decoded)
	testing.expect(t, ok)
	testing.expect_value(t, decoded.disable_active_migration, true)
}

@(test)
test_tp_datagram_frame_size_critical :: proc(t: ^testing.T) {
	// max_datagram_frame_size is the negotiation for RFC 9221 DATAGRAM support.
	// Zero means disabled; any non-zero value means the peer accepts DATAGRAMs.
	buf: [32]u8
	params := Transport_Params{
		max_datagram_frame_size = 1200,
	}
	n := transport_params_encode(buf[:], &params)
	testing.expect(t, n > 0)

	decoded: Transport_Params
	ok := transport_params_decode(buf[:n], &decoded)
	testing.expect(t, ok)
	testing.expect_value(t, decoded.max_datagram_frame_size, u64(1200))
}

@(test)
test_tp_unknown_params_ignored :: proc(t: ^testing.T) {
	// Build a blob containing a known param + an unknown one. The decoder
	// should consume both and populate only the known field.
	buf: [64]u8
	pos := 0

	// Known: max_idle_timeout = 100
	w := _encode_varint_param(buf[pos:], TP_MAX_IDLE_TIMEOUT, 100); pos += w

	// Unknown: id 0x1234 with 4 bytes of value
	w = varint_encode(buf[pos:], 0x1234); pos += w
	w = varint_encode(buf[pos:], 4);       pos += w
	buf[pos] = 0xaa; pos += 1
	buf[pos] = 0xbb; pos += 1
	buf[pos] = 0xcc; pos += 1
	buf[pos] = 0xdd; pos += 1

	// Known: max_ack_delay = 10
	w = _encode_varint_param(buf[pos:], TP_MAX_ACK_DELAY, 10); pos += w

	decoded: Transport_Params
	ok := transport_params_decode(buf[:pos], &decoded)
	testing.expect(t, ok, "decode should skip unknown params")
	testing.expect_value(t, decoded.max_idle_timeout, u64(100))
	testing.expect_value(t, decoded.max_ack_delay,    u64(10))
}

@(test)
test_tp_full_roundtrip_zenoh_profile :: proc(t: ^testing.T) {
	// A realistic set of parameters matching what we'd send to zenoh-rs.
	buf: [512]u8
	scid := []u8{0xde, 0xad, 0xbe, 0xef, 0xca, 0xfe, 0xba, 0xbe}
	params := Transport_Params{
		initial_source_cid         = scid,
		max_idle_timeout           = 30_000,
		max_udp_payload_size       = 1472,
		initial_max_data           = 10 * 1024 * 1024,
		initial_max_streams_bidi   = 0,   // we don't open streams
		initial_max_streams_uni    = 0,
		ack_delay_exponent         = 3,
		max_ack_delay              = 25,
		active_connection_id_limit = 2,
		max_datagram_frame_size    = 65527, // accept any datagram
		disable_active_migration   = true,
	}
	n := transport_params_encode(buf[:], &params)
	testing.expect(t, n > 0)

	decoded: Transport_Params
	ok := transport_params_decode(buf[:n], &decoded)
	testing.expect(t, ok)

	testing.expect(t, slice_equal(decoded.initial_source_cid, scid))
	testing.expect_value(t, decoded.max_idle_timeout,         u64(30_000))
	testing.expect_value(t, decoded.max_udp_payload_size,     u64(1472))
	testing.expect_value(t, decoded.initial_max_data,         u64(10 * 1024 * 1024))
	testing.expect_value(t, decoded.ack_delay_exponent,       u64(3))
	testing.expect_value(t, decoded.max_ack_delay,            u64(25))
	testing.expect_value(t, decoded.active_connection_id_limit, u64(2))
	testing.expect_value(t, decoded.max_datagram_frame_size,  u64(65527))
	testing.expect_value(t, decoded.disable_active_migration, true)
}

@(test)
test_tp_truncated_decode_fails :: proc(t: ^testing.T) {
	// Build a valid blob, then truncate it.
	buf: [64]u8
	params := Transport_Params{max_idle_timeout = 12345}
	n := transport_params_encode(buf[:], &params)

	decoded: Transport_Params
	ok := transport_params_decode(buf[:n - 1], &decoded)
	testing.expect(t, !ok, "decode should fail on truncated input")
}
