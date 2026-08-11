// Minimal empty-ok server on the proactr io_uring host (Linux).
// Env:
//   PORT    listen port (default 8080)
//   WORKERS worker threads / rings (default 1; pass via listen_builder opts)
package main

import "core:fmt"
import "core:log"
import "core:net"
import "core:os"
import "core:strconv"

import http "../../http"

main :: proc() {
	context.logger = log.create_console_logger(.Info)

	port := 8080
	if p := os.get_env_alloc("PORT", context.allocator); p != "" {
		if v, ok2 := strconv.parse_int(p); ok2 {
			port = v
		}
		delete(p)
	}
	// Must pass as listen_builder opts — setting s.opts alone is overwritten.
	workers := 1
	if p := os.get_env_alloc("WORKERS", context.allocator); p != "" {
		if v, ok2 := strconv.parse_int(p); ok2 {
			workers = max(1, v)
		}
		delete(p)
	}

	b: http.Builder
	http.builder_init(&b)
	defer http.builder_destroy(&b)

	http.builder_get_fn(&b, "/", proc(req: ^http.Request, res: ^http.Response) {
		http.respond_plain(res, "OK")
	})
	http.builder_get_fn(&b, "/health", proc(req: ^http.Request, res: ^http.Response) {
		http.respond_plain(res, "ok")
	})

	s: http.Server
	http.server_shutdown_on_interrupt(&s)

	opts := http.Default_Server_Opts
	opts.thread_count = workers

	log.infof(
		"proactr empty_ok on :%d workers=%d (io_uring host on Linux)",
		port,
		workers,
	)
	err, build_err := http.listen_builder(
		&s,
		&b,
		net.Endpoint{address = net.IP4_Address{0, 0, 0, 0}, port = port},
		opts,
	)
	if build_err.kind != .None {
		fmt.eprintf("route build: %s\n", http.builder_error_format(build_err))
		os.exit(1)
	}
	fmt.eprintf("server exited: %v\n", err)
	if err == .Unsupported {
		os.exit(2)
	}
}
