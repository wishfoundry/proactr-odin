package client

import "core:io"
import "core:mem"
import "core:strings"
import "core:testing"
import "core:time"

import http "../http"

// In-memory duplex stream (same shape as client_test.odin mocks).
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

// Counts dials. Each dial hands out streams[dials-1] so multi-dial tests do not
// share one pipe (h1 keep-alive buffering would otherwise steal the next response).
@(private = "file")
Dial_Counter :: struct {
	streams: []Mock_Stream,
	dials:   int,
}

@(private = "file")
_counting_dial :: proc(
	data: rawptr, target: Target, allocator: mem.Allocator,
) -> (io.Stream, ProtocolVersion, Http_Error) {
	d := (^Dial_Counter)(data)
	d.dials += 1
	if d.dials > len(d.streams) {
		return {}, .Http1, .Connect_Failed
	}
	m := &d.streams[d.dials - 1]
	v := target.version if target.version != .Auto else ProtocolVersion.Http1
	return io.Stream{data = m, procedure = _mock_proc}, v, .None
}

// Build a single content-length h1 response (fixed short bodies only).
@(private = "file")
fmt_h1_ok :: proc(body: string) -> string {
	// Only used with fixed short bodies in tests.
	switch body {
	case "one":
		return "HTTP/1.1 200 OK\r\ncontent-length: 3\r\n\r\none"
	case "two":
		return "HTTP/1.1 200 OK\r\ncontent-length: 3\r\n\r\ntwo"
	case "a":
		return "HTTP/1.1 200 OK\r\ncontent-length: 1\r\n\r\na"
	case "b":
		return "HTTP/1.1 200 OK\r\ncontent-length: 1\r\n\r\nb"
	case "x":
		return "HTTP/1.1 200 OK\r\ncontent-length: 1\r\n\r\nx"
	case "y":
		return "HTTP/1.1 200 OK\r\ncontent-length: 1\r\n\r\ny"
	case "z":
		return "HTTP/1.1 200 OK\r\ncontent-length: 1\r\n\r\nz"
	case "ok":
		return "HTTP/1.1 200 OK\r\ncontent-length: 2\r\n\r\nok"
	case:
		return "HTTP/1.1 200 OK\r\ncontent-length: 0\r\n\r\n"
	}
}

// Two connection_pool_get calls to the same origin must reuse one dial (keep-alive).
@(test)
test_connection_pool_two_gets_one_dial :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	// One stream, two pipelined responses — second get reuses the connection.
	streams := [1]Mock_Stream {
		{
			to_send = transmute([]u8)string(
				"HTTP/1.1 200 OK\r\ncontent-length: 3\r\n\r\none" +
				"HTTP/1.1 200 OK\r\ncontent-length: 3\r\n\r\ntwo",
			),
		},
	}
	defer delete(streams[0].captured)

	ctr := Dial_Counter{streams = streams[:]}
	opts := Options {
		version = .Http1,
		dialer  = Dialer{data = &ctr, procedure = _counting_dial},
	}

	pool: Connection_Pool
	connection_pool_init(&pool)
	defer connection_pool_destroy(&pool)

	r1, e1 := connection_pool_get(&pool, "http://example.com/a", opts)
	defer response_destroy(&r1)
	testing.expect_value(t, e1, Http_Error.None)
	testing.expect_value(t, string(r1.body[:]), "one")
	testing.expect_value(t, ctr.dials, 1)
	testing.expect_value(t, len(pool.idle), 1)

	r2, e2 := connection_pool_get(&pool, "http://example.com/b", opts)
	defer response_destroy(&r2)
	testing.expect_value(t, e2, Http_Error.None)
	testing.expect_value(t, string(r2.body[:]), "two")
	// Second get reused the idle connection — still one dial.
	testing.expect_value(t, ctr.dials, 1)

	sent := string(streams[0].captured[:])
	testing.expect(t, strings.contains(sent, "GET /a HTTP/1.1"), "first path")
	testing.expect(t, strings.contains(sent, "GET /b HTTP/1.1"), "second path")
}

// Different origins do not share an idle connection.
@(test)
test_connection_pool_different_origins_two_dials :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	streams := [2]Mock_Stream {
		{to_send = transmute([]u8)fmt_h1_ok("a")},
		{to_send = transmute([]u8)fmt_h1_ok("b")},
	}
	defer delete(streams[0].captured)
	defer delete(streams[1].captured)

	ctr := Dial_Counter{streams = streams[:]}
	opts := Options {
		version = .Http1,
		dialer  = Dialer{data = &ctr, procedure = _counting_dial},
	}

	pool: Connection_Pool
	connection_pool_init(&pool)
	defer connection_pool_destroy(&pool)

	r1, e1 := connection_pool_get(&pool, "http://a.example/x", opts)
	defer response_destroy(&r1)
	testing.expect_value(t, e1, Http_Error.None)
	testing.expect_value(t, string(r1.body[:]), "a")
	testing.expect_value(t, ctr.dials, 1)

	r2, e2 := connection_pool_get(&pool, "http://b.example/x", opts)
	defer response_destroy(&r2)
	testing.expect_value(t, e2, Http_Error.None)
	testing.expect_value(t, string(r2.body[:]), "b")
	testing.expect_value(t, ctr.dials, 2)
	testing.expect_value(t, len(pool.idle), 2)
}

// Forced protocol must not reuse a connection negotiated for a different version.
@(test)
test_connection_pool_protocol_mismatch_no_reuse :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	streams := [2]Mock_Stream {
		{to_send = transmute([]u8)fmt_h1_ok("x")},
		// Second dial is forced h2 — stream content unused (we only assert dial count).
		{to_send = transmute([]u8)string("")},
	}
	defer delete(streams[0].captured)
	defer delete(streams[1].captured)

	ctr := Dial_Counter{streams = streams[:]}
	opts_h1 := Options {
		version = .Http1,
		dialer  = Dialer{data = &ctr, procedure = _counting_dial},
	}
	opts_h2 := Options {
		version = .Http2,
		dialer  = Dialer{data = &ctr, procedure = _counting_dial},
	}

	pool: Connection_Pool
	connection_pool_init(&pool)
	defer connection_pool_destroy(&pool)

	// Put an h1 connection idle.
	c1, e := connection_pool_dial(&pool, "http://example.com/", opts_h1)
	testing.expect_value(t, e, Http_Error.None)
	testing.expect_value(t, c1.version, ProtocolVersion.Http1)
	req := Request{method = "GET", target = c1.target}
	res, re := request(c1, &req)
	defer response_destroy(&res)
	testing.expect_value(t, re, Http_Error.None)
	connection_pool_put(&pool, c1)
	testing.expect_value(t, len(pool.idle), 1)
	testing.expect_value(t, ctr.dials, 1)

	// Forced h2 must not take the h1 idle — new dial.
	c2, e2 := connection_pool_dial(&pool, "http://example.com/", opts_h2)
	testing.expect_value(t, e2, Http_Error.None)
	testing.expect_value(t, c2.version, ProtocolVersion.Http2)
	testing.expect_value(t, ctr.dials, 2)
	// h1 idle still present.
	testing.expect_value(t, len(pool.idle), 1)
	close(c2)
}

// Dead h1 connections are not returned from the pool.
@(test)
test_connection_pool_skips_dead_h1 :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	streams := [2]Mock_Stream {
		{to_send = transmute([]u8)fmt_h1_ok("z")},
		{to_send = transmute([]u8)fmt_h1_ok("z")},
	}
	defer delete(streams[0].captured)
	defer delete(streams[1].captured)

	ctr := Dial_Counter{streams = streams[:]}
	opts := Options {
		version = .Http1,
		dialer  = Dialer{data = &ctr, procedure = _counting_dial},
	}

	pool: Connection_Pool
	connection_pool_init(&pool)
	defer connection_pool_destroy(&pool)

	c, e := dial("http://example.com/", opts)
	testing.expect_value(t, e, Http_Error.None)
	c.h1_alive = false // simulate peer close / framing error after use
	connection_pool_put(&pool, c)
	// Not reusable — closed on put.
	testing.expect_value(t, len(pool.idle), 0)

	// Next dial creates a fresh connection.
	c2, e2 := connection_pool_dial(&pool, "http://example.com/", opts)
	testing.expect_value(t, e2, Http_Error.None)
	testing.expect_value(t, ctr.dials, 2)
	close(c2)
}

// max_idle_time expires idle entries on take.
@(test)
test_connection_pool_max_idle_time_evicts :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	// Separate streams per dial: expiring the first closes its stream; the
	// second dial must not depend on leftover keep-alive bytes.
	streams := [2]Mock_Stream {
		{to_send = transmute([]u8)fmt_h1_ok("a")},
		{to_send = transmute([]u8)fmt_h1_ok("b")},
	}
	defer delete(streams[0].captured)
	defer delete(streams[1].captured)

	ctr := Dial_Counter{streams = streams[:]}
	opts := Options {
		version = .Http1,
		dialer  = Dialer{data = &ctr, procedure = _counting_dial},
	}

	pool: Connection_Pool
	connection_pool_init(&pool, Connection_Pool_Config{max_idle_time = time.Nanosecond})
	defer connection_pool_destroy(&pool)

	r1, e1 := connection_pool_get(&pool, "http://example.com/a", opts)
	defer response_destroy(&r1)
	testing.expect_value(t, e1, Http_Error.None)
	testing.expect_value(t, ctr.dials, 1)

	// Ensure clock moves past max_idle_time.
	time.sleep(2 * time.Millisecond)

	r2, e2 := connection_pool_get(&pool, "http://example.com/b", opts)
	defer response_destroy(&r2)
	testing.expect_value(t, e2, Http_Error.None)
	// Expired idle was dropped; second dial required.
	testing.expect_value(t, ctr.dials, 2)
}

// connection_pool_request reuses like connection_pool_get.
@(test)
test_connection_pool_request_reuses :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	streams := [1]Mock_Stream {
		{
			to_send = transmute([]u8)string(
				"HTTP/1.1 200 OK\r\ncontent-length: 2\r\n\r\nok" +
				"HTTP/1.1 200 OK\r\ncontent-length: 2\r\n\r\nok",
			),
		},
	}
	defer delete(streams[0].captured)

	ctr := Dial_Counter{streams = streams[:]}
	opts := Options {
		version = .Http1,
		dialer  = Dialer{data = &ctr, procedure = _counting_dial},
	}

	pool: Connection_Pool
	connection_pool_init(&pool)
	defer connection_pool_destroy(&pool)

	req1 := Request{method = "GET"}
	r1, e1 := connection_pool_request(&pool, "http://example.com/1", &req1, opts)
	defer response_destroy(&r1)
	testing.expect_value(t, e1, Http_Error.None)

	req2 := Request{method = "GET"}
	r2, e2 := connection_pool_request(&pool, "http://example.com/2", &req2, opts)
	defer response_destroy(&r2)
	testing.expect_value(t, e2, Http_Error.None)
	testing.expect_value(t, ctr.dials, 1)
}
