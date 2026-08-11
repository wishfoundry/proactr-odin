package client

import "core:io"
import "core:mem"
import "core:testing"

// File-local mock stream for Exchange H1 tests.
@(private = "file")
Ex_Mock :: struct {
	to_send:  []u8,
	pos:      int,
	captured: [dynamic]u8,
}

@(private = "file")
_ex_mock_proc :: proc(
	stream_data: rawptr, mode: io.Stream_Mode, p: []byte, offset: i64, whence: io.Seek_From,
) -> (n: i64, err: io.Error) {
	m := (^Ex_Mock)(stream_data)
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

@(private = "file")
_ex_mock_dial :: proc(
	data: rawptr, target: Target, allocator: mem.Allocator,
) -> (io.Stream, ProtocolVersion, Http_Error) {
	_ = target
	_ = allocator
	m := (^Ex_Mock)(data)
	return io.Stream{data = m, procedure = _ex_mock_proc}, .Http1, .None
}

@(test)
test_exchange_headers_then_body :: proc(t: ^testing.T) {
	m := Ex_Mock {
		to_send = transmute([]u8)string(
			"HTTP/1.1 200 OK\r\ncontent-type: text/plain\r\ncontent-length: 5\r\n\r\nhello",
		),
	}
	defer delete(m.captured)

	c, e := dial(
		"http://example.com/x",
		Options{version = .Http1, dialer = Dialer{data = &m, procedure = _ex_mock_dial}},
	)
	testing.expect_value(t, e, Http_Error.None)
	if e != .None do return
	defer close(c)

	req := Request{method = "GET", target = c.target}
	ex, xerr := exchange_start(c, &req)
	testing.expect_value(t, xerr, Http_Error.None)
	if xerr != .None do return

	status, headers, herr := exchange_wait_headers(ex)
	testing.expect_value(t, herr, Http_Error.None)
	testing.expect_value(t, status, Status.OK)
	testing.expect(t, len(headers) >= 1)

	// Headers usable before body fully read.
	body: [8]u8
	n, berr := exchange_read_body(ex, body[:])
	testing.expect_value(t, berr, Http_Error.None)
	testing.expect_value(t, n, 5)
	testing.expect_value(t, string(body[:n]), "hello")

	n2, berr2 := exchange_read_body(ex, body[:])
	testing.expect_value(t, berr2, Http_Error.None)
	testing.expect_value(t, n2, 0)
	testing.expect(t, ex.body_done)

	// Request was written.
	testing.expect(t, len(m.captured) > 0)
	exchange_finish(ex)
}

@(test)
test_exchange_collect_full_response :: proc(t: ^testing.T) {
	m := Ex_Mock {
		to_send = transmute([]u8)string(
			"HTTP/1.1 201 Created\r\ncontent-length: 3\r\n\r\nyes",
		),
	}
	defer delete(m.captured)

	c, e := dial(
		"http://example.com/",
		Options{version = .Http1, dialer = Dialer{data = &m, procedure = _ex_mock_dial}},
	)
	testing.expect_value(t, e, Http_Error.None)
	if e != .None do return
	defer close(c)

	req := Request{method = "GET", target = c.target}
	ex, xerr := exchange_start(c, &req)
	testing.expect_value(t, xerr, Http_Error.None)
	if xerr != .None do return

	res, rerr := exchange_collect(ex)
	defer response_destroy(&res)
	testing.expect_value(t, rerr, Http_Error.None)
	testing.expect_value(t, res.status, Status.Created)
	testing.expect_value(t, string(res.body[:]), "yes")
}

@(test)
test_exchange_cancel_marks_closed :: proc(t: ^testing.T) {
	// Body never fully delivered; cancel mid-stream.
	m := Ex_Mock {
		to_send = transmute([]u8)string(
			"HTTP/1.1 200 OK\r\ncontent-length: 100\r\n\r\npartial",
		),
	}
	defer delete(m.captured)

	c, e := dial(
		"http://example.com/",
		Options{version = .Http1, dialer = Dialer{data = &m, procedure = _ex_mock_dial}},
	)
	testing.expect_value(t, e, Http_Error.None)
	if e != .None do return
	defer close(c)

	req := Request{method = "GET", target = c.target}
	ex, xerr := exchange_start(c, &req)
	testing.expect_value(t, xerr, Http_Error.None)
	if xerr != .None do return

	_, _, herr := exchange_wait_headers(ex)
	testing.expect_value(t, herr, Http_Error.None)

	exchange_cancel(ex)
	testing.expect(t, ex.cancelled)
	testing.expect(t, !c.h1_alive)

	buf: [16]u8
	_, berr := exchange_read_body(ex, buf[:])
	testing.expect_value(t, berr, Http_Error.Closed)
	exchange_finish(ex)
}

@(test)
test_exchange_rejects_h2 :: proc(t: ^testing.T) {
	m := Ex_Mock {
		to_send = transmute([]u8)string("HTTP/1.1 200 OK\r\ncontent-length: 0\r\n\r\n"),
	}
	defer delete(m.captured)

	// Force H2 negotiated — Exchange v1 is H1-only.
	c, e := dial(
		"https://example.com/",
		Options{
			version = .Http2,
			dialer  = Dialer{data = &m, procedure = _ex_mock_dial},
		},
	)
	// Dial may fail version mismatch if mock claims Http1 — use raw bind style.
	if e != .None {
		// Mock always returns Http1; hop_dial_stream rejects version mismatch.
		testing.expect_value(t, e, Http_Error.Unsupported_Version)
		return
	}
	defer close(c)
	c.version = .Http2
	req := Request{method = "GET", target = c.target}
	ex, xerr := exchange_start(c, &req)
	testing.expect_value(t, xerr, Http_Error.Unsupported_Version)
	testing.expect(t, ex == nil)
}
