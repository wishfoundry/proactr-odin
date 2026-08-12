package quic

import "core:fmt"
import "core:mem"
import "core:net"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:time"

// Synchronous UDP transport layer.
// Drives the handshake to completion via blocking send/recv on a UDP
// socket. This is deliberately simple — no async, no nbio — so the zenoh
// integration can reuse zenoh's existing blocking-connect pattern.
// Once the handshake is complete, callers should use conn_send_datagram
// (then net.send_udp with the produced packet) and conn_udp_read +
// conn_on_udp_recv to move application data.

Transport_Error :: enum {
	None,
	Resolve_Failed,
	Socket_Failed,
	Send_Failed,
	Recv_Failed,
	Timeout,
	Handshake_Failed,
}

// Parse an endpoint string of form "host:port" or "quic/host:port" into a
// net.Endpoint. Returns the resolved endpoint plus the hostname portion so
// callers can use it as the TLS SNI value.
conn_parse_endpoint :: proc(endpoint: string) -> (
	ep: net.Endpoint,
	hostname: string,
	ok: bool,
) {
	host_port := endpoint
	if strings.has_prefix(endpoint, "quic/") {
		host_port = endpoint[5:]
	}
	// Strip query string (e.g. "?mixed_rel=1") — these are zenoh-rs
	// endpoint metadata, not part of the host:port address.
	if qi := strings.index_byte(host_port, '?'); qi >= 0 {
		host_port = host_port[:qi]
	}

	host_or_ep, err := net.parse_hostname_or_endpoint(host_port)
	if err != nil do return {}, "", false

	switch t in host_or_ep {
	case net.Endpoint:
		return t, "", true
	case net.Host:
		ep4, ep6, rerr := net.resolve(t.hostname)
		if rerr != nil do return {}, "", false
		resolved := ep4 if ep4.address != nil else ep6
		resolved.port = t.port
		if resolved.port == 0 do resolved.port = 7447 // zenoh default
		return resolved, t.hostname, true
	}
	return {}, "", false
}

// Drive a blocking client handshake against the peer at `endpoint`.
// - Opens an unbound UDP socket in the peer's address family
// - Emits ClientHello, sends, reads the response, feeds to conn_on_udp_recv
// - Loops until conn.state == .Connected
conn_connect :: proc(
	conn:         ^Conn,
	endpoint:     string,
	handshake_timeout: time.Duration = 5 * time.Second,
) -> Transport_Error {
	ep, _, ok := conn_parse_endpoint(endpoint)
	if !ok do return .Resolve_Failed

	family := net.family_from_endpoint(ep)
	sock, serr := net.make_unbound_udp_socket(family)
	if serr != nil do return .Socket_Failed

	conn.socket = sock
	conn.remote = ep
	conn.socket_owned = true

	// Non-blocking from the start: with a blocking socket, a quiet peer (or a
	// lost datagram) parks recv_udp forever and the handshake deadline below
	// never fires.
	net.set_blocking(sock, false)

	// Kick off the handshake — BoringSSL emits ClientHello into
	// conn.initial.tx_crypto.
	if hs := conn_start_handshake(conn); hs != .None do return .Handshake_Failed

	// Send the first Initial packet.
	if terr := _send_pending_initial(conn); terr != .None do return terr

	// Loop: recv, feed, send whatever comes out, until Connected.
	deadline := time.time_add(time.now(), handshake_timeout)
	recv_buf: [2048]u8

	for conn.state != .Connected {
		if time.diff(time.now(), deadline) <= 0 {
			return .Timeout
		}

		n, _, rerr := net.recv_udp(sock, recv_buf[:])
		if rerr == net.UDP_Recv_Error.Would_Block {
			// Quiet peer: maybe our last flight was lost — PTO re-queues it
			// and the sends below pick it up.
			if conn_pto_check(conn) {
				if terr := _send_pending_initial(conn); terr != .None do return terr
				if terr := _send_pending_handshake(conn); terr != .None do return terr
			}
			time.sleep(time.Millisecond)
			continue
		}
		if rerr != nil do return .Recv_Failed
		if n == 0 do continue

		if err := conn_on_udp_recv(conn, recv_buf[:n]); err != .None {
			return .Handshake_Failed
		}

		// Emit any response the TLS advance produced — or a bare ACK. The
		// builders return n=0 when there's nothing to send; ACKs must flow
		// even without crypto data or the server stalls on its amplification
		// limit / retransmit timers when its flight spans datagrams.
		if terr := _send_pending_initial(conn); terr != .None do return terr
		if terr := _send_pending_handshake(conn); terr != .None do return terr
	}
	return .None
}

@(private)
_send_pending_initial :: proc(conn: ^Conn) -> Transport_Error {
	pkt: [2048]u8
	n, err := conn_build_initial_packet(conn, pkt[:])
	if err != .None do return .Send_Failed
	if n == 0 do return .None
	_, serr := net.send_udp(conn.socket, pkt[:n], conn.remote)
	if serr != nil do return .Send_Failed
	return .None
}

@(private)
_send_pending_handshake :: proc(conn: ^Conn) -> Transport_Error {
	pkt: [2048]u8
	n, err := conn_build_handshake_packet(conn, pkt[:])
	if err != .None do return .Send_Failed
	if n == 0 do return .None
	_, serr := net.send_udp(conn.socket, pkt[:n], conn.remote)
	if serr != nil do return .Send_Failed
	return .None
}


// Ship one zenoh frame as a DATAGRAM over the connected UDP socket.
conn_udp_send_datagram :: proc(conn: ^Conn, data: []u8) -> Transport_Error {
	pkt: [2048]u8
	n, err := conn_send_datagram(conn, data, pkt[:])
	if err != .None do return .Send_Failed
	return udp_send_raw(conn, pkt[:n])
}

// Send an already-encoded QUIC packet over the UDP socket.
conn_udp_send_packet :: proc(conn: ^Conn, packet: []u8) -> Transport_Error {
	return udp_send_raw(conn, packet)
}

// Low-level UDP send. Uses send() on a connected socket, sendto() otherwise.
udp_send_raw :: proc(conn: ^Conn, data: []u8) -> Transport_Error {
	if conn.udp_connected {
		// Connected socket: use send() (no destination address).
		res := posix.send(posix.FD(conn.socket), raw_data(data), len(data), {})
		if res < 0 {
			conn.stats.udp_send_errors += 1
			return .Send_Failed
		}
		conn.stats.udp_packets_sent += 1
		return .None
	}
	// Unconnected: use sendto() with the stored remote endpoint.
	_, serr := net.send_udp(conn.socket, data, conn.remote)
	if serr != nil {
		conn.stats.udp_send_errors += 1
		return .Send_Failed
	}
	conn.stats.udp_packets_sent += 1
	return .None
}

// Blocking read of one UDP datagram, decrypt, and push any contained
// DATAGRAM frames onto the rx queue. Caller should drain with
// conn_recv_datagram until empty.
conn_udp_read :: proc(conn: ^Conn, buf: []u8) -> Transport_Error {
	n, _, rerr := net.recv_udp(conn.socket, buf)
	if rerr != nil {
		conn.stats.udp_recv_errors += 1
		return .Recv_Failed
	}
	if n == 0 {
		conn.stats.udp_recv_would_block += 1
		return .None
	}
	conn.stats.udp_packets_received += 1
	if err := conn_on_udp_recv(conn, buf[:n]); err != .None {
		return .Recv_Failed
	}
	return .None
}

// Connect the UDP socket to the remote endpoint. This makes kqueue
// report readability only when there's a datagram from the peer (instead
// of reporting the socket as always-readable). Must be called after
// conn_connect and before handing the socket to nbio for async recv.
conn_udp_connect :: proc(conn: ^Conn) -> bool {
	// Build a sockaddr_in from the stored remote endpoint.
	addr: posix.sockaddr_in
	addr.sin_family = .INET
	port := u16(conn.remote.port)
	addr.sin_port = u16be(port)
	ip4 := conn.remote.address.(net.IP4_Address)
	mem.copy(&addr.sin_addr, &ip4[0], 4)
	// sin_len is BSD/Darwin only; Linux sockaddr_in has no such field.
	when ODIN_OS == .Darwin || ODIN_OS == .FreeBSD || ODIN_OS == .OpenBSD {
		addr.sin_len = u8(size_of(posix.sockaddr_in))
	}

	fd := posix.FD(conn.socket)
	if posix.connect(fd, cast(^posix.sockaddr)&addr, posix.socklen_t(size_of(posix.sockaddr_in))) != .OK {
		return false
	}
	conn.udp_connected = true
	return true
}

// Close the UDP socket. No-op when the Conn is borrowing an Endpoint's
// socket — the Endpoint is responsible for that close.
conn_udp_close :: proc(conn: ^Conn) {
	if !conn.socket_owned do return
	net.close(conn.socket)
}
