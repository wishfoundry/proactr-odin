package quic

import "core:mem"
import "core:net"
import "core:time"

// Server-side QUIC endpoint: one UDP socket multiplexing many
// connections, routed by Destination Connection ID (DCID). Mirrors the
// shape of quinn's `Endpoint` and zenoh-rs's `LinkManagerUnicastQuic`.
//
// Lifecycle:
//
//   ep := endpoint_new(udp_addr, cert_pem, key_pem, local_tp)
//   loop:
//     conn := endpoint_accept(ep, timeout)  // blocks until a peer's
//                                           // handshake completes
//     hand `conn` off to a worker
//   endpoint_close(ep)
//
// During endpoint_accept the endpoint drains the UDP socket, routes each
// incoming datagram to the right Conn (by DCID), runs the server-side
// TLS handshake forward via `conn_on_udp_recv`, and emits whatever
// Initial / Handshake / 1-RTT response packets the Conn produces.
//
// All Conns share the listener's UDP socket and send via sendto with
// the per-Conn `remote` address — this is why each accepted Conn has
// `socket_owned = false`: only the Endpoint closes the FD.

// DCID lookup key. RFC 9000 §17.2 allows up to 20 byte DCIDs; we store
// the full 20 bytes with the unused tail as zeros plus an explicit
// length so two different-length CIDs with the same prefix don't alias.
Cid_Key :: struct {
	bytes: [20]u8,
	len:   u8,
}

Endpoint :: struct {
	socket:    net.UDP_Socket,
	local_addr: net.Endpoint,

	// Server certificate material. The Endpoint borrows these slices —
	// the caller must keep them alive until endpoint_close.
	cert_pem: []u8,
	key_pem:  []u8,

	// Template transport parameters announced to every accepted peer.
	local_tp: Transport_Params,

	// Active connections, indexed under every CID we'll see on the wire
	// for that conn (client-chosen DCID and our own SCID).
	conn_by_dcid: map[Cid_Key]^Conn,

	// FIFO of conns whose handshake just completed and are awaiting an
	// endpoint_accept() caller.
	pending_accept: [dynamic]^Conn,

	allocator: mem.Allocator,
}

Endpoint_Error :: enum {
	None,
	Socket_Failed,
	Bind_Failed,
	Resolve_Failed,
	Accept_Timeout,
}

// Bind a UDP socket on `local_addr` (e.g. "0.0.0.0:7448") and stand up
// an Endpoint ready to accept QUIC connections. Cert/key are PEM bytes;
// the caller owns the storage.
endpoint_new :: proc(
	local_addr: string,
	cert_pem:   []u8,
	key_pem:    []u8,
	local_tp:   Transport_Params,
	allocator := context.allocator,
) -> (ep: ^Endpoint, err: Endpoint_Error) {
	ep_addr, _, parse_ok := conn_parse_endpoint(local_addr)
	if !parse_ok do return nil, .Resolve_Failed

	sock, bind_err := net.make_bound_udp_socket(ep_addr.address, ep_addr.port)
	if bind_err != nil do return nil, .Bind_Failed

	ep = new(Endpoint, allocator)
	ep.socket     = sock
	ep.local_addr = ep_addr
	ep.cert_pem   = cert_pem
	ep.key_pem    = key_pem
	ep.local_tp   = local_tp
	ep.allocator  = allocator
	return ep, .None
}

// Remove every CID route pointing at `conn` so the caller can free it.
// MUST be called before conn_free for a conn the endpoint routed —
// otherwise the next datagram with that DCID dereferences freed memory.
endpoint_forget :: proc(ep: ^Endpoint, conn: ^Conn) {
	stale: [dynamic]Cid_Key
	stale.allocator = context.temp_allocator
	defer delete(stale)
	for key, c in ep.conn_by_dcid {
		if c == conn do append(&stale, key)
	}
	for key in stale do delete_key(&ep.conn_by_dcid, key)
}

// Close the listener socket and free the lookup table. Does NOT free
// accepted Conns — once they've been handed out via endpoint_accept
// their lifetime belongs to the caller.
endpoint_close :: proc(ep: ^Endpoint) {
	if ep == nil do return
	net.close(ep.socket)
	delete(ep.conn_by_dcid)
	delete(ep.pending_accept)
	free(ep, ep.allocator)
}

// Extract the DCID from a raw UDP datagram without decryption. Handles
// both long-header (Initial/Handshake/0-RTT/1-RTT after version) and
// short-header (1-RTT) packets. For short headers we assume the local
// DCID length is 8 bytes — every Conn we mint has src_cid_len = 8.
@(private)
_peek_dcid :: proc(packet: []u8) -> (key: Cid_Key, ok: bool) {
	if len(packet) < 1 do return {}, false

	if packet[0] & 0x80 != 0 {
		// Long header: type(1) + version(4) + dcid_len(1) + dcid(...)
		if len(packet) < 6 do return {}, false
		dcid_len := int(packet[5])
		if dcid_len == 0 || dcid_len > 20 do return {}, false
		if len(packet) < 6 + dcid_len do return {}, false
		k: Cid_Key
		copy(k.bytes[:], packet[6:6+dcid_len])
		k.len = u8(dcid_len)
		return k, true
	}

	// Short header: type(1) + dcid(N). N is OOB; we always use 8.
	if len(packet) < 1 + 8 do return {}, false
	k: Cid_Key
	copy(k.bytes[:], packet[1:1+8])
	k.len = 8
	return k, true
}

@(private)
_is_initial_packet :: proc(packet: []u8) -> bool {
	if len(packet) < 1 do return false
	// Long header with type bits == Initial.
	if packet[0] & 0xc0 != 0xc0 do return false
	return (packet[0] & 0x30) >> 4 == Long_Type_Initial
}

// Look up a Conn by CID, or mint a fresh server-side Conn if this is the
// first Initial packet from a new peer. Returns the routed Conn plus a
// bool indicating whether it's freshly created.
@(private)
_endpoint_route :: proc(ep: ^Endpoint, packet: []u8, src: net.Endpoint) -> (conn: ^Conn, fresh: bool, err: Quic_Error) {
	key, key_ok := _peek_dcid(packet)
	if !key_ok do return nil, false, .Encrypt_Failed // unparseable; caller will drop

	if existing, found := ep.conn_by_dcid[key]; found {
		// Update remote in case the peer NAT-rebound.
		existing.remote = src
		return existing, false, .None
	}

	// Only Initial packets create a new Conn.
	if !_is_initial_packet(packet) do return nil, false, .Encrypt_Failed

	new_conn, qerr := conn_new_server(ep.cert_pem, ep.key_pem, ep.local_tp, ep.allocator)
	if qerr != .None do return nil, false, qerr

	new_conn.socket       = ep.socket
	new_conn.socket_owned = false
	new_conn.remote       = src

	// Index under the client-chosen DCID. We'll also index under our own
	// SCID below so post-handshake packets (which use server's SCID as
	// their DCID) route correctly.
	ep.conn_by_dcid[key] = new_conn

	our_key: Cid_Key
	copy(our_key.bytes[:], new_conn.src_cid[:new_conn.src_cid_len])
	our_key.len = u8(new_conn.src_cid_len)
	ep.conn_by_dcid[our_key] = new_conn

	return new_conn, true, .None
}

// Feed one received UDP datagram to the endpoint. Routes by DCID,
// advances the chosen Conn's state machine, and flushes any handshake
// response the Conn produces. Newly-Connected Conns get queued for the
// next endpoint_accept() call.
endpoint_on_udp_recv :: proc(ep: ^Endpoint, packet: []u8, src: net.Endpoint) -> Quic_Error {
	conn, _, route_err := _endpoint_route(ep, packet, src)
	if route_err != .None || conn == nil do return route_err

	prev_state := conn.state
	rerr := conn_on_udp_recv(conn, packet)
	// Even when recv reports an error we still try to flush whatever
	// CRYPTO data BoringSSL produced — the error may be from a stray
	// packet that arrived before the handshake completed.

	_endpoint_flush(ep, conn)

	if prev_state != .Connected && conn.state == .Connected {
		append(&ep.pending_accept, conn)
	}

	if rerr != .None do return _recv_to_quic_err(rerr)
	return .None
}

// Block until a Conn's handshake completes (or `timeout` elapses) and
// return it. The caller is responsible for the Conn's lifetime from
// here on — `conn_free` cleans up Conn state but not the Endpoint's
// socket (which is shared by other in-flight Conns).
endpoint_accept :: proc(ep: ^Endpoint, timeout: time.Duration = 5 * time.Second) -> (conn: ^Conn, err: Endpoint_Error) {
	deadline := time.time_add(time.now(), timeout)
	recv_buf: [2048]u8

	for {
		if len(ep.pending_accept) > 0 {
			c := ep.pending_accept[0]
			ordered_remove(&ep.pending_accept, 0)
			return c, .None
		}
		if time.diff(time.now(), deadline) <= 0 {
			return nil, .Accept_Timeout
		}

		n, src, rerr := net.recv_udp(ep.socket, recv_buf[:])
		if rerr != nil || n == 0 do continue
		endpoint_on_udp_recv(ep, recv_buf[:n], src) // ignore errors — keep listening
	}
}

// Drain any CRYPTO data the Conn produced (ServerHello / EncryptedExtensions
// / Finished) and emit it on the shared socket. Symmetric with the client's
// conn_connect flush loop in conn_transport.odin.
@(private)
_endpoint_flush :: proc(ep: ^Endpoint, conn: ^Conn) {
	pkt: [2048]u8
	if len(conn.initial.tx_crypto) > 0 {
		if n, e := conn_build_initial_packet(conn, pkt[:]); e == .None && n > 0 {
			net.send_udp(ep.socket, pkt[:n], conn.remote)
		}
	}
	if len(conn.handshake.tx_crypto) > 0 {
		if n, e := conn_build_handshake_packet(conn, pkt[:]); e == .None && n > 0 {
			net.send_udp(ep.socket, pkt[:n], conn.remote)
		}
	}
}

@(private)
_recv_to_quic_err :: proc(rerr: Recv_Error) -> Quic_Error {
	if rerr == .None do return .None
	return .Handshake_Failed
}
