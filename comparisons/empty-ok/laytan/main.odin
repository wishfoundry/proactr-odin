// Empty-ok against vendored laytan/odin-http (nbio / reactor-shaped baseline).
package main

import "core:fmt"
import "core:log"
import "core:net"
import "core:os"
import "core:strconv"

// Build with:
//   odin build . -out:server.bin -o:speed \
//     -collection:laytan=../../../vendor/laytan/odin-http
import http "laytan:."

main :: proc() {
	context.logger = log.create_console_logger(.Info)

	port: int = 18080
	if p, ok := os.lookup_env("PORT"); ok {
		if v, ok2 := strconv.parse_int(p); ok2 {
			port = v
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

	log.infof("laytan empty-ok on :%d", port)
	err := http.listen_and_serve(
		&s,
		http.router_handler(&router),
		net.Endpoint{address = net.IP4_Address{0, 0, 0, 0}, port = port},
	)
	fmt.assertf(err == nil, "server stopped: %v", err)
}
