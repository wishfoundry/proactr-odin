// Drain outbound QUIC packets without touching sockets. Your loop:
//   conn_on_udp_recv(conn, datagram)
//   … advance app / http3 …
//   conn_poll_send(conn, my_emit, user)  // my_emit sends via your socket
// Convenience pumps in http3.pump_quic_* wrap these with net.send_udp/recv_udp.
// See docs/LIBRARY.md.
package quic

// Callback for each fully-built datagram ready to put on the wire.
// `packet` is only valid for the duration of the call (stack buffer).
Packet_Emit :: #type proc(packet: []u8, user: rawptr)

// Max 1-RTT packets emitted per poll_send call. Bounds the for-loop if a
// bug would otherwise emit forever; ~64 is enough to drain a full initial
// cwnd several times over on one tick.
POLL_SEND_MAX_APP_PACKETS :: 64

// Build and emit every currently-available outbound packet (Initial, Handshake,
// 1-RTT stream). Runs PTO / loss checks first. Does not read or write sockets.
// Returns the number of application (1-RTT) packets emitted.
conn_poll_send :: proc(conn: ^Conn, emit: Packet_Emit, user: rawptr = nil) -> int {
	if emit == nil do return 0
	buf: [2048]u8
	app_pkts := 0

	conn_pto_check(conn)
	loss_check_pto(conn)

	if n, e := conn_build_initial_packet(conn, buf[:]); e == .None && n > 0 {
		emit(buf[:n], user)
	}
	if n, e := conn_build_handshake_packet(conn, buf[:]); e == .None && n > 0 {
		emit(buf[:n], user)
	}
	for app_pkts < POLL_SEND_MAX_APP_PACKETS {
		n, _, e := conn_build_stream_packet(conn, buf[:])
		if e != .None || n == 0 do break
		emit(buf[:n], user)
		app_pkts += 1
	}
	return app_pkts
}

// True if any stream still has unsent bytes or an unsent FIN — caller should
// keep polling recv (for ACKs / credit) and poll_send.
conn_has_unsent_stream_data :: proc(conn: ^Conn) -> bool {
	for _, s in conn.streams {
		if s == nil do continue
		if s.tx_sent_off < u64(len(s.tx_buffered)) do return true
		if s.tx_fin && !s.tx_fin_sent do return true
	}
	return false
}

// Collect outbound packets into `dst` (each packet appended as a contiguous
// slice owned by `dst`'s allocator via append of bytes + length markers is
// awkward). Prefer conn_poll_send. This helper copies each packet into `dst`
// as a length-prefixed blob: u32le length || bytes (for tests / offline).
conn_poll_send_into :: proc(conn: ^Conn, dst: ^[dynamic]u8) {
	emit :: proc(packet: []u8, user: rawptr) {
		d := (^([dynamic]u8))(user)
		n := u32(len(packet))
		append(d, u8(n), u8(n >> 8), u8(n >> 16), u8(n >> 24))
		append(d, ..packet)
	}
	conn_poll_send(conn, emit, dst)
}

// Feed one inbound datagram. Alias kept for discoverability next to poll_send;
// same as conn_on_udp_recv.
conn_poll_recv :: proc(conn: ^Conn, datagram: []u8) -> Recv_Error {
	return conn_on_udp_recv(conn, datagram)
}
