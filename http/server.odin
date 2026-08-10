// Server host surface forked from laytan/odin-http.
// proactr completion host: io_uring (Linux), kqueue (Darwin/BSD), IOCP (Windows ring; HTTP host POSIX/Linux).
// Hardening: I/O backend host (server_io_uring / server_kqueue / server_iocp),
// multishot accept where proactor, fixed files/bufs, conn slab.
package http

import "core:bufio"
import "core:bytes"
import "core:log"
import "core:mem"
import "core:mem/virtual"
import "core:net"
import "core:slice"
import "core:sync"
import "core:thread"
import "core:time"

import proactr "../proactr"
import http2 "../http2"
import tls_server "../tls_server"

// virtual used for session_scratch arena on Server_Thread.

// Multi-slot slab capacity for H2 host (PR8 structure, PR9 concurrent unary).
// Slab is heap-allocated only on ALPN-h2 open (lazy) so clear/TLS H1 Connections
// do not pay H2_SLOT_CAP × Stream_Slot. Concurrent oneshot uses free slots; serial
// opt holds one in-flight (h2_serial_dispatch=true).
H2_SLOT_CAP :: 8

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
	// Implies multi-mem gather and file Sendfile when platform/server allow (prefer_sendfile
	// not required). Default false: materialize-only. Harness PLAN_MODE=optimize sets true.
	// Also enabled per-request via prefer_gather / prefer_sendfile.
	// PLAN_WIRE_MODE=fallback forces multi_send/copy_into on Linux.
	plan_optimize:        bool,
	// D2 Session caps (0 → session.odin defaults).
	max_sessions_per_worker: int,
	max_stream_buffer:       int, // unreclaimed stream bytes per session
	max_stream_bytes_total:  int, // worker Stream_Buf_Pool admitted cap (0 → 64 MiB)
	stream_buf_size:         int, // Stream_Buf_Pool slab (0 → 8 KiB)
	stream_idle_timeout_ms:  int,
	stream_mailbox_depth:    int,
	// After sse_start: shrink permanent resp_buf capacity (0 → 16 KiB).
	stream_resp_shrink_cap:  int,
	// PR5 TLS knobs (listen_tls / handshake later). Empty PEM = TLS off.
	// PEM slices match vapor-style in-memory cert material (not paths).
	tls_cert_pem:            []u8,
	tls_key_pem:             []u8,
	// H2 dispatch: false (default) = concurrent unary — take while free slots remain.
	// true = eng/debug single-flight (h2_serial_busy; at most one oneshot in flight).
	// Does not implement SSE-on-H2; long-lived holds keep their slot only.
	h2_serial_dispatch:      bool,
	// PR10 optional SSE-vs-bulk fairness (engine RR flush). 0 → defaults (2 / 1).
	// Interactive (sse_start H2) streams get h2_weight_interactive DATA frames per
	// RR turn; oneshot bulk bodies use h2_weight_bulk.
	h2_weight_interactive:   u8,
	h2_weight_bulk:          u8,
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
	h2_serial_dispatch   = false, // product concurrent unary; true = serial single-flight
	h2_weight_interactive = 2,    // SSE / session streams (PR10 RR quanta)
	h2_weight_bulk        = 1,    // oneshot large body
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
	// kqueue Darwin: shared listen. io_uring/other: usually zero (per-worker listen_fd).
	tcp_sock:       net.TCP_Socket,
	// Endpoint to bind (host_listen_bind / host_worker_attach_listen per backend).
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
	// PR5 host TLS/bulk scrape gauges (atomics). Updated by tls_metrics_* helpers.
	// peak_pt / peak_ct: high-water of admitted PT / sealed CT bytes; seal_units: count.
	tls_peak_pt:    Atomic(u64),
	tls_peak_ct:    Atomic(u64),
	tls_seal_units: Atomic(u64),
	// Shared TLS context (nil provider / nil ctx = TLS off; clear-H1 only).
	// Init in listen when PEMs set; freed in serve teardown via server_tls_destroy.
	tls_provider:   ^tls_server.Provider,
	tls_ctx:        tls_server.Ctx,
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
	// Listen socket (backend-owned: shared mirror or REUSEPORT fd).
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
	// Fixed Stream send slab pool (progressive Stream / Session).
	stream_pool:        Stream_Buf_Pool,
	// Mailbox pending for this worker (wake short-circuit for ring_wait).
	mail_pending:       i64, // atomic
	// Small scrap for session effect framing after request temp detach (not 4.5 MiB slot).
	session_scratch:       virtual.Arena,
	session_scratch_block: []u8,
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

// listen stores the endpoint and opts; backend may bind process-wide (kqueue Darwin)
// or defer to host_worker_attach_listen (io_uring REUSEPORT, etc.).
listen :: proc(
	s: ^Server,
	endpoint: net.Endpoint = Default_Endpoint,
	opts: Server_Opts = Default_Server_Opts,
) -> (err: proactr.Error) {
	s.opts = opts
	server_opts_resolve(&s.opts)
	s.endpoint = endpoint
	s.conn_allocator = context.allocator
	s.tcp_sock = {}
	if e := host_listen_bind(s, endpoint); e != .None {
		return e
	}
	// PR5: init shared SSL_CTX when PEMs present. On failure: honest clear-H1 only.
	if server_tls_wanted(s) {
		if !server_tls_init(s) {
			// Clear PEM knobs so accept path does not pretend TLS is live.
			s.opts.tls_cert_pem = nil
			s.opts.tls_key_pem = nil
			s.tls_provider = nil
			s.tls_ctx = nil
		}
	} else {
		s.tls_provider = nil
		s.tls_ctx = nil
	}
	return .None
}

// serve runs the host completion loop (one ring per worker thread).
// Temp memory is a per-worker growable slot pool (see conn_slab.odin) — empty until first accept.
serve :: proc(s: ^Server, h: Handler) -> (err: proactr.Error) {
	if atomic_load(&s.closing) {
		return .Closed
	}
		// Belt-and-suspenders: even if the app skipped server_shutdown_on_interrupt,
		// never die on client disconnect mid-sendfile/send (SIGPIPE → exit 141).
		server_ignore_sigpipe()

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
	// Free shared SSL_CTX (provider stays process-default if any).
	server_tls_destroy(s)
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

// server_close_listen closes listen socket(s) at most once.
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
	server_close_listen_sockets(s)
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
// In-flight invariant: at most one of {recv, send/writev/sendfile, close} is outstanding
// per connection at a time (no concurrent SQEs, no refcount). wire.kind != .None while a
// send/WRITEV/sendfile SQE (or soft completion) is outstanding; wire.pending_send stays valid
// until a Send fully completes. tls_ct_recv_inflight is true while a CT RECV SQE is
// outstanding (TLS hangup/HS/Open). close_pending gates submit_close; close_on_io defers
// close until the in-flight CQE so the connection is not freed under a still-submitted
// op (and wire.exec_bufs/iovecs/file_send_*/tls_ct_rx stay live). See wire.odin.
//
// Memory: resp_buf is permanent (conn_allocator) and holds response wire bytes across
// keep-alive requests. temp_allocator is request scrap only (headers/parse) — bump reset
// after each send completes; never free response memory while wire I/O is in flight.
//
// Phase 3 multi-buffer (Writev-style): when plan chooses Writev, wire.exec_bufs[0..exec_n)
// holds [heading_slice, body1, body2, …]. Linux prefers IORING_OP_WRITEV via ephemeral
// iovecs packed from exec_bufs; fallback is sequential pending_send (exec_i advanced).
// Body slices are borrowed Static/Bytes and must remain valid until the final CQE.
//
// Phase 4 file region: after heading (and optional mem) complete, stream a File cmd
// via kernel sendfile(2) (Linux) or chunked pread into wire.file_send_buf + send.
// wire.file_send_remaining > 0 means more file bytes remain; Host does NOT close
// file_send_fd — the handler/app owns the fd for the full send lifetime.

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
	// Nested wire bag: mem queue, iovecs, file region, in-flight kind (see Wire_State).
	// Clear-H1 path still drives Wire_State; Plan A pipe bags below are not yet wired.
	wire:           Wire_State,
	// Plan A pipe bags (POD; clear-H1 still uses Wire_State for mem/file send).
	// wire_conn is thin (~24 B); pure-pipe Seal_Queue / Tls_Pipe CT[2] only via
	// connection_enable_ciphered_pipe_sm (firehose tests). Live TLS seal∥send uses
	// dual_ct slabs (tls_host_on_accept) + connection_enable_ciphered (flag + plan_policy).
	pt:        Conn_Pt_Ring,
	wire_conn: Wire_Conn_State,
	// tls: Tls_Pipe SM + host mem-BIO engine (opaque Conn; no SSL* public).
	tls_pipe:  Tls_Pipe,
	// True when TLS/cipher path is active for this conn (set by connection_enable_ciphered).
	// plan_policy_for reads this: ciphered ⇒ no sendfile, max_write_unit = PULL_WINDOW_DEFAULT.
	ciphered:  bool,
	// Host-private TLS engine (0 / nil = clear). Opaque tls_server.Conn only.
	tls_ssl:        tls_server.Conn,
	// Cached SSL write-BIO (opaque rawptr from tls_server.get_wbio after setup_mem_bios).
	// Drain uses bio_*_out_bio(p, tls_wbio) — no SSL_get_wbio per iteration.
	// Not exposed to handlers (APP_CONTRACT). Owned by SSL; nil on clear / free.
	tls_wbio:       rawptr,
	// True after plain cursor armed until first successful SSL_write (first_seal_pt).
	tls_first_seal_pending: bool,
	// Network CT recv scratch (allocated on TLS accept; freed on destroy).
	tls_ct_rx:      []u8,
	// Live dual-CT seal∥send (PR5.1 Linux): primary + hold slabs; seal next window into
	// free slab while one sock send is in flight. See tls_dual_ct.odin.
	// Darwin H1+H2 reactor: dual_ct.tx is the single residual CT slab (hold unused on
	// reactor product paths). Stream residual-first also uses tx; dual_ct_try_ahead no-op.
	dual_ct:        Dual_Ct,
	// Darwin reactor residual: dual_ct.tx[reactor_res_off:][:reactor_res_n].
	// reactor_h1: residual WRITE armed (native EVFILT_WRITE on reactor kq); must be set
	// before arm so soft_cq_send_completes is not charged and write demuxes to reactor.
	// reactor_fairness_yield: reserved (fairness uses product re-entry, not soft-Nop).
	// reactor_read/write_armed: native interest on the reactor kqueue (P5).
	// Product READ always level; residual WRITE level; fairness WRITE oneshot.
	// reactor_recv_buf: buffer for next native RECV (CT or clear scanner window).
	reactor_res_off:         int,
	reactor_res_n:           int,
	reactor_h1:              bool,
	reactor_fairness_yield:  bool,
	reactor_read_armed:      bool,
	reactor_write_armed:     bool,
	// residual WRITE: level EVFILT_WRITE until residual empty. Fairness WRITE: oneshot.
	reactor_write_level:     bool,
	// product READ: always level until reactor_host_close (accept uses REACTOR_UDATA_ACCEPT).
	reactor_read_level:      bool,
	// reactor_need_clean: oneshot finished sync inside scan/handler — defer
	// clean_request_loop until end of kevent turn (avoid reentrant scanner UAF).
	reactor_need_clean:      bool,
	// reactor_scan_injected: host_submit_recv wrote PT into scanner free window
	// without reentrant scanner_on_bytes; scanner_scan should re-enter parse.
	reactor_scan_injected:   bool,
	reactor_recv_buf:        []u8,
	// True while a CT RECV into tls_ct_rx is outstanding (hangup / HS / Open).
	// Arm is idempotent; re-arm only after the matching completion clears this bit.
	// Prevents kqueue EV_ADD replace-udata orphan of a prior Recv (CQ-F1).
	tls_ct_recv_inflight: bool,
	// Remaining plaintext for windowed ciphered oneshot response.
	// Heading (or full materialize) first; optional borrowed Static/Bytes body second
	// so seal can avoid O(body) memcpy into resp_buf on single-cmd H1 oneshot.
	tls_plain_rest:     []u8, // view into resp_buf (heading or full PT)
	tls_plain_body:     []u8, // borrowed Static/Bytes body (not owned; valid until clean)
	tls_plain_body_off: int,  // cursor into tls_plain_body
	// pending_send is handshake CT (vs response CT) for send-complete demux.
	tls_hs_send:    bool,
	// Progressive stream (SSE/WS): deferred plain when multi-record residual CT of a
	// seal is still outstanding (advance stream_sent only after full CT for that
	// seal is delivered). Per-slab plain lives on dual_ct.tx_plain_n / hold_plain_n.
	tls_stream_plain_n:  int,
	// H1 N=1 exchange ownership (Response + session + progressive stream). Pipe-only above;
	// sole storage for exchange fields — no dual-write on Connection (Plan A §D).
	slot:           Stream_Slot,
	// H2 host (ALPN h2 after TLS Open). Engine + slots init only when negotiated
	// (h2_host_on_open); destroy on connection_destroy. h2_slots is lazy: nil until
	// ALPN-h2 open allocates [H2_SLOT_CAP]Stream_Slot. In-flight tracked per slot
	// (h2_slot_used / h2_slot_sids); h2_serial_busy only when serial mode.
	h2:              http2.Http2_Connection,
	h2_active:       bool,
	h2_out:          [dynamic]u8, // pending outbound H2 frame bytes (plaintext)
	// Read cursor into h2_out — SSL_write advances this instead of front-delete
	// (same class of O(n) memmove fix as http2 stream.pending_off).
	h2_out_off:      int,
	h2_serial_busy:  bool,        // serial mode: true while one oneshot is in flight
	h2_dispatch_sid: u32,         // last taken/respond sid (respond prefers r._slot map)
	h2_slots:        ^[H2_SLOT_CAP]Stream_Slot, // nil until h2 open; free on destroy
	h2_slot_used:    [H2_SLOT_CAP]bool,
	h2_slot_sids:    [H2_SLOT_CAP]u32, // stream id per slot; 0 when free
	h2_pt_buf:       []u8,             // SSL_read PT scratch under H2 (not scanner)
	// PR10: graceful GOAWAY drain started (engine also tracks goaway_sent).
	// Host uses this to avoid double begin + to decide close-when-idle.
	h2_goaway_drain: bool,
	// Owning worker index (for mailbox affinity); set on accept.
	worker_index:   int,
	// True while a close SQE is outstanding.
	close_pending:  bool,
	// Set on shutdown for Idle/New conns that still have a pending Recv; close on that CQE.
	// Do not set while Active (finish the request via Will_Close instead).
	// Also set when connection_close is deferred while wire.kind != .None.
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

// Loop/request cycle state. Response lives on Stream_Slot (exchange ownership).
@(private)
Loop :: struct {
	conn: ^Connection,
	req:  Request,
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

		// Backend listen attach (server_kqueue / server_io_uring / server_iocp).
		if !host_worker_attach_listen(s) {
			return
		}

		// Install listen fd as fixed file slot 0 when available.
		td.listen_fixed = false
		if proactr.ring_has_fixed_files(&td.ring) {
			if serr := proactr.ring_set_listen_file(&td.ring, i32(td.listen_fd)); serr == .None {
				td.listen_fixed = true
			} else {
				log.debugf("ring_set_listen_file failed: %v (using raw listen fd)", serr)
			}
		}

		// Native reactor backends take the thread (kqueue Darwin); else portable host loop.
		if host_worker_enter(s) {
			return
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

			// Mailbox wake: if external posts are pending for this worker, do not
			// block up to wait_timeout_ms (follow-up pin without eventfd).
			loop_wait := wait_ms
			if sync.atomic_load(&td.mail_pending) > 0 {
				loop_wait = 0
				min_complete = 0
			}
			n, werr := proactr.ring_wait(&td.ring, completions[:], min_complete, loop_wait)
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

			// Session external mailbox (D2) then app tick (e.g. async DB → respond).
			session_mailbox_drain()
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
	// H2: GOAWAY NO_ERROR drain — do not hard-close while streams / pending remain.
	for _, conn in td.conns {
		if conn.h2_active {
			h2_host_on_server_closing(conn)
			continue
		}
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

// Backend host hooks: server_io_uring | server_kqueue | server_iocp | server_unsupported.

// host_submit_accept enqueues one accept SQE (user = Server), multishot by default.
// Darwin P5: native reactor EVFILT_READ on listen (no proactr submit_accept).
// On failure returns false and does not set accept_pending (caller should set needs_accept_rearm).
@(private)
host_submit_accept :: proc(s: ^Server) -> bool {
	when ODIN_OS == .Darwin {
		return reactor_host_submit_accept(s)
	} else {
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
// When TLS Open: try SSL_read PT first (buffered app data); else arm CT recv into tls_ct_rx.
// Clear-H1: pointer RECV into scanner window (pool-backed or dynamic). FIXED_BUF not used.
// Darwin P5: native reactor EVFILT_READ (no proactr submit_recv).
@(private)
host_submit_recv :: proc(conn: ^Connection, buf: []u8) -> proactr.Error {
	assert_has_td()
	if conn.state >= .Closing {
		return .Closed
	}
	// Ciphered Open: decrypt path owns network CT; scanner only sees PT.
	if conn.tls_ssl != nil && conn.tls_pipe.state == .Open {
		if len(buf) > 0 {
			n := tls_host_try_ssl_read_into(conn, buf)
			if n > 0 {
				// SSL_read wrote into scanner free window (buf == scanner.buf[end:]).
				// Darwin reactor: do **not** reenter scanner_on_bytes here (nested
				// scan from host_submit_recv → UAF / Advanced_Too_Far). Advance end
				// and let scanner_scan tail-recurse via reactor_scan_injected.
				when ODIN_OS == .Darwin {
					s := &conn.scanner
					if s.end + n <= len(s.buf) {
						s.end += n
						conn.reactor_scan_injected = true
						return .None
					}
					// Fall through to façade-style inject if bounds fail (should not).
				}
				scanner_on_bytes(&conn.scanner, n, false)
				return .None
			}
			// n==0: WANT_READ (or hard error already closed conn).
			if conn.state >= .Closing {
				return .Closed
			}
		}
		if tls_host_arm_recv(conn) {
			return .None
		}
		return .Closed
	}
	// Clear path (or Handshake should not call this — HS arms via tls_host_arm_recv).
	when ODIN_OS == .Darwin {
		if reactor_host_arm_recv(conn, buf) {
			return .None
		}
		return .Closed
	} else {
		_, err := proactr.submit_recv(
			&td.ring,
			i32(conn.socket),
			buf,
			conn,
			conn.fixed_idx,
		)
		return err
	}
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
	case .Send, .Writev, .Sendfile:
		// Always account for the wire CQE (clear buffer ownership). Dropping
		// it after submit_close would UAF once the slab entry is recycled.
		conn := cast(^Connection)op.user
		if conn == nil {
			return
		}
		if conn.state >= .Closing {
			_conn_clear_exec(conn)
			return
		}
		kind: Wire_Kind
		switch op.kind {
		case .Send:
			// Progressive stream submits via proactr Send but stores wire.kind=.Stream.
			// Route completion using the in-flight kind, not the op kind alone.
			if conn.wire.kind == .Stream {
				kind = .Stream
			} else {
				kind = .Send
			}
		case .Writev:
			kind = .Writev
		case .Sendfile:
			kind = .Sendfile
		case .Accept, .Recv, .Close, .Timeout, .Nop:
			return
		}
		host_on_wire(conn, kind, op.result)
	case .Close:
		conn := cast(^Connection)op.user
		if conn == nil {
			return
		}
		host_on_close(conn)
	case .Timeout:
		// Session timers (effect_arm) post soft_cq Timeout with user = Session_State*.
		_session_on_timeout_cqe(op.user, op.result, c.op_id)
	case .Nop:
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
	// Keep file_send_buf allocation across accept; reset cursor only.
	c.wire.pending_send = nil
	c.wire.exec_i = 0
	c.wire.exec_n = 0
	c.wire.iov_count = 0
	c.wire.kind = .None
	c.wire.file_send_fd = -1
	c.wire.file_send_off = 0
	c.wire.file_send_remaining = 0
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

	c.worker_index = td.index
	td.conns[c.socket] = c
	log.debugf("accepted fd=%v fixed=%v conns=%d", c.socket, c.fixed_idx, len(td.conns))

	// PR5 TLS accept: mem-BIO SSL, Handshake state, arm CT recv — no clear parse yet.
	if server_tls_live(s) {
		if !tls_host_on_accept(c) {
			log.errorf("TLS accept setup failed; dropping fd=%v", c.socket)
			// No SQE yet: sync close + free.
			net.close(c.socket)
			if c.fixed_idx >= 0 {
				_ = proactr.ring_file_clear(&td.ring, c.fixed_idx)
				c.fixed_idx = -1
			}
			connection_destroy(c)
			return
		}
		if !tls_host_arm_recv(c) {
			connection_close(c)
			return
		}
		return
	}

	// Clear HTTP/1.1 path.
	conn_handle_reqs(c)
}

@(private)
host_on_recv :: proc(conn: ^Connection, result: i32) {
	// CT RECV CQE always consumes the outstanding SQE — clear flight bit first so
	// deferred close / re-arm / destroy see a free slot (kqueue oneshot discipline).
	if conn.tls_ssl != nil {
		conn.tls_ct_recv_inflight = false
	}

	if conn.state >= .Closing {
		return
	}

	// Shutdown drain / deferred close: Recv was in flight; close now (no UAF).
	if conn.close_on_io {
		connection_close(conn)
		return
	}

	// Stream PIN hangup (1-byte recv while long-lived stream is idle).
	if conn.slot.stream_pin_armed {
		conn.slot.stream_pin_armed = false
		if result <= 0 {
			if conn.slot.session != nil {
				sync.atomic_add(&session_metrics_client_gone, 1)
				_session_drive(conn, Session_Event{kind = .Client_Gone})
				if conn.slot.session != nil {
					_session_abort(conn)
				}
			} else if conn.slot.stream_open {
				connection_close(conn)
			}
			return
		}
		// Unexpected data on PIN: treat as client gone for sessions.
		if conn.slot.session != nil {
			sync.atomic_add(&session_metrics_client_gone, 1)
			_session_drive(conn, Session_Event{kind = .Client_Gone})
			if conn.slot.session != nil {
				_session_abort(conn)
			}
			return
		}
	} else if conn.slot.stream_open && conn.slot.session != nil && conn.tls_ssl == nil {
		// Clear-H1 only: stale PIN CQE after disarm for send — ignore body, resume flush.
		// TLS sessions route CT through tls_host_on_recv (hangup / close_notify).
		if conn.slot.stream_flush_pending {
			_stream_try_submit(conn)
		}
		return
	}

	// PR5 TLS: network bytes are ciphertext (into tls_ct_rx), not scanner PT.
	if conn.tls_ssl != nil {
		tls_host_on_recv(conn, result)
		return
	}

	// Detached temp: re-attach scrap for normal request parse if needed.
	if conn.temp_slot < 0 {
		_ = conn_temp_attach(conn)
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

	// Invariant: at most one of {recv, send/writev/sendfile, close}. Never
	// submit_close while wire I/O or CT RECV is outstanding — defer until completion.
	// wire.kind != .None covers Send, WRITEV, and sendfile (pending_send alone is not enough:
	// WRITEV/sendfile leave pending empty while SQE is still outstanding).
	// Platform interest (kqueue level vs proactor oneshot): conn_reactor_io_in_flight.
	if _conn_wire_in_flight(c) {
		log.debugf("connection %i close deferred (wire I/O in flight)", c.socket)
		c.close_on_io = true
		return
	}
	if conn_reactor_io_in_flight(c) {
		c.close_on_io = true
		return
	}

	// Session teardown before close (Client_Gone path may have already destroyed).
	if c.slot.session != nil {
		_session_destroy(c, after_wire = false)
	} else {
		// Orphan sse_alloc pad without session attach must not survive close.
		stream_slot_free_pad(&c.slot)
	}
	// Clear progressive stream markers so free-list reuse is clean (preserve gen).
	c.slot.stream_open = false
	c.slot.stream_ending = false
	c.slot.stream_sent = 0
	c.slot.stream_flush_pending = false
	c.slot.stream_respond_fired = false
	dual_ct_clear_meta(&c.dual_ct)
	c.tls_stream_plain_n = 0
	c.reactor_res_off = 0
	c.reactor_res_n = 0
	c.reactor_h1 = false
	c.reactor_fairness_yield = false
	// Return any in-flight Stream slab before forgetting the pointer.
	_stream_pool_abandon(c)
	c.slot.stream_pin_armed = false

	log.debugf("closing connection: %i", c.socket)
	c.state = .Closing
	_conn_clear_exec(c)
	c.close_on_io = false

	if c.close_pending {
		return
	}
	// Backend finish: reactor_host_close (kqueue Darwin) or submit_close (proactor).
	conn_close_finish(c)
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
		if l == nil || l.conn == nil {
			// Defensive: nil user_data from a stale scan callback (peer RST mid-parse).
			log.debugf("on_rline1: nil loop/conn err=%v", err)
			return
		}

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
			headers_set_close(&l.conn.slot.res.headers)
			l.conn.slot.res.status = .Not_Implemented
			respond(&l.conn.slot.res)
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
			headers_set_close(&l.conn.slot.res.headers)
			l.conn.slot.res.status = .HTTP_Version_Not_Supported
			respond(&l.conn.slot.res)
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
			headers_set_close(&l.conn.slot.res.headers)
			l.conn.slot.res.status = .Bad_Request
			respond(&l.conn.slot.res)
			return
		}

		l.conn.scanner.max_token_size -= len(token)
		if l.conn.scanner.max_token_size <= 0 {
			log.warn("request headers too large")
			headers_set_close(&l.conn.slot.res.headers)
			l.conn.slot.res.status = .Request_Header_Fields_Too_Large
			respond(&l.conn.slot.res)
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
			headers_set_close(&l.conn.slot.res.headers)
			l.conn.slot.res.status = .Bad_Request
			respond(&l.conn.slot.res)
			return
		}

		l.req.headers.readonly = true

		l.conn.scanner.max_token_size = bufio.DEFAULT_MAX_SCAN_TOKEN_SIZE

		// Automatically respond with a continue status when the client has the Expect: 100-continue header.
		if expect, ok := headers_get_unsafe(l.req.headers, "expect");
		   ok && expect == "100-continue" && l.conn.server.opts.auto_expect_continue {

			l.conn.slot.res.status = .Continue

			respond(&l.conn.slot.res)
			return
		}

		rline := &l.req.line.(Requestline)
		// An options request with the "*" is a no-op/ping request to
		// check for server capabilities and should not be sent to handlers.
		if rline.method == .Options && rline.target.(string) == "*" {
			l.conn.slot.res.status = .OK
			respond(&l.conn.slot.res)
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
			l.conn.server.handler.handle(&l.conn.server.handler, &l.req, &l.conn.slot.res)
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
	response_init(&c.slot.res, c, allocator)

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
