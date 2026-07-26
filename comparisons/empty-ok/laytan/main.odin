// Empty-ok against vendored laytan/odin-http (nbio / reactor-shaped baseline).
package main

import "core:fmt"
import "core:log"
import "core:net"
import "core:os"
import "core:strconv"

// Build with (from this directory):
//   odin build . -out:server.bin -o:speed \
//     -collection:laytan=../../../vendor/laytan
import http "laytan:odin-http"

main :: proc() {
	context.logger = log.create_console_logger(.Info)

	port := 18080
	if p, ok := os.lookup_env("PORT", context.allocator); ok {
		if v, ok2 := strconv.parse_int(p); ok2 {
			port = v
		}
	}
	// Honor WORKERS (default 1). Unset/zero must NOT fall through to all cores —
	// laytan's Default_Server_Opts thread_count==0 means get_processor_core_count().
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

	http.route_get(&router, "/", http.handler(proc(req: ^http.Request, res: ^http.Response) {
		http.respond_plain(res, "OK")
	}))
	http.route_get(&router, "/health", http.handler(proc(req: ^http.Request, res: ^http.Response) {
		http.respond_plain(res, "ok")
	}))

	opts := http.Default_Server_Opts
	opts.thread_count = workers

	log.infof("laytan empty-ok on :%d workers=%d io=nbio/io_uring", port, workers)
	err := http.listen_and_serve(
		&s,
		http.router_handler(&router),
		net.Endpoint{address = net.IP4_Address{0, 0, 0, 0}, port = port},
		opts,
	)
	fmt.assertf(err == nil, "server stopped: %v", err)
}
