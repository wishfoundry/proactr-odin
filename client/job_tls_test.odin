// PR3: https H1/H2 over proactr mem-BIO Client_Job.
package client

import "core:c"
import "core:fmt"
import "core:net"
import "core:testing"
import "core:thread"
import "core:time"

import "../http2"
import "../http3" // TEST_CERT_PEM / TEST_KEY_PEM
import od "../openssl_dynlib"

@(private)
Tls_Proactr_Server :: struct {
	listener:     net.TCP_Socket,
	alpn_h1_only: bool,
}

@(private)
_proactr_alpn_h2 :: proc "c" (
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

@(private)
_proactr_alpn_h1 :: proc "c" (
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

@(private)
_proactr_ctx_load_pem :: proc(ctx: rawptr, cert_pem, key_pem: []u8) -> bool {
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

@(private)
_proactr_tls_server_thread :: proc(data: rawptr) {
	args := (^Tls_Proactr_Server)(data)
	if !od.os_ensure_ssl() do return

	sock, _, aerr := net.accept_tcp(args.listener)
	if aerr != nil do return
	defer net.close(sock)
	_suppress_sigpipe(sock)

	ctx := od.g_os.SSL_CTX_new(od.g_os.TLS_server_method())
	if ctx == nil do return
	defer od.g_os.SSL_CTX_free(ctx)
	if !_proactr_ctx_load_pem(
		ctx,
		transmute([]u8)string(http3.TEST_CERT_PEM),
		transmute([]u8)string(http3.TEST_KEY_PEM),
	) {return}
	if args.alpn_h1_only {
		od.g_os.SSL_CTX_set_alpn_select_cb(ctx, rawptr(_proactr_alpn_h1), nil)
	} else {
		od.g_os.SSL_CTX_set_alpn_select_cb(ctx, rawptr(_proactr_alpn_h2), nil)
	}

	conn := od.g_os.SSL_new(ctx)
	if conn == nil do return
	defer od.g_os.SSL_free(conn)
	_ = od.g_os.SSL_set_fd(conn, c.int(sock))
	if od.g_os.SSL_accept(conn) != 1 do return

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
			hdrs := [2]Header {
				{name = ":status", value = "200"},
				{name = "content-type", value = "text/plain"},
			}
			body := fmt.tprintf("hello over h2 %s", path)
			http2.conn_send_response(&h2, &out, sid, hdrs[:], transmute([]u8)body)
		}
	}
}

@(test)
test_proactr_https_h1 :: proc(t: ^testing.T) {
	if !od.os_ensure_ssl() {
		testing.expect(t, true, "skip: no OpenSSL")
		return
	}
	listener, lerr := net.listen_tcp(net.Endpoint{address = net.IP4_Address{127, 0, 0, 1}, port = 0})
	testing.expect(t, lerr == nil, "listen")
	if lerr != nil do return
	defer net.close(listener)
	ep, _ := net.bound_endpoint(listener)

	args := Tls_Proactr_Server{listener = listener, alpn_h1_only = true}
	th := thread.create_and_start_with_data(&args, _proactr_tls_server_thread)
	defer {
		thread.join(th)
		thread.destroy(th)
	}

	rt: Client_Runtime
	if !runtime_init(&rt, context.allocator, 32) {
		testing.expect(t, false, "runtime_init")
		return
	}
	defer runtime_destroy(&rt)

	res: Response
	err: Http_Error = .Connect_Failed
	for attempt in 0 ..< 30 {
		if attempt > 0 {
			time.sleep(2 * time.Millisecond)
		}
		sock, derr := net.dial_tcp(ep)
		if derr != nil {
			err = .Connect_Failed
			continue
		}
		_ = net.set_blocking(sock, false)
		res, err = tls_request_blocking(
			&rt,
			i32(sock),
			"GET",
			"127.0.0.1",
			"/",
			ep.port,
			nil,
			DEFAULT_MAX_RESPONSE_BODY,
			true,
			.Http1,
			2_000,
			context.allocator,
		)
		if err == .None do break
		response_destroy(&res)
		res = {}
	}
	defer response_destroy(&res)
	_ = runtime_drain(&rt, 16, 0)
	testing.expect_value(t, err, Http_Error.None)
	testing.expect_value(t, res.version, ProtocolVersion.Http1)
	testing.expect_value(t, res.status, Status.OK)
	testing.expect_value(t, string(res.body[:]), "ok")
}

@(test)
test_proactr_https_h2 :: proc(t: ^testing.T) {
	if !od.os_ensure_ssl() {
		testing.expect(t, true, "skip: no OpenSSL")
		return
	}
	listener, lerr := net.listen_tcp(net.Endpoint{address = net.IP4_Address{127, 0, 0, 1}, port = 0})
	testing.expect(t, lerr == nil, "listen")
	if lerr != nil do return
	defer net.close(listener)
	ep, _ := net.bound_endpoint(listener)

	args := Tls_Proactr_Server{listener = listener, alpn_h1_only = false}
	th := thread.create_and_start_with_data(&args, _proactr_tls_server_thread)
	defer {
		thread.join(th)
		thread.destroy(th)
	}

	url := fmt.tprintf("https://127.0.0.1:%d/greet", ep.port)
	// Private runtime (not thread-local) to avoid cross-test ring pollution under parallel load.
	rt: Client_Runtime
	if !runtime_init(&rt, context.allocator, 32) {
		testing.expect(t, false, "runtime_init")
		return
	}
	defer runtime_destroy(&rt)

	// Retry short dials until accept thread is ready (do not use 5s × N).
	res: Response
	err: Http_Error = .Connect_Failed
	for attempt in 0 ..< 30 {
		if attempt > 0 {
			time.sleep(2 * time.Millisecond)
		}
		// Dial TCP + TLS on private runtime (same path as get_proactr https).
		sock, derr := net.dial_tcp(ep)
		if derr != nil {
			err = .Connect_Failed
			continue
		}
		_ = net.set_blocking(sock, false)
		res, err = tls_request_blocking(
			&rt,
			i32(sock),
			"GET",
			"127.0.0.1",
			"/greet",
			ep.port,
			nil,
			DEFAULT_MAX_RESPONSE_BODY,
			true, // insecure
			.Auto,
			2_000,
			context.allocator,
		)
		if err == .None do break
		response_destroy(&res)
		res = {}
	}
	defer response_destroy(&res)
	_ = runtime_drain(&rt, 16, 0)
	testing.expect_value(t, err, Http_Error.None)
	testing.expect_value(t, res.version, ProtocolVersion.Http2)
	testing.expect_value(t, res.status, Status.OK)
	testing.expect_value(t, string(res.body[:]), "hello over h2 /greet")
}

@(test)
test_proactr_https_h2_async_runtime :: proc(t: ^testing.T) {
	if !od.os_ensure_ssl() {
		testing.expect(t, true, "skip: no OpenSSL")
		return
	}
	listener, lerr := net.listen_tcp(net.Endpoint{address = net.IP4_Address{127, 0, 0, 1}, port = 0})
	testing.expect(t, lerr == nil, "listen")
	if lerr != nil do return
	defer net.close(listener)
	ep, _ := net.bound_endpoint(listener)

	args := Tls_Proactr_Server{listener = listener, alpn_h1_only = false}
	th := thread.create_and_start_with_data(&args, _proactr_tls_server_thread)
	defer {
		thread.join(th)
		thread.destroy(th)
	}
	time.sleep(10 * time.Millisecond)

	rt: Client_Runtime
	if !runtime_init(&rt, context.allocator, 32) {
		testing.expect(t, false, "runtime_init")
		return
	}
	defer runtime_destroy(&rt)

	Wait :: struct {
		done: bool,
		res:  Response,
		err:  Http_Error,
	}
	wait: Wait
	url := fmt.tprintf("https://127.0.0.1:%d/async", ep.port)
	job, err := get_async_runtime(
		&rt,
		url,
		Options{insecure = true, version = .Http2},
		rawptr(&wait),
		proc(user: rawptr, res: Response, err: Http_Error) {
			w := (^Wait)(user)
			w.res = res
			w.err = err
			w.done = true
		},
	)
	if err != .None {
		testing.expect(t, false, fmt.tprintf("start: %v", err))
		return
	}
	_ = job
	perr := runtime_pump_until(&rt, &wait.done, 5_000)
	testing.expect_value(t, perr, Http_Error.None)
	testing.expect(t, wait.done, "on_done fired")
	defer response_destroy(&wait.res)
	testing.expect_value(t, wait.err, Http_Error.None)
	testing.expect_value(t, wait.res.version, ProtocolVersion.Http2)
	testing.expect_value(t, string(wait.res.body[:]), "hello over h2 /async")
}

@(test)
test_proactr_https_cancel_during_handshake :: proc(t: ^testing.T) {
	if !od.os_ensure_ssl() {
		testing.expect(t, true, "skip: no OpenSSL")
		return
	}
	// Listener that never accepts → client stuck after TCP connect / HS want-read.
	listener, lerr := net.listen_tcp(net.Endpoint{address = net.IP4_Address{127, 0, 0, 1}, port = 0})
	testing.expect(t, lerr == nil, "listen")
	if lerr != nil do return
	defer net.close(listener)
	ep, _ := net.bound_endpoint(listener)

	rt: Client_Runtime
	if !runtime_init(&rt, context.allocator, 32) {
		testing.expect(t, false, "runtime_init")
		return
	}
	defer runtime_destroy(&rt)

	Done_Ctx :: struct {
		calls: int,
		err:   Http_Error,
	}
	ctx: Done_Ctx

	// Dial ourselves so we can cancel before peer accepts TLS.
	sock, derr := net.dial_tcp(net.Endpoint{address = net.IP4_Address{127, 0, 0, 1}, port = ep.port})
	testing.expect(t, derr == nil, "dial")
	if derr != nil do return
	_ = net.set_blocking(sock, false)

	job, err := tls_request_start(
		&rt,
		i32(sock),
		"GET",
		"127.0.0.1",
		"/",
		ep.port,
		nil,
		DEFAULT_MAX_RESPONSE_BODY,
		true,
		.Http1,
		rawptr(&ctx),
		proc(user: rawptr, res: Response, err: Http_Error) {
			_ = res
			c := (^Done_Ctx)(user)
			c.calls += 1
			c.err = err
		},
		context.allocator,
	)
	if err != .None {
		testing.expect(t, false, fmt.tprintf("tls start: %v", err))
		return
	}
	testing.expect(t, job != nil && job.live, "job live")
	// Option B: first cancel fires on_done sync with .Closed (no second reason).
	job_cancel(job, false)
	testing.expect_value(t, ctx.calls, 1)
	testing.expect_value(t, ctx.err, Http_Error.Closed)
	// Second cancel is no-op (reason frozen).
	job_cancel(job, true)
	testing.expect_value(t, ctx.calls, 1)
	testing.expect_value(t, ctx.err, Http_Error.Closed)
	// Best-effort harvest; SSL free when ops hit 0 (peer never answers TLS).
	for _ in 0 ..< 32 {
		_ = runtime_drain(&rt, 8, 5)
		if len(rt.job_free) > 0 {
			break
		}
	}
}
