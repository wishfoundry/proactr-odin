package client

import "core:c"
import "core:fmt"
import "core:net"
import "core:testing"
import "core:thread"

import "../http2"
import "../http3" // TEST_CERT_PEM / TEST_KEY_PEM
import od "../openssl_dynlib"

// Full TLS + ALPN + HTTP/2 over OpenSSL dynlib test server (self-signed).
// Skips when OpenSSL cannot load.

@(private = "file")
Tls_Test_Server :: struct {
	listener: net.TCP_Socket,
	// When true, ALPN select returns http/1.1 only (for ALPN Http1 tests).
	alpn_h1_only: bool,
}

@(private = "file")
_alpn_select_h2 :: proc "c" (
	s: rawptr, out: ^[^]u8, out_len: ^u8, in_data: [^]u8, in_len: c.uint, arg: rawptr,
) -> c.int {
	for i: c.uint = 0; i < in_len; {
		l := c.uint(in_data[i])
		if i + 1 + l > in_len do break
		if l == 2 && in_data[i + 1] == 'h' && in_data[i + 2] == '2' {
			out^ = in_data[i + 1:]
			out_len^ = 2
			return od.SSL_TLSEXT_ERR_OK
		}
		i += 1 + l
	}
	return od.SSL_TLSEXT_ERR_NOACK
}

@(private = "file")
_alpn_select_h1 :: proc "c" (
	s: rawptr, out: ^[^]u8, out_len: ^u8, in_data: [^]u8, in_len: c.uint, arg: rawptr,
) -> c.int {
	for i: c.uint = 0; i < in_len; {
		l := c.uint(in_data[i])
		if i + 1 + l > in_len do break
		if l == 8 &&
		   in_data[i + 1] == 'h' &&
		   in_data[i + 2] == 't' &&
		   in_data[i + 3] == 't' &&
		   in_data[i + 4] == 'p' {
			out^ = in_data[i + 1:]
			out_len^ = 8
			return od.SSL_TLSEXT_ERR_OK
		}
		i += 1 + l
	}
	return od.SSL_TLSEXT_ERR_NOACK
}

@(private = "file")
_ctx_load_pem :: proc(ctx: rawptr, cert_pem, key_pem: []u8) -> bool {
	cbio := od.g_os.BIO_new_mem_buf(raw_data(cert_pem), c.int(len(cert_pem)))
	if cbio == nil do return false
	defer od.g_os.BIO_free(cbio)
	cert := od.g_os.PEM_read_bio_X509(cbio, nil, nil, nil)
	if cert == nil do return false
	defer od.g_os.X509_free(cert)
	if od.g_os.SSL_CTX_use_certificate(ctx, cert) != 1 do return false

	kbio := od.g_os.BIO_new_mem_buf(raw_data(key_pem), c.int(len(key_pem)))
	if kbio == nil do return false
	defer od.g_os.BIO_free(kbio)
	key := od.g_os.PEM_read_bio_PrivateKey(kbio, nil, nil, nil)
	if key == nil do return false
	defer od.g_os.EVP_PKEY_free(key)
	return od.g_os.SSL_CTX_use_PrivateKey(ctx, key) == 1
}

@(private = "file")
server_thread :: proc(data: rawptr) {
	args := (^Tls_Test_Server)(data)
	if !od.os_ensure_ssl() do return

	sock, _, aerr := net.accept_tcp(args.listener)
	if aerr != nil do return
	defer net.close(sock)
	_suppress_sigpipe(sock)

	ctx := od.g_os.SSL_CTX_new(od.g_os.TLS_server_method())
	if ctx == nil do return
	defer od.g_os.SSL_CTX_free(ctx)
	if !_ctx_load_pem(
		ctx,
		transmute([]u8)string(http3.TEST_CERT_PEM),
		transmute([]u8)string(http3.TEST_KEY_PEM),
	) {return}
	if args.alpn_h1_only {
		od.g_os.SSL_CTX_set_alpn_select_cb(ctx, rawptr(_alpn_select_h1), nil)
	} else {
		od.g_os.SSL_CTX_set_alpn_select_cb(ctx, rawptr(_alpn_select_h2), nil)
	}

	conn := od.g_os.SSL_new(ctx)
	if conn == nil do return
	defer od.g_os.SSL_free(conn)
	_ = od.g_os.SSL_set_fd(conn, c.int(sock))
	if od.g_os.SSL_accept(conn) != 1 do return

	// ALPN h1 path: minimal HTTP/1.1 response then exit.
	if args.alpn_h1_only {
		buf: [4096]u8
		_ = od.g_os.SSL_read(conn, raw_data(buf[:]), c.int(len(buf)))
		resp := "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"
		_ = od.g_os.SSL_write(conn, raw_data(transmute([]u8)resp), c.int(len(resp)))
		_ = od.g_os.SSL_shutdown(conn)
		return
	}

	h2: http2.Http2_Connection
	http2.conn_init(&h2, true)
	defer http2.conn_destroy(&h2)

	out: [dynamic]u8
	defer delete(out)
	http2.conn_send_preface(&h2, &out)

	buf: [4096]u8
	for {
		if len(out) > 0 {
			if od.g_os.SSL_write(conn, raw_data(out), c.int(len(out))) <= 0 do return
			clear(&out)
		}
		n := od.g_os.SSL_read(conn, raw_data(buf[:]), c.int(len(buf)))
		if n <= 0 {
			_ = od.g_os.SSL_shutdown(conn)
			return
		}
		if http2.conn_feed(&h2, buf[:n], &out) != .None do return

		for {
			sid, req_hdrs, _, ok := http2.conn_take_request(&h2)
			if !ok do break
			path := "?"
			for h in req_hdrs do if h.name == ":path" do path = h.value
			hdrs := [2]Header{{name = ":status", value = "200"}, {name = "content-type", value = "text/plain"}}
			body := fmt.tprintf("hello over h2 %s", path)
			http2.conn_send_response(&h2, &out, sid, hdrs[:], transmute([]u8)body)
		}
	}
}

@(test)
test_tls_dialer_alpn_h2 :: proc(t: ^testing.T) {
	if !od.os_ensure_ssl() {
		testing.expect(t, true, "skip: no OpenSSL")
		return
	}
	listener, lerr := net.listen_tcp(net.Endpoint{address = net.IP4_Address{127, 0, 0, 1}, port = 0})
	testing.expect(t, lerr == nil, "listen")
	defer net.close(listener)
	ep, _ := net.bound_endpoint(listener)

	args := Tls_Test_Server{listener = listener}
	th := thread.create_and_start_with_data(&args, server_thread)
	defer {
		thread.join(th)
		thread.destroy(th)
	}

	url := fmt.tprintf("https://127.0.0.1:%d/greet", ep.port)
	res, err := get(url, {insecure = true})
	defer response_destroy(&res)
	testing.expect_value(t, err, Http_Error.None)
	testing.expect_value(t, res.version, ProtocolVersion.Http2)
	testing.expect_value(t, res.status, Status.OK)
	testing.expect_value(t, string(res.body[:]), "hello over h2 /greet")
}

@(test)
test_tls_h2_multiplexing :: proc(t: ^testing.T) {
	if !od.os_ensure_ssl() {
		testing.expect(t, true, "skip: no OpenSSL")
		return
	}
	listener, lerr := net.listen_tcp(net.Endpoint{address = net.IP4_Address{127, 0, 0, 1}, port = 0})
	testing.expect(t, lerr == nil, "listen")
	defer net.close(listener)
	ep, _ := net.bound_endpoint(listener)

	args := Tls_Test_Server{listener = listener}
	th := thread.create_and_start_with_data(&args, server_thread)
	defer {
		thread.join(th)
		thread.destroy(th)
	}

	conn, derr := dial(fmt.tprintf("https://127.0.0.1:%d/", ep.port), {insecure = true})
	testing.expect_value(t, derr, Http_Error.None)
	defer close(conn)
	testing.expect_value(t, conn.version, ProtocolVersion.Http2)

	for path in ([]string{"/one", "/two", "/three"}) {
		req := Request{method = "GET", target = Target{host = conn.target.host, path = path}}
		r, err := request(conn, &req)
		defer response_destroy(&r)
		testing.expect_value(t, err, Http_Error.None)
		testing.expect_value(t, string(r.body[:]), fmt.tprintf("hello over h2 %s", path))
	}
	testing.expect_value(t, conn.h2.next_stream_id, u32(7))
}

@(test)
test_tls_dialer_rejects_self_signed :: proc(t: ^testing.T) {
	if !od.os_ensure_ssl() {
		testing.expect(t, true, "skip: no OpenSSL")
		return
	}
	listener, lerr := net.listen_tcp(net.Endpoint{address = net.IP4_Address{127, 0, 0, 1}, port = 0})
	testing.expect(t, lerr == nil, "listen")
	defer net.close(listener)
	ep, _ := net.bound_endpoint(listener)

	args := Tls_Test_Server{listener = listener}
	th := thread.create_and_start_with_data(&args, server_thread)
	defer {
		thread.join(th)
		thread.destroy(th)
	}

	url := fmt.tprintf("https://127.0.0.1:%d/", ep.port)
	res, err := get(url)
	defer response_destroy(&res)
	testing.expect_value(t, err, Http_Error.Tls_Failed)
}

@(test)
test_tls_alpn_http1_only :: proc(t: ^testing.T) {
	if !od.os_ensure_ssl() {
		testing.expect(t, true, "skip: no OpenSSL")
		return
	}
	listener, lerr := net.listen_tcp(net.Endpoint{address = net.IP4_Address{127, 0, 0, 1}, port = 0})
	testing.expect(t, lerr == nil, "listen")
	defer net.close(listener)
	ep, _ := net.bound_endpoint(listener)

	args := Tls_Test_Server{listener = listener, alpn_h1_only = true}
	th := thread.create_and_start_with_data(&args, server_thread)
	defer {
		thread.join(th)
		thread.destroy(th)
	}

	url := fmt.tprintf("https://127.0.0.1:%d/", ep.port)
	res, err := get(url, {insecure = true, version = .Http1})
	defer response_destroy(&res)
	testing.expect_value(t, err, Http_Error.None)
	testing.expect_value(t, res.version, ProtocolVersion.Http1)
	testing.expect_value(t, res.status, Status.OK)
}

@(test)
test_client_shared_ctx_roots_once :: proc(t: ^testing.T) {
	if !od.os_ensure_ssl() {
		testing.expect(t, true, "skip: no OpenSSL")
		return
	}
	// Trigger shared CTX init via insecure dial machinery.
	_client_ssl_ctx_ensure()
	n0 := client_roots_load_count
	_client_ssl_ctx_ensure()
	_client_ssl_ctx_ensure()
	testing.expect(t, client_roots_load_count == n0 || client_roots_load_count <= 1, "roots at most once")
	// After first ensure, count should not grow.
	testing.expect(t, client_roots_load_count <= 1)
}
