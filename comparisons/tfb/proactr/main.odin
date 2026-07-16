// proactr TFB peer — not live until io_uring host lands.
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
	if p, ok := os.lookup_env("PORT"); ok {
		if v, ok2 := strconv.parse_int(p); ok2 do port = v
	}
	router: http.Router
	http.router_init(&router)
	defer http.router_destroy(&router)
	// Routes will match TFB once host works; respond paths stubbed in package.
	s: http.Server
	log.infof("proactr tfb peer scaffold on :%d", port)
	err := http.listen_and_serve(
		&s,
		http.router_handler(&router),
		net.Endpoint{address = net.IP4_Address{0, 0, 0, 0}, port = port},
	)
	fmt.eprintf("exited: %v\n", err)
	os.exit(2)
}
