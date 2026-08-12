// Owns a UDP socket, handshake, and request dispatch to http3.Handler.
package http3

import "core:mem"
import "core:net"
import "core:strconv"
import "core:strings"
import "core:time"

import "../qpack"
import "../quic"

Http3_Server_Error :: enum {
	None,
	Server_Create_Failed,
}


// Handler receives a request and returns a response. Allocate response data
// from `allocator` (a per-request arena the server frees after sending).
Handler :: proc(req: Request, allocator: mem.Allocator) -> Response

// Serve one client connection on `sock` (already bound) until `stop^` is set.
// Non-blocking; spins with a 1ms idle sleep. Intended to run on its own thread
// or as one tick of a larger event loop (see the loop body).
serve_conn :: proc(
	sock: net.UDP_Socket, cert, key: []u8, handler: Handler,
	stop: ^bool, allocator := context.allocator,
) -> Http3_Server_Error {
	server, snerr := quic.conn_new_server(cert, key, _server_tp())
	if snerr != .None do return .Server_Create_Failed
	server.socket = sock
	server.socket_owned = false
	defer quic.conn_free(server)

	h3c: Http3_Connection
	inited := false
	defer if inited do h3_conn_destroy(&h3c)

	buf: [2048]u8
	for !stop^ {
		got := false
		for {
			n, src, r := net.recv_udp(sock, buf[:])
			if r != nil || n == 0 do break
			server.remote = src // reply to whoever is talking to us
			quic.conn_on_udp_recv(server, buf[:n])
			got = true
		}
		pump_quic_send(server)

		if server.state == .Connected && !inited {
			h3_conn_init(&h3c, server, true, DEFAULT_SETTINGS, allocator)
			inited = true
		}
		if inited {
			h3_conn_process(&h3c)
			for {
				rs, hdrs, body, ok := h3_next_request(&h3c)
				if !ok do break
				_dispatch(&h3c, rs, hdrs, body, handler)
			}
			pump_quic_send(server)
		}

		if !got do time.sleep(time.Millisecond)
	}
	return .None
}

@(private)
_dispatch :: proc(
	h3c: ^Http3_Connection, rs: Http3_Stream, hdrs: []qpack.Header, body: []u8, handler: Handler,
) {
	method, path := "", ""
	for h in hdrs {
		switch h.name {
		case ":method": method = h.value
		case ":path":   path = h.value
		}
	}

	resp := handler(Request{method, path, hdrs, body}, context.temp_allocator)

	status_buf: [8]u8
	status_str := strconv.write_int(status_buf[:], i64(resp.status), 10)
	send: [dynamic]qpack.Header
	send.allocator = context.temp_allocator
	append(&send, qpack.Header{name = ":status", value = strings.clone(status_str, context.temp_allocator), value_owned = true})
	for h in resp.headers do append(&send, h)

	h3_send_response(h3c, rs, send[:], resp.body)
	free_all(context.temp_allocator)
}

@(private)
_server_tp :: proc() -> quic.Transport_Params {
	return quic.Transport_Params {
		max_idle_timeout                    = 30_000,
		max_udp_payload_size                = 1472,
		initial_max_data                    = 10 * 1024 * 1024,
		initial_max_stream_data_bidi_local  = 1 * 1024 * 1024,
		initial_max_stream_data_bidi_remote = 1 * 1024 * 1024,
		initial_max_stream_data_uni         = 1 * 1024 * 1024,
		initial_max_streams_bidi            = 16,
		initial_max_streams_uni             = 16,
		ack_delay_exponent                  = 3,
		max_ack_delay                       = 25,
		active_connection_id_limit          = 2,
		max_datagram_frame_size             = 65527,
		disable_active_migration            = true,
	}
}
