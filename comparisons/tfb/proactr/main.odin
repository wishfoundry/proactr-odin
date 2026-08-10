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
// PROFILE_MATRIX.md: 8×64KiB with first byte 'A'+i, concat = 524288.
SLICE_N :: 8
SLICE_SIZE :: 64 * 1024
g_slices: [SLICE_N][]u8
g_assembled: []u8
g_file_path: string
g_file_fd: i32 = -1
g_file_len: i64
g_plan_optimize: bool
SSE_BODY :: "event: ping\ndata: 1\n\nevent: ping\ndata: 2\n\n"
GEN_BODY :: "generated:ok\n"

main :: proc() {
	context.logger = log.create_console_logger(.Info)
	P_4K = make_payload(4 * 1024)
	P_64K = make_payload(64 * 1024)
	P_1M = make_payload(1024 * 1024)
	P_4M = make_payload(4 * 1024 * 1024)
	init_profile_payloads()

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
	g_plan_optimize = false
	if p := os.get_env_alloc("PLAN_MODE", context.allocator); p != "" {
		low := strings.to_lower(p, context.temp_allocator)
		g_plan_optimize = low == "optimize" || low == "opt" || low == "1" || low == "on"
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

	b: http.Builder
	http.builder_init(&b)
	defer http.builder_destroy(&b)

	http.builder_get(&b, "/plaintext", http.handler(on_plaintext))
	http.builder_get(&b, "/api/tiny", http.handler(on_plaintext))
	http.builder_get(&b, "/gen/ok", http.handler(on_gen))
	http.builder_get(&b, "/static/assembled", http.handler(on_assembled))
	http.builder_get(&b, "/static/blob/1m", http.handler(on_blob))
	http.builder_get(&b, "/file/1m", http.handler(on_file))
	http.builder_get(&b, "/sse", http.handler(on_sse))
	http.builder_get(&b, "/s/4k", http.handler(on_4k))
	http.builder_get(&b, "/s/64k", http.handler(on_64k))
	http.builder_get(&b, "/s/1m", http.handler(on_1m))
	http.builder_get(&b, "/s/4m", http.handler(on_4m))
	http.builder_get(&b, "/fortunes", http.handler(on_fortunes))

	opts := http.Default_Server_Opts
	opts.thread_count = workers
	opts.plan_optimize = g_plan_optimize
	opts.plan_sendfile_ok = true
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
	plan_s := g_plan_optimize ? "optimize" : "materialize"
	log.infof(
		"proactr tfb peer on :%d workers=%d db=%s io=proactr fortunes=%s plan=%s file=%s",
		port,
		workers,
		db_path,
		mode_s,
		plan_s,
		g_file_path,
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

on_gen :: proc(req: ^http.Request, res: ^http.Response) {
	// Fair peer gen: same static bytes as ntex/drogon/laytan (no DB).
	// body_reserve microbench stays in comparisons/plan /gen/ok if needed.
	set_server(res)
	http.respond_plain(res, GEN_BODY)
}

on_assembled :: proc(req: ^http.Request, res: ^http.Response) {
	set_server(res)
	res.status = .OK
	http.headers_set_content_type(&res.headers, "text/plain")
	if g_plan_optimize {
		// Multi-cmd intent → Writev/multi_send under plan_optimize (no prefer_gather required).
		for i in 0 ..< SLICE_N {
			http.body_static(res, g_slices[i])
		}
		http.respond(res)
		return
	}
	// Materialize mode: preconcat blob (same bytes as multi-static).
	http.respond_plain(res, transmute(string)g_assembled)
}

on_blob :: proc(req: ^http.Request, res: ^http.Response) {
	set_server(res)
	http.respond_plain(res, P_1M)
}

on_file :: proc(req: ^http.Request, res: ^http.Response) {
	set_server(res)
	// Never fall back to in-memory P_1M — PROFILE_MATRIX: /file/1m must be disk.
	if g_plan_optimize && g_file_fd >= 0 {
		// plan_optimize + plan_sendfile_ok → Sendfile plan (prefer_sendfile not required).
		res.status = .OK
		http.headers_set_content_type(&res.headers, "text/plain")
		http.body_file(res, g_file_fd, 0, g_file_len)
		http.respond(res)
		return
	}
	if g_file_path != "" {
		// Materialize: full file read from path (file_read_full). 404/500 if missing.
		http.respond_file(res, g_file_path)
		return
	}
	res.status = .Internal_Server_Error
	http.headers_set_content_type(&res.headers, "text/plain")
	http.body_set(res, "file path not configured")
	http.respond(res)
}

on_sse :: proc(req: ^http.Request, res: ^http.Response) {
	// Peer-fair oneshot: Content-Length body (same 42 bytes as ntex/drogon/laytan).
	// Chunked begin_stream is covered by comparisons/plan, not this peer matrix.
	set_server(res)
	res.status = .OK
	http.headers_set_content_type(&res.headers, "text/event-stream")
	http.headers_set(&res.headers, "cache-control", "no-cache")
	http.body_set(res, SSE_BODY)
	http.respond(res)
}

init_profile_payloads :: proc() {
	for i in 0 ..< SLICE_N {
		g_slices[i] = transmute([]u8)make_payload(SLICE_SIZE)
		// Distinct first byte per PROFILE_MATRIX.md
		g_slices[i][0] = u8('A' + i)
	}
	g_assembled = make([]u8, SLICE_N * SLICE_SIZE)
	for i in 0 ..< SLICE_N {
		copy(g_assembled[i * SLICE_SIZE:][:SLICE_SIZE], g_slices[i])
	}
	g_file_path = "/tmp/proactr-profile-file-1m.bin"
	if p := os.get_env_alloc("PLAN_FILE_PATH", context.allocator); p != "" {
		g_file_path = p
	}
	// Write file if missing/wrong size so /file/1m is real disk I/O for all peers.
	need_write := true
	if data, err := os.read_entire_file(g_file_path, context.temp_allocator); err == nil {
		if len(data) == len(P_1M) {
			need_write = false
		}
	}
	if need_write {
		_ = os.write_entire_file(g_file_path, transmute([]u8)P_1M)
	}
	g_file_len = i64(len(P_1M))
	when ODIN_OS != .Windows {
		if f, err := os.open(g_file_path); err == nil {
			// Keep process-lifetime fd for body_file optimize path.
			g_file_fd = i32(os.fd(f))
		}
	}
}
