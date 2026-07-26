// TechEmpower Fortunes — two execution models for bastion comparison.
//
// Hot path: one SQL pass (`ORDER BY message`) → write HTML while stepping.
// No Fortune[] materialization, no message clones, no app-side sort.
// sqlite3_column_text is only used between step() calls.
//
//   FORTUNES_MODE=sync  (default): stream on the I/O worker.
//     Default: one SQLite connection per I/O worker (thread_local).
//     FORTUNES_SYNC_SHARED=1: one shared conn + mutex around the stream.
//
//   FORTUNES_MODE=async: offload stream to a thread pool.
//
// Profile: odin build -define:FORTUNES_PROFILE=true
package main

import "core:c"
import "core:log"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

import http "../../../http"

// Runtime row (TE). Lex place among ORDER BY message rows.
ADDITIONAL_FORTUNE :: "Additional fortune added at request time."

HTML_HEAD :: "<!DOCTYPE html><html><head><title>Fortunes</title></head><body><table><tr><th>id</th><th>message</th></tr>"
HTML_TAIL :: "</table></body></html>"
ROW_OPEN :: "<tr><td>"
ROW_MID :: "</td><td>"
ROW_CLOSE :: "</td></tr>"

SQL_FORTUNES :: "SELECT id, message FROM fortune ORDER BY message"

// ~1.2 KiB typical body; 4 KiB is comfortable headroom for escape expansion.
HTML_SCRATCH_CAP :: 4096

Fortunes_Mode :: enum {
	Sync,
	Async,
}

Db_Conn :: struct {
	db:   ^sqlite3_t,
	stmt: ^sqlite3_stmt,
}

g_mode:        Fortunes_Mode
g_db_path:     string
g_sync_shared: bool

g_shared: Db_Conn
g_db_mu:  sync.Mutex

@(thread_local)
tls_db: Db_Conn

// Build HTML here; body_set still copies into the connection wire buffer once.
@(thread_local)
html_scratch: [HTML_SCRATCH_CAP]byte

g_pool:         thread.Pool
g_pool_started: bool
g_worker_n:     int

Ready_Queue :: struct {
	mu:   sync.Mutex,
	jobs: [dynamic]^Fortune_Job,
}

g_ready: []Ready_Queue

Fortune_Job :: struct {
	res:        ^http.Response,
	worker_idx: int,
	html:       string, // heap; for async handoff only
	ok:         bool,
}

db_open_conn :: proc(path: string) -> (conn: Db_Conn, ok: bool) {
	path_c := strings.clone_to_cstring(path, context.temp_allocator)
	flags := c.int(SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX)
	rc := sqlite3_open_v2(path_c, &conn.db, flags, nil)
	if rc != SQLITE_OK || conn.db == nil {
		msg: cstring = "unknown"
		if conn.db != nil {
			msg = sqlite3_errmsg(conn.db)
		}
		log.errorf("sqlite open %s: rc=%d %s (run schema/prepare.sh)", path, rc, msg)
		return {}, false
	}
	sqlite3_busy_timeout(conn.db, 5000)
	_ = sqlite3_exec(
		conn.db,
		"PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA temp_store=MEMORY; PRAGMA cache_size=-65536; PRAGMA mmap_size=268435456; PRAGMA query_only=ON;",
		nil,
		nil,
		nil,
	)
	rc = sqlite3_prepare_v2(conn.db, SQL_FORTUNES, -1, &conn.stmt, nil)
	if rc != SQLITE_OK || conn.stmt == nil {
		log.errorf("sqlite prepare: %s", sqlite3_errmsg(conn.db))
		sqlite3_close(conn.db)
		return {}, false
	}
	return conn, true
}

db_close_conn :: proc(conn: ^Db_Conn) {
	if conn.stmt != nil {
		sqlite3_finalize(conn.stmt)
		conn.stmt = nil
	}
	if conn.db != nil {
		sqlite3_close(conn.db)
		conn.db = nil
	}
}

sync_conn_get :: proc() -> (conn: ^Db_Conn, ok: bool) {
	if g_sync_shared {
		return &g_shared, g_shared.db != nil
	}
	if tls_db.db == nil {
		c, cok := db_open_conn(g_db_path)
		if !cok {
			return nil, false
		}
		tls_db = c
	}
	return &tls_db, true
}

db_init_sync :: proc(path: string, shared: bool) -> bool {
	g_db_path = path
	g_sync_shared = shared
	if shared {
		c, ok := db_open_conn(path)
		if !ok {
			return false
		}
		g_shared = c
		log.info("fortunes sync: shared connection + mutex (single-pass stream)")
	} else {
		log.info("fortunes sync: per-I/O-worker connection (single-pass stream)")
	}
	return true
}

db_close_sync :: proc() {
	if g_sync_shared {
		db_close_conn(&g_shared)
	}
}

pool_thread_init :: proc(t: ^thread.Thread, user_data: rawptr) {
	_ = t
	_ = user_data
	c, ok := db_open_conn(g_db_path)
	if !ok {
		log.error("async pool thread: sqlite open failed")
		tls_db = {}
		return
	}
	tls_db = c
}

pool_thread_fini :: proc(t: ^thread.Thread, user_data: rawptr) {
	_ = t
	_ = user_data
	db_close_conn(&tls_db)
}

db_init_async :: proc(path: string, io_workers: int, db_workers: int) -> bool {
	g_db_path = path
	g_sync_shared = false
	g_worker_n = max(1, io_workers)
	g_ready = make([]Ready_Queue, g_worker_n)
	for i in 0 ..< g_worker_n {
		g_ready[i].jobs = make([dynamic]^Fortune_Job, 0, 64)
	}
	nw := max(1, db_workers)
	thread.pool_init(
		&g_pool,
		context.allocator,
		nw,
		pool_thread_init,
		nil,
		pool_thread_fini,
		nil,
	)
	thread.pool_start(&g_pool)
	g_pool_started = true
	log.infof("fortunes async: db_workers=%d io_workers=%d", nw, g_worker_n)
	return true
}

db_close_async :: proc() {
	if g_pool_started {
		thread.pool_join(&g_pool)
		thread.pool_destroy(&g_pool)
		g_pool_started = false
	}
	if g_ready != nil {
		for i in 0 ..< len(g_ready) {
			delete(g_ready[i].jobs)
		}
		delete(g_ready)
		g_ready = nil
	}
}

fortunes_init :: proc(
	mode: Fortunes_Mode,
	path: string,
	io_workers: int,
	db_workers: int,
	sync_shared: bool,
) -> bool {
	g_mode = mode
	switch mode {
	case .Sync:
		return db_init_sync(path, sync_shared)
	case .Async:
		return db_init_async(path, io_workers, db_workers)
	}
	return false
}

fortunes_shutdown :: proc() {
	switch g_mode {
	case .Sync:
		db_close_sync()
	case .Async:
		db_close_async()
	}
}

// --- single-pass HTML stream -------------------------------------------------

html_escape_write :: proc(b: ^strings.Builder, s: string) {
	// Copy runs of non-special bytes; expand only & < > " '
	i := 0
	n := len(s)
	for i < n {
		c := s[i]
		switch c {
		case '&':
			strings.write_string(b, "&amp;")
			i += 1
		case '<':
			strings.write_string(b, "&lt;")
			i += 1
		case '>':
			strings.write_string(b, "&gt;")
			i += 1
		case '"':
			strings.write_string(b, "&quot;")
			i += 1
		case '\'':
			strings.write_string(b, "&#39;")
			i += 1
		case:
			j := i + 1
			for j < n {
				d := s[j]
				if d == '&' || d == '<' || d == '>' || d == '"' || d == '\'' {
					break
				}
				j += 1
			}
			strings.write_bytes(b, transmute([]byte)s[i:j])
			i = j
		}
	}
}

write_fortune_row :: #force_inline proc(b: ^strings.Builder, id: i32, message: string) {
	id_buf: [16]byte
	strings.write_string(b, ROW_OPEN)
	strings.write_string(b, strconv.write_int(id_buf[:], i64(id), 10))
	strings.write_string(b, ROW_MID)
	html_escape_write(b, message)
	strings.write_string(b, ROW_CLOSE)
}

// Zero-copy view of sqlite TEXT (valid until next step/reset/finalize).
column_text_view :: #force_inline proc(stmt: ^sqlite3_stmt, col: c.int) -> string {
	p := sqlite3_column_text(stmt, col)
	if p == nil {
		return ""
	}
	n := int(sqlite3_column_bytes(stmt, col))
	if n <= 0 {
		return ""
	}
	return strings.string_from_ptr((^byte)(rawptr(p)), n)
}

// Stream ORDER BY message rows into `out`. Returns byte length written (not a string view).
fortunes_stream_html :: proc(conn: ^Db_Conn, out: []byte) -> (n: int, ok: bool) {
	if conn == nil || conn.db == nil || conn.stmt == nil || len(out) < 512 {
		return 0, false
	}

	b := strings.builder_from_bytes(out)
	_ = sqlite3_reset(conn.stmt)

	strings.write_string(&b, HTML_HEAD)
	emitted_additional := false

	for sqlite3_step(conn.stmt) == SQLITE_ROW {
		id := i32(sqlite3_column_int(conn.stmt, 0))
		msg := column_text_view(conn.stmt, 1)

		// Insert TE runtime row in sorted order (matches ntex / TE).
		if !emitted_additional && msg >= ADDITIONAL_FORTUNE {
			write_fortune_row(&b, 0, ADDITIONAL_FORTUNE)
			emitted_additional = true
		}
		write_fortune_row(&b, id, msg)

		// Cap check: builder_from_bytes uses nil allocator — writes past cap are unsafe.
		if strings.builder_len(b) > len(out) - 64 {
			return 0, false
		}
	}
	if !emitted_additional {
		write_fortune_row(&b, 0, ADDITIONAL_FORTUNE)
	}
	strings.write_string(&b, HTML_TAIL)

	n = strings.builder_len(b)
	if n > len(out) {
		return 0, false
	}
	return n, true
}

// Microbench / async: stream into thread-local scratch, return string view of scratch.
fortunes_html_from_conn :: proc(conn: ^Db_Conn) -> (html: string, ok: bool) {
	n: int
	n, ok = fortunes_stream_html(conn, html_scratch[:])
	if !ok {
		return "", false
	}
	return string(html_scratch[:n]), true
}

// Stream into body_reserve slot under optional shared mutex.
fortunes_fill_body :: proc(out: []byte) -> (
	n: int,
	ok: bool,
	lock_c, query_c: u64,
	lock_ns, query_ns: u64,
) {
	if g_sync_shared {
		t_lock0 := prof_now()
		c_lock0 := prof_cyc()
		sync.mutex_lock(&g_db_mu)
		lock_c = prof_cyc() - c_lock0
		lock_ns = u64(prof_now() - t_lock0)

		t_q0 := prof_now()
		c_q0 := prof_cyc()
		n, ok = fortunes_stream_html(&g_shared, out)
		query_c = prof_cyc() - c_q0
		query_ns = u64(prof_now() - t_q0)

		sync.mutex_unlock(&g_db_mu)
		return
	}

	conn, cok := sync_conn_get()
	if !cok {
		return 0, false, 0, 0, 0, 0
	}
	t_q0 := prof_now()
	c_q0 := prof_cyc()
	n, ok = fortunes_stream_html(conn, out)
	query_c = prof_cyc() - c_q0
	query_ns = u64(prof_now() - t_q0)
	return
}

// --- async -------------------------------------------------------------------

fortune_task :: proc(task: thread.Task) {
	job := cast(^Fortune_Job)task.data
	context.allocator = task.allocator

	html, ok := fortunes_html_from_conn(&tls_db)
	if ok {
		// Own across threads until the I/O worker responds.
		job.html = strings.clone(html, context.allocator)
		job.ok = true
	} else {
		job.ok = false
	}

	idx := job.worker_idx
	if idx < 0 || idx >= len(g_ready) {
		if job.ok {
			delete(job.html)
		}
		free(job)
		return
	}
	sync.mutex_lock(&g_ready[idx].mu)
	append(&g_ready[idx].jobs, job)
	sync.mutex_unlock(&g_ready[idx].mu)
}

fortunes_worker_tick :: proc(user: rawptr) {
	_ = user
	idx := http.server_worker_index()
	if idx < 0 || idx >= len(g_ready) {
		return
	}

	batch: [dynamic]^Fortune_Job
	sync.mutex_lock(&g_ready[idx].mu)
	if len(g_ready[idx].jobs) == 0 {
		sync.mutex_unlock(&g_ready[idx].mu)
		return
	}
	batch = g_ready[idx].jobs
	g_ready[idx].jobs = make([dynamic]^Fortune_Job, 0, 64)
	sync.mutex_unlock(&g_ready[idx].mu)

	for job in batch {
		res := job.res
		http.headers_set(&res.headers, "server", "Proactr")
		if !job.ok {
			http.respond(res, http.Status.Internal_Server_Error)
		} else {
			res.status = .OK
			http.headers_set_content_type(&res.headers, "text/html; charset=utf-8")
			http.body_set(res, job.html)
			http.respond(res)
			delete(job.html)
		}
		free(job)
	}
	delete(batch)
}

// --- handlers ----------------------------------------------------------------

on_fortunes :: proc(req: ^http.Request, res: ^http.Response) {
	_ = req
	switch g_mode {
	case .Sync:
		on_fortunes_sync(res)
	case .Async:
		on_fortunes_async(res)
	}
}

on_fortunes_sync :: proc(res: ^http.Response) {
	t_tot0 := prof_now()
	c_tot0 := prof_cyc()

	http.headers_set(&res.headers, "server", "Proactr")
	res.status = .OK
	http.headers_set_content_type(&res.headers, "text/html; charset=utf-8")

	// Write HTML directly into the connection wire buffer (no scratch→body copy).
	slot := http.body_reserve(res, HTML_SCRATCH_CAP)

	t_q0 := prof_now()
	c_q0 := prof_cyc()
	n, ok, lock_c, query_c, lock_ns, query_ns := fortunes_fill_body(slot)
	_ = t_q0
	_ = c_q0
	if !ok {
		http.body_cancel(res)
		http.respond(res, http.Status.Internal_Server_Error)
		return
	}

	t_r0 := prof_now()
	c_r0 := prof_cyc()
	http.body_commit(res, n)
	http.respond(res)
	respond_c := prof_cyc() - c_r0
	respond_ns := u64(prof_now() - t_r0)

	// stream work is in query_*; sort/html folded into stream (0).
	total_c := prof_cyc() - c_tot0
	total_ns := u64(prof_now() - t_tot0)
	prof_add(
		lock_c,
		query_c,
		0,
		0,
		respond_c,
		total_c,
		lock_ns,
		query_ns,
		0,
		0,
		respond_ns,
		total_ns,
	)
}

on_fortunes_async :: proc(res: ^http.Response) {
	widx := http.server_worker_index()
	if widx < 0 || !g_pool_started {
		http.headers_set(&res.headers, "server", "Proactr")
		http.respond(res, http.Status.Internal_Server_Error)
		return
	}
	job := new(Fortune_Job)
	job.res = res
	job.worker_idx = widx
	thread.pool_add_task(&g_pool, context.allocator, fortune_task, job, 0)
}

// CPU microbench: stream only (no HTTP). Env FORTUNES_MICROBENCH=N.
fortunes_microbench :: proc(n: int) {
	if n <= 0 {
		return
	}
	conn, ok := sync_conn_get()
	if !ok && g_sync_shared {
		conn = &g_shared
		ok = g_shared.db != nil
	}
	if !ok {
		log.error("microbench: no db")
		return
	}
	for _ in 0 ..< 1000 {
		_, _ = fortunes_html_from_conn(conn)
	}
	t0 := time.tick_now()
	for _ in 0 ..< n {
		_, _ = fortunes_html_from_conn(conn)
	}
	elapsed := time.tick_since(t0)
	ns := time.duration_nanoseconds(elapsed)
	log.infof(
		"fortunes_microbench n=%d elapsed_ms=%.2f avg_ns=%.0f serial_rps≈%.0f",
		n,
		f64(ns) / 1e6,
		f64(ns) / f64(n),
		1e9 * f64(n) / f64(ns),
	)
}
