// TechEmpower-shaped peer on vendored laytan/odin-http.
//
// json + plaintext: full (real JSON encode each request).
// fortunes/db/queries: 501 until SQLite is linked (fail closed — no RAM fortunes).
//
// Build:
//   odin build . -out:tfb-laytan -o:speed -collection:laytan=../../../vendor/laytan
package main

import "core:fmt"
import "core:log"
import "core:net"
import "core:os"
import "core:strconv"

import http "laytan:odin-http"

main :: proc() {
	context.logger = log.create_console_logger(.Info)

	port := 18080
	if p, ok := os.lookup_env("PORT", context.allocator); ok {
		if v, ok2 := strconv.parse_int(p); ok2 {
			port = v
		}
	}

	s: http.Server
	http.server_shutdown_on_interrupt(&s)

	router: http.Router
	http.router_init(&router)
	defer http.router_destroy(&router)

	http.route_get(&router, "/json", http.handler(on_json))
	http.route_get(&router, "/plaintext", http.handler(on_plaintext))
	http.route_get(&router, "/fortunes", http.handler(on_fortunes))
	http.route_get(&router, "/db", http.handler(on_db))
	http.route_get(&router, "/queries", http.handler(on_queries))

	log.infof("laytan tfb peer on :%d (DB routes=501 until SQLITE linked)", port)
	err := http.listen_and_serve(
		&s,
		http.router_handler(&router),
		net.Endpoint{address = net.IP4_Address{0, 0, 0, 0}, port = port},
	)
	fmt.assertf(err == nil, "server stopped: %v", err)
}

on_json :: proc(req: ^http.Request, res: ^http.Response) {
	Msg :: struct {
		message: string,
	}
	http.headers_set(&res.headers, "server", "Laytan")
	if err := http.respond_json(res, Msg{"Hello, World!"}); err != nil {
		log.errorf("json: %v", err)
	}
}

on_plaintext :: proc(req: ^http.Request, res: ^http.Response) {
	http.headers_set(&res.headers, "server", "Laytan")
	http.respond_plain(res, "Hello, World!")
}

on_fortunes :: proc(req: ^http.Request, res: ^http.Response) {
	http.headers_set(&res.headers, "server", "Laytan")
	http.respond(res, http.Status.Not_Implemented)
}

on_db :: proc(req: ^http.Request, res: ^http.Response) {
	http.headers_set(&res.headers, "server", "Laytan")
	http.respond(res, http.Status.Not_Implemented)
}

on_queries :: proc(req: ^http.Request, res: ^http.Response) {
	http.headers_set(&res.headers, "server", "Laytan")
	http.respond(res, http.Status.Not_Implemented)
}
