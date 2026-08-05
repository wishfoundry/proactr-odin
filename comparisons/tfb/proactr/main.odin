// proactr TFB peer — size ladder + fortunes (sync or async SQLite).
//
// Env:
//   PORT, WORKERS, DATABASE_PATH
//   FORTUNES_MODE=sync|async   (default sync)
//   FORTUNES_SYNC_SHARED=1     (sync only: one conn + mutex like ntex; default is per-worker)
//   DB_WORKERS                 (async only; default = WORKERS)
package main

import "core:fmt"
import "core:log"
import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"

import http "../../../http"

P_4K, P_64K, P_1M, P_4M: string

main :: proc() {
	context.logger = log.create_console_logger(.Info)
	P_4K = make_payload(4 * 1024)
	P_64K = make_payload(64 * 1024)
	P_1M = make_payload(1024 * 1024)
	P_4M = make_payload(4 * 1024 * 1024)

	db_path := "/tmp/proactr-tfb.sqlite"
	if p := os.get_env_alloc("DATABASE_PATH", context.allocator); p != "" {
		db_path = p
	}

	mode := Fortunes_Mode.Sync
	if p := os.get_env_alloc("FORTUNES_MODE", context.allocator); p != "" {
		switch strings.to_lower(p, context.temp_allocator) {
		case "sync":
			mode = .Sync
		case "async":
			mode = .Async
		case:
			log.errorf("unknown FORTUNES_MODE=%q (use sync|async)", p)
			os.exit(1)
		}
		delete(p)
	}

	sync_shared := false
	if p := os.get_env_alloc("FORTUNES_SYNC_SHARED", context.allocator); p != "" {
		sync_shared = p == "1" || p == "true" || p == "yes"
		delete(p)
	}

	port := 18080
	if p := os.get_env_alloc("PORT", context.allocator); p != "" {
		if v, ok2 := strconv.parse_int(p); ok2 {
			port = v
		}
		delete(p)
	}
	workers := 1
	if p := os.get_env_alloc("WORKERS", context.allocator); p != "" {
		if v, ok2 := strconv.parse_int(p); ok2 {
			workers = max(1, v)
		}
		delete(p)
	}
	db_workers := workers
	if p := os.get_env_alloc("DB_WORKERS", context.allocator); p != "" {
		if v, ok2 := strconv.parse_int(p); ok2 {
			db_workers = max(1, v)
		}
		delete(p)
	}

	if !fortunes_init(mode, db_path, workers, db_workers, sync_shared) {
		os.exit(1)
	}
	defer fortunes_shutdown()

	// CPU-only microbench (no HTTP): FORTUNES_MICROBENCH=N then exit.
	if p := os.get_env_alloc("FORTUNES_MICROBENCH", context.allocator); p != "" {
		if n, ok2 := strconv.parse_int(p); ok2 && n > 0 {
			// Ensure a connection is available (shared or open once).
			if !sync_shared {
				// Force open on this thread for microbench.
				g_sync_shared = true
				if g_shared.db == nil {
					c, cok := db_open_conn(db_path)
					if !cok {
						os.exit(1)
					}
					g_shared = c
				}
			}
			fortunes_microbench(n)
			os.exit(0)
		}
		delete(p)
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
	if mode == .Async {
		// Poll deferred job queues promptly (pool posts results without ring wake).
		opts.wait_timeout_ms = 1
		opts.on_worker_tick = fortunes_worker_tick
		opts.worker_tick_user = nil
	}

	mode_s := "sqlite-sync-per-worker"
	if mode == .Async {
		mode_s = "sqlite-async"
	} else if sync_shared {
		mode_s = "sqlite-sync-shared-mutex"
	}
	log.infof(
		"proactr tfb peer on :%d workers=%d db=%s io=proactr fortunes=%s",
		port,
		workers,
		db_path,
		mode_s,
	)
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

make_payload :: proc(n: int) -> string {
	pat := "0123456789abcdef0123456789ABCDEF0123456789abcdef0123456789ABCDEF"
	b := strings.builder_make()
	for strings.builder_len(b) < n {
		strings.write_string(&b, pat)
	}
	s := strings.to_string(b)
	return s[:n]
}

// Prefer headers_set_unsafe: key already lowercase, skip sanitize on TFB hot path.
set_server :: #force_inline proc(res: ^http.Response) {
	http.headers_set_unsafe(&res.headers, "server", "Proactr")
}

on_plaintext :: proc(req: ^http.Request, res: ^http.Response) {
	set_server(res)
	http.respond_plain(res, "Hello, World!")
}

on_4k :: proc(req: ^http.Request, res: ^http.Response) {
	set_server(res)
	http.respond_plain(res, P_4K)
}

on_64k :: proc(req: ^http.Request, res: ^http.Response) {
	set_server(res)
	http.respond_plain(res, P_64K)
}

on_1m :: proc(req: ^http.Request, res: ^http.Response) {
	set_server(res)
	http.respond_plain(res, P_1M)
}

on_4m :: proc(req: ^http.Request, res: ^http.Response) {
	set_server(res)
	http.respond_plain(res, P_4M)
}
