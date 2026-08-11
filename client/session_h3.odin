// LIBRARY CORE — HTTP/3 client connection session (sans-I/O).
//
// Mirror of server.H3_Session / client.H2_Session on the client side: you own
// the QUIC connection's I/O (UDP recv → conn_on_udp_recv / conn_poll_recv;
// conn_poll_send → sendto). This type wraps http3.Http3_Connection. No
// threads, no sockets — only framing / QPACK / stream state over a ^quic.Conn
// that is already Connected (post-handshake, ALPN h3).
//
// Pull-based state machine (typical non-blocking host):
//   1. h3_client_session_init(s, connected_quic_conn)
//   2. poll_send SETTINGS; on datagram: poll_recv → process until
//      h3_client_session_peer_settings_ready
//   3. stream := h3_client_session_send_request(s, &req)  // queues on conn
//   4. poll_send; on datagram: poll_recv → process
//   5. take_response(stream) when done
//
// You own quic.conn_poll_recv / conn_poll_send (or http3.pump_quic_* adapters).
// Blocking dial/request (Options.version = .Http3) is a convenience adapter
// that drives this session with a sleep-poll loop — see client/h3.odin.
// See docs/LIBRARY.md.
package client

import "../http3"
import "../qpack"
import "../quic"

// One HTTP/3 client connection over an existing, Connected quic.Conn.
// Name is package-local: client.H3_Session vs server.H3_Session.
H3_Session :: struct {
	conn: ^quic.Conn,
	h3:   http3.Http3_Connection,
}

// Init the h3 client engine on `conn` (must already be Connected / post-handshake
// with ALPN h3). Opens control + QPACK uni streams and queues local SETTINGS —
// you must flush QUIC (`quic.conn_poll_send` or `http3.pump_quic_send`) after
// init. Does not take ownership of `conn`; destroy frees engine state only.
h3_client_session_init :: proc(
	s: ^H3_Session, conn: ^quic.Conn,
	settings := http3.DEFAULT_SETTINGS, allocator := context.allocator,
) -> http3.Http3_Error {
	s.conn = conn
	return http3.h3_conn_init(&s.h3, conn, false, settings, allocator)
}

// Destroy the h3 engine. Does **not** close or free `s.conn` — you own the QUIC
// connection (UDP socket, conn_free, …).
h3_client_session_destroy :: proc(s: ^H3_Session) {
	http3.h3_conn_destroy(&s.h3)
	s.conn = nil
	s.h3 = {}
}

// Advance h3 framing / QPACK after new stream data has been delivered on conn
// (call after poll_recv / conn_on_udp_recv). May queue more stream bytes —
// flush QUIC after process.
h3_client_session_process :: proc(s: ^H3_Session) -> http3.Http3_Error {
	return http3.h3_conn_process(&s.h3)
}

// True once peer SETTINGS have been received (safe to send requests).
h3_client_session_peer_settings_ready :: proc(s: ^H3_Session) -> bool {
	return s.h3.peer_settings_received
}

// Open a client bidi stream and enqueue HEADERS [+ DATA] + FIN on the QUIC
// connection. Pseudo-headers are built from `req` (method, scheme, authority,
// path). Flush QUIC after calling. Returns the stream token for take_response.
h3_client_session_send_request :: proc(
	s: ^H3_Session, req: ^Request, allocator := context.allocator,
) -> (http3.Http3_Stream, http3.Http3_Error) {
	hdrs: [dynamic]Header
	hdrs.allocator = allocator
	defer delete(hdrs)

	scheme := req.target.scheme if req.target.scheme != "" else "https"
	authority := format_authority(req.target.scheme, req.target.host, req.target.port)
	path := req.target.path if req.target.path != "" else "/"

	append(&hdrs, Header{name = ":method", value = req.method if req.method != "" else "GET"})
	append(&hdrs, Header{name = ":scheme", value = scheme})
	append(&hdrs, Header{name = ":authority", value = authority})
	append(&hdrs, Header{name = ":path", value = path})
	for h in req.headers {
		append(&hdrs, Header{name = h.name, value = h.value})
	}

	return http3.h3_send_request(&s.h3, hdrs[:], req.body)
}

// Open a stream from an explicit header list (including pseudo-headers).
// Prefer h3_client_session_send_request when you have a client.Request.
h3_client_session_send_headers :: proc(
	s: ^H3_Session, headers: []Header, body: []u8 = nil,
) -> (http3.Http3_Stream, http3.Http3_Error) {
	return http3.h3_send_request(&s.h3, headers, body)
}

// Response for `stream` once fully received. Headers and body borrow engine
// storage until the stream is destroyed — copy if you need them longer.
// Prefer h3_client_session_take_response to own a client.Response.
h3_client_session_response :: proc(
	s: ^H3_Session, stream: http3.Http3_Stream,
) -> (headers: []Header, body: []u8, done: bool) {
	return http3.h3_response(&s.h3, stream)
}

// Fully-received response for `stream`, copied into a client.Response.
// Returns ok=false if the stream is not yet complete.
h3_client_session_take_response :: proc(
	s: ^H3_Session, stream: http3.Http3_Stream, allocator := context.allocator,
) -> (res: Response, ok: bool) {
	rh, rb, done := http3.h3_response(&s.h3, stream)
	if !done do return {}, false
	return _headers_to_response(rh, rb, .Http3, allocator), true
}

// Graceful GOAWAY on the control stream (then flush QUIC yourself).
// `id` 0 → max known request stream id + 4 (next unhandled).
h3_client_session_goaway :: proc(s: ^H3_Session, id: u64 = 0) {
	goaway_id := id
	if goaway_id == 0 {
		for sid in s.h3.xs do goaway_id = max(goaway_id, sid + 4)
	}
	_ = http3.h3_send_goaway(&s.h3, goaway_id)
}
