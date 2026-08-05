// Server host surface forked from laytan/odin-http.
// proactr completion host: io_uring (Linux), kqueue (Darwin/BSD), IOCP (Windows ring; HTTP host POSIX/Linux).
// Hardening: SO_REUSEPORT per-worker listen, multishot accept, fixed files/bufs, conn slab.
package http

import "core:bufio"
import "core:bytes"
import "core:c"
import "core:log"
import "core:mem"
import "core:mem/virtual"
import "core:net"
import "core:slice"
import "core:sync"
import "core:sys/posix"
import "core:thread"
import "core:time"

import proactr "../proactr"

Server_Opts :: struct {
	// Whether the server should accept every request that sends a "Expect: 100-continue" header automatically.
	// Defaults to true.
	auto_expect_continue: bool,
	// When this is true, any HEAD request is automatically redirected to the handler as a GET request.
	// Then, when the response is sent, the body is removed from the response.
	// Defaults to true.
	redirect_head_to_get: bool,
	// Limit the maximum number of bytes to read for the request line (first line of request containing the URI).
	// defaults to 8000.
	limit_request_line:   int,
	// Limit the length of the headers.
	// defaults to 8000.
	limit_headers:        int,
	// Worker thread count. 0 → 1 (v1 default). Each worker owns a proactr.Ring.
	thread_count:         int,
	// Bytes per connection temp slot (buffer arena). 0 → HOST_REQ_TEMP_BYTES (~4.5 MiB).
	temp_slot_bytes:      int,
	// Max concurrent temp slots per worker for the growable pool.
	// 0 → HOST_TEMP_SLOTS_MAX_DEFAULT (256); <0 → unlimited; >0 → hard cap.
	// Pool starts empty and grows in temp_chunk_slots quanta (no multi‑GiB prealloc).
	temp_slots_max:       int,
	// Slots allocated each time the temp pool grows. 0 → HOST_TEMP_CHUNK_SLOTS (8).
	temp_chunk_slots:     int,
	// Initial capacity of permanent Connection.resp_buf (response wire bytes).
	// 0 → HOST_RESP_BUF_INITIAL (1 MiB + 4 KiB). Grows on demand; capacity retained.
	resp_buf_initial:     int,
	// Scanner / RECV window size in bytes. 0 → HOST_RECV_SIZE (16 KiB).
	// Also used as registered-buffer element size when reg_buf_count > 0.
	recv_buf_size:        int,
	// Registered RECV buffer pool count per worker. 0 → DEFAULT_REG_BUF_COUNT (1024).
	// Registration is best-effort; failure falls back to dynamic scanners.
	reg_buf_count:        int,
	// io_uring / ring entries per worker. 0 → HOST_RING_ENTRIES (1024).
	ring_entries:         int,
	// Max CQEs harvested per ring_wait. 0 → HOST_CQE_BATCH (64).
	cqe_batch:            int,
	// ring_wait timeout so workers can observe server.closing. 0 → HOST_WAIT_TIMEOUT_MS (500).
	wait_timeout_ms:      int,
	// Listen backlog per worker. 0 → HOST_LISTEN_BACKLOG (1024).
	listen_backlog:       int,
	// Connection slab grow quantum (records per chunk). 0 → CONN_CHUNK_SIZE (64).
	conn_chunk_size:      int,
	// Optional per-worker tick after each CQE batch (deferred work, async handlers).
	// Runs on the worker thread with thread-local host state set (safe to respond).
	on_worker_tick:       proc(user: rawptr),
	worker_tick_user:     rawptr,
	// Plan_Context knobs (Phase 2+). Used by plan_context / response_plan_preview and the
	// Phase 3–4 wire executor (kernel WRITEV/sendfile on Linux; multi_send/copy_into fallback).
	// preferred_copy_budget: 0 → PLAN_DEFAULT_COPY_BUDGET (4096).
	plan_copy_budget:     u32,
	// max_iovecs gather budget: 0 → PLAN_DEFAULT_MAX_IOVECS (1024).
	plan_max_iovecs:      u16,
	// Allow sendfile in optimize plan when platform supports it (Linux/Darwin plain TCP).
	// Default true in Default_Server_Opts. Ignored / false on non-posix platforms.
	// Phase 4: Linux prefers sendfile(2); else chunked pread+send (not full materialize).
	plan_sendfile_ok:     bool,
	// When true, response_send may run plan_body and execute Writev / Sendfile wire paths.
	// Default false: materialize-only (zero profile / no surprise). Harness sets true for
	// PLAN_MODE=optimize. Also enabled per-request when Response profile has prefer_gather
	// or prefer_sendfile. PLAN_WIRE_MODE=fallback forces multi_send/copy_into on Linux.
	plan_optimize:        bool,
}

// Zero-valued sizing fields mean “use host product defaults” (resolved in listen).
Default_Server_Opts := Server_Opts {
	auto_expect_continue = true,
	redirect_head_to_get = true,
	limit_request_line   = 8000,
	limit_headers        = 8000,
	thread_count         = 0,
	temp_slot_bytes      = 0,
	temp_slots_max       = 0,
	temp_chunk_slots     = 0,
	resp_buf_initial     = 0,
	recv_buf_size        = 0,
	reg_buf_count        = 0,
	ring_entries         = 0,
	cqe_batch            = 0,
	wait_timeout_ms      = 0,
	listen_backlog       = 0,
	conn_chunk_size      = 0,
	plan_copy_budget     = 0, // → PLAN_DEFAULT_COPY_BUDGET at plan_context fill
	plan_max_iovecs      = 0, // → PLAN_DEFAULT_MAX_IOVECS at plan_context fill
	plan_sendfile_ok     = true,
	plan_optimize        = false, // opt-in: Writev/Sendfile wire (kernel or fallback)
}

Server_State :: enum {
	Uninitialized,
	Idle,
	Listening,
	Serving,
	Running,
	Closing,
	Cleaning,
	Closed,
}

Server :: struct {
	opts:           Server_Opts,
	// Legacy field kept for API familiarity; always zero under REUSEPORT (workers own listen fds).
	// Do not close: worker listen lifetime is solely via Server_Thread.listen_fd + server_close_listen.
	tcp_sock:       net.TCP_Socket,
	// Endpoint to bind; each worker creates its own SO_REUSEPORT listen socket.
	endpoint:       net.Endpoint,
	conn_allocator: mem.Allocator,
	handler:        Handler,

	threads:        []Server_Thread,
	// Once the server starts closing/shutdown this is set to true.
	closing:        Atomic(bool),
	// Ensures listen fds are closed exactly once (shutdown or serve teardown).
	listen_closed:  Atomic(bool),
	// Threads will decrement the wait group when they have fully closed/shutdown.
	threads_closed: sync.Wait_Group,
}

// Thread-local host state: one proactr ring per worker.
Server_Thread :: struct {
	thread:      ^thread.Thread,
	server:      ^Server,
	// Index into Server.threads (set at serve start).
	index:       int,
	ring:        proactr.Ring,
	conns:       map[net.TCP_Socket]^Connection,
	state:       Server_State,
	// Per-worker SO_REUSEPORT listen socket.
	listen_fd:          net.TCP_Socket,
	// True when listen_fd is installed in fixed file slot 0 (use FIXED_FILE for accept).
	listen_fixed:       bool,
	// True while an accept SQE is outstanding on this worker's ring.
	accept_pending:     bool,
	// Prefer multishot accept; fall back to single-shot if unsupported.
	accept_multishot:   bool,
	// Set when submit_accept fails so the host loop retries arming (never leave accept unarmed).
	needs_accept_rearm: bool,
	// Per-worker Date header (avoids multi-worker races on a shared buffer).
	date:               Server_Date,
	date_updated:       time.Time,
	// Conn slab free list (no hot-path malloc after warm-up).
	conn_free:          [dynamic]^Connection,
	conn_chunks:        [dynamic][]Connection,
	// Growable temp slot pool: owned chunks, region views, free indices (see conn_slab.odin).
	temp_chunks:        [dynamic][]u8,
	temp_regions:       [dynamic][]u8,
	temp_free:          [dynamic]int,
	temp_slot_size:     int,
	// Max slots for this worker; 0 means unlimited growth.
	temp_slots_max:     int,
}

@(private, disabled = ODIN_DISABLE_ASSERT)
assert_has_td :: #force_inline proc(loc := #caller_location) {
	assert(td != nil && td.state != .Uninitialized, "not on a server worker thread", loc)
}

// server_worker_index returns this thread's index in Server.threads, or -1 off-worker.
server_worker_index :: proc() -> int {
	if td == nil || td.state == .Uninitialized {
		return -1
	}
	return td.index
}

@(thread_local)
td: ^Server_Thread

Default_Endpoint := net.Endpoint {
	address = net.IP4_Any,
	port    = 8080,
}

// Product defaults for Server_Opts sizing fields (used when the corresponding opt is 0).
// After listen(), s.opts holds resolved concrete values (except temp_slots_max < 0 = unlimited).

// How many CQEs to harvest per wait (default for cqe_batch).
@(private)
HOST_CQE_BATCH :: 64

// io_uring entries per worker ring (default for ring_entries).
@(private)
HOST_RING_ENTRIES :: 1024

// Poll interval while waiting so workers can observe server.closing (default for wait_timeout_ms).
@(private)
HOST_WAIT_TIMEOUT_MS :: 500

// Conn slab chunk size (default for conn_chunk_size).
@(private)
CONN_CHUNK_SIZE :: 64

// Scanner / recv window size (default for recv_buf_size; matches proactr DEFAULT_RECV_BUF_SIZE).
@(private)
HOST_RECV_SIZE :: proactr.DEFAULT_RECV_BUF_SIZE

// Listen backlog per worker (default for listen_backlog).
@(private)
HOST_LISTEN_BACKLOG :: 1024

// Per-connection request scrap temp region (default for temp_slot_bytes).
// Headers/parse only — response wire bytes live in Connection.resp_buf.
// Sized generously for request scrap + embedded virtual.Memory_Block header
// used by arena_init_buffer; not sized for large response bodies.
@(private)
HOST_REQ_TEMP_BYTES :: 4 * 1024 * 1024 + 512 * 1024

// server_opts_resolve fills 0-valued sizing fields with product defaults.
// Call once from listen so the rest of the host can use s.opts without 0-checks.
// temp_slots_max: 0 → default soft cap; <0 left negative (unlimited); >0 kept.
@(private)
server_opts_resolve :: proc(opts: ^Server_Opts) {
	if opts.thread_count <= 0 {
		opts.thread_count = 1
	}
	if opts.temp_slot_bytes <= 0 {
		opts.temp_slot_bytes = HOST_REQ_TEMP_BYTES
	}
	if opts.temp_slots_max == 0 {
		opts.temp_slots_max = HOST_TEMP_SLOTS_MAX_DEFAULT
	}
	if opts.temp_chunk_slots <= 0 {
		opts.temp_chunk_slots = HOST_TEMP_CHUNK_SLOTS
	}
	if opts.resp_buf_initial <= 0 {
		opts.resp_buf_initial = HOST_RESP_BUF_INITIAL
	}
	if opts.recv_buf_size <= 0 {
		opts.recv_buf_size = HOST_RECV_SIZE
	}
	if opts.reg_buf_count <= 0 {
		opts.reg_buf_count = int(proactr.DEFAULT_REG_BUF_COUNT)
	}
	if opts.ring_entries <= 0 {
		opts.ring_entries = HOST_RING_ENTRIES
	}
	if opts.cqe_batch <= 0 {
		opts.cqe_batch = HOST_CQE_BATCH
	}
	if opts.wait_timeout_ms <= 0 {
		opts.wait_timeout_ms = HOST_WAIT_TIMEOUT_MS
	}
	if opts.listen_backlog <= 0 {
		opts.listen_backlog = HOST_LISTEN_BACKLOG
	}
	if opts.conn_chunk_size <= 0 {
		opts.conn_chunk_size = CONN_CHUNK_SIZE
	}
}

// listen stores the endpoint and opts. On Linux, binding is deferred to each worker
// (SO_REUSEPORT). On non-Linux, returns Unsupported without binding.
listen :: proc(
	s: ^Server,
	endpoint: net.Endpoint = Default_Endpoint,
	opts: Server_Opts = Default_Server_Opts,
) -> (err: proactr.Error) {
	s.opts = opts
	server_opts_resolve(&s.opts)
	s.endpoint = endpoint
	s.conn_allocator = context.allocator
	// No shared listen socket; workers bind with REUSEPORT (or REUSEADDR).
	s.tcp_sock = {}
	return .None
}

// serve runs the host completion loop (one ring per worker thread).
// Temp memory is a per-worker growable slot pool (see conn_slab.odin) — empty until first accept.
serve :: proc(s: ^Server, h: Handler) -> (err: proactr.Error) {
	if atomic_load(&s.closing) {
		return .Closed
	}
		s.handler = h

		thread_count := max(1, s.opts.thread_count)
		sync.wait_group_add(&s.threads_closed, thread_count)
		s.threads = make([]Server_Thread, thread_count, s.conn_allocator)

		log.infof(
			"host sizing: workers=%d temp_slot=%d temp_chunk=%d temp_max=%d resp_buf=%d recv=%d reg_bufs=%d ring=%d cqe=%d backlog=%d",
			thread_count,
			s.opts.temp_slot_bytes,
			s.opts.temp_chunk_slots,
			s.opts.temp_slots_max,
			s.opts.resp_buf_initial,
			s.opts.recv_buf_size,
			s.opts.reg_buf_count,
			s.opts.ring_entries,
			s.opts.cqe_batch,
			s.opts.listen_backlog,
		)

		for i in 0 ..< thread_count {
			t := &s.threads[i]
			t.server = s
			t.index = i
			t.state = .Idle
			t.listen_fd = {}
			t.accept_multishot = true
			_server_thread_init_temp(t, s)
		}
		for &t in s.threads[1:] {
			t.thread = thread.create_and_start_with_poly_data2(s, &t, _server_thread_main, context)
		}

		_server_thread_main(s, &s.threads[0])

		sync.wait(&s.threads_closed)

		log.debug("server threads are done, shutting down")
		// Idempotent if server_shutdown already closed listen fds.
		server_close_listen(s)
		for t in s.threads[1:] {
			if t.thread != nil {
				thread.destroy(t.thread)
			}
		}
		// Free conn slab + temp chunks after workers exit.
		for &t in s.threads {
			_server_thread_free_slab(&t)
		}
	delete(s.threads)
	s.threads = nil
	return .None
}

// listen_and_serve binds endpoint and runs the host completion loop.
listen_and_serve :: proc(
	s: ^Server,
	h: Handler,
	endpoint: net.Endpoint = Default_Endpoint,
	opts: Server_Opts = Default_Server_Opts,
) -> (err: proactr.Error) {
	listen(s, endpoint, opts) or_return
	return serve(s, h)
}

// server_close_listen closes all worker listen sockets at most once.
// Single owner for listen lifetime: workers never net.close their listen_fd.
// Call from normal thread context only (not from a signal handler).
// See crash_listener.odin for signal-safe request + worker reap.
@(private)
server_close_listen :: proc(s: ^Server) {
	// CAS false → true; only the winner closes.
	_, exchanged := sync.atomic_compare_exchange_strong(&s.listen_closed.raw, false, true)
	if !exchanged {
		return
	}
	if s.threads == nil {
		return
	}
	for &t in s.threads {
		if t.listen_fd != {} {
			net.close(t.listen_fd)
			t.listen_fd = {}
		}
	}
	// tcp_sock is never a live fd under REUSEPORT; clear only for cleanliness.
	s.tcp_sock = {}
}

// Taken from Go's implementation,
// The maximum amount of bytes to read (if handler did not)
// in order to get the connection ready for the next request.
@(private)
Max_Post_Handler_Discard_Bytes :: 256 << 10

Connection_State :: enum {
	Pending, // Pending a client to attach.
	New, // Got client, waiting to service first request.
	Active, // Servicing request.
	Idle, // Waiting for next request.
	Will_Close, // Closing after the current response is sent.
	Closing, // Going to close, cleaning up.
	Closed, // Fully closed.
}

@(private)
connection_set_state :: proc(c: ^Connection, s: Connection_State) -> bool {
	if s < .Closing && c.state >= .Closing {
		return false
	}

	if s == .Closing && c.state == .Closed {
		return false
	}

	c.state = s
	return true
}

// Connection holds per-client request/response state for the protocol layer.
//
// In-flight invariant: at most one of {recv, send, close} is outstanding per connection
// at a time (no concurrent SQEs, no refcount). pending_send stays valid until the full
// send completes; close_pending gates submit_close; close_on_io defers close until the
// in-flight recv CQE so the connection is not freed under a still-submitted op.
//
// Memory: resp_buf is permanent (conn_allocator) and holds response wire bytes across
// keep-alive requests. temp_allocator is request scrap only (headers/parse) — bump reset
// after each send completes; never free response memory while pending_send is non-nil.
//
// Phase 3 multi-buffer (Writev-style): when plan chooses Writev, exec_bufs[0..exec_n)
// holds [heading_slice, body1, body2, …]. Linux prefers IORING_OP_WRITEV via iovecs[];
// fallback is sequential pending_send (exec_bufs[exec_i] advanced on partial).
// Body slices are borrowed Static/Bytes and must remain valid until the final CQE.
// Max slots = PLAN_MAX_BODY_CMDS + 1 (heading).
//
// Phase 4 file region: after heading (and optional mem iovecs) complete, stream a
// File cmd via kernel sendfile(2) (Linux) or chunked pread into file_send_buf + send.
// file_send_remaining > 0 means more file bytes remain; Host does NOT close
// file_send_fd — the handler/app owns the fd for the full send lifetime.
PLAN_MAX_EXEC_BUFS :: PLAN_MAX_BODY_CMDS + 1
// Scratch size for Phase 4 chunked file send (not full-file materialize).
FILE_SEND_CHUNK :: 64 * 1024

Connection :: struct {
	server:         ^Server,
	socket:         net.TCP_Socket,
	state:          Connection_State,
	scanner:        Scanner,
	// Buffer-backed arena over a growable-pool temp slot (request scrap only).
	temp_allocator: virtual.Arena,
	// Index into this worker's temp_regions; -1 if none yet.
	temp_slot:      int,
	// Permanent response wire buffer (headers+body). Capacity retained across requests.
	resp_buf:       [dynamic]u8,
	loop:           Loop,
	// Remaining response bytes for (possibly multi-CQE) send. Valid until send fully completes.
	// Slices into resp_buf (materialize), exec_bufs[exec_i] (multi_send), or file_send_buf.
	pending_send:   []u8,
	// Multi-buffer send queue (Phase 3). exec_n == 0 → single-buffer / inactive.
	exec_bufs:      [PLAN_MAX_EXEC_BUFS][]u8,
	exec_i:         int,
	exec_n:         int,
	// Kernel WRITEV: packed from exec_bufs; advanced on short writev completions.
	iovecs:         [PLAN_MAX_EXEC_BUFS]proactr.Io_Vec,
	iov_count:      int,
	kernel_writev_active: bool,
	// Phase 4 file-region stream. fd < 0 → inactive (handler owns fd; host never closes).
	// remaining = bytes not yet delivered; kernel_sendfile_active → sendfile(2) path.
	file_send_fd:        i32,
	file_send_off:       i64,
	file_send_remaining: i64,
	file_send_buf:       []u8, // conn_allocator scratch; len==FILE_SEND_CHUNK when allocated
	kernel_sendfile_active: bool,
	// True while a close SQE is outstanding.
	close_pending:  bool,
	// Set on shutdown for Idle/New conns that still have a pending Recv; close on that CQE.
	// Do not set while Active (finish the request via Will_Close instead).
	close_on_io:    bool,
	// Registered file table index (>= 0) or -1 when using raw fds.
	fixed_idx:      i32,
	// Registered recv buffer index (>= 0) or -1.
	reg_buf_index:  i32,
	// True when scanner.buf is owned by the registered pool (do not delete on recycle).
	scanner_pooled: bool,
	// Optional phase timers (HTTP_PHASE_STATS).
	phase:          Phase_Conn,
}

// Loop/request cycle state.
@(private)
Loop :: struct {
	conn: ^Connection,
	req:  Request,
	res:  Response,
}

@(private)
_server_thread_main :: proc(s: ^Server, ttd: ^Server_Thread) {
		td = ttd
		td.state = .Serving
		td.conns = make(map[net.TCP_Socket]^Connection, s.conn_allocator)
		chunk_cap := max(1, s.opts.conn_chunk_size)
		td.conn_free = make([dynamic]^Connection, 0, chunk_cap, s.conn_allocator)
		td.conn_chunks = make([dynamic][]Connection, 0, 4, s.conn_allocator)
		td.accept_multishot = true
		defer {
			// Listen fd stays on Server_Thread until server_close_listen (sole closer).
			// Do not net.close or zero it here — that races shutdown and leaks the fd.
			delete(td.conns)
			td.state = .Closed
			sync.wait_group_done(&s.threads_closed)
		}

		rerr := proactr.ring_init(&td.ring, u32(s.opts.ring_entries), s.conn_allocator)
		if rerr != .None {
			log.errorf("proactr.ring_init failed: %v", rerr)
			return
		}
		defer proactr.ring_destroy(&td.ring)

		// Optional registered recv pool (scanner windows). Non-fatal on failure.
		if berr := proactr.ring_register_recv_pool(
			&td.ring,
			u32(s.opts.reg_buf_count),
			u32(s.opts.recv_buf_size),
		); berr != .None {
			log.debugf("REGISTER_BUFFERS skipped: %v", berr)
		}

		// Per-worker SO_REUSEPORT listen socket.
		lfd, lerr := host_listen_reuseport(s.endpoint, s.opts.listen_backlog)
		if lerr != .None {
			log.errorf("listen REUSEPORT failed: %v", lerr)
			return
		}
		td.listen_fd = lfd
		// Do not alias listen_fd onto s.tcp_sock (double-close hazard on teardown).

		// Install listen fd as fixed file slot 0 when available.
		td.listen_fixed = false
		if proactr.ring_has_fixed_files(&td.ring) {
			if serr := proactr.ring_set_listen_file(&td.ring, i32(td.listen_fd)); serr == .None {
				td.listen_fixed = true
			} else {
				log.debugf("ring_set_listen_file failed: %v (using raw listen fd)", serr)
			}
		}

		server_date_refresh()

		// Prime accept on this worker; on failure flag for retry (do not leave accept unarmed).
		if !host_submit_accept(s) {
			log.error("initial submit_accept failed; will retry")
			td.needs_accept_rearm = true
		}

		cqe_n := max(1, s.opts.cqe_batch)
		completions := make([]proactr.Completion, cqe_n, s.conn_allocator)
		defer delete(completions)
		wait_ms := i32(s.opts.wait_timeout_ms)
		td.state = .Running

		for {
			// Cold-path crash/reap: flag set by signal or server_shutdown;
			// close listen (once) + begin conn drain. Not on the CQE hot path.
			closing := server_reap_if_closing(s)

			// Retry accept arm if a previous submit_accept failed.
			if td.needs_accept_rearm {
				host_try_rearm_accept(s)
			}

			// Refresh Date header about once a second (thread-local buffer).
			if time.diff(td.date_updated, time.now()) >= time.Second {
				server_date_refresh()
			}

			min_complete: u32 = 1
			// During shutdown with no pending work, exit.
			if closing && len(td.conns) == 0 && !td.accept_pending {
				break
			}

			n, werr := proactr.ring_wait(&td.ring, completions[:], min_complete, wait_ms)
			if werr != .None {
				log.errorf("ring_wait error: %v", werr)
				// Soft-fail: continue so closing can progress; hard-fail only if not shutting down.
				if !atomic_load(&s.closing) {
					break
				}
			}

			// Re-check after wait (signal may have arrived while blocked).
			closing = server_reap_if_closing(s)

			for i in 0 ..< n {
				c := completions[i]
				op := proactr.complete_apply(&td.ring, c)
				if op == nil {
					continue
				}
				host_dispatch(s, op, c)
				// Multishot MORE: op stays Submitted — do not free.
				if op.status != .Submitted {
					proactr.op_free(&td.ring, c.op_id)
				}
			}

			// After CQEs, retry accept re-arm if needed (e.g. failed re-arm after accept CQE).
			if td.needs_accept_rearm {
				host_try_rearm_accept(s)
			}

			// Deferred handler completions (e.g. async DB work → respond on this worker).
			if s.opts.on_worker_tick != nil {
				s.opts.on_worker_tick(s.opts.worker_tick_user)
			}

			if closing && len(td.conns) == 0 && !td.accept_pending {
				break
			}
		}

	td.state = .Cleaning
	log.debug("worker host loop end")
}

@(private)
_server_thread_begin_shutdown :: proc(s: ^Server) {
	if td.state == .Closing || td.state == .Cleaning || td.state == .Closed {
		return
	}
	td.state = .Closing
	// Do not submit_close while Recv/Send may still be in flight (UAF on CQE).
	// Idle/New typically have a pending recv: close_on_io → host_on_recv closes.
	// Active: Will_Close so the response finishes, then clean_request_loop closes.
	for _, conn in td.conns {
		#partial switch conn.state {
		case .New, .Idle, .Pending:
			conn.close_on_io = true
		case .Active:
			_ = connection_set_state(conn, .Will_Close)
		case .Will_Close, .Closing, .Closed:
		}
	}
	_ = s
}

// host_listen_reuseport is implemented in server_linux.odin / server_stub.odin.

// host_submit_accept enqueues one accept SQE (user = Server), multishot by default.
// On failure returns false and does not set accept_pending (caller should set needs_accept_rearm).
@(private)
host_submit_accept :: proc(s: ^Server) -> bool {
	if atomic_load(&s.closing) || td.state >= .Closing {
		return false
	}
	if atomic_load(&s.listen_closed) || td.listen_fd == {} {
		return false
	}

	listen_fd := i32(td.listen_fd)
	// Only use FIXED_FILE for accept when slot 0 was successfully installed.
	fixed_listen: i32 = -1
	if td.listen_fixed {
		fixed_listen = 0
	}

	// Prefer continuous accept (uring multishot); fall back to one-shot.
	continuous := td.accept_multishot
	_, err := proactr.submit_accept(
		&td.ring,
		listen_fd,
		s,
		continuous,
		fixed_listen,
	)
	if err != .None && continuous {
		// Retry one-shot once.
		td.accept_multishot = false
		_, err = proactr.submit_accept(&td.ring, listen_fd, s, false, fixed_listen)
	}
	if err != .None {
		log.errorf("submit_accept: %v", err)
		return false
	}
	td.accept_pending = true
	td.needs_accept_rearm = false
	return true
}

// host_try_rearm_accept retries submit_accept after a prior failure.
// Clears needs_accept_rearm on success, when already pending, or when shutting down.
@(private)
host_try_rearm_accept :: proc(s: ^Server) {
	if atomic_load(&s.closing) || td.state >= .Closing || atomic_load(&s.listen_closed) {
		td.needs_accept_rearm = false
		return
	}
	if td.accept_pending {
		td.needs_accept_rearm = false
		return
	}
	if !host_submit_accept(s) {
		td.needs_accept_rearm = true
	}
}

// host_submit_recv enqueues recv into the scanner buffer window.
@(private)
host_submit_recv :: proc(conn: ^Connection, buf: []u8) -> proactr.Error {
	assert_has_td()
	if conn.state >= .Closing {
		return .Closed
	}
	// Pointer RECV into scanner window (pool-backed or dynamic). FIXED_BUF not used.
	_, err := proactr.submit_recv(
		&td.ring,
		i32(conn.socket),
		buf,
		conn,
		conn.fixed_idx,
	)
	return err
}

// host_submit_send enqueues send of conn.pending_send.
@(private)
host_submit_send :: proc(conn: ^Connection) -> proactr.Error {
	assert_has_td()
	if conn.state >= .Closing {
		return .Closed
	}
	if len(conn.pending_send) == 0 {
		return .None
	}
	_, err := proactr.submit_send(
		&td.ring,
		i32(conn.socket),
		conn.pending_send,
		conn,
		conn.fixed_idx,
	)
	return err
}

// Pack non-empty exec_bufs into conn.iovecs. Returns iov count (0 if nothing to send).
@(private)
_conn_pack_iovecs :: proc(conn: ^Connection) -> int {
	n := 0
	for i in 0 ..< conn.exec_n {
		b := conn.exec_bufs[i]
		if len(b) == 0 {
			continue
		}
		if n >= PLAN_MAX_EXEC_BUFS {
			break
		}
		conn.iovecs[n] = proactr.Io_Vec {
			base = raw_data(b),
			len  = uint(len(b)),
		}
		n += 1
	}
	conn.iov_count = n
	return n
}

// Advance iovecs after a short writev of `sent` bytes. Returns remaining iov count.
@(private)
_conn_advance_iovecs :: proc(conn: ^Connection, sent: int) -> int {
	if sent <= 0 || conn.iov_count <= 0 {
		return conn.iov_count
	}
	left := sent
	i := 0
	for i < conn.iov_count && left > 0 {
		l := int(conn.iovecs[i].len)
		if left >= l {
			left -= l
			i += 1
		} else {
			// Partial within this iov: slide base forward.
			base := uintptr(conn.iovecs[i].base) + uintptr(left)
			conn.iovecs[i].base = rawptr(base)
			conn.iovecs[i].len = uint(l - left)
			left = 0
		}
	}
	if i > 0 {
		// Compact remaining iovs to the front.
		remain := conn.iov_count - i
		for j in 0 ..< remain {
			conn.iovecs[j] = conn.iovecs[i + j]
		}
		conn.iov_count = remain
	}
	return conn.iov_count
}

// host_submit_writev enqueues IORING_OP_WRITEV from conn.iovecs[:iov_count].
// Caller packs iovecs (or call after _conn_pack_iovecs). On .Unsupported, caller falls back.
@(private)
host_submit_writev :: proc(conn: ^Connection) -> proactr.Error {
	assert_has_td()
	if conn.state >= .Closing {
		return .Closed
	}
	if conn.iov_count <= 0 {
		return .Invalid_Op
	}
	// Always raw socket fd for WRITEV — FIXED_FILE + WRITEV was unstable under load
	// (bastion proactr-opt silent death after high-RPS blob). Register slot still
	// used for RECV/SEND.
	_, err := proactr.submit_writev(
		&td.ring,
		i32(conn.socket),
		conn.iovecs[:conn.iov_count],
		conn,
		-1,
	)
	if err == .None {
		conn.kernel_writev_active = true
	}
	return err
}

// host_submit_sendfile enqueues kernel sendfile for conn.file_send_* region.
// On .Unsupported, caller falls back to chunked pread+send.
@(private)
host_submit_sendfile :: proc(conn: ^Connection) -> proactr.Error {
	assert_has_td()
	if conn.state >= .Closing {
		return .Closed
	}
	if conn.file_send_fd < 0 || conn.file_send_remaining <= 0 {
		return .Invalid_Op
	}
	// Raw socket fd (see host_submit_writev). file_fd is always a real open file.
	_, err := proactr.submit_sendfile(
		&td.ring,
		i32(conn.socket),
		conn.file_send_fd,
		conn.file_send_off,
		u64(conn.file_send_remaining),
		conn,
		-1,
	)
	if err == .None {
		conn.kernel_sendfile_active = true
	}
	return err
}

@(private)
host_dispatch :: proc(s: ^Server, op: ^proactr.Operation, c: proactr.Completion) {
	switch op.kind {
	case .Accept:
		host_on_accept(s, op.result, c.flags)
	case .Recv:
		conn := cast(^Connection)op.user
		if conn == nil || conn.state >= .Closing {
			return
		}
		host_on_recv(conn, op.result)
	case .Send:
		conn := cast(^Connection)op.user
		if conn == nil {
			return
		}
		// Always account for the send CQE (clear buffer ownership). Dropping
		// it after submit_close would UAF once the slab entry is recycled.
		if conn.state >= .Closing {
			_conn_clear_exec(conn)
			return
		}
		host_on_send(conn, op.result)
	case .Writev:
		conn := cast(^Connection)op.user
		if conn == nil {
			return
		}
		if conn.state >= .Closing {
			_conn_clear_exec(conn)
			return
		}
		host_on_writev(conn, op.result)
	case .Sendfile:
		conn := cast(^Connection)op.user
		if conn == nil {
			return
		}
		if conn.state >= .Closing {
			_conn_clear_exec(conn)
			return
		}
		host_on_sendfile(conn, op.result)
	case .Close:
		conn := cast(^Connection)op.user
		if conn == nil {
			return
		}
		host_on_close(conn)
	case .Timeout, .Nop:
		// Host does not arm per-conn timers; software timeouts are for ring_smoke / apps.
		_ = op
		_ = c
	}
}

@(private)
host_on_accept :: proc(s: ^Server, result: i32, cqe_flags: u32) {
	more := proactr.completion_has_more(proactr.Completion{flags = cqe_flags})

	// Handle result before re-arm so multishot→single-shot fallback does not
	// immediately re-submit another multishot accept that will fail again.
	if result < 0 {
		if more {
			td.accept_pending = true
		} else {
			td.accept_pending = false
		}
		// -errno (incl. listen closed on shutdown). EMFILE/ENFILE: back off without panic.
		// Multishot not supported: fall back and re-arm if needed.
		if host_accept_is_unsupported_multishot(result) {
			if td.accept_multishot {
				td.accept_multishot = false
				log.debug("accept multishot unsupported; falling back to single-shot")
			}
		}
		if !atomic_load(&s.closing) {
			log.errorf("accept failed: res=%d", result)
		} else {
			log.debugf("accept completed during shutdown: res=%d", result)
		}
		// Re-arm only when the multishot parent is done (!MORE).
		if !more &&
		   !atomic_load(&s.closing) &&
		   td.state < .Closing &&
		   !atomic_load(&s.listen_closed) &&
		   !td.accept_pending {
			if !host_submit_accept(s) {
				td.needs_accept_rearm = true
			}
		}
		return
	}

	if more {
		// Multishot still armed: keep accept_pending, do not re-submit.
		td.accept_pending = true
	} else {
		td.accept_pending = false
		// Re-arm (multishot or single-shot) unless shutting down.
		if !atomic_load(&s.closing) && td.state < .Closing && !atomic_load(&s.listen_closed) {
			if !host_submit_accept(s) {
				td.needs_accept_rearm = true
			}
		}
	}

	client_fd := net.TCP_Socket(result)

	// Drop connections accepted during shutdown.
	if atomic_load(&s.closing) || td.state >= .Closing {
		net.close(client_fd)
		return
	}

	// kqueue (and good practice on all backends): accepted fds must be nonblocking.
	_ = net.set_blocking(client_fd, false)

	c := conn_alloc(s)
	if c == nil {
		// Temp pool at max or grow failed for this worker.
		log.errorf("conn_alloc failed (temp pool); dropping fd=%v", client_fd)
		net.close(client_fd)
		return
	}
	c.state = .New
	c.server = s
	c.socket = client_fd
	c.close_pending = false
	c.close_on_io = false
	c.pending_send = nil
	c.exec_i = 0
	c.exec_n = 0
	c.file_send_fd = -1
	c.file_send_off = 0
	c.file_send_remaining = 0
	c.fixed_idx = -1
	// reg_buf_index / scanner_pooled / temp_slot already set by conn_alloc.

	// Register accepted fd into fixed file table when available.
	if proactr.ring_has_fixed_files(&td.ring) {
		if slot, ok := proactr.ring_file_alloc(&td.ring); ok {
			if serr := proactr.ring_file_set(&td.ring, slot, i32(client_fd)); serr == .None {
				c.fixed_idx = slot
			} else {
				// Slot was reserved; free it on failure.
				_ = proactr.ring_file_clear(&td.ring, slot)
			}
		}
	}

	td.conns[c.socket] = c
	log.debugf("accepted fd=%v fixed=%v conns=%d", c.socket, c.fixed_idx, len(td.conns))
	conn_handle_reqs(c)
}

@(private)
host_on_recv :: proc(conn: ^Connection, result: i32) {
	if conn.state >= .Closing {
		return
	}

	// Shutdown drain for Idle/New: a Recv was in flight; close now (no UAF).
	if conn.close_on_io {
		connection_close(conn)
		return
	}

	context.temp_allocator = virtual.arena_allocator(&conn.temp_allocator)

	if result < 0 {
		// Error (connection reset, etc.)
		log.debugf("recv error fd=%v res=%d", conn.socket, result)
		scanner_on_bytes(&conn.scanner, 0, true)
		return
	}
	if result == 0 {
		// Peer closed.
		scanner_on_bytes(&conn.scanner, 0, true)
		return
	}
	scanner_on_bytes(&conn.scanner, int(result), false)
}

// exec_queue_after_send advances multi-buffer send state after a successful CQE.
// Pure helper for host_on_send and unit tests.
//   - partial (0 < n_sent < len(pending)): stay on exec_i, pending shrinks
//   - full buffer: exec_i+1, skip empty slots; if more non-empty, next pending; else finished
//   - n_sent <= 0 or n_sent > len(pending): finished (caller treats as error / clamp complete)
// Does not touch Connection; caller applies the result.
// CRITICAL: never return a zero-length pending with finished=false — host_submit_send
// returns .None for empty slices without posting a CQE (connection would hang).
@(private)
exec_queue_after_send :: proc(
	exec_bufs: [][]u8,
	exec_i: int,
	exec_n: int,
	pending: []u8,
	n_sent: int,
) -> (
	new_pending: []u8,
	new_i: int,
	finished: bool,
) {
	if n_sent <= 0 {
		// No progress (or error signal from caller): do not spin on the same buffer.
		return nil, exec_i, true
	}
	if n_sent < len(pending) {
		return pending[n_sent:], exec_i, false
	}
	// Current buffer fully sent (n_sent >= len(pending)); advance, skipping empties.
	next := exec_i + 1
	for next < exec_n && next >= 0 {
		if len(exec_bufs[next]) > 0 {
			return exec_bufs[next], next, false
		}
		next += 1
	}
	return nil, next, true
}

// Pure math: after pread of `got` bytes from a known remaining region.
// Returns false if got is invalid (0, negative, or > remaining).
@(private)
file_send_after_pread :: proc(off, remaining, got: i64) -> (new_off, new_remaining: i64, ok: bool) {
	if remaining <= 0 || got <= 0 || got > remaining {
		return off, remaining, false
	}
	return off + got, remaining - got, true
}

// Clear Phase 4 file-region cursor. Keeps file_send_buf allocation for reuse.
// Does not close file_send_fd (handler ownership).
@(private)
_conn_clear_file_send :: proc(conn: ^Connection) {
	conn.file_send_fd = -1
	conn.file_send_off = 0
	conn.file_send_remaining = 0
	conn.kernel_sendfile_active = false
}

// After mem/heading complete: start kernel sendfile if preferred, else chunked pread.
// Increments plan_wire_sendfile or plan_wire_copy_into once when the file body starts.
// Returns true if a new SQE was submitted or clean finished; false if connection closed.
@(private)
_conn_file_region_start_or_finish :: proc(conn: ^Connection) -> bool {
	if conn.file_send_remaining > 0 {
		if plan_wire_prefer_kernel() {
			if err := host_submit_sendfile(conn); err == .None {
				plan_wire_inc_sendfile()
				return true
			}
			// Unsupported / submit fail → chunked fallback below.
			conn.kernel_sendfile_active = false
		}
		// Chunked pread+send fallback (portable; not kernel sendfile).
		plan_wire_inc_copy_into()
		return _conn_file_send_continue_or_finish(conn)
	}
	_conn_clear_file_send(conn)
	clean_request_loop(conn)
	return true
}

// Ensure conn.file_send_buf has FILE_SEND_CHUNK capacity (conn_allocator, permanent).
@(private)
_conn_ensure_file_send_buf :: proc(conn: ^Connection) -> bool {
	if len(conn.file_send_buf) >= FILE_SEND_CHUNK {
		return true
	}
	if conn.server == nil {
		return false
	}
	if conn.file_send_buf != nil {
		delete(conn.file_send_buf, conn.server.conn_allocator)
		conn.file_send_buf = nil
	}
	conn.file_send_buf = make([]u8, FILE_SEND_CHUNK, conn.server.conn_allocator)
	return len(conn.file_send_buf) == FILE_SEND_CHUNK
}

// pread next file chunk into file_send_buf and set pending_send.
// On success: pending_send non-empty, off/remaining advanced (remaining = not-yet-pread).
// Short pread (0 < got < want) is progress — next fill continues at new off.
// got==0 with remaining>0 is unexpected EOF (declared length past file) → fail.
// On failure: state uncleared (caller closes connection).
@(private)
_conn_file_send_fill_chunk :: proc(conn: ^Connection) -> bool {
	if conn.file_send_remaining <= 0 {
		return false
	}
	if !_conn_ensure_file_send_buf(conn) {
		log.errorf("file_send: scratch alloc failed fd=%v", conn.socket)
		return false
	}
	want := conn.file_send_remaining
	if want > i64(FILE_SEND_CHUNK) {
		want = i64(FILE_SEND_CHUNK)
	}
	n := int(want)
	when ODIN_OS == .Windows {
		log.errorf("file_send: pread not available on Windows (fd=%d)", conn.file_send_fd)
		return false
	} else {
		got: int
		for {
			g := posix.pread(
				posix.FD(conn.file_send_fd),
				raw_data(conn.file_send_buf),
				c.size_t(n),
				posix.off_t(conn.file_send_off),
			)
			if g < 0 {
				if posix.errno() == .EINTR {
					continue
				}
				log.errorf("file_send pread failed fd=%v file=%d: %v", conn.socket, conn.file_send_fd, posix.errno())
				return false
			}
			got = int(g)
			break
		}
		if got == 0 {
			// EOF before declared remaining — not a short-but-positive pread.
			log.errorf("file_send EOF fd=%v file=%d remaining=%d", conn.socket, conn.file_send_fd, conn.file_send_remaining)
			return false
		}
		new_off, new_rem, ok := file_send_after_pread(conn.file_send_off, conn.file_send_remaining, i64(got))
		if !ok {
			return false
		}
		conn.file_send_off = new_off
		conn.file_send_remaining = new_rem
		// remaining==0 after fill: this is the last pending chunk; file_send_fd stays set
		// until host_on_send drains pending_send and calls _conn_clear_file_send.
		conn.pending_send = conn.file_send_buf[:got]
		return true
	}
}

// After a full buffer (header / mem / chunk) has been sent: either fill next file
// chunk, or finish the response. Returns true if a new send was submitted (or clean
// completed); false if connection was closed on error.
@(private)
_conn_file_send_continue_or_finish :: proc(conn: ^Connection) -> bool {
	if conn.file_send_remaining > 0 {
		if !_conn_file_send_fill_chunk(conn) {
			_conn_clear_exec(conn)
			connection_close(conn)
			return false
		}
		if len(conn.pending_send) == 0 {
			_conn_clear_exec(conn)
			connection_close(conn)
			return false
		}
		if err := host_submit_send(conn); err != .None {
			log.errorf("submit_send (file chunk) failed: %v", err)
			_conn_clear_exec(conn)
			connection_close(conn)
			return false
		}
		return true
	}
	// File region fully loaded and prior chunk fully sent (or zero-length file).
	_conn_clear_exec(conn)
	clean_request_loop(conn)
	return true
}

@(private)
_conn_clear_exec :: proc(conn: ^Connection) {
	conn.exec_i = 0
	conn.exec_n = 0
	conn.pending_send = nil
	conn.iov_count = 0
	conn.kernel_writev_active = false
	// Drop dangling body/heading slice refs (temp may be reset / slab recycled).
	for i in 0 ..< len(conn.exec_bufs) {
		conn.exec_bufs[i] = nil
	}
	_conn_clear_file_send(conn)
	// Keep file_send_buf for reuse across requests.
}

// Kernel WRITEV completion: advance iovecs on short write; then file region or finish.
@(private)
host_on_writev :: proc(conn: ^Connection, result: i32) {
	context.temp_allocator = virtual.arena_allocator(&conn.temp_allocator)

	if conn.close_on_io {
		_conn_clear_exec(conn)
		conn.close_on_io = false
		if conn.state < .Closing {
			connection_close(conn)
		}
		return
	}

	if result < 0 {
		log.errorf("writev error fd=%v res=%d", conn.socket, result)
		_conn_clear_exec(conn)
		connection_close(conn)
		return
	}

	if result == 0 && conn.iov_count > 0 {
		log.errorf("writev zero-length fd=%v iov_count=%d", conn.socket, conn.iov_count)
		_conn_clear_exec(conn)
		connection_close(conn)
		return
	}

	remain := _conn_advance_iovecs(conn, int(result))
	if remain > 0 {
		if err := host_submit_writev(conn); err != .None {
			log.errorf("submit_writev (partial) failed: %v", err)
			_conn_clear_exec(conn)
			connection_close(conn)
		}
		return
	}

	// Gather complete.
	conn.kernel_writev_active = false
	conn.exec_i = 0
	conn.exec_n = 0
	conn.pending_send = nil
	for i in 0 ..< len(conn.exec_bufs) {
		conn.exec_bufs[i] = nil
	}
	// Mixed Writev+Sendfile: start file region (kernel sendfile or chunked).
	if conn.file_send_remaining > 0 || conn.file_send_fd >= 0 {
		_ = _conn_file_region_start_or_finish(conn)
		return
	}
	clean_request_loop(conn)
}

// Kernel sendfile completion: advance file cursor; resubmit remainder or finish.
@(private)
host_on_sendfile :: proc(conn: ^Connection, result: i32) {
	context.temp_allocator = virtual.arena_allocator(&conn.temp_allocator)

	if conn.close_on_io {
		_conn_clear_exec(conn)
		conn.close_on_io = false
		if conn.state < .Closing {
			connection_close(conn)
		}
		return
	}

	if result < 0 {
		log.errorf("sendfile error fd=%v res=%d", conn.socket, result)
		_conn_clear_exec(conn)
		connection_close(conn)
		return
	}

	n := i64(result)
	if n == 0 && conn.file_send_remaining > 0 {
		log.errorf("sendfile zero progress fd=%v file=%d remaining=%d", conn.socket, conn.file_send_fd, conn.file_send_remaining)
		_conn_clear_exec(conn)
		connection_close(conn)
		return
	}

	if n > conn.file_send_remaining {
		n = conn.file_send_remaining
	}
	conn.file_send_off += n
	conn.file_send_remaining -= n

	if conn.file_send_remaining > 0 {
		if err := host_submit_sendfile(conn); err != .None {
			log.errorf("submit_sendfile (partial) failed: %v — falling back to chunked", err)
			conn.kernel_sendfile_active = false
			_ = _conn_file_send_continue_or_finish(conn)
		}
		return
	}

	// File region fully delivered.
	_conn_clear_exec(conn)
	clean_request_loop(conn)
}

@(private)
host_on_send :: proc(conn: ^Connection, result: i32) {
	context.temp_allocator = virtual.arena_allocator(&conn.temp_allocator)

	// Deferred close while a send SQE was outstanding: account for this CQE first.
	// Mid multi-buffer / file stream: abort remaining queue (partial response on wire).
	if conn.close_on_io {
		_conn_clear_exec(conn)
		conn.close_on_io = false
		if conn.state < .Closing {
			connection_close(conn)
		}
		return
	}

	if result < 0 {
		log.errorf("send error fd=%v res=%d", conn.socket, result)
		_conn_clear_exec(conn)
		connection_close(conn)
		return
	}

	// Zero-byte completion with a non-empty pending buffer: do not resubmit forever.
	// (Normal TCP send of N>0 bytes returns >0, EAGAIN-as-error, or short count.)
	if result == 0 && len(conn.pending_send) > 0 {
		log.errorf("send zero-length fd=%v pending=%d exec_n=%d", conn.socket, len(conn.pending_send), conn.exec_n)
		_conn_clear_exec(conn)
		connection_close(conn)
		return
	}

	n := int(result)

	// Multi-buffer sequential queue (Phase 3 fallback): advance within/across exec_bufs.
	// When the queue finishes and a file region remains, start sendfile or chunked stream.
	if conn.exec_n > 0 {
		new_pending, new_i, finished := exec_queue_after_send(
			conn.exec_bufs[:conn.exec_n],
			conn.exec_i,
			conn.exec_n,
			conn.pending_send,
			n,
		)
		if finished {
			// Clear mem queue slots; file_send_* preserved if active.
			conn.exec_i = 0
			conn.exec_n = 0
			conn.pending_send = nil
			for i in 0 ..< len(conn.exec_bufs) {
				conn.exec_bufs[i] = nil
			}
			if conn.file_send_remaining > 0 || conn.file_send_fd >= 0 {
				_ = _conn_file_region_start_or_finish(conn)
				return
			}
			_conn_clear_file_send(conn)
			clean_request_loop(conn)
			return
		}
		// Defense: never arm a zero-length pending (no CQE → hang).
		if len(new_pending) == 0 {
			log.errorf("multi-op empty pending after advance fd=%v i=%d n=%d", conn.socket, new_i, conn.exec_n)
			_conn_clear_exec(conn)
			connection_close(conn)
			return
		}
		conn.exec_i = new_i
		conn.pending_send = new_pending
		if err := host_submit_send(conn); err != .None {
			log.errorf("submit_send (multi-op) failed: %v", err)
			_conn_clear_exec(conn)
			connection_close(conn)
			return
		}
		// host_submit_send(.None) with empty pending is a hang; guarded above.
		return
	}

	// Single-buffer or file-chunk path: partial send within current pending.
	if n < len(conn.pending_send) {
		// Partial send — advance and resubmit. Buffer still owned until full send.
		// n==0 already closed above; n>0 here.
		conn.pending_send = conn.pending_send[n:]
		if len(conn.pending_send) == 0 {
			// Should not happen (n < len implies remainder > 0); fail closed.
			_conn_clear_exec(conn)
			connection_close(conn)
			return
		}
		if err := host_submit_send(conn); err != .None {
			log.errorf("submit_send (partial) failed: %v", err)
			_conn_clear_exec(conn)
			connection_close(conn)
		}
		return
	}

	// Current buffer fully sent.
	conn.pending_send = nil

	// Phase 4: after heading (or last multi_send buffer), start file region;
	// or continue chunked fills when already in copy_into path.
	if conn.file_send_remaining > 0 {
		if !conn.kernel_sendfile_active {
			// First transition into file body: try kernel sendfile, else chunked.
			_ = _conn_file_region_start_or_finish(conn)
			return
		}
		// kernel_sendfile_active handled by host_on_sendfile; should not land here.
		_ = _conn_file_send_continue_or_finish(conn)
		return
	}
	if conn.file_send_fd >= 0 {
		// Last file chunk fully delivered (remaining already 0 after last pread).
		_conn_clear_file_send(conn)
		clean_request_loop(conn)
		return
	}

	// Single-buffer path complete (materialize / body_reserve / HEAD).
	clean_request_loop(conn)
}

@(private)
host_on_close :: proc(conn: ^Connection) {
	conn.close_pending = false
	// After close CQE: clear fixed file slot and return to free list.
	if conn.fixed_idx >= 0 {
		_ = proactr.ring_file_clear(&td.ring, conn.fixed_idx)
		conn.fixed_idx = -1
	}
	connection_destroy(conn)
}

@(private)
connection_close :: proc(c: ^Connection, loc := #caller_location) {
	assert_has_td(loc)

	if c.state >= .Closing {
		log.debugf("connection %i already closing/closed", c.socket)
		return
	}

	// Invariant: at most one of {recv, send, close}. Never submit_close while
	// a send SQE is outstanding — defer until host_on_send accounts for it.
	// Multi-buffer: pending_send is set for the current buffer while SQE in flight.
	if len(c.pending_send) > 0 {
		log.debugf("connection %i close deferred (send in flight)", c.socket)
		c.close_on_io = true
		return
	}

	log.debugf("closing connection: %i", c.socket)
	c.state = .Closing
	_conn_clear_exec(c)
	c.close_on_io = false

	if c.close_pending {
		return
	}
	// Close the process fd (raw). After CQE we FILES_UPDATE the fixed slot to -1
	// (drops the registered ref). Using FIXED_FILE for close would leave the process
	// fd open and leak descriptors.
	_, err := proactr.submit_close(&td.ring, i32(c.socket), c, -1)
	if err != .None {
		log.errorf("submit_close failed: %v", err)
		// Fall back to synchronous close + free.
		net.close(c.socket)
		if c.fixed_idx >= 0 {
			_ = proactr.ring_file_clear(&td.ring, c.fixed_idx)
			c.fixed_idx = -1
		}
		connection_destroy(c)
		return
	}
	c.close_pending = true
}

// Protocol request handling. Parsing is callback-driven via Scanner;
// I/O is submitted through the proactr host (submit_recv / CQE → scanner_on_bytes).
@(private)
conn_handle_reqs :: proc(c: ^Connection) {
	scanner_prepare(c)

	// Temp arena is buffer-backed scrap (attached in conn_alloc). Bump-reset only;
	// response bytes are in c.resp_buf, not this arena.
	assert(c.temp_slot >= 0 && c.temp_allocator.kind == .Buffer)
	conn_temp_reset(c)
	context.temp_allocator = virtual.arena_allocator(&c.temp_allocator)

	conn_handle_req(c, context.temp_allocator)
}

@(private)
conn_handle_req :: proc(c: ^Connection, allocator := context.temp_allocator) {
	on_rline1 :: proc(loop: rawptr, token: string, err: bufio.Scanner_Error) {
		l := cast(^Loop)loop

		if !connection_set_state(l.conn, .Active) { return }

		when HTTP_PHASE_STATS {
			if !l.conn.phase.in_parse {
				l.conn.phase.parse_t0 = phase_now()
				l.conn.phase.in_parse = true
			}
		}

		if err != nil {
			if err == .EOF {
				log.debugf("client disconnected (EOF)")
			} else {
				log.warnf("request scanner error: %v", err)
			}

			clean_request_loop(l.conn, close = true)
			return
		}

		// In the interest of robustness, a server that is expecting to receive
		// and parse a request-line SHOULD ignore at least one empty line (CRLF)
		// received prior to the request-line.
		if len(token) == 0 {
			log.debug("first request line empty, skipping in interest of robustness")
			scanner_scan(&l.conn.scanner, loop, on_rline2)
			return
		}

		on_rline2(loop, token, err)
	}

	on_rline2 :: proc(loop: rawptr, token: string, err: bufio.Scanner_Error) {
		l := cast(^Loop)loop

		if err != nil {
			log.warnf("request scanning error: %v", err)
			clean_request_loop(l.conn, close = true)
			return
		}

		t0_rline: u64
		when HTTP_PHASE_STATS {
			t0_rline = phase_now()
		}
		rline, err := requestline_parse(token, context.temp_allocator)
		when HTTP_PHASE_STATS {
			phase_add(0, 0, 0, phase_now() - t0_rline, 0, 0, 0)
		}
		switch err {
		case .Method_Not_Implemented:
			log.infof("request-line %q invalid method", token)
			headers_set_close(&l.res.headers)
			l.res.status = .Not_Implemented
			respond(&l.res)
			return
		case .Invalid_Version_Format, .Not_Enough_Fields:
			log.warnf("request-line %q invalid: %s", token, err)
			clean_request_loop(l.conn, close = true)
			return
		case .None:
			l.req.line = rline
		}

		// Might need to support more versions later.
		if rline.version.major != 1 || rline.version.minor > 1 {
			log.infof("request http version not supported %v", rline.version)
			headers_set_close(&l.res.headers)
			l.res.status = .HTTP_Version_Not_Supported
			respond(&l.res)
			return
		}

		l.req.url = url_parse(rline.target.(string))

		l.conn.scanner.max_token_size = l.conn.server.opts.limit_headers
		scanner_scan(&l.conn.scanner, loop, on_header_line)
	}

	on_header_line :: proc(loop: rawptr, token: string, err: bufio.Scanner_Error) {
		l := cast(^Loop)loop

		if err != nil {
			log.warnf("request scanning error: %v", err)
			clean_request_loop(l.conn, close = true)
			return
		}

		// The first empty line denotes the end of the headers section.
		if len(token) == 0 {
			on_headers_end(l)
			return
		}

		t0_hdr: u64
		when HTTP_PHASE_STATS {
			t0_hdr = phase_now()
		}
		ok_hdr: bool
		_, ok_hdr = header_parse(&l.req.headers, token)
		when HTTP_PHASE_STATS {
			phase_add(0, 0, phase_now() - t0_hdr, 0, 0, 0, 0)
		}
		if !ok_hdr {
			log.warnf("header-line %s is invalid", token)
			headers_set_close(&l.res.headers)
			l.res.status = .Bad_Request
			respond(&l.res)
			return
		}

		l.conn.scanner.max_token_size -= len(token)
		if l.conn.scanner.max_token_size <= 0 {
			log.warn("request headers too large")
			headers_set_close(&l.res.headers)
			l.res.status = .Request_Header_Fields_Too_Large
			respond(&l.res)
			return
		}

		scanner_scan(&l.conn.scanner, loop, on_header_line)
	}

	on_headers_end :: proc(l: ^Loop) {
		when HTTP_PHASE_STATS {
			if l.conn.phase.in_parse {
				phase_add(0, phase_now() - l.conn.phase.parse_t0, 0, 0, 0, 0, 0)
				l.conn.phase.in_parse = false
			}
		}

		if !headers_validate_for_server(&l.req.headers) {
			log.warn("request headers are invalid")
			headers_set_close(&l.res.headers)
			l.res.status = .Bad_Request
			respond(&l.res)
			return
		}

		l.req.headers.readonly = true

		l.conn.scanner.max_token_size = bufio.DEFAULT_MAX_SCAN_TOKEN_SIZE

		// Automatically respond with a continue status when the client has the Expect: 100-continue header.
		if expect, ok := headers_get_unsafe(l.req.headers, "expect");
		   ok && expect == "100-continue" && l.conn.server.opts.auto_expect_continue {

			l.res.status = .Continue

			respond(&l.res)
			return
		}

		rline := &l.req.line.(Requestline)
		// An options request with the "*" is a no-op/ping request to
		// check for server capabilities and should not be sent to handlers.
		if rline.method == .Options && rline.target.(string) == "*" {
			l.res.status = .OK
			respond(&l.res)
		} else {
			// Give the handler this request as a GET, since the HTTP spec
			// says a HEAD is identical to a GET but just without writing the body,
			// handlers shouldn't have to worry about it.
			is_head := rline.method == .Head
			if is_head && l.conn.server.opts.redirect_head_to_get {
				l.req.is_head = true
				rline.method = .Get
			}

			// CPS handler chain. Happy path calls respond() inside.
			when HTTP_PHASE_STATS {
				l.conn.phase.handle_t0 = phase_now()
				l.conn.phase.in_handle = true
			}
			l.conn.server.handler.handle(&l.conn.server.handler, &l.req, &l.res)
			when HTTP_PHASE_STATS {
				if l.conn.phase.in_handle {
					phase_add(1, 0, 0, 0, phase_now() - l.conn.phase.handle_t0, 0, 0)
					l.conn.phase.in_handle = false
				}
			}
		}
	}

	c.loop.conn = c
	c.loop.req._scanner = &c.scanner
	request_init(&c.loop.req, allocator)
	response_init(&c.loop.res, c, allocator)

	c.scanner.max_token_size = c.server.opts.limit_request_line
	scanner_scan(&c.scanner, &c.loop, on_rline1)
}

// A buffer that will contain the date header for the current second (per worker).
@(private)
Server_Date :: struct {
	buf_backing: [DATE_LENGTH]byte,
	buf:         bytes.Buffer,
}

// server_date_refresh updates this worker's thread-local Date string.
// Single time.now() (was two: format + assign).
@(private)
server_date_refresh :: proc() {
	assert_has_td()
	now := time.now()
	td.date.buf.buf = slice.into_dynamic(td.date.buf_backing[:])
	bytes.buffer_reset(&td.date.buf)
	date_write(bytes.buffer_to_stream(&td.date.buf), now)
	td.date_updated = now
}

// server_date returns this worker's Date header value (thread-local; no shared mutex).
@(private)
server_date :: proc(s: ^Server) -> string {
	_ = s
	assert_has_td()
	if td.date.buf.buf == nil || len(td.date.buf.buf) == 0 {
		server_date_refresh()
	}
	return string(td.date.buf_backing[:])
}
