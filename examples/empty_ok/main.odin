// Minimal empty-ok server — will listen once proactr io_uring host lands.
package main

import "core:fmt"
import "core:log"
import "core:net"
import "core:os"

import http "../../http"

main :: proc() {
	context.logger = log.create_console_logger(.Info)

	router: http.Router
	http.router_init(&router)
	defer http.router_destroy(&router)

	http.route_get(&router, "/", proc(req: ^http.Request, res: ^http.Response) {
		http.respond_plain(res, "OK")
	})
	http.route_get(&router, "/health", proc(req: ^http.Request, res: ^http.Response) {
		http.respond_plain(res, "ok")
	})

	s: http.Server
	ep := net.Endpoint {
		address = net.IP4_Address{0, 0, 0, 0},
		port    = 8080,
	}

	log.info("proactr empty_ok starting on :8080 (scaffold — host not live yet)")
	err := http.listen_and_serve(&s, http.router_handler(&router), ep)
	fmt.eprintf("server exited: %v\n", err)
	if err == .Unsupported {
		os.exit(2)
	}
}
