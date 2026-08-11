package client

import "core:fmt"
import "core:mem"
import "core:net"
import "core:testing"
import "core:thread"
import "core:time"

import "../http3"
import od "../openssl_dynlib"
import "../quic"

@(private = "file")
Pref_H3_Srv :: struct {
	sock: net.UDP_Socket,
	stop: bool,
}

@(private = "file")
_pref_h3_handler :: proc(req: http3.Request, allocator: mem.Allocator) -> http3.Response {
	hdrs := make([]Header, 1, allocator)
	hdrs[0] = {name = "content-type", value = "text/plain"}
	body := fmt.aprintf("prefer-h3 %s", req.path, allocator = allocator)
	return http3.Response{status = 200, headers = hdrs, body = transmute([]u8)body}
}

@(private = "file")
_pref_h3_server :: proc(data: rawptr) {
	args := (^Pref_H3_Srv)(data)
	http3.serve_conn(
		args.sock,
		transmute([]u8)string(http3.TEST_CERT_PEM),
		transmute([]u8)string(http3.TEST_KEY_PEM),
		_pref_h3_handler,
		&args.stop,
	)
}

@(test)
test_prefer_h3_succeeds_when_h3_available :: proc(t: ^testing.T) {
	if !od.os_ensure_ssl() || !quic.os_ensure() {
		testing.expect(t, true, "skip: no OpenSSL/QUIC")
		return
	}
	lo := net.IP4_Address{127, 0, 0, 1}
	ssock, se := net.make_bound_udp_socket(lo, 0)
	testing.expect(t, se == nil, "bind")
	if se != nil do return
	net.set_blocking(ssock, false)
	sep, _ := net.bound_endpoint(ssock)

	args := Pref_H3_Srv{sock = ssock}
	th := thread.create_and_start_with_data(&args, _pref_h3_server)
	defer {
		args.stop = true
		thread.join(th)
		thread.destroy(th)
		net.close(ssock)
	}
	time.sleep(10 * time.Millisecond)

	rt: Client_Runtime
	if !runtime_init(&rt, context.allocator, 64) {
		testing.expect(t, false, "runtime_init")
		return
	}
	defer runtime_destroy(&rt)

	// Single request: serve_conn is one-connection; prefer_h3 via get_proactr.
	url := fmt.tprintf("https://127.0.0.1:%d/p2", sep.port)
	res, err := get(
		url,
		Options {
			use_proactr_io = true,
			prefer_h3     = true,
			insecure      = true,
			version       = .Auto,
			timeout       = 5_000,
		},
	)
	defer response_destroy(&res)
	_ = rt // kept for possible future local-path assertion
	testing.expect_value(t, err, Http_Error.None)
	testing.expect_value(t, res.version, ProtocolVersion.Http3)
	testing.expect_value(t, string(res.body[:]), "prefer-h3 /p2")
}

@(test)
test_prefer_h3_falls_back_to_tcp_when_quic_fails :: proc(t: ^testing.T) {
	if !od.os_ensure_ssl() {
		testing.expect(t, true, "skip: no OpenSSL")
		return
	}
	// TCP TLS H1 server only (no UDP) — prefer_h3 tries QUIC, fails, falls back.
	listener, lerr := net.listen_tcp(net.Endpoint{address = net.IP4_Address{127, 0, 0, 1}, port = 0})
	testing.expect(t, lerr == nil, "listen")
	if lerr != nil do return
	defer net.close(listener)
	ep, _ := net.bound_endpoint(listener)

	// Reuse TLS proactr H1 server thread from job_tls_test (same package).
	args := Tls_Proactr_Server{listener = listener, alpn_h1_only = true}
	th := thread.create_and_start_with_data(&args, _proactr_tls_server_thread)
	defer {
		thread.join(th)
		thread.destroy(th)
	}

	// Closed UDP is not needed: prefer_h3 dials QUIC to same host:port where only TCP listens → fail → TLS.
	url := fmt.tprintf("https://127.0.0.1:%d/", ep.port)
	res: Response
	err: Http_Error = .Connect_Failed
	for attempt in 0 ..< 30 {
		if attempt > 0 {
			time.sleep(2 * time.Millisecond)
		}
		res, err = get(
			url,
			Options {
				use_proactr_io = true,
				prefer_h3     = true,
				insecure      = true,
				version       = .Auto,
				timeout       = 2_000,
			},
		)
		if err == .None do break
		response_destroy(&res)
		res = {}
	}
	defer response_destroy(&res)
	testing.expect_value(t, err, Http_Error.None)
	// Fallback is TCP TLS H1 (ALPN h1-only server).
	testing.expect_value(t, res.version, ProtocolVersion.Http1)
	testing.expect_value(t, string(res.body[:]), "ok")
}

@(test)
test_opts_prefer_h3_first_predicate :: proc(t: ^testing.T) {
	testing.expect(t, _opts_prefer_h3_first(Options{prefer_h3 = true, version = .Auto}, "https"))
	testing.expect(t, !_opts_prefer_h3_first(Options{prefer_h3 = true, version = .Http1}, "https"))
	testing.expect(t, !_opts_prefer_h3_first(Options{prefer_h3 = true, version = .Auto}, "http"))
	testing.expect(t, !_opts_prefer_h3_first(Options{prefer_h3 = false, version = .Auto}, "https"))
}

@(test)
test_pool_invalid_use_on_worker :: proc(t: ^testing.T) {
	prev := http_worker_active
	http_worker_active = true
	defer {http_worker_active = prev}

	pool: Connection_Pool
	connection_pool_init(&pool)
	defer connection_pool_destroy(&pool)
	_, err := connection_pool_get(&pool, "http://example.com/")
	testing.expect_value(t, err, Http_Error.Invalid_Use)
	testing.expect_value(t, INVALID_USE_DIAGNOSTIC != "", true)
}

@(test)
test_tls_body_rejected_loud :: proc(t: ^testing.T) {
	rt: Client_Runtime
	if !runtime_init(&rt, context.allocator, 8) {
		testing.expect(t, false, "runtime_init")
		return
	}
	defer runtime_destroy(&rt)
	// Body reject is before SSL setup / OpenSSL need.
	body := transmute([]u8)string("x")
	job, err := tls_request_start(
		&rt,
		42, // dummy; rejected before use
		"POST",
		"127.0.0.1",
		"/",
		443,
		body,
		1024,
		true,
		.Http1,
		nil,
		nil,
		context.allocator,
	)
	testing.expect(t, job == nil)
	testing.expect_value(t, err, Http_Error.Unsupported_Version)
}
