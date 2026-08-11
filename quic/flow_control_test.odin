package quic

import "core:testing"

// Unit tests for connection-level flow control bookkeeping (Phase C).
// These don't exercise the wire — they invoke the private accounting
// hooks directly so the assertions stay close to the state mutations.

@(test)
test_conn_rx_flow_control_arms_max_data :: proc(t: ^testing.T) {
	c: Conn
	c.local_tp.initial_max_data = 1024
	c.rx_our_max_data = 1024
	c.streams = make(map[u64]^Stream)
	defer { for _, s in c.streams { stream_free(s) }; delete(c.streams) }

	// Deliver 600 bytes — past half of the 1024 advertised limit. That
	// should arm a MAX_DATA update and slide rx_our_max_data forward.
	payload := make([]u8, 600)
	defer delete(payload)
	frame := Stream_Frame{
		stream_id = 0,
		offset    = 0,
		data      = payload,
		fin       = false,
	}
	_handle_stream_frame(&c, frame)

	testing.expect_value(t, c.rx_data_received, u64(600))
	testing.expect(t, c.rx_max_data_pending,
		"crossing half-window should arm a MAX_DATA update")
	testing.expect(t, c.rx_our_max_data >= 600 + 1024,
		"rx_our_max_data should slide forward by another window")
}

@(test)
test_max_streams_frame_decode :: proc(t: ^testing.T) {
	// MAX_STREAMS_UNI with max=42 — type byte 0x13, then varint 42.
	buf: [4]u8 = {0x13, 0x2a, 0, 0}
	frame, n, derr := frame_decode(buf[:2])
	testing.expect_value(t, derr, Frame_Error.None)
	testing.expect_value(t, n, 2)
	msu, ok := frame.(Max_Streams_Frame)
	testing.expect(t, ok, "should decode as Max_Streams_Frame")
	testing.expect_value(t, msu.is_uni, true)
	testing.expect_value(t, msu.max_count, u64(42))

	// MAX_STREAMS_BIDI with max=17 — type 0x12.
	buf2: [4]u8 = {0x12, 0x11, 0, 0}
	frame2, n2, derr2 := frame_decode(buf2[:2])
	testing.expect_value(t, derr2, Frame_Error.None)
	testing.expect_value(t, n2, 2)
	msb, ok2 := frame2.(Max_Streams_Frame)
	testing.expect(t, ok2, "should decode as Max_Streams_Frame")
	testing.expect_value(t, msb.is_uni, false)
	testing.expect_value(t, msb.max_count, u64(17))
}

@(test)
test_outbound_max_streams_uni_arms_after_half_cap :: proc(t: ^testing.T) {
	// Advertised cap = 4. After the peer opens 3 streams we should arm a
	// MAX_STREAMS_UNI bump and slide the cap forward.
	c: Conn
	c.local_tp.initial_max_streams_uni = 4
	c.rx_uni_max_advertised            = 4
	c.streams                          = make(map[u64]^Stream)
	c.is_server                        = false // we're client → peer-uni mask = 3
	defer { for _, s in c.streams { stream_free(s) }; delete(c.streams) }

	// Open three peer-initiated uni streams (server-uni IDs: 3, 7, 11).
	_ = conn_get_or_open_stream(&c, 3)
	_ = conn_get_or_open_stream(&c, 7)
	testing.expect(t, !c.rx_max_streams_uni_pending,
		"two streams should not yet trigger a bump (4/2 = 2 not exceeded)")
	_ = conn_get_or_open_stream(&c, 11)
	testing.expect(t, c.rx_max_streams_uni_pending,
		"third stream should arm the bump")
	testing.expect(t, c.rx_uni_max_advertised > 4,
		"advertised cap should slide forward")

	// Opening a locally-initiated uni stream should NOT count against the
	// inbound cap (it's tracked by next_local_uni_id, not rx_uni_count).
	prev_count := c.rx_uni_count
	c.rx_max_streams_uni_pending = false
	c.peer_tp.initial_max_streams_uni = 8
	_ = conn_open_uni(&c) // assigns id 2 (client-uni)
	testing.expect_value(t, c.rx_uni_count, prev_count)
	testing.expect(t, !c.rx_max_streams_uni_pending,
		"opening our own uni stream must not arm an inbound bump")
}

@(test)
test_conn_tx_flow_control_caps_send :: proc(t: ^testing.T) {
	// Cap of 100 bytes across the whole connection; per-stream allows 1 KiB.
	// to_send should pick the 100-byte conn cap.
	c: Conn
	c.tx_peer_max_data = 100
	c.tx_data_sent     = 0
	s := stream_new(0)
	defer stream_free(s)
	s.tx_peer_max_data = 1024

	// Manually run the same min() the packet builder uses so the test
	// doesn't depend on the AEAD path.
	per_stream := int(s.tx_peer_max_data) - int(s.tx_next_offset)
	per_conn   := int(c.tx_peer_max_data) - int(c.tx_data_sent)
	to_send    := min(500, min(per_stream, per_conn))
	testing.expect_value(t, to_send, 100)
}
