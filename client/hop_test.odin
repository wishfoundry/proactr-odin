package client

import "core:fmt"
import "core:io"
import "core:mem"
import "core:net"
import "core:testing"
import "core:thread"
import "core:time"

// File-local mock (same shape as client_test; that mock is file-private).
@(private = "file")
Hop_Mock_Stream :: struct {
	to_send:  []u8,
	pos:      int,
	captured: [dynamic]u8,
}

@(private = "file")
_hop_mock_proc :: proc(
	stream_data: rawptr, mode: io.Stream_Mode, p: []byte, offset: i64, whence: io.Seek_From,
) -> (n: i64, err: io.Error) {
	m := (^Hop_Mock_Stream)(stream_data)
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
_hop_mock_dial :: proc(
	data: rawptr, target: Target, allocator: mem.Allocator,
) -> (io.Stream, ProtocolVersion, Http_Error) {
	_ = allocator
	m := (^Hop_Mock_Stream)(data)
	v := target.version if target.version != .Auto else ProtocolVersion.Http1
	return io.Stream{data = m, procedure = _hop_mock_proc}, v, .None
}

@(test)
test_hop_dial_clear_fd_sets_fd_and_remote :: proc(t: ^testing.T) {
	listener, lerr := net.listen_tcp(net.Endpoint{address = net.IP4_Address{127, 0, 0, 1}, port = 0})
	testing.expect(t, lerr == nil)
	if lerr != nil do return
	defer net.close(listener)
	bound, _ := net.bound_endpoint(listener)

	target := Target {
		scheme = "http",
		host   = "127.0.0.1",
		path   = "/",
		port   = bound.port,
	}
	hop, err := hop_dial_clear_fd(target, Options{}, context.allocator)
	testing.expect_value(t, err, Http_Error.None)
	testing.expect(t, hop.fd >= 0, "fd set")
	testing.expect(t, hop.owns_fd, "owns fd")
	testing.expect(t, hop.meta.nonblocking, "nonblocking")
	testing.expect_value(t, hop.meta.negotiated, ProtocolVersion.Http1)
	client, _, aerr := net.accept_tcp(listener)
	if aerr == nil do net.close(client)
	hop_close(&hop)
}

@(test)
test_hop_take_fd_prevents_double_close :: proc(t: ^testing.T) {
	listener, lerr := net.listen_tcp(net.Endpoint{address = net.IP4_Address{127, 0, 0, 1}, port = 0})
	testing.expect(t, lerr == nil)
	if lerr != nil do return
	defer net.close(listener)
	bound, _ := net.bound_endpoint(listener)

	target := Target{scheme = "http", host = "127.0.0.1", path = "/", port = bound.port}
	hop, err := hop_dial_clear_fd(target, Options{}, context.allocator)
	testing.expect_value(t, err, Http_Error.None)
	fd := hop_take_fd(&hop)
	testing.expect(t, fd >= 0)
	testing.expect(t, !hop.owns_fd)
	hop_close(&hop)
	net.close(net.TCP_Socket(fd))
	client, _, aerr := net.accept_tcp(listener)
	if aerr == nil do net.close(client)
}

@(test)
test_hop_dial_stream_mock_request_path :: proc(t: ^testing.T) {
	m := Hop_Mock_Stream {
		to_send = transmute([]u8)string("HTTP/1.1 200 OK\r\ncontent-length: 2\r\n\r\nok"),
	}
	defer delete(m.captured)
	opts := Options {
		version = .Http1,
		dialer  = Dialer{data = rawptr(&m), procedure = _hop_mock_dial},
	}
	c, e := dial("http://example.com/", opts)
	testing.expect_value(t, e, Http_Error.None)
	if e != .None do return
	defer close(c)
	testing.expect_value(t, c.hop.meta.negotiated, ProtocolVersion.Http1)
	req := Request{method = "GET", target = c.target}
	res, rerr := request(c, &req)
	defer response_destroy(&res)
	testing.expect_value(t, rerr, Http_Error.None)
	testing.expect_value(t, string(res.body[:]), "ok")
}

@(private)
_count_clear_dials: int

@(private)
_counting_clear_dial :: proc(
	data: rawptr, target: Target, allocator: mem.Allocator,
) -> (io.Stream, ProtocolVersion, Http_Error) {
	_ = data
	_ = allocator
	_count_clear_dials += 1
	ep4, ep6, rerr := net.resolve(target.host)
	if rerr != nil do return {}, .Http1, .Resolve_Failed
	ep := ep4 if ep4.address != nil else ep6
	ep.port = target.port
	sock, derr := net.dial_tcp(ep)
	if derr != nil do return {}, .Http1, .Connect_Failed
	_ = net.set_blocking(sock, false)
	return tcp_stream(sock), .Http1, .None
}

@(test)
test_proactr_uses_clear_fd_dialer :: proc(t: ^testing.T) {
	listener, lerr := net.listen_tcp(net.Endpoint{address = net.IP4_Address{127, 0, 0, 1}, port = 0})
	testing.expect(t, lerr == nil)
	if lerr != nil do return
	defer net.close(listener)
	bound, _ := net.bound_endpoint(listener)

	Srv :: struct {
		listener: net.TCP_Socket,
	}
	srv := Srv{listener = listener}
	th := thread.create_and_start_with_data(rawptr(&srv), proc(data: rawptr) {
		s := (^Srv)(data)
		client, _, aerr := net.accept_tcp(s.listener)
		if aerr != nil do return
		defer net.close(client)
		buf: [1024]u8
		_, _ = net.recv_tcp(client, buf[:])
		resp := "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"
		_, _ = net.send_tcp(client, transmute([]u8)resp)
	})
	defer {
		thread.join(th)
		thread.destroy(th)
	}
	time.sleep(5 * time.Millisecond)

	_count_clear_dials = 0
	url := fmt.tprintf("http://127.0.0.1:%d/", bound.port)
	res, err := get(
		url,
		Options {
			use_proactr_io = true,
			version       = .Http1,
			timeout       = 3_000,
			dialer        = Dialer{procedure = _counting_clear_dial},
		},
	)
	defer response_destroy(&res)
	testing.expect_value(t, err, Http_Error.None)
	testing.expect(t, _count_clear_dials >= 1, "dialer invoked on proactr path")
	if err == .None {
		testing.expect_value(t, string(res.body[:]), "ok")
	}
}
