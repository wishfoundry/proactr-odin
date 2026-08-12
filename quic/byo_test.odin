package quic

import "core:testing"

// conn_poll_send is safe on a new client conn (may emit Initial once crypto is queued).
@(test)
test_conn_poll_send_no_crash :: proc(t: ^testing.T) {
	alpn := [3]u8{2, 'h', '3'}
	params := Transport_Params {
		max_idle_timeout                    = 30_000,
		max_udp_payload_size                = 1472,
		initial_max_data                    = 1 << 20,
		initial_max_stream_data_bidi_local  = 1 << 16,
		initial_max_stream_data_bidi_remote = 1 << 16,
		initial_max_stream_data_uni         = 1 << 16,
		initial_max_streams_bidi            = 4,
		initial_max_streams_uni             = 4,
		ack_delay_exponent                  = 3,
		max_ack_delay                       = 25,
		active_connection_id_limit          = 2,
	}
	conn, err := conn_new("localhost", alpn[:], params)
	testing.expect_value(t, err, Quic_Error.None)
	testing.expect(t, conn != nil)
	defer conn_free(conn)

	count := 0
	emit :: proc(packet: []u8, user: rawptr) {
		c := (^int)(user)
		if len(packet) > 0 do c^ += 1
	}
	conn_poll_send(conn, emit, &count)
	testing.expect(t, count >= 0)
}
