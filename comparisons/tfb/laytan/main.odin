// Size ladder + fortunes stub on laytan/odin-http (nbio/io_uring on Linux).
package main

import "core:fmt"
import "core:log"
import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"

import http "laytan:odin-http"

P_4K, P_64K, P_1M, P_4M, P_ASSEMBLED: string
g_file_path: string
SSE_BODY :: "event: ping\ndata: 1\n\nevent: ping\ndata: 2\n\n"
GEN_BODY :: "generated:ok\n"

main :: proc() {
	context.logger = log.create_console_logger(.Info)
	P_4K = make_payload(4 * 1024)
	P_64K = make_payload(64 * 1024)
	P_1M = make_payload(1024 * 1024)
	P_4M = make_payload(4 * 1024 * 1024)
	P_ASSEMBLED = make_assembled()
	g_file_path = "/tmp/proactr-profile-file-1m.bin"
	if p, ok := os.lookup_env("PLAN_FILE_PATH", context.allocator); ok {
		g_file_path = p
	}
	ensure_profile_file(g_file_path, P_1M)

	port := 18080
	if p, ok := os.lookup_env("PORT", context.allocator); ok {
		if v, ok2 := strconv.parse_int(p); ok2 {
			port = v
		}
	}
	// Honor WORKERS (default 1). Unset/zero must NOT fall through to all cores —
	// that made laytan unfair vs peers that pass WORKERS=8.
	workers := 1
	if p, ok := os.lookup_env("WORKERS", context.allocator); ok {
		if v, ok2 := strconv.parse_int(p); ok2 {
			workers = max(1, v)
		}
	}

	s: http.Server
	http.server_shutdown_on_interrupt(&s)

	router: http.Router
	http.router_init(&router)
	defer http.router_destroy(&router)

	http.route_get(&router, "/plaintext", http.handler(on_plaintext))
	http.route_get(&router, "/api/tiny", http.handler(on_plaintext))
	http.route_get(&router, "/gen/ok", http.handler(on_gen))
	http.route_get(&router, "/static/assembled", http.handler(on_assembled))
	http.route_get(&router, "/static/blob/1m", http.handler(on_blob))
	http.route_get(&router, "/file/1m", http.handler(on_file))
	http.route_get(&router, "/sse", http.handler(on_sse))
	http.route_get(&router, "/s/4k", http.handler(on_4k))
	http.route_get(&router, "/s/64k", http.handler(on_64k))
	http.route_get(&router, "/s/1m", http.handler(on_1m))
	http.route_get(&router, "/s/4m", http.handler(on_4m))
	http.route_get(&router, "/fortunes", http.handler(on_fortunes))

	opts := http.Default_Server_Opts
	opts.thread_count = workers

	log.infof(
		"laytan tfb peer on :%d workers=%d io=nbio/io_uring profiles=on fortunes=501 file=%s mech=assembled:preconcat_blob,file:file_read_full,sse:sse_oneshot",
		port,
		workers,
		g_file_path,
	)
	err := http.listen_and_serve(
		&s,
		http.router_handler(&router),
		net.Endpoint{address = net.IP4_Address{0, 0, 0, 0}, port = port},
		opts,
	)
	fmt.assertf(err == nil, "server stopped: %v", err)
}

make_payload :: proc(n: int) -> string {
	pat := "0123456789abcdef0123456789ABCDEF0123456789abcdef0123456789ABCDEF"
	b := strings.builder_make()
	for strings.builder_len(b) < n {
		strings.write_string(&b, pat)
	}
	s := strings.to_string(b)
	return s[:n]
}

on_plaintext :: proc(req: ^http.Request, res: ^http.Response) {
	http.headers_set(&res.headers, "server", "Laytan")
	http.respond_plain(res, "Hello, World!")
}

on_4k :: proc(req: ^http.Request, res: ^http.Response) {
	http.headers_set(&res.headers, "server", "Laytan")
	http.respond_plain(res, P_4K)
}

on_64k :: proc(req: ^http.Request, res: ^http.Response) {
	http.headers_set(&res.headers, "server", "Laytan")
	http.respond_plain(res, P_64K)
}

on_1m :: proc(req: ^http.Request, res: ^http.Response) {
	http.headers_set(&res.headers, "server", "Laytan")
	http.respond_plain(res, P_1M)
}

on_4m :: proc(req: ^http.Request, res: ^http.Response) {
	http.headers_set(&res.headers, "server", "Laytan")
	http.respond_plain(res, P_4M)
}

on_gen :: proc(req: ^http.Request, res: ^http.Response) {
	http.headers_set(&res.headers, "server", "Laytan")
	http.respond_plain(res, GEN_BODY)
}

on_assembled :: proc(req: ^http.Request, res: ^http.Response) {
	http.headers_set(&res.headers, "server", "Laytan")
	http.respond_plain(res, P_ASSEMBLED)
}

on_blob :: proc(req: ^http.Request, res: ^http.Response) {
	http.headers_set(&res.headers, "server", "Laytan")
	http.respond_plain(res, P_1M)
}

on_file :: proc(req: ^http.Request, res: ^http.Response) {
	http.headers_set(&res.headers, "server", "Laytan")
	http.respond_file(res, g_file_path)
}

on_sse :: proc(req: ^http.Request, res: ^http.Response) {
	http.headers_set(&res.headers, "server", "Laytan")
	http.headers_set(&res.headers, "cache-control", "no-cache")
	http.headers_set_content_type(&res.headers, "text/event-stream")
	res.status = .OK
	http.body_set(res, SSE_BODY)
	http.respond(res)
}

make_assembled :: proc() -> string {
	// 8×64KiB, first byte 'A'+i
	total := 8 * 64 * 1024
	b := strings.builder_make()
	strings.builder_grow(&b, total)
	for i in 0 ..< 8 {
		s := make_payload(64 * 1024)
		// mutate first byte
		bytes := transmute([]u8)s
		bytes[0] = u8('A' + i)
		strings.write_bytes(&b, bytes)
	}
	return strings.to_string(b)
}

ensure_profile_file :: proc(path: string, content: string) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err == nil && len(data) == len(content) {
		return
	}
	_ = os.write_entire_file(path, transmute([]u8)content)
}

on_fortunes :: proc(req: ^http.Request, res: ^http.Response) {
	http.headers_set(&res.headers, "server", "Laytan")
	http.respond(res, http.Status.Not_Implemented)
}
