// Empty-ok for proactr-hosted http (live once io_uring host lands).
package main

import "core:fmt"
import "core:log"
import "core:net"
import "core:os"
import "core:strconv"

import http "../../../http"

main :: proc() {
	context.logger = log.create_console_logger(.Info)

	port: int = 18080
	if p, ok := os.lookup_env("PORT", context.allocator); ok {
		if v, ok2 := strconv.parse_int(p); ok2 {
			port = v
		}
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
	log.infof("proactr empty-ok on :%d", port)
	err := http.listen_and_serve(
		&s,
		http.router_handler(&router),
		net.Endpoint{address = net.IP4_Address{0, 0, 0, 0}, port = port},
	)
	fmt.eprintf("exited: %v\n", err)
	if err == .Unsupported {
		os.exit(2)
	}
}
