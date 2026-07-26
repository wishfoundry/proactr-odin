// Size ladder + fortunes stub on laytan/odin-http (nbio/io_uring on Linux).
package main

import "core:fmt"
import "core:log"
import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"

import http "laytan:odin-http"

P_4K, P_64K, P_1M, P_4M: string

main :: proc() {
	context.logger = log.create_console_logger(.Info)
	P_4K = make_payload(4 * 1024)
	P_64K = make_payload(64 * 1024)
	P_1M = make_payload(1024 * 1024)
	P_4M = make_payload(4 * 1024 * 1024)

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
	http.route_get(&router, "/s/4k", http.handler(on_4k))
	http.route_get(&router, "/s/64k", http.handler(on_64k))
	http.route_get(&router, "/s/1m", http.handler(on_1m))
	http.route_get(&router, "/s/4m", http.handler(on_4m))
	http.route_get(&router, "/fortunes", http.handler(on_fortunes))

	opts := http.Default_Server_Opts
	opts.thread_count = workers

	log.infof(
		"laytan tfb peer on :%d workers=%d io=nbio/io_uring size-ladder=on fortunes=501",
		port,
		workers,
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

on_fortunes :: proc(req: ^http.Request, res: ^http.Response) {
	http.headers_set(&res.headers, "server", "Laytan")
	http.respond(res, http.Status.Not_Implemented)
}
