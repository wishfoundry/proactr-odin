// ADAPTER — real-UDP-socket pumps for a quic.Conn.
//
// Not library core: these two procs move bytes between conn and conn.socket.
// Your event loop (blocking, nbio, fibers, …) can call them — or replace them
// entirely by reading/writing UDP yourself and calling quic.conn_on_udp_recv /
// packet builders. See docs/LIBRARY.md.
package http3

import "core:net"

import "../quic"

// Drain every packet pending on `conn` and send each as a UDP datagram to
// conn.remote over conn.socket. Thin adapter over quic.conn_poll_send.
pump_quic_send :: proc(conn: ^quic.Conn) -> net.Network_Error {
	Send_Ctx :: struct {
		conn: ^quic.Conn,
		err:  net.Network_Error,
	}
	ctx := Send_Ctx{conn = conn}
	emit :: proc(packet: []u8, user: rawptr) {
		c := (^Send_Ctx)(user)
		if c.err != nil do return
		_, c.err = net.send_udp(c.conn.socket, packet, c.conn.remote)
	}
	quic.conn_poll_send(conn, emit, &ctx)
	return ctx.err
}

// Drain all currently-available datagrams from conn.socket into `conn`. The
// socket must be non-blocking (net.set_blocking(sock, false)); recv stops at the
// first would-block. Returns the number of datagrams processed.
pump_quic_recv :: proc(conn: ^quic.Conn) -> int {
	buf: [2048]u8
	count := 0
	for {
		n, _, rerr := net.recv_udp(conn.socket, buf[:])
		if rerr != nil || n == 0 do break
		quic.conn_on_udp_recv(conn, buf[:n])
		count += 1
	}
	return count
}
