// Mirror of server.H2_Session on the client side: you own the byte stream
// (TLS, pipe, SSH, …). Feed peer bytes, drain `session.out`, open streams with
package client

import "../http2"
import "../qpack"

// One HTTP/2 client connection: pure state + outbound frame buffer.
// Caller writes `out` after init / send / feed.
H2_Session :: struct {
	h2:  http2.Http2_Connection,
	out: [dynamic]u8,
}

// Client connection preface (magic + SETTINGS) is appended to s.out.
h2_client_session_init :: proc(s: ^H2_Session, allocator := context.allocator) {
	http2.conn_init(&s.h2, false, allocator)
	s.out.allocator = allocator
	http2.conn_send_preface(&s.h2, &s.out)
}

h2_client_session_destroy :: proc(s: ^H2_Session) {
	http2.conn_destroy(&s.h2)
	delete(s.out)
	s^ = {}
}

// Feed peer bytes. May append control frames (SETTINGS ACK, PING, WINDOW_UPDATE, …)
// to s.out. On protocol error, s.h2.fail_code is set; caller should GOAWAY and close.
h2_client_session_feed :: proc(s: ^H2_Session, inbound: []u8) -> http2.H2_Error {
	return http2.conn_feed(&s.h2, inbound, &s.out)
}

// True if request bodies are still waiting on peer flow-control credit.
// Read more peer data, feed it, and flush s.out until this is false.
h2_client_session_has_pending :: proc(s: ^H2_Session) -> bool {
	return http2.conn_has_pending_body(&s.h2)
}

// Append GOAWAY to s.out (graceful or error shutdown).
h2_client_session_goaway :: proc(s: ^H2_Session, error_code: u32 = 0) {
	code := error_code
	if code == 0 && s.h2.fail_code != 0 do code = s.h2.fail_code
	http2.goaway_write(&s.out, s.h2.last_peer_sid, code)
}

// Open a new client stream and enqueue HEADERS [+ DATA] on s.out.
// Pseudo-headers are built from `req` (method, scheme, authority, path).
h2_client_session_send_request :: proc(
	s: ^H2_Session, req: ^Request, allocator := context.allocator,
) -> u32 {
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

	return http2.conn_send_request(&s.h2, &s.out, hdrs[:], req.body)
}

// Open a stream from an explicit header list (including pseudo-headers).
// Prefer h2_client_session_send_request when you have a client.Request.
h2_client_session_send_headers :: proc(
	s: ^H2_Session, headers: []Header, body: []u8 = nil,
) -> u32 {
	return http2.conn_send_request(&s.h2, &s.out, headers, body)
}

// Response for `sid` once fully received. Headers and body borrow engine
// storage until the stream is destroyed — copy if you need them longer.
// Prefer h2_client_session_take_response to own a client.Response.
h2_client_session_response :: proc(
	s: ^H2_Session, sid: u32,
) -> (headers: []Header, body: []u8, done: bool) {
	rh, rb, ok := http2.conn_response(&s.h2, sid)
	if !ok do return nil, nil, false
	return rh, rb, true
}

// Fully-received response for `sid`, copied into a client.Response.
h2_client_session_take_response :: proc(
	s: ^H2_Session, sid: u32, allocator := context.allocator,
) -> (res: Response, ok: bool) {
	rh2, rb, done := http2.conn_response(&s.h2, sid)
	if !done do return {}, false
	return _headers_to_response(rh2, rb, .Http2, allocator), true
}

// Peer RST_STREAM or GOAWAY past this stream — never completes take_response.
h2_client_session_stream_failed :: proc(
	s: ^H2_Session, sid: u32,
) -> (code: u32, failed: bool) {
	return http2.conn_stream_failed(&s.h2, sid)
}
