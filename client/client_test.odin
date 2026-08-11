package client

import "core:fmt"
import "core:io"
import "core:mem"
import "core:strings"
import "core:testing"

import "../http2"

// An in-memory duplex stream: serves `to_send` on Read (then EOF), captures
// everything written. Proves the client drives a real HTTP/1.1 exchange over an
// ARBITRARY io.Stream — the dialer-flexibility thesis, no socket involved.
@(private = "file")
Mock_Stream :: struct {
	to_send:  []u8,
	pos:      int,
	captured: [dynamic]u8,
}

@(private = "file")
_mock_proc :: proc(
	stream_data: rawptr, mode: io.Stream_Mode, p: []byte, offset: i64, whence: io.Seek_From,
) -> (n: i64, err: io.Error) {
	m := (^Mock_Stream)(stream_data)
	#partial switch mode {
	case .Query:
		return io.query_utility(io.Stream_Mode_Set{.Query, .Read, .Write, .Close})
	case .Write:
		append(&m.captured, ..p)
		return i64(len(p)), .None
	case .Read:
		if m.pos >= len(m.to_send) do return 0, .EOF
		k := copy(p, m.to_send[m.pos:])
		m.pos += k
		return i64(k), .None
	case .Close:
		return 0, .None
	}
	return 0, .Empty
}

// A Dialer that hands back our in-memory stream (its userdata is the ^Mock_Stream).
// Reports target.version as negotiated (or .Http1 when Auto) so ALPN-trust tests work.
@(private = "file")
_mock_dial :: proc(
	data: rawptr, target: Target, allocator: mem.Allocator,
) -> (io.Stream, ProtocolVersion, Http_Error) {
	m := (^Mock_Stream)(data)
	v := target.version if target.version != .Auto else ProtocolVersion.Http1
	return io.Stream{data = m, procedure = _mock_proc}, v, .None
}

// Always claims .Http1 regardless of target — for mismatch tests.
@(private = "file")
_mock_dial_h1_only :: proc(
	data: rawptr, target: Target, allocator: mem.Allocator,
) -> (io.Stream, ProtocolVersion, Http_Error) {
	m := (^Mock_Stream)(data)
	return io.Stream{data = m, procedure = _mock_proc}, .Http1, .None
}

@(test)
test_unified_get_over_arbitrary_stream :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	m := Mock_Stream {
		to_send = transmute([]u8)string(
			"HTTP/1.1 200 OK\r\ncontent-type: text/plain\r\ncontent-length: 5\r\n\r\nhello",
		),
	}
	defer delete(m.captured)

	// Hand the client our in-memory stream via the pluggable Dialer.
	opts := Options{version = .Http1, dialer = Dialer{data = &m, procedure = _mock_dial}}
	res, err := get("http://example.com/path", opts)
	defer response_destroy(&res)

	testing.expect_value(t, err, Http_Error.None)
	testing.expect_value(t, res.status, Status.OK)
	testing.expect_value(t, res.version, ProtocolVersion.Http1)
	testing.expect_value(t, string(res.body[:]), "hello")

	ct := ""
	for h in res.headers do if h.name == "content-type" do ct = h.value
	testing.expect_value(t, ct, "text/plain")

	// The request we wrote out went onto the stream, correctly formed.
	sent := string(m.captured[:])
	testing.expect(t, strings.has_prefix(sent, "GET /path HTTP/1.1\r\n"), "request line")
	testing.expect(t, strings.contains(sent, "host: example.com\r\n"), "host header")
}

@(test)
test_unified_get_http2_over_stream :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	// Pre-generate a canned HTTP/2 server response on stream 1 (preface SETTINGS
	// + HEADERS + DATA), using a real server-side http2.Http2_Connection.
	srv: http2.Http2_Connection
	http2.conn_init(&srv, true)
	defer http2.conn_destroy(&srv)
	canned: [dynamic]u8
	defer delete(canned)
	http2.conn_send_preface(&srv, &canned)
	resp_hdrs := []Header{{name = ":status", value = "200"}, {name = "content-type", value = "text/plain"}}
	http2.conn_send_response(&srv, &canned, 1, resp_hdrs, transmute([]u8)string("h2 body"))

	m := Mock_Stream{to_send = canned[:]}
	defer delete(m.captured)

	opts := Options{version = .Http2, dialer = Dialer{data = &m, procedure = _mock_dial}}
	res, err := get("http://example.com/", opts)
	defer response_destroy(&res)

	testing.expect_value(t, err, Http_Error.None)
	testing.expect_value(t, res.status, Status.OK)
	testing.expect_value(t, res.version, ProtocolVersion.Http2)
	testing.expect_value(t, string(res.body[:]), "h2 body")
	// The client emitted the HTTP/2 connection preface onto the stream.
	testing.expect(t, strings.has_prefix(string(m.captured[:]), "PRI * HTTP/2.0"), "h2 preface sent")
}

@(test)
test_target_parsing :: proc(t: ^testing.T) {
	Case :: struct {
		url:    string,
		host:   string,
		port:   int,
		path:   string,
		scheme: string,
	}
	cases := []Case {
		{"http://example.com/", "example.com", 80, "/", "http"},
		{"https://example.com/a/b", "example.com", 443, "/a/b", "https"},
		{"https://host:8443/x", "host", 8443, "/x", "https"},
		{"http://h", "h", 80, "/", "http"},
		// IPv6 literals (RFC 3986 brackets); host stored unbracketed.
		{"http://[::1]/", "::1", 80, "/", "http"},
		{"https://[::1]/", "::1", 443, "/", "https"},
		{"http://[2001:db8::1]:8080/p", "2001:db8::1", 8080, "/p", "http"},
		{"https://[2001:db8::1]:8443/x", "2001:db8::1", 8443, "/x", "https"},
	}
	for c in cases {
		tgt, ok := parse_target(c.url)
		testing.expect(t, ok, c.url)
		testing.expect_value(t, tgt.host, c.host)
		testing.expect_value(t, tgt.port, c.port)
		testing.expect_value(t, tgt.path, c.path)
		testing.expect_value(t, tgt.scheme, c.scheme)
	}
	// Bare IPv6 without brackets is rejected.
	_, bad := parse_target("http://2001:db8::1/")
	testing.expect(t, !bad, "unbracketed IPv6 must fail")
}

// Forced version must match dialer negotiation (Chrome trusts ALPN).
@(test)
test_alpn_trust_rejects_mismatch :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	m := Mock_Stream {
		to_send = transmute([]u8)string("HTTP/1.1 200 OK\r\ncontent-length: 0\r\n\r\n"),
	}
	defer delete(m.captured)

	opts := Options {
		version = .Http2,
		dialer  = Dialer{data = &m, procedure = _mock_dial_h1_only},
	}
	c, err := dial("http://example.com/", opts)
	testing.expect_value(t, err, Http_Error.Unsupported_Version)
	testing.expect(t, c == nil, "no connection on mismatch")
}

// H1 keep-alive: two requests, one connection, content-length framing.
@(test)
test_h1_keep_alive_two_requests :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	m := Mock_Stream {
		to_send = transmute([]u8)string(
			"HTTP/1.1 200 OK\r\ncontent-length: 3\r\n\r\none" +
			"HTTP/1.1 200 OK\r\ncontent-length: 3\r\n\r\ntwo",
		),
	}
	defer delete(m.captured)

	opts := Options {
		version = .Http1,
		dialer  = Dialer{data = &m, procedure = _mock_dial},
	}
	c, err := dial("http://example.com/", opts)
	testing.expect_value(t, err, Http_Error.None)
	defer close(c)

	req1 := Request{method = "GET", target = c.target}
	req1.target.path = "/a"
	r1, e1 := request(c, &req1)
	defer response_destroy(&r1)
	testing.expect_value(t, e1, Http_Error.None)
	testing.expect_value(t, string(r1.body[:]), "one")
	testing.expect(t, c.h1_alive, "still alive after first")

	req2 := Request{method = "GET", target = c.target}
	req2.target.path = "/b"
	r2, e2 := request(c, &req2)
	defer response_destroy(&r2)
	testing.expect_value(t, e2, Http_Error.None)
	testing.expect_value(t, string(r2.body[:]), "two")

	sent := string(m.captured[:])
	testing.expect(t, strings.contains(sent, "GET /a HTTP/1.1"), "first req")
	testing.expect(t, strings.contains(sent, "GET /b HTTP/1.1"), "second req")
	testing.expect(t, strings.contains(sent, "connection: keep-alive"), "keep-alive offered")
}

@(test)
test_alt_svc_parse_h3 :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	entries, clear, ok := alt_svc_parse(`h3=":443"; ma=3600`, context.temp_allocator)
	testing.expect(t, ok)
	testing.expect(t, !clear)
	testing.expect_value(t, len(entries), 1)
	testing.expect_value(t, entries[0].protocol, "h3")
	testing.expect_value(t, entries[0].port, 443)
	testing.expect_value(t, entries[0].host, "")

	entries2, clear2, ok2 := alt_svc_parse(`h3="alt.example.com:8443"; ma=60, h2=":443"`, context.temp_allocator)
	testing.expect(t, ok2 && !clear2)
	testing.expect(t, len(entries2) >= 1)
	testing.expect(t, alt_svc_is_h3(entries2[0].protocol))
	testing.expect_value(t, entries2[0].host, "alt.example.com")
	testing.expect_value(t, entries2[0].port, 8443)

	_, clear3, ok3 := alt_svc_parse("clear", context.temp_allocator)
	testing.expect(t, ok3 && clear3)
}

@(test)
test_alt_svc_cache_learn_and_lookup :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	cache: Alt_Svc_Cache
	defer alt_svc_cache_clear(&cache)

	hdrs := []Header{{name = "alt-svc", value = `h3=":4433"; ma=86400`}}
	alt_svc_learn_from_headers(&cache, "https", "example.com", 443, hdrs)

	e, ok := alt_svc_cache_lookup(&cache, "https", "example.com", 443)
	testing.expect(t, ok)
	testing.expect(t, alt_svc_is_h3(e.protocol))
	testing.expect_value(t, e.port, 4433)
	testing.expect_value(t, e.host, "")

	// clear wipes the origin
	alt_svc_learn_from_headers(&cache, "https", "example.com", 443, []Header{{name = "alt-svc", value = "clear"}})
	_, ok2 := alt_svc_cache_lookup(&cache, "https", "example.com", 443)
	testing.expect(t, !ok2)
}

// Response Alt-Svc is learned onto the connection's cache.
@(test)
test_request_learns_alt_svc :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	cache: Alt_Svc_Cache
	defer alt_svc_cache_clear(&cache)

	m := Mock_Stream {
		to_send = transmute([]u8)string(
			"HTTP/1.1 200 OK\r\ncontent-length: 2\r\nalt-svc: h3=\":443\"; ma=60\r\n\r\nok",
		),
	}
	defer delete(m.captured)

	opts := Options {
		version        = .Http1,
		dialer         = Dialer{data = &m, procedure = _mock_dial},
		alt_svc_cache  = &cache, // attach private cache for learning (no follow needed)
	}
	c, err := dial("https://example.com/", opts)
	testing.expect_value(t, err, Http_Error.None)
	defer close(c)

	req := Request{method = "GET", target = c.target}
	res, e := request(c, &req)
	defer response_destroy(&res)
	testing.expect_value(t, e, Http_Error.None)

	ent, hit := alt_svc_cache_lookup(&cache, "https", "example.com", 443)
	testing.expect(t, hit)
	testing.expect_value(t, ent.port, 443)
}

// Package defaults when Options fields are 0 (documented contract).
@(test)
test_client_limit_defaults :: proc(t: ^testing.T) {
	testing.expect_value(t, DEFAULT_DIAL_TIMEOUT_MS, 10_000)
	testing.expect_value(t, DEFAULT_REQUEST_TIMEOUT_MS, 30_000)
	testing.expect_value(t, DEFAULT_MAX_RESPONSE_BODY, 32 * 1024 * 1024)
	testing.expect_value(t, DEFAULT_MAX_REDIRECTS, 10)
	testing.expect_value(t, DEFAULT_USER_AGENT, "vapor-http/client")
	testing.expect_value(t, _resolve_max_body(0), DEFAULT_MAX_RESPONSE_BODY)
	testing.expect_value(t, _resolve_max_body(100), 100)
	testing.expect_value(t, _resolve_dial_timeout_ms(0), DEFAULT_DIAL_TIMEOUT_MS)
	testing.expect_value(t, _resolve_request_timeout_ms(0), DEFAULT_REQUEST_TIMEOUT_MS)
	testing.expect_value(t, _resolve_dial_timeout_ms(1500), 1500)
	testing.expect_value(t, _resolve_max_redirects(0), DEFAULT_MAX_REDIRECTS)
	testing.expect_value(t, _resolve_max_redirects(-1), -1)
	testing.expect_value(t, _resolve_max_redirects(-5), -1)
	testing.expect_value(t, _resolve_max_redirects(3), 3)
}

// Default User-Agent is injected when the caller did not set one.
@(test)
test_default_user_agent_header :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	m := Mock_Stream {
		to_send = transmute([]u8)string("HTTP/1.1 200 OK\r\ncontent-length: 0\r\n\r\n"),
	}
	defer delete(m.captured)

	opts := Options{version = .Http1, dialer = Dialer{data = &m, procedure = _mock_dial}}
	res, err := get("http://example.com/", opts)
	defer response_destroy(&res)
	testing.expect_value(t, err, Http_Error.None)

	sent := string(m.captured[:])
	testing.expect(t, strings.contains(sent, "user-agent: vapor-http/client\r\n"), "default UA")
	testing.expect(t, strings.contains(sent, "host: example.com\r\n"), "host header")
}

// Caller-supplied User-Agent is not overridden.
@(test)
test_user_agent_not_overridden :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	m := Mock_Stream {
		to_send = transmute([]u8)string("HTTP/1.1 200 OK\r\ncontent-length: 0\r\n\r\n"),
	}
	defer delete(m.captured)

	opts := Options{version = .Http1, dialer = Dialer{data = &m, procedure = _mock_dial}}
	c, err := dial("http://example.com/", opts)
	testing.expect_value(t, err, Http_Error.None)
	defer close(c)

	req := Request{method = "GET", target = c.target}
	req.headers.allocator = context.temp_allocator
	append(&req.headers, Header{name = "User-Agent", value = "my-app/1.0"})
	res, e := request(c, &req)
	defer response_destroy(&res)
	testing.expect_value(t, e, Http_Error.None)

	sent := string(m.captured[:])
	testing.expect(t, strings.contains(sent, "User-Agent: my-app/1.0\r\n"), "custom UA kept")
	testing.expect(t, !strings.contains(sent, "vapor-http/client"), "default UA not added")
}

// Same-origin 302 chain over H1 keep-alive: relative Location then final 200.
@(test)
test_redirect_relative_chain :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	m := Mock_Stream {
		to_send = transmute([]u8)string(
			"HTTP/1.1 302 Found\r\nlocation: /step2\r\ncontent-length: 0\r\n\r\n" +
			"HTTP/1.1 302 Found\r\nlocation: final\r\ncontent-length: 0\r\n\r\n" +
			"HTTP/1.1 200 OK\r\ncontent-length: 4\r\n\r\ndone",
		),
	}
	defer delete(m.captured)

	opts := Options{version = .Http1, dialer = Dialer{data = &m, procedure = _mock_dial}}
	res, err := get("http://example.com/start", opts)
	defer response_destroy(&res)

	testing.expect_value(t, err, Http_Error.None)
	testing.expect_value(t, res.status, Status.OK)
	testing.expect_value(t, string(res.body[:]), "done")

	sent := string(m.captured[:])
	testing.expect(t, strings.contains(sent, "GET /start HTTP/1.1"), "first hop")
	testing.expect(t, strings.contains(sent, "GET /step2 HTTP/1.1"), "absolute-path hop")
	// relative "final" resolves against directory of /step2 → /final
	testing.expect(t, strings.contains(sent, "GET /final HTTP/1.1"), "relative hop")
}

// Absolute Location to another host triggers a re-dial.
@(test)
test_redirect_cross_host_redial :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	// Dialer serves successive canned responses and records dial hosts.
	Dual :: struct {
		to_send:  [2][]u8,
		dial_n:   int,
		captured: [dynamic]u8,
		hosts:    [dynamic]string,
	}
	Slot :: struct {
		dual: ^Dual,
		idx:  int,
		pos:  int,
	}
	dual := Dual {
		to_send = {
			transmute([]u8)string("HTTP/1.1 301 Moved Permanently\r\nlocation: http://second.example/here\r\ncontent-length: 0\r\n\r\n"),
			transmute([]u8)string("HTTP/1.1 200 OK\r\ncontent-length: 2\r\n\r\nok"),
		},
	}
	dual.captured.allocator = context.allocator
	dual.hosts.allocator = context.allocator
	defer delete(dual.captured)
	defer delete(dual.hosts)

	dual_proc :: proc(
		stream_data: rawptr, mode: io.Stream_Mode, p: []byte, offset: i64, whence: io.Seek_From,
	) -> (n: i64, err: io.Error) {
		s := (^Slot)(stream_data)
		#partial switch mode {
		case .Query:
			return io.query_utility(io.Stream_Mode_Set{.Query, .Read, .Write, .Close})
		case .Write:
			append(&s.dual.captured, ..p)
			return i64(len(p)), .None
		case .Read:
			src := s.dual.to_send[s.idx]
			if s.pos >= len(src) do return 0, .EOF
			k := copy(p, src[s.pos:])
			s.pos += k
			return i64(k), .None
		case .Close:
			return 0, .None
		}
		return 0, .Empty
	}

	dual_dial :: proc(
		data: rawptr, target: Target, allocator: mem.Allocator,
	) -> (io.Stream, ProtocolVersion, Http_Error) {
		d := (^Dual)(data)
		idx := d.dial_n
		if idx > 1 do idx = 1
		d.dial_n += 1
		append(&d.hosts, strings.clone(target.host, context.temp_allocator))
		slot := new(Slot, context.temp_allocator)
		slot.dual = d
		slot.idx = idx
		return io.Stream{data = slot, procedure = dual_proc}, .Http1, .None
	}

	opts := Options {
		version = .Http1,
		dialer  = Dialer{data = &dual, procedure = dual_dial},
	}
	res, err := get("http://first.example/", opts)
	defer response_destroy(&res)

	testing.expect_value(t, err, Http_Error.None)
	testing.expect_value(t, res.status, Status.OK)
	testing.expect_value(t, string(res.body[:]), "ok")
	testing.expect_value(t, dual.dial_n, 2)
	testing.expect(t, len(dual.hosts) >= 2, "two dials")
	if len(dual.hosts) >= 2 {
		testing.expect_value(t, dual.hosts[0], "first.example")
		testing.expect_value(t, dual.hosts[1], "second.example")
	}
	sent := string(dual.captured[:])
	testing.expect(t, strings.contains(sent, "GET / HTTP/1.1"), "first path")
	testing.expect(t, strings.contains(sent, "GET /here HTTP/1.1"), "redirect path")
	testing.expect(t, strings.contains(sent, "host: second.example\r\n"), "new host")
}

// 303 See Other forces GET and drops the body (POST → GET).
@(test)
test_redirect_303_post_to_get :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	m := Mock_Stream {
		to_send = transmute([]u8)string(
			"HTTP/1.1 303 See Other\r\nlocation: /result\r\ncontent-length: 0\r\n\r\n" +
			"HTTP/1.1 200 OK\r\ncontent-length: 2\r\n\r\nok",
		),
	}
	defer delete(m.captured)

	opts := Options{version = .Http1, dialer = Dialer{data = &m, procedure = _mock_dial}}
	c, err := dial("http://example.com/submit", opts)
	testing.expect_value(t, err, Http_Error.None)
	defer close(c)

	req := Request {
		method = "POST",
		target = c.target,
		body   = transmute([]u8)string("payload"),
	}
	req.headers.allocator = context.temp_allocator
	append(&req.headers, Header{name = "content-type", value = "text/plain"})
	res, e := request(c, &req)
	defer response_destroy(&res)

	testing.expect_value(t, e, Http_Error.None)
	testing.expect_value(t, res.status, Status.OK)

	sent := string(m.captured[:])
	testing.expect(t, strings.contains(sent, "POST /submit HTTP/1.1"), "original POST")
	testing.expect(t, strings.contains(sent, "GET /result HTTP/1.1"), "303 becomes GET")
	// Second request must not re-send the body.
	// Count "payload" occurrences — only the first request.
	testing.expect_value(t, strings.count(sent, "payload"), 1)
}

// 307 keeps method and body.
@(test)
test_redirect_307_keeps_post :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	m := Mock_Stream {
		to_send = transmute([]u8)string(
			"HTTP/1.1 307 Temporary Redirect\r\nlocation: /other\r\ncontent-length: 0\r\n\r\n" +
			"HTTP/1.1 200 OK\r\ncontent-length: 2\r\n\r\nok",
		),
	}
	defer delete(m.captured)

	opts := Options{version = .Http1, dialer = Dialer{data = &m, procedure = _mock_dial}}
	c, err := dial("http://example.com/submit", opts)
	testing.expect_value(t, err, Http_Error.None)
	defer close(c)

	req := Request {
		method = "POST",
		target = c.target,
		body   = transmute([]u8)string("payload"),
	}
	res, e := request(c, &req)
	defer response_destroy(&res)

	testing.expect_value(t, e, Http_Error.None)
	testing.expect_value(t, res.status, Status.OK)

	sent := string(m.captured[:])
	testing.expect(t, strings.contains(sent, "POST /submit HTTP/1.1"), "first POST")
	testing.expect(t, strings.contains(sent, "POST /other HTTP/1.1"), "307 keeps POST")
	testing.expect_value(t, strings.count(sent, "payload"), 2)
}

// max_redirects < 0 → never follow; return the 3xx response.
@(test)
test_redirect_disabled :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	m := Mock_Stream {
		to_send = transmute([]u8)string(
			"HTTP/1.1 302 Found\r\nlocation: /elsewhere\r\ncontent-length: 0\r\n\r\n",
		),
	}
	defer delete(m.captured)

	opts := Options {
		version       = .Http1,
		dialer        = Dialer{data = &m, procedure = _mock_dial},
		max_redirects = -1,
	}
	res, err := get("http://example.com/", opts)
	defer response_destroy(&res)

	testing.expect_value(t, err, Http_Error.None)
	testing.expect_value(t, res.status, Status.Found)
	sent := string(m.captured[:])
	testing.expect(t, !strings.contains(sent, "GET /elsewhere"), "did not follow")
}

// max_redirects budget: chain longer than limit returns the last 3xx.
@(test)
test_redirect_max_limit :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	m := Mock_Stream {
		to_send = transmute([]u8)string(
			"HTTP/1.1 302 Found\r\nlocation: /a\r\ncontent-length: 0\r\n\r\n" +
			"HTTP/1.1 302 Found\r\nlocation: /b\r\ncontent-length: 0\r\n\r\n" +
			"HTTP/1.1 302 Found\r\nlocation: /c\r\ncontent-length: 0\r\n\r\n" +
			"HTTP/1.1 200 OK\r\ncontent-length: 2\r\n\r\nok",
		),
	}
	defer delete(m.captured)

	opts := Options {
		version       = .Http1,
		dialer        = Dialer{data = &m, procedure = _mock_dial},
		max_redirects = 2, // follow at most two hops
	}
	res, err := get("http://example.com/", opts)
	defer response_destroy(&res)

	testing.expect_value(t, err, Http_Error.None)
	// After / → /a → /b (2 follows), stop on the 302 to /c.
	testing.expect_value(t, res.status, Status.Found)
	loc, ok := _headers_get_ci(res.headers[:], "location")
	testing.expect(t, ok)
	testing.expect_value(t, loc, "/c")

	sent := string(m.captured[:])
	testing.expect(t, strings.contains(sent, "GET /a HTTP/1.1"), "followed /a")
	testing.expect(t, strings.contains(sent, "GET /b HTTP/1.1"), "followed /b")
	testing.expect(t, !strings.contains(sent, "GET /c HTTP/1.1"), "did not follow /c")
}

// Location resolution unit checks.
@(test)
test_resolve_redirect_target :: proc(t: ^testing.T) {
	base := Target{scheme = "http", host = "ex.com", port = 80, path = "/dir/page"}

	abs, ok := _resolve_redirect_target(base, "https://other.com:8443/x")
	testing.expect(t, ok)
	testing.expect_value(t, abs.scheme, "https")
	testing.expect_value(t, abs.host, "other.com")
	testing.expect_value(t, abs.port, 8443)
	testing.expect_value(t, abs.path, "/x")

	path, ok2 := _resolve_redirect_target(base, "/abs")
	testing.expect(t, ok2)
	testing.expect_value(t, path.host, "ex.com")
	testing.expect_value(t, path.path, "/abs")

	rel, ok3 := _resolve_redirect_target(base, "peer")
	testing.expect(t, ok3)
	testing.expect_value(t, rel.path, "/dir/peer")

	scheme_rel, ok4 := _resolve_redirect_target(base, "//cdn.ex.com/a")
	testing.expect(t, ok4)
	testing.expect_value(t, scheme_rel.host, "cdn.ex.com")
	testing.expect_value(t, scheme_rel.path, "/a")
	testing.expect_value(t, scheme_rel.scheme, "http")
}

// Content-Length over max_response_body → Body_Too_Large without buffering the body.
@(test)
test_h1_body_too_large_content_length :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	// Claim 1000 bytes, only deliver a few — client rejects on CL before waiting for all.
	m := Mock_Stream {
		to_send = transmute([]u8)string(
			"HTTP/1.1 200 OK\r\ncontent-length: 1000\r\n\r\nabc",
		),
	}
	defer delete(m.captured)

	opts := Options {
		version            = .Http1,
		dialer             = Dialer{data = &m, procedure = _mock_dial},
		max_response_body  = 10,
	}
	res, err := get("http://example.com/", opts)
	defer response_destroy(&res)
	testing.expect_value(t, err, Http_Error.Body_Too_Large)
}

// Chunked body that exceeds max_response_body → Body_Too_Large.
@(test)
test_h1_body_too_large_chunked :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	// Two 8-byte chunks = 16 decoded body bytes; limit is 10.
	m := Mock_Stream {
		to_send = transmute([]u8)string(
			"HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n" +
			"8\r\n01234567\r\n" +
			"8\r\n89abcdef\r\n" +
			"0\r\n\r\n",
		),
	}
	defer delete(m.captured)

	opts := Options {
		version           = .Http1,
		dialer            = Dialer{data = &m, procedure = _mock_dial},
		max_response_body = 10,
	}
	res, err := get("http://example.com/", opts)
	defer response_destroy(&res)
	testing.expect_value(t, err, Http_Error.Body_Too_Large)
}

// Body under the limit still succeeds (CL path).
@(test)
test_h1_body_under_limit :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	m := Mock_Stream {
		to_send = transmute([]u8)string(
			"HTTP/1.1 200 OK\r\ncontent-length: 5\r\n\r\nhello",
		),
	}
	defer delete(m.captured)

	opts := Options {
		version           = .Http1,
		dialer            = Dialer{data = &m, procedure = _mock_dial},
		max_response_body = 5,
	}
	res, err := get("http://example.com/", opts)
	defer response_destroy(&res)
	testing.expect_value(t, err, Http_Error.None)
	testing.expect_value(t, string(res.body[:]), "hello")
}

// H2 response body over max_response_body → Body_Too_Large.
@(test)
test_h2_body_too_large :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	srv: http2.Http2_Connection
	http2.conn_init(&srv, true)
	defer http2.conn_destroy(&srv)
	canned: [dynamic]u8
	defer delete(canned)
	http2.conn_send_preface(&srv, &canned)
	resp_hdrs := []Header{{name = ":status", value = "200"}}
	big := "0123456789abcdef" // 16 bytes
	http2.conn_send_response(&srv, &canned, 1, resp_hdrs, transmute([]u8)string(big))

	m := Mock_Stream{to_send = canned[:]}
	defer delete(m.captured)

	opts := Options {
		version           = .Http2,
		dialer            = Dialer{data = &m, procedure = _mock_dial},
		max_response_body = 8,
	}
	res, err := get("http://example.com/", opts)
	defer response_destroy(&res)
	testing.expect_value(t, err, Http_Error.Body_Too_Large)
}

// dial stores the resolved max_response_body on the Connection.
@(test)
test_dial_resolves_max_response_body :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	m := Mock_Stream {
		to_send = transmute([]u8)string("HTTP/1.1 200 OK\r\ncontent-length: 0\r\n\r\n"),
	}
	defer delete(m.captured)

	opts := Options {
		version = .Http1,
		dialer  = Dialer{data = &m, procedure = _mock_dial},
		// 0 → package default
	}
	c, err := dial("http://example.com/", opts)
	testing.expect_value(t, err, Http_Error.None)
	defer close(c)
	testing.expect_value(t, c.max_response_body, DEFAULT_MAX_RESPONSE_BODY)

	m2 := Mock_Stream {
		to_send = transmute([]u8)string("HTTP/1.1 200 OK\r\ncontent-length: 0\r\n\r\n"),
	}
	defer delete(m2.captured)
	opts2 := Options {
		version           = .Http1,
		dialer            = Dialer{data = &m2, procedure = _mock_dial},
		max_response_body = 4096,
	}
	c2, err2 := dial("http://example.com/", opts2)
	testing.expect_value(t, err2, Http_Error.None)
	defer close(c2)
	testing.expect_value(t, c2.max_response_body, 4096)
}

// format_authority: default ports omitted, non-default included, IPv6 bracketed.
@(test)
test_format_authority :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	testing.expect_value(t, format_authority("https", "example.com", 443), "example.com")
	testing.expect_value(t, format_authority("http", "example.com", 80), "example.com")
	testing.expect_value(t, format_authority("https", "example.com", 8443), "example.com:8443")
	testing.expect_value(t, format_authority("http", "example.com", 8080), "example.com:8080")
	// https with port 80 is non-default for https → include port
	testing.expect_value(t, format_authority("https", "example.com", 80), "example.com:80")
	// http with port 443 is non-default for http → include port
	testing.expect_value(t, format_authority("http", "example.com", 443), "example.com:443")
	// IPv6
	testing.expect_value(t, format_authority("http", "::1", 80), "[::1]")
	testing.expect_value(t, format_authority("https", "::1", 443), "[::1]")
	testing.expect_value(t, format_authority("http", "2001:db8::1", 8080), "[2001:db8::1]:8080")
	// Already bracketed stays bracketed
	testing.expect_value(t, format_authority("http", "[::1]", 80), "[::1]")
	testing.expect_value(t, format_dial_endpoint("::1", 443), "[::1]:443")
	testing.expect_value(t, format_dial_endpoint("example.com", 443), "example.com:443")
}

// Host header carries non-default port and brackets IPv6.
@(test)
test_h1_host_authority_port_and_ipv6 :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	// Non-default port
	{
		m := Mock_Stream {
			to_send = transmute([]u8)string("HTTP/1.1 200 OK\r\ncontent-length: 0\r\n\r\n"),
		}
		defer delete(m.captured)
		opts := Options{version = .Http1, dialer = Dialer{data = &m, procedure = _mock_dial}}
		res, err := get("http://example.com:8080/x", opts)
		defer response_destroy(&res)
		testing.expect_value(t, err, Http_Error.None)
		sent := string(m.captured[:])
		testing.expect(t, strings.contains(sent, "host: example.com:8080\r\n"), "host with port")
	}
	// IPv6 with non-default port
	{
		m := Mock_Stream {
			to_send = transmute([]u8)string("HTTP/1.1 200 OK\r\ncontent-length: 0\r\n\r\n"),
		}
		defer delete(m.captured)
		opts := Options{version = .Http1, dialer = Dialer{data = &m, procedure = _mock_dial}}
		res, err := get("http://[2001:db8::1]:9090/", opts)
		defer response_destroy(&res)
		testing.expect_value(t, err, Http_Error.None)
		sent := string(m.captured[:])
		testing.expect(t, strings.contains(sent, "host: [2001:db8::1]:9090\r\n"), "IPv6 host")
	}
}

// Pre-gzipped body mock: Accept-Encoding offered; body transparently gunzipped.
@(test)
test_gzip_response_transparent_decode :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	// gzip("hello") — fixed vector (mtime 0).
	gz_hello := []u8{
		0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0xff,
		0xcb, 0x48, 0xcd, 0xc9, 0xc9, 0x07, 0x00, 0x86, 0xa6, 0x10,
		0x36, 0x05, 0x00, 0x00, 0x00,
	}
	// Build response wire bytes: headers + gzip body.
	head := fmt.tprintf(
		"HTTP/1.1 200 OK\r\ncontent-encoding: gzip\r\ncontent-length: %d\r\n\r\n",
		len(gz_hello),
	)
	wire: [dynamic]u8
	defer delete(wire)
	append(&wire, ..transmute([]u8)head)
	append(&wire, ..gz_hello)

	m := Mock_Stream{to_send = wire[:]}
	defer delete(m.captured)

	opts := Options{version = .Http1, dialer = Dialer{data = &m, procedure = _mock_dial}}
	res, err := get("http://example.com/", opts)
	defer response_destroy(&res)

	testing.expect_value(t, err, Http_Error.None)
	testing.expect_value(t, string(res.body[:]), "hello")
	// Accept-Encoding was offered.
	sent := string(m.captured[:])
	testing.expect(t, strings.contains(sent, "accept-encoding: gzip\r\n"), "offered gzip")
	// Content-Encoding stripped after decode.
	_, has_ce := _headers_get_ci(res.headers[:], "content-encoding")
	testing.expect(t, !has_ce, "content-encoding removed after gunzip")
}

// accept_gzip = false: no Accept-Encoding; body left compressed.
@(test)
test_gzip_disabled_leaves_body :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	gz_hello := []u8{
		0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0xff,
		0xcb, 0x48, 0xcd, 0xc9, 0xc9, 0x07, 0x00, 0x86, 0xa6, 0x10,
		0x36, 0x05, 0x00, 0x00, 0x00,
	}
	head := fmt.tprintf(
		"HTTP/1.1 200 OK\r\ncontent-encoding: gzip\r\ncontent-length: %d\r\n\r\n",
		len(gz_hello),
	)
	wire: [dynamic]u8
	defer delete(wire)
	append(&wire, ..transmute([]u8)head)
	append(&wire, ..gz_hello)

	m := Mock_Stream{to_send = wire[:]}
	defer delete(m.captured)

	opts := Options {
		version     = .Http1,
		dialer      = Dialer{data = &m, procedure = _mock_dial},
		accept_gzip = false,
	}
	res, err := get("http://example.com/", opts)
	defer response_destroy(&res)

	testing.expect_value(t, err, Http_Error.None)
	testing.expect_value(t, len(res.body), len(gz_hello))
	sent := string(m.captured[:])
	testing.expect(t, !strings.contains(sent, "accept-encoding:"), "no Accept-Encoding when disabled")
	ce, has_ce := _headers_get_ci(res.headers[:], "content-encoding")
	testing.expect(t, has_ce && ce == "gzip")
}

// Corrupt gzip body → Protocol error.
@(test)
test_gzip_corrupt_is_protocol_error :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	// Valid gzip header magic but truncated/corrupt payload.
	bad := []u8{0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff, 0xff}
	head := fmt.tprintf(
		"HTTP/1.1 200 OK\r\ncontent-encoding: gzip\r\ncontent-length: %d\r\n\r\n",
		len(bad),
	)
	wire: [dynamic]u8
	defer delete(wire)
	append(&wire, ..transmute([]u8)head)
	append(&wire, ..bad)

	m := Mock_Stream{to_send = wire[:]}
	defer delete(m.captured)

	opts := Options{version = .Http1, dialer = Dialer{data = &m, procedure = _mock_dial}}
	res, err := get("http://example.com/", opts)
	defer response_destroy(&res)
	testing.expect_value(t, err, Http_Error.Protocol)
}

// User-supplied Accept-Encoding is not overwritten.
@(test)
test_gzip_respects_user_accept_encoding :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	m := Mock_Stream {
		to_send = transmute([]u8)string("HTTP/1.1 200 OK\r\ncontent-length: 2\r\n\r\nok"),
	}
	defer delete(m.captured)

	opts := Options{version = .Http1, dialer = Dialer{data = &m, procedure = _mock_dial}}
	c, err := dial("http://example.com/", opts)
	testing.expect_value(t, err, Http_Error.None)
	defer close(c)

	req := Request{method = "GET", target = c.target}
	req.headers.allocator = context.temp_allocator
	append(&req.headers, Header{name = "accept-encoding", value = "identity"})
	res, e := request(c, &req)
	defer response_destroy(&res)
	testing.expect_value(t, e, Http_Error.None)

	sent := string(m.captured[:])
	testing.expect(t, strings.contains(sent, "accept-encoding: identity\r\n"), "user AE kept")
	testing.expect(t, !strings.contains(sent, "accept-encoding: gzip\r\n"), "no auto gzip AE")
}
