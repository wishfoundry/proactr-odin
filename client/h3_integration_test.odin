package client

import "core:fmt"
import "core:mem"
import "core:net"
import "core:testing"
import "core:thread"

import http "../http"
import "../http3"
import "../qpack"

// A minimal h3 server (the http3 engine's serve_conn) on a worker thread; the
// unified clientx client drives it over real UDP from the main thread.

@(private = "file")
Test_Server_Args :: struct {
	sock: net.UDP_Socket,
	stop: bool,
}

@(private = "file")
test_handler :: proc(req: http3.Request, allocator: mem.Allocator) -> http3.Response {
	hdrs := make([]Header, 1, allocator)
	hdrs[0] = {name = "content-type", value = "text/plain"}
	// Echo the path so multiple requests on one connection are distinguishable.
	body := fmt.aprintf("you asked for %s", req.path, allocator = allocator)
	return http3.Response{status = 200, headers = hdrs, body = transmute([]u8)body}
}

@(private = "file")
server_thread :: proc(data: rawptr) {
	args := (^Test_Server_Args)(data)
	http3.serve_conn(
		args.sock,
		transmute([]u8)string(http3.TEST_CERT_PEM),
		transmute([]u8)string(http3.TEST_KEY_PEM),
		test_handler,
		&args.stop,
	)
}

// Full HTTP/3 client<->server over real UDP: http3.serve_conn on a worker
// thread, the unified clientx client on the main thread (two requests on one
// connection, exercising the client-bidi allocator over the wire).
@(test)
test_h3_client_server_real_socket :: proc(t: ^testing.T) {
	lo := net.IP4_Address{127, 0, 0, 1}
	ssock, se := net.make_bound_udp_socket(lo, 0)
	testing.expect(t, se == nil, "bind server socket")
	net.set_blocking(ssock, false)
	sep, _ := net.bound_endpoint(ssock)

	args := Test_Server_Args{sock = ssock}
	th := thread.create_and_start_with_data(&args, server_thread)
	defer {
		args.stop = true
		thread.join(th)
		thread.destroy(th)
		net.close(ssock)
	}

	url := fmt.tprintf("https://127.0.0.1:%d/", sep.port)
	c, derr := dial(url, Options{version = .Http3, insecure = true}) // self-signed test cert
	defer close(c)
	testing.expect_value(t, derr, Http_Error.None)

	// First request (bidi stream id 0).
	req1 := Request{method = "GET", target = c.target}
	r1, e1 := request(c, &req1)
	defer response_destroy(&r1)
	testing.expect_value(t, e1, Http_Error.None)
	testing.expect_value(t, r1.status, Status.OK)
	testing.expect_value(t, string(r1.body[:]), "you asked for /")

	// Second request on the SAME connection (bidi stream id 4).
	req2 := Request{method = "GET", target = Target{path = "/two"}}
	r2, e2 := request(c, &req2)
	defer response_destroy(&r2)
	testing.expect_value(t, e2, Http_Error.None)
	testing.expect_value(t, r2.status, Status.OK)
	testing.expect_value(t, string(r2.body[:]), "you asked for /two")
}

// Verification is on by default — the self-signed test cert must be REJECTED
// when the caller does NOT opt into insecure. Own server: the failed
// handshake leaves a one-conn server unusable for further dials.
@(test)
test_h3_dial_rejects_self_signed :: proc(t: ^testing.T) {
	lo := net.IP4_Address{127, 0, 0, 1}
	ssock, se := net.make_bound_udp_socket(lo, 0)
	testing.expect(t, se == nil, "bind server socket")
	net.set_blocking(ssock, false)
	sep, _ := net.bound_endpoint(ssock)

	args := Test_Server_Args{sock = ssock}
	th := thread.create_and_start_with_data(&args, server_thread)
	defer {
		args.stop = true
		thread.join(th)
		thread.destroy(th)
		net.close(ssock)
	}

	url := fmt.tprintf("https://127.0.0.1:%d/", sep.port)
	c, derr := dial(url, Options{version = .Http3}) // verification ON
	testing.expect(t, derr != .None, "secure dial rejects the self-signed cert")
	if c != nil do close(c)
}
