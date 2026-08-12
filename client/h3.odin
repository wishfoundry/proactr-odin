// HTTP/3 convenience adapter. Unlike h1/h2 (which ride an io.Stream), h3 runs
// over QUIC: this file dials a UDP/QUIC connection, wraps it in client.H3_Session
package client

import "core:mem"
import "core:net"
import "core:strings"
import "core:time"

import "../http3"
import "../qpack"
import "../quic"

// Dial / request defaults when Options.timeout is 0 — same numbers as
// DEFAULT_DIAL_TIMEOUT_MS / DEFAULT_REQUEST_TIMEOUT_MS (client.odin).
H3_DIAL_TIMEOUT    :: time.Duration(DEFAULT_DIAL_TIMEOUT_MS) * time.Millisecond
H3_REQUEST_TIMEOUT :: time.Duration(DEFAULT_REQUEST_TIMEOUT_MS) * time.Millisecond

// The h3 transport, held by Connection.transport's h3 arm: a QUIC connection +
// H3_Session (engine) + the authority (for the :authority pseudo-header).
Http3_State :: struct {
	session:   H3_Session,
	h3_inited: bool,
	authority: string,
	allocator: mem.Allocator,
}

// Dial host:port over QUIC (ALPN h3), init H3_Session, exchange SETTINGS.
// `host` is unbracketed (IPv6 as `::1`); SNI uses host, connect uses
// format_dial_endpoint, and :authority uses format_authority.
// Certificate verification is on by default; `insecure` opts out.
// `timeout_ms` 0 → DEFAULT_DIAL_TIMEOUT_MS / H3_DIAL_TIMEOUT.
@(private)
_h3_dial :: proc(
	host: string, port: int, scheme: string,
	insecure: bool, timeout_ms: int = 0, allocator := context.allocator,
) -> (^Http3_State, Http_Error) {
	p := port
	if p == 0 do p = 443
	sch := scheme if len(scheme) > 0 else "https"
	endpoint := format_dial_endpoint(host, p)

	st := new(Http3_State, allocator)
	st.allocator = allocator
	// Own the authority string for the life of the connection.
	st.authority = strings.clone(format_authority(sch, host, p), allocator)

	alpn := [3]u8{2, 'h', '3'}
	conn, cerr := quic.conn_new(host, alpn[:], _h3_transport_params())
	if cerr != .None {
		delete(st.authority, allocator)
		free(st, allocator)
		return nil, .Tls_Failed
	}
	if insecure do quic.conn_disable_verify(conn)

	dial_to := time.Duration(_resolve_dial_timeout_ms(timeout_ms)) * time.Millisecond
	#partial switch quic.conn_connect(conn, endpoint, dial_to) {
	case .None:
	case .Timeout:        quic.conn_udp_close(conn); quic.conn_free(conn); delete(st.authority, allocator); free(st, allocator); return nil, .Timeout
	case .Resolve_Failed: quic.conn_udp_close(conn); quic.conn_free(conn); delete(st.authority, allocator); free(st, allocator); return nil, .Resolve_Failed
	case:                 quic.conn_udp_close(conn); quic.conn_free(conn); delete(st.authority, allocator); free(st, allocator); return nil, .Connect_Failed
	}
	net.set_blocking(conn.socket, false)

	if h3_client_session_init(&st.session, conn, http3.DEFAULT_SETTINGS, allocator) != .None {
		quic.conn_udp_close(conn)
		quic.conn_free(conn)
		delete(st.authority, allocator)
		free(st, allocator)
		return nil, .Protocol
	}
	st.h3_inited = true

	deadline := time.time_add(time.now(), dial_to)
	for time.diff(time.now(), deadline) > 0 {
		n_recv := http3.pump_quic_recv(conn)
		_ = h3_client_session_process(&st.session)
		if h3_client_session_peer_settings_ready(&st.session) {
			_ = http3.pump_quic_send(conn)
			return st, .None
		}
		_ = http3.pump_quic_send(conn)
		if n_recv == 0 do time.sleep(time.Millisecond)
	}
	_h3_close(st)
	return nil, .Timeout
}

// Send one request over the h3 connection and read its response.
// `timeout_ms` 0 → DEFAULT_REQUEST_TIMEOUT_MS. `max_body` 0 → DEFAULT_MAX_RESPONSE_BODY.
@(private)
_h3_do :: proc(
	st: ^Http3_State, req: ^Request, allocator: mem.Allocator,
	timeout_ms: int = 0, max_body: int = 0, accept_gzip := false,
) -> (Response, Http_Error) {
	headers: [dynamic]Header
	headers.allocator = context.temp_allocator
	scheme := req.target.scheme if len(req.target.scheme) > 0 else "https"
	// Prefer request target authority when filled; fall back to dial-time authority.
	authority := st.authority
	if len(req.target.host) > 0 {
		authority = format_authority(req.target.scheme, req.target.host, req.target.port)
	}
	append(&headers, Header{name = ":method", value = req.method})
	append(&headers, Header{name = ":scheme", value = scheme})
	append(&headers, Header{name = ":authority", value = authority})
	append(&headers, Header{name = ":path", value = req.target.path})
	if !_headers_has_ci(req.headers[:], "user-agent") {
		append(&headers, Header{name = "user-agent", value = DEFAULT_USER_AGENT})
	}
	if accept_gzip && !_headers_has_ci(req.headers[:], "accept-encoding") {
		append(&headers, Header{name = "accept-encoding", value = "gzip"})
	}
	for h in req.headers do append(&headers, Header{name = h.name, value = h.value})

	rs, e := h3_client_session_send_headers(&st.session, headers[:], req.body)
	if e != .None do return {}, .Protocol

	limit := _resolve_max_body(max_body)
	conn := st.session.conn
	req_to := _resolve_request_timeout(timeout_ms)
	deadline := time.time_add(time.now(), req_to)
	for time.diff(time.now(), deadline) > 0 {
		// Recv first so ACKs / flow-control updates run before the next send.
		n_recv := http3.pump_quic_recv(conn)
		_ = h3_client_session_process(&st.session)
		// Early reject while body is still accumulating in the engine.
		if _, body, done := h3_client_session_response(&st.session, rs); len(body) > limit {
			return {}, .Body_Too_Large
		} else if done {
			res, ok := h3_client_session_take_response(&st.session, rs, allocator)
			_ = http3.pump_quic_send(conn)
			if !ok do return {}, .Protocol
			if len(res.body) > limit {
				response_destroy(&res, allocator)
				return {}, .Body_Too_Large
			}
			return res, .None
		}
		_ = http3.pump_quic_send(conn)
		// Work-conserving: spin while datagrams are arriving or we still owe
		// stream bytes (large responses under a small congestion window).
		if n_recv > 0 || quic.conn_has_unsent_stream_data(conn) {
			continue
		}
		time.sleep(time.Millisecond)
	}
	return {}, .Timeout
}

@(private)
_h3_close :: proc(st: ^Http3_State) {
	if st == nil do return
	conn := st.session.conn
	if st.h3_inited {
		h3_client_session_destroy(&st.session)
		st.h3_inited = false
	}
	if conn != nil {
		quic.conn_udp_close(conn)
		quic.conn_free(conn)
	}
	delete(st.authority, st.allocator)
	free(st, st.allocator)
}

@(private)
_h3_transport_params :: proc() -> quic.Transport_Params {
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
