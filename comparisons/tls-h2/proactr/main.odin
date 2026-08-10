// TLS/H2 peer for comparisons/tls-h2 matrix.
// WORKERS, PORT, CERT_FILE, KEY_FILE from env.
// Instrumentation: GET /_matrix/stats (path_metrics scrape) + PHASE if built with HTTP_PHASE_STATS.
package main

import "core:fmt"
import "core:log"
import "core:net"
import "core:os"
import "core:strconv"

import http "../../../http"

g_p4k:  []u8
g_p64k: []u8
g_p1m:  []u8

make_payload :: proc(n: int, allocator := context.allocator) -> []u8 {
	pat := transmute([]u8)string("0123456789abcdef0123456789ABCDEF0123456789abcdef0123456789ABCDEF")
	b := make([]u8, n, allocator)
	for i in 0 ..< n {
		b[i] = pat[i % len(pat)]
	}
	return b
}

env_str :: proc(key, def: string) -> string {
	s := os.get_env_alloc(key, context.temp_allocator)
	if s == "" {
		return def
	}
	return s
}

main :: proc() {
	context.logger = log.create_console_logger(.Info)
	port := 18443
	if p := env_str("PORT", ""); p != "" {
		if v, ok := strconv.parse_int(p); ok {
			port = v
		}
	}
	workers := 8
	if w := env_str("WORKERS", ""); w != "" {
		if v, ok := strconv.parse_int(w); ok && v > 0 {
			workers = v
		}
	}
	cert_path := env_str("CERT_FILE", "certs/cert.pem")
	key_path := env_str("KEY_FILE", "certs/key.pem")
	cert_pem, cerr := os.read_entire_file(cert_path, context.allocator)
	key_pem, kerr := os.read_entire_file(key_path, context.allocator)
	if cerr != nil || kerr != nil || len(cert_pem) == 0 || len(key_pem) == 0 {
		log.errorf("need CERT_FILE/KEY_FILE readable pems (got cert=%v key=%v paths=%s %s)", cerr, kerr, cert_path, key_path)
		os.exit(1)
	}

	g_p4k = make_payload(4 * 1024)
	g_p64k = make_payload(64 * 1024)
	g_p1m = make_payload(1024 * 1024)

	b: http.Builder
	http.builder_init(&b)
	defer http.builder_destroy(&b)

	http.builder_get_fn(&b, "/plaintext", proc(req: ^http.Request, res: ^http.Response) {
		_ = req
		http.respond_plain(res, "Hello, World!")
	})
	http.builder_get_fn(&b, "/api/tiny", proc(req: ^http.Request, res: ^http.Response) {
		_ = req
		http.respond_plain(res, "Hello, World!")
	})
	http.builder_get_fn(&b, "/s/4k", proc(req: ^http.Request, res: ^http.Response) {
		_ = req
		res.status = .OK
		http.headers_set_content_type(&res.headers, "text/plain")
		http.body_set_bytes(res, g_p4k)
		http.respond(res)
	})
	http.builder_get_fn(&b, "/s/64k", proc(req: ^http.Request, res: ^http.Response) {
		_ = req
		res.status = .OK
		http.headers_set_content_type(&res.headers, "text/plain")
		http.body_set_bytes(res, g_p64k)
		http.respond(res)
	})
	http.builder_get_fn(&b, "/s/1m", proc(req: ^http.Request, res: ^http.Response) {
		_ = req
		res.status = .OK
		http.headers_set_content_type(&res.headers, "text/plain")
		http.body_set_bytes(res, g_p1m)
		http.respond(res)
	})
	http.builder_get_fn(&b, "/sse", proc(req: ^http.Request, res: ^http.Response) {
		_ = req
		http.headers_set_content_type(&res.headers, "text/event-stream")
		http.respond_plain(res, "event: ping\ndata: 1\n\nevent: ping\ndata: 2\n\n")
	})
	// Scrape path instrumentation (does not count as bench work when not under load).
	http.builder_get_fn(&b, "/_matrix/stats", proc(req: ^http.Request, res: ^http.Response) {
		_ = req
		s := http.path_metrics_format(context.temp_allocator)
		res.status = .OK
		http.headers_set_content_type(&res.headers, "text/plain")
		http.body_set_bytes(res, transmute([]u8)s)
		http.respond(res)
	})
	http.builder_post_fn(&b, "/_matrix/reset", proc(req: ^http.Request, res: ^http.Response) {
		_ = req
		http.path_metrics_reset()
		http.respond_plain(res, "ok\n")
	})

	s: http.Server
	http.server_shutdown_on_interrupt(&s)
	opts := http.Default_Server_Opts
	opts.thread_count = workers
	opts.tls_cert_pem = cert_pem
	opts.tls_key_pem = key_pem
	opts.h2_serial_dispatch = false

	ep := net.Endpoint{address = net.IP4_Address{0, 0, 0, 0}, port = port}
	// Operator label (path_metrics.io_engine); not exposed to handlers/APP_CONTRACT.
	io_name := http.path_metrics_io_engine()
	fmt.printf(
		"proactr tls-h2 on 0.0.0.0:%d workers=%d alpn=h2|http/1.1 tls=openssl-membio io_engine=%s instrument=path_metrics phase_stats=%v\n",
		port,
		workers,
		io_name,
		http.HTTP_PHASE_STATS,
	)
	// PEMs on opts; listen_builder → listen_and_serve (TLS path same as listen_and_serve_tls).
	err, build_err := http.listen_builder(&s, &b, ep, opts)
	if build_err.kind != .None {
		log.errorf("route build: %s", http.builder_error_format(build_err))
		os.exit(1)
	}
	if err != .None {
		log.errorf("listen_builder: %v", err)
		os.exit(1)
	}
}
