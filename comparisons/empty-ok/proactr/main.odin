// Empty-ok for proactr-hosted http (io_uring host on Linux).
package main

import "core:fmt"
import "core:log"
import "core:net"
import "core:os"
import "core:strconv"

import http "../../../http"

main :: proc() {
	context.logger = log.create_console_logger(.Info)

	port := 18080
	if p := os.get_env_alloc("PORT", context.allocator); p != "" {
		if v, ok2 := strconv.parse_int(p); ok2 {
			port = v
		}
		delete(p)
	}
	// Honor WORKERS (default 1). Must pass as listen_and_serve 4th arg —
	// setting s.opts alone is overwritten by Default_Server_Opts.
	workers := 1
	if p := os.get_env_alloc("WORKERS", context.allocator); p != "" {
		if v, ok2 := strconv.parse_int(p); ok2 {
			workers = max(1, v)
		}
		delete(p)
	}

	router: http.Router
	http.router_init(&router)
	defer http.router_destroy(&router)

	http.route_get(&router, "/", http.handler(proc(req: ^http.Request, res: ^http.Response) {
		http.respond_plain(res, "OK")
	}))
	http.route_get(&router, "/health", http.handler(proc(req: ^http.Request, res: ^http.Response) {
		http.respond_plain(res, "ok")
	}))

	s: http.Server
	http.server_shutdown_on_interrupt(&s)

	opts := http.Default_Server_Opts
	opts.thread_count = workers

	log.infof("proactr empty-ok on :%d workers=%d io=proactr/io_uring", port, workers)
	err := http.listen_and_serve(
		&s,
		http.router_handler(&router),
		net.Endpoint{address = net.IP4_Address{0, 0, 0, 0}, port = port},
		opts,
	)
	fmt.eprintf("exited: %v\n", err)
	if err == .Unsupported {
		os.exit(2)
	}
}
