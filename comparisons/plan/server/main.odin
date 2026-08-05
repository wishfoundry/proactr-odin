// Planner A/B demo server — body-archetype routes + plan counters.
//
// Phase 3–5: PLAN_MODE=optimize sets Server_Opts.plan_optimize and route profiles so
// the real wire path can multi-buffer send (Writev-style) for multi-static routes
// and stream File regions via chunked pread+send for /file/1m (prefer_sendfile).
// /sse uses response_begin_stream (Phase 5) — not plan_body.
//
// Shadow plan_body counters remain for policy checks; http.plan_wire_* counters
// show what the executor actually chose on the wire.
//
// Env:
//   PORT              listen port (default 19090)
//   WORKERS           worker threads / rings (default 1)
//   PLAN_MODE         materialize | optimize  (default materialize)
//   PLAN_SENDFILE_OK  1 to allow sendfile in optimize mode (default 1)
//   PLAN_COPY_BUDGET  preferred_copy_budget bytes (default 4096)
//   PLAN_MAX_IOVECS   max iovecs incl. heading (default 1024)
//   PLAN_FILE_PATH    path for /file/1m (default: create under data dir)
//   PLAN_DATA_DIR     dir for generated file payload (default /tmp/proactr-plan-bench)
package main

import "core:fmt"
import "core:log"
import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"

import http "../../../http"

// --- plan mode & global knobs ------------------------------------------------

Plan_Mode :: enum {
	Materialize,
	Optimize,
}

g_mode: Plan_Mode
g_sendfile_ok: bool
g_copy_budget: u32
g_max_iovecs: u16

// Immutable payloads (process lifetime).
SLICE_N :: 8
SLICE_SIZE :: 64 * 1024 // 8×64K = 512K assembled
BLOB_1M_SIZE :: 1024 * 1024
FILE_1M_SIZE :: 1024 * 1024

g_slices: [SLICE_N][]u8
g_blob_1m: []u8
g_assembled_flat: []u8 // same bytes as slices joined (wire body)
g_file_path: string
g_file_len: i64
g_file_fd: i32 = -1 // process-lifetime open for body_file wire path
g_file_wire: []u8 // preloaded bytes for materialize-mode / fallback

// --- metrics (atomic) --------------------------------------------------------

Metrics :: struct {
	plan_materialize: u64,
	plan_writev:      u64,
	plan_sendfile:    u64,
	plan_copy_into:   u64,
	plan_patch_cl:    u64,
	plan_flush:       u64,
	plan_other:       u64,
	plan_responses:   u64,
	hit_tiny:         u64,
	hit_gen:          u64,
	hit_assembled:    u64,
	hit_blob:         u64,
	hit_file:         u64,
	hit_sse:          u64,
	hit_metrics:      u64,
	stream_responses: u64,
}

g_m: Metrics

inc :: #force_inline proc(p: ^u64) {
	sync.atomic_add(p, u64(1))
}

// Count materialize flag + non-materialize op kinds (Writev/Sendfile/…).
record_plan_simple :: proc(r: http.Plan_Result) {
	inc(&g_m.plan_responses)
	if r.materialized {
		inc(&g_m.plan_materialize)
	}
	for i in 0 ..< r.op_count {
		switch r.ops[i].kind {
		case .Write_Slice:
			if !r.materialized {
				inc(&g_m.plan_other) // e.g. headers-only before Sendfile
			}
		case .Writev:
			inc(&g_m.plan_writev)
		case .Sendfile:
			inc(&g_m.plan_sendfile)
		case .Copy_Into:
			inc(&g_m.plan_copy_into)
		case .Patch_CL:
			inc(&g_m.plan_patch_cl)
		case .Flush:
			inc(&g_m.plan_flush)
		}
	}
}

// --- plan context from mode + profile ----------------------------------------

Handler_Profile :: struct {
	name:               string,
	prefer_materialize: bool,
	prefer_gather:      bool,
	prefer_sendfile:    bool,
	copy_budget:        u32, // 0 + prefer_gather → disable size-based copy
}

PROFILE_TINY :: Handler_Profile {
	name               = "tiny",
	prefer_materialize = true,
}
PROFILE_GEN :: Handler_Profile {
	name               = "gen",
	prefer_materialize = true,
}
PROFILE_ASSEMBLED :: Handler_Profile {
	name          = "assembled",
	prefer_gather = true,
	copy_budget   = 0,
}
PROFILE_BLOB :: Handler_Profile {
	name          = "blob",
	prefer_gather = true,
	copy_budget   = 0,
}
PROFILE_FILE :: Handler_Profile {
	name            = "file",
	prefer_sendfile = true,
	copy_budget     = 0,
}

plan_ctx_for :: proc(profile: Handler_Profile) -> http.Plan_Context {
	ctx := http.plan_context_default()
	ctx.max_iovecs = g_max_iovecs
	ctx.preferred_copy_budget = g_copy_budget
	ctx.sendfile_ok = g_sendfile_ok && profile.prefer_sendfile
	ctx.tls = false

	if profile.prefer_gather {
		ctx.preferred_copy_budget = profile.copy_budget
	}
	if profile.prefer_materialize {
		ctx.preferred_copy_budget = max(u32)
	}
	return ctx
}

run_shadow_plan :: proc(cmds: []http.Response_Cmd, profile: Handler_Profile) {
	r: http.Plan_Result
	if g_mode == .Materialize {
		r = http.plan_body_materialize_only(cmds)
	} else {
		r = http.plan_body(cmds, plan_ctx_for(profile))
	}
	record_plan_simple(r)
}

// --- routes ------------------------------------------------------------------

on_tiny :: proc(req: ^http.Request, res: ^http.Response) {
	inc(&g_m.hit_tiny)
	body := transmute([]u8)string("Hello, World!")
	cmds := []http.Response_Cmd{http.cmd_static(body)}
	run_shadow_plan(cmds, PROFILE_TINY)

	// prefer_materialize: even under plan_optimize, keep single-buffer path.
	http.response_set_profile(res, http.Handler_Profile{prefer_materialize = true})
	http.headers_set(&res.headers, "server", "proactr-plan")
	http.headers_set(&res.headers, "x-plan-profile", "tiny")
	http.respond_plain(res, "Hello, World!")
}

on_gen :: proc(req: ^http.Request, res: ^http.Response) {
	inc(&g_m.hit_gen)
	res.status = .OK
	slot := http.body_reserve(res, 256)
	n := copy(slot, transmute([]u8)string("generated:ok\n"))
	cmds := []http.Response_Cmd{http.cmd_bytes(slot[:n], true)}
	run_shadow_plan(cmds, PROFILE_GEN)
	inc(&g_m.plan_patch_cl) // body_reserve / CL patch lineage

	http.headers_set(&res.headers, "server", "proactr-plan")
	http.headers_set(&res.headers, "x-plan-profile", "gen")
	http.headers_set_content_type(&res.headers, "text/plain")
	http.body_commit(res, n)
	http.respond(res)
}

on_assembled :: proc(req: ^http.Request, res: ^http.Response) {
	inc(&g_m.hit_assembled)
	cmds: [SLICE_N]http.Response_Cmd
	for i in 0 ..< SLICE_N {
		cmds[i] = http.cmd_static(g_slices[i])
	}
	run_shadow_plan(cmds[:], PROFILE_ASSEMBLED)

	// Multi Static cmds always (proves multi-cmd path). prefer_gather only in
	// optimize mode so materialize A/B does not enable wire Writev via profile.
	if g_mode == .Optimize {
		http.response_set_profile(
			res,
			http.Handler_Profile{prefer_gather = true, copy_budget = 0},
		)
	}
	http.headers_set(&res.headers, "server", "proactr-plan")
	http.headers_set(&res.headers, "x-plan-profile", "assembled")
	http.headers_set(&res.headers, "x-plan-slices", "8")
	http.headers_set_content_type(&res.headers, "text/plain")
	res.status = .OK
	for i in 0 ..< SLICE_N {
		http.body_static(res, g_slices[i])
	}
	http.respond(res)
}

on_blob :: proc(req: ^http.Request, res: ^http.Response) {
	inc(&g_m.hit_blob)
	cmds := []http.Response_Cmd{http.cmd_static(g_blob_1m)}
	run_shadow_plan(cmds, PROFILE_BLOB)

	// Single large Static: optimize may Writev(heading+body) to avoid copy.
	if g_mode == .Optimize {
		http.response_set_profile(
			res,
			http.Handler_Profile{prefer_gather = true, copy_budget = 0},
		)
	}
	http.headers_set(&res.headers, "server", "proactr-plan")
	http.headers_set(&res.headers, "x-plan-profile", "blob")
	http.respond_plain(res, transmute(string)g_blob_1m)
}

on_file :: proc(req: ^http.Request, res: ^http.Response) {
	inc(&g_m.hit_file)
	// Intent is File region. Shadow plan always uses File cmd.
	// Optimize: body_file + prefer_sendfile → wire streams via chunked pread (Phase 4).
	// Materialize: preloaded bytes (same pattern as on-disk) so load does not
	// open/read entire file into the request temp arena per hit.
	cmds := []http.Response_Cmd{http.cmd_file(g_file_fd >= 0 ? g_file_fd : 3, 0, g_file_len)}
	run_shadow_plan(cmds, PROFILE_FILE)

	http.headers_set(&res.headers, "server", "proactr-plan")
	http.headers_set(&res.headers, "x-plan-profile", "file")
	res.status = .OK
	http.headers_set_content_type(&res.headers, "text/plain")

	if g_mode == .Optimize && g_file_fd >= 0 {
		http.response_set_profile(res, http.Handler_Profile{prefer_sendfile = true})
		http.headers_set(&res.headers, "x-plan-wire", "body_file")
		http.body_file(res, g_file_fd, 0, g_file_len)
		http.respond(res)
		return
	}

	http.headers_set(&res.headers, "x-plan-wire", "preloaded")
	http.respond_plain(res, transmute(string)g_file_wire)
}

on_sse :: proc(req: ^http.Request, res: ^http.Response) {
	inc(&g_m.hit_sse)
	inc(&g_m.stream_responses)
	// Phase 5: Response_Stream API — not plan_body / Response_Cmd.
	// One-shot events (bombardier-friendly); stream_flush is no-op; end sends once.
	res.status = .OK
	http.headers_set(&res.headers, "server", "proactr-plan")
	http.headers_set(&res.headers, "x-plan-profile", "sse")
	http.headers_set(&res.headers, "cache-control", "no-cache")
	http.headers_set_content_type(&res.headers, "text/event-stream")
	stream := http.response_begin_stream(res)
	http.stream_write(&stream, transmute([]u8)string("event: ping\ndata: 1\n\n"))
	http.stream_write(&stream, transmute([]u8)string("event: ping\ndata: 2\n\n"))
	http.stream_flush(&stream)
	http.stream_end(&stream) // final 0-chunk + respond; increments http.stream_responses_total
}

on_metrics :: proc(req: ^http.Request, res: ^http.Response) {
	inc(&g_m.hit_metrics)
	b: strings.Builder
	strings.builder_init(&b, context.temp_allocator)

	mode_s := g_mode == .Optimize ? "optimize" : "materialize"
	fmt.sbprintf(&b, "# proactr plan A/B metrics\n")
	wire_multi, wire_mat := http.plan_wire_load()
	wire_sf, wire_ci := http.plan_wire_load_file()

	fmt.sbprintf(&b, "plan_mode %s\n", mode_s)
	fmt.sbprintf(&b, "plan_sendfile_ok %v\n", g_sendfile_ok)
	fmt.sbprintf(&b, "plan_copy_budget %d\n", g_copy_budget)
	fmt.sbprintf(&b, "plan_max_iovecs %d\n", g_max_iovecs)
	fmt.sbprintf(&b, "plan_responses_total %d\n", sync.atomic_load(&g_m.plan_responses))
	fmt.sbprintf(&b, "plan_materialize_total %d\n", sync.atomic_load(&g_m.plan_materialize))
	fmt.sbprintf(&b, "plan_writev_total %d\n", sync.atomic_load(&g_m.plan_writev))
	fmt.sbprintf(&b, "plan_sendfile_total %d\n", sync.atomic_load(&g_m.plan_sendfile))
	fmt.sbprintf(&b, "plan_copy_into_total %d\n", sync.atomic_load(&g_m.plan_copy_into))
	fmt.sbprintf(&b, "plan_patch_cl_total %d\n", sync.atomic_load(&g_m.plan_patch_cl))
	fmt.sbprintf(&b, "plan_flush_total %d\n", sync.atomic_load(&g_m.plan_flush))
	fmt.sbprintf(&b, "plan_other_total %d\n", sync.atomic_load(&g_m.plan_other))
	// Phase 3–4 real wire executor counters (package http).
	fmt.sbprintf(&b, "plan_wire_multi_send_total %d\n", wire_multi)
	fmt.sbprintf(&b, "plan_wire_kernel_writev_total %d\n", http.plan_wire_load_kernel_writev())
	fmt.sbprintf(&b, "plan_wire_materialize_total %d\n", wire_mat)
	fmt.sbprintf(&b, "plan_wire_sendfile_total %d\n", wire_sf)
	fmt.sbprintf(&b, "plan_wire_copy_into_total %d\n", wire_ci)
	// Harness-local + package stream counter (Phase 5 stream_end).
	fmt.sbprintf(&b, "stream_responses_total %d\n", sync.atomic_load(&g_m.stream_responses))
	fmt.sbprintf(&b, "http_stream_responses_total %d\n", http.stream_responses_load())
	// Escape {{ }} — core:fmt treats bare { as a format verb.
	fmt.sbprintf(&b, "route_hits{{route=\"tiny\"}} %d\n", sync.atomic_load(&g_m.hit_tiny))
	fmt.sbprintf(&b, "route_hits{{route=\"gen\"}} %d\n", sync.atomic_load(&g_m.hit_gen))
	fmt.sbprintf(&b, "route_hits{{route=\"assembled\"}} %d\n", sync.atomic_load(&g_m.hit_assembled))
	fmt.sbprintf(&b, "route_hits{{route=\"blob\"}} %d\n", sync.atomic_load(&g_m.hit_blob))
	fmt.sbprintf(&b, "route_hits{{route=\"file\"}} %d\n", sync.atomic_load(&g_m.hit_file))
	fmt.sbprintf(&b, "route_hits{{route=\"sse\"}} %d\n", sync.atomic_load(&g_m.hit_sse))

	http.headers_set(&res.headers, "server", "proactr-plan")
	http.headers_set_content_type(&res.headers, "text/plain; version=0.0.4")
	http.respond_plain(res, strings.to_string(b))
}

on_health :: proc(req: ^http.Request, res: ^http.Response) {
	http.respond_plain(res, "ok")
}

// --- init helpers ------------------------------------------------------------

make_pattern_buf :: proc(n: int) -> []u8 {
	pat := transmute([]u8)string("0123456789abcdef0123456789ABCDEF")
	buf := make([]u8, n)
	for i in 0 ..< n {
		buf[i] = pat[i % len(pat)]
	}
	return buf
}

ensure_file_payload :: proc(path: string, n: int) -> bool {
	data := make_pattern_buf(n)
	defer delete(data)
	if err := os.write_entire_file(path, data); err != nil {
		log.errorf("write_entire_file %s: %v", path, err)
		return false
	}
	return true
}

parse_mode :: proc(s: string) -> Plan_Mode {
	switch strings.to_lower(s, context.temp_allocator) {
	case "optimize", "opt", "on", "1":
		return .Optimize
	case:
		return .Materialize
	}
}

main :: proc() {
	context.logger = log.create_console_logger(.Info)

	port := 19090
	if p := os.get_env_alloc("PORT", context.allocator); p != "" {
		if v, ok := strconv.parse_int(p); ok {
			port = v
		}
		delete(p)
	}
	workers := 1
	if p := os.get_env_alloc("WORKERS", context.allocator); p != "" {
		if v, ok := strconv.parse_int(p); ok {
			workers = max(1, v)
		}
		delete(p)
	}

	g_mode = .Materialize
	if p := os.get_env_alloc("PLAN_MODE", context.allocator); p != "" {
		g_mode = parse_mode(p)
		delete(p)
	}

	g_sendfile_ok = true
	if p := os.get_env_alloc("PLAN_SENDFILE_OK", context.allocator); p != "" {
		g_sendfile_ok = p == "1" || p == "true" || p == "yes"
		delete(p)
	}

	g_copy_budget = http.PLAN_DEFAULT_COPY_BUDGET
	if p := os.get_env_alloc("PLAN_COPY_BUDGET", context.allocator); p != "" {
		if v, ok := strconv.parse_u64(p); ok {
			g_copy_budget = u32(v)
		}
		delete(p)
	}

	g_max_iovecs = http.PLAN_DEFAULT_MAX_IOVECS
	if p := os.get_env_alloc("PLAN_MAX_IOVECS", context.allocator); p != "" {
		if v, ok := strconv.parse_int(p); ok && v > 0 {
			g_max_iovecs = u16(min(v, int(max(u16))))
		}
		delete(p)
	}

	data_dir := "/tmp/proactr-plan-bench"
	if p := os.get_env_alloc("PLAN_DATA_DIR", context.allocator); p != "" {
		data_dir = strings.clone(p)
		delete(p)
	}
	_ = os.make_directory_all(data_dir)

	for i in 0 ..< SLICE_N {
		g_slices[i] = make_pattern_buf(SLICE_SIZE)
		g_slices[i][0] = u8('A' + i)
	}
	g_assembled_flat = make([]u8, SLICE_N * SLICE_SIZE)
	for i in 0 ..< SLICE_N {
		copy(g_assembled_flat[i * SLICE_SIZE:][:SLICE_SIZE], g_slices[i])
	}
	g_blob_1m = make_pattern_buf(BLOB_1M_SIZE)

	g_file_path = fmt.aprintf("%s/file-1m.bin", data_dir)
	if p := os.get_env_alloc("PLAN_FILE_PATH", context.allocator); p != "" {
		delete(g_file_path)
		g_file_path = strings.clone(p)
		delete(p)
	}
	if !ensure_file_payload(g_file_path, FILE_1M_SIZE) {
		os.exit(1)
	}
	g_file_len = i64(FILE_1M_SIZE)
	// Same pattern as on-disk file for materialize-mode wire path under load.
	g_file_wire = make_pattern_buf(FILE_1M_SIZE)
	// Keep one open fd for body_file (Phase 4 optimize path). Process lifetime.
	// Do not close until process exit — concurrent requests borrow this fd via pread.
	{
		f, err := os.open(g_file_path)
		if err != nil {
			log.errorf("open file payload %s: %v", g_file_path, err)
			os.exit(1)
		}
		g_file_fd = i32(os.fd(f))
		if g_file_fd < 0 {
			log.errorf("invalid fd for %s", g_file_path)
			os.exit(1)
		}
	}

	router: http.Router
	http.router_init(&router)
	defer http.router_destroy(&router)

	http.route_get(&router, "/health", http.handler(on_health))
	http.route_get(&router, "/metrics", http.handler(on_metrics))
	http.route_get(&router, "/api/tiny", http.handler(on_tiny))
	http.route_get(&router, "/gen/ok", http.handler(on_gen))
	http.route_get(&router, "/static/assembled", http.handler(on_assembled))
	http.route_get(&router, "/static/blob/1m", http.handler(on_blob))
	http.route_get(&router, "/file/1m", http.handler(on_file))
	http.route_get(&router, "/sse", http.handler(on_sse))
	http.route_get(&router, "/plaintext", http.handler(on_tiny))

	s: http.Server
	http.server_shutdown_on_interrupt(&s)
	opts := http.Default_Server_Opts
	opts.thread_count = workers
	// Phase 3: optimize mode enables real multi-buffer Writev-style wire path.
	// Profiles on routes further bias plan_body (prefer_gather / prefer_materialize).
	opts.plan_optimize = g_mode == .Optimize
	opts.plan_copy_budget = g_copy_budget
	opts.plan_max_iovecs = g_max_iovecs
	opts.plan_sendfile_ok = g_sendfile_ok

	mode_s := g_mode == .Optimize ? "optimize" : "materialize"
	log.infof(
		"proactr plan bench :%d workers=%d PLAN_MODE=%s plan_optimize=%v sendfile_ok=%v copy_budget=%d max_iovecs=%d file=%s",
		port,
		workers,
		mode_s,
		opts.plan_optimize,
		g_sendfile_ok,
		g_copy_budget,
		g_max_iovecs,
		g_file_path,
	)

	err := http.listen_and_serve(
		&s,
		http.router_handler(&router),
		net.Endpoint{address = net.IP4_Address{0, 0, 0, 0}, port = port},
		opts,
	)
	fmt.eprintf("server exited: %v\n", err)
	if err == .Unsupported {
		os.exit(2)
	}
}
