package quic

// Debug counters for diagnosing the packet flow through a Conn.
// Always active — the counters are plain u64 increments, near-zero overhead.
// Access via conn.stats after any operation to see what happened.

Conn_Stats :: struct {
	// UDP I/O
	udp_packets_sent:     u64,
	udp_packets_received: u64,
	udp_send_errors:      u64,
	udp_recv_errors:      u64,
	udp_recv_would_block: u64, // non-blocking recv returned no data

	// QUIC packet processing
	packets_decrypted:    u64,
	packets_decrypt_failed: u64,
	packets_dropped:      u64, // undecryptable-yet / unsupported — dropped per RFC 9000 §12.2

	// Stream
	stream_bytes_written: u64, // bytes handed to stream_write
	stream_bytes_sent:    u64, // bytes put into STREAM frames on the wire
	stream_bytes_received: u64, // bytes delivered to rx_delivered
	stream_bytes_read:    u64, // bytes consumed by stream_read

	// Frames
	stream_frames_sent:   u64,
	stream_frames_received: u64,
	datagram_frames_sent: u64,
	datagram_frames_received: u64,
	ack_frames_sent:      u64,
	ack_frames_received:  u64,
}
