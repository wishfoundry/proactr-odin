// Server host surface forked from laytan/odin-http.
// Phase 2: proactr io_uring completion host on Linux; Unsupported elsewhere.
package http

import "base:runtime"

import "core:bufio"
import "core:bytes"
import "core:c/libc"
import "core:log"
import "core:mem"
import "core:mem/virtual"
import "core:net"
import "core:slice"
import "core:sync"
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
}

Default_Server_Opts := Server_Opts {
	auto_expect_continue = true,
	redirect_head_to_get = true,
	limit_request_line   = 8000,
	limit_headers        = 8000,
	thread_count         = 0,
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
	tcp_sock:       net.TCP_Socket,
	conn_allocator: mem.Allocator,
	handler:        Handler,

	threads:        []Server_Thread,
	// Once the server starts closing/shutdown this is set to true.
	closing:        Atomic(bool),
	// Ensures the shared listen fd is closed exactly once (shutdown or serve teardown).
	listen_closed:  Atomic(bool),
	// Threads will decrement the wait group when they have fully closed/shutdown.
	threads_closed: sync.Wait_Group,
}

// Thread-local host state: one proactr ring per worker.
Server_Thread :: struct {
	thread:      ^thread.Thread,
	server:      ^Server,
	ring:        proactr.Ring,
	conns:       map[net.TCP_Socket]^Connection,
	state:       Server_State,
	// True while an accept SQE is outstanding on this worker's ring.
	accept_pending:     bool,
	// Set when submit_accept fails so the host loop retries arming (never leave accept unarmed).
	needs_accept_rearm: bool,
	// Per-worker Date header (avoids multi-worker races on a shared buffer).
	date:               Server_Date,
	date_updated:       time.Time,
}

@(private, disabled = ODIN_DISABLE_ASSERT)
assert_has_td :: #force_inline proc(loc := #caller_location) {
	assert(td != nil && td.state != .Uninitialized, "not on a server worker thread", loc)
}

@(thread_local)
td: ^Server_Thread

Default_Endpoint := net.Endpoint {
	address = net.IP4_Any,
	port    = 8080,
}

// How many CQEs to harvest per wait.
@(private)
HOST_CQE_BATCH :: 64

// io_uring entries per worker ring.
@(private)
HOST_RING_ENTRIES :: 1024

// Poll interval while waiting so workers can observe server.closing.
@(private)
HOST_WAIT_TIMEOUT_MS :: i32(500)

// listen binds a TCP listen socket. On non-Linux, returns Unsupported without binding.
listen :: proc(
	s: ^Server,
	endpoint: net.Endpoint = Default_Endpoint,
	opts: Server_Opts = Default_Server_Opts,
) -> (err: proactr.Error) {
	when ODIN_OS != .Linux {
		_ = endpoint
		s.opts = opts
		s.conn_allocator = context.allocator
		return .Unsupported
	} else {
		s.opts = opts
		s.conn_allocator = context.allocator
		if s.opts.thread_count <= 0 {
			s.opts.thread_count = 1
		}

		sock, nerr := net.listen_tcp(endpoint)
		if nerr != nil {
			log.errorf("listen_tcp failed: %v", nerr)
			return .Init_Failed
		}
		s.tcp_sock = sock
		return .None
	}
}

// serve runs the host completion loop (one ring per worker thread).
serve :: proc(s: ^Server, h: Handler) -> (err: proactr.Error) {
	when ODIN_OS != .Linux {
		_ = s
		_ = h
		return .Unsupported
	} else {
		if atomic_load(&s.closing) {
			return .Closed
		}
		s.handler = h

		thread_count := max(1, s.opts.thread_count)
		sync.wait_group_add(&s.threads_closed, thread_count)
		s.threads = make([]Server_Thread, thread_count, s.conn_allocator)
		for i in 0 ..< thread_count {
			s.threads[i].server = s
			s.threads[i].state = .Idle
		}
		for &t in s.threads[1:] {
			t.thread = thread.create_and_start_with_poly_data2(s, &t, _server_thread_main, context)
		}

		_server_thread_main(s, &s.threads[0])

		sync.wait(&s.threads_closed)

		log.debug("server threads are done, shutting down")
		// Idempotent if server_shutdown already closed the listen fd.
		server_close_listen(s)
		for t in s.threads[1:] {
			if t.thread != nil {
				thread.destroy(t.thread)
			}
		}
		delete(s.threads)
		s.threads = nil
		return .None
	}
}

// listen_and_serve binds endpoint and runs the host completion loop.
// Non-Linux: returns .Unsupported.
listen_and_serve :: proc(
	s: ^Server,
	h: Handler,
	endpoint: net.Endpoint = Default_Endpoint,
	opts: Server_Opts = Default_Server_Opts,
) -> (err: proactr.Error) {
	listen(s, endpoint, opts) or_return
	return serve(s, h)
}

// Starts a graceful shutdown.
// Order: set closing → close listen (unblocks outstanding accept) → workers drain → serve waits.
server_shutdown :: proc(s: ^Server) {
	atomic_store(&s.closing, true)
	// Close the listen fd so pending accept SQEs complete/fail, clear accept_pending,
	// and workers can exit when conns are drained. Without this, accept can hang forever.
	server_close_listen(s)
}

// server_close_listen closes the shared listen socket at most once.
@(private)
server_close_listen :: proc(s: ^Server) {
	when ODIN_OS == .Linux {
		// CAS false → true; only the winner closes.
		_, exchanged := sync.atomic_compare_exchange_strong(&s.listen_closed.raw, false, true)
		if !exchanged {
			return
		}
		sock := s.tcp_sock
		s.tcp_sock = {}
		if sock != {} {
			net.close(sock)
		}
	} else {
		_ = s
	}
}

@(private)
on_interrupt_server: ^Server
@(private)
on_interrupt_context: runtime.Context

// Registers a signal handler to shutdown the server gracefully on interrupt signal.
server_shutdown_on_interrupt :: proc(s: ^Server) {
	on_interrupt_server = s
	on_interrupt_context = context

	libc.signal(
		libc.SIGINT,
		proc "cdecl" (_: i32) {
			context = on_interrupt_context
			server_shutdown(on_interrupt_server)
		},
	)
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
Connection :: struct {
	server:         ^Server,
	socket:         net.TCP_Socket,
	state:          Connection_State,
	scanner:        Scanner,
	temp_allocator: virtual.Arena,
	loop:           Loop,
	// Remaining response bytes for (possibly multi-CQE) send. Valid until send fully completes.
	pending_send:   []u8,
	// True while a close SQE is outstanding.
	close_pending:  bool,
	// Set on shutdown for Idle/New conns that still have a pending Recv; close on that CQE.
	// Do not set while Active (finish the request via Will_Close instead).
	close_on_io:    bool,
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
	when ODIN_OS != .Linux {
		_ = s
		_ = ttd
	} else {
		td = ttd
		td.state = .Serving
		td.conns = make(map[net.TCP_Socket]^Connection, s.conn_allocator)
		defer {
			delete(td.conns)
			td.state = .Closed
			sync.wait_group_done(&s.threads_closed)
		}

		rerr := proactr.ring_init(&td.ring, HOST_RING_ENTRIES, s.conn_allocator)
		if rerr != .None {
			log.errorf("proactr.ring_init failed: %v", rerr)
			return
		}
		defer proactr.ring_destroy(&td.ring)

		server_date_refresh()

		// Prime accept on this worker; on failure flag for retry (do not leave accept unarmed).
		if !host_submit_accept(s) {
			log.error("initial submit_accept failed; will retry")
			td.needs_accept_rearm = true
		}

		completions: [HOST_CQE_BATCH]proactr.Completion
		td.state = .Running

		for {
			closing := atomic_load(&s.closing)
			if closing {
				_server_thread_begin_shutdown(s)
			}

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

			n, werr := proactr.ring_wait(&td.ring, completions[:], min_complete, HOST_WAIT_TIMEOUT_MS)
			if werr != .None {
				log.errorf("ring_wait error: %v", werr)
				// Soft-fail: continue so closing can progress; hard-fail only if not shutting down.
				if !atomic_load(&s.closing) {
					break
				}
			}

			for i in 0 ..< n {
				c := completions[i]
				op := proactr.complete_apply(&td.ring, c)
				if op == nil {
					continue
				}
				host_dispatch(s, op, c)
				proactr.op_free(&td.ring, c.op_id)
			}

			// After CQEs, retry accept re-arm if needed (e.g. failed re-arm after accept CQE).
			if td.needs_accept_rearm {
				host_try_rearm_accept(s)
			}

			if closing && len(td.conns) == 0 && !td.accept_pending {
				break
			}
		}

		td.state = .Cleaning
		log.debug("worker host loop end")
	}
}

@(private)
_server_thread_begin_shutdown :: proc(s: ^Server) {
	when ODIN_OS == .Linux {
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
}

// host_submit_accept enqueues one accept SQE (user = Server).
// On failure returns false and does not set accept_pending (caller should set needs_accept_rearm).
@(private)
host_submit_accept :: proc(s: ^Server) -> bool {
	when ODIN_OS != .Linux {
		_ = s
		return false
	} else {
		if atomic_load(&s.closing) || td.state >= .Closing {
			return false
		}
		if atomic_load(&s.listen_closed) {
			return false
		}
		_, err := proactr.submit_accept(&td.ring, i32(s.tcp_sock), s)
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
	when ODIN_OS != .Linux {
		_ = s
	} else {
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
}

// host_submit_recv enqueues recv into the scanner buffer window.
@(private)
host_submit_recv :: proc(conn: ^Connection, buf: []u8) -> proactr.Error {
	when ODIN_OS != .Linux {
		_ = conn
		_ = buf
		return .Unsupported
	} else {
		assert_has_td()
		if conn.state >= .Closing {
			return .Closed
		}
		_, err := proactr.submit_recv(&td.ring, i32(conn.socket), buf, conn)
		return err
	}
}

// host_submit_send enqueues send of conn.pending_send.
@(private)
host_submit_send :: proc(conn: ^Connection) -> proactr.Error {
	when ODIN_OS != .Linux {
		_ = conn
		return .Unsupported
	} else {
		assert_has_td()
		if conn.state >= .Closing {
			return .Closed
		}
		if len(conn.pending_send) == 0 {
			return .None
		}
		_, err := proactr.submit_send(&td.ring, i32(conn.socket), conn.pending_send, conn)
		return err
	}
}

@(private)
host_dispatch :: proc(s: ^Server, op: ^proactr.Op, c: proactr.Completion) {
	when ODIN_OS != .Linux {
		_ = s
		_ = op
		_ = c
	} else {
		switch op.kind {
		case .Accept:
			host_on_accept(s, op.result)
		case .Recv:
			conn := cast(^Connection)op.user
			if conn == nil || conn.state >= .Closing {
				return
			}
			host_on_recv(conn, op.result)
		case .Send:
			conn := cast(^Connection)op.user
			if conn == nil || conn.state >= .Closing {
				return
			}
			host_on_send(conn, op.result)
		case .Close:
			conn := cast(^Connection)op.user
			if conn == nil {
				return
			}
			host_on_close(conn)
		case .Nop, .Cancel, .Timeout:
			// Unused by the HTTP host today.
		}
		_ = c
	}
}

@(private)
host_on_accept :: proc(s: ^Server, result: i32) {
	when ODIN_OS != .Linux {
		_ = s
		_ = result
	} else {
		td.accept_pending = false

		// Always re-arm accept unless shutting down; on failure, retry later via needs_accept_rearm.
		if !atomic_load(&s.closing) && td.state < .Closing && !atomic_load(&s.listen_closed) {
			if !host_submit_accept(s) {
				td.needs_accept_rearm = true
			}
		}

		if result < 0 {
			// -errno (incl. listen closed on shutdown). EMFILE/ENFILE: back off without panic.
			if !atomic_load(&s.closing) {
				log.errorf("accept failed: res=%d", result)
			} else {
				log.debugf("accept completed during shutdown: res=%d", result)
			}
			return
		}

		client_fd := net.TCP_Socket(result)

		// Drop connections accepted during shutdown.
		if atomic_load(&s.closing) || td.state >= .Closing {
			net.close(client_fd)
			return
		}

		c := new(Connection, s.conn_allocator)
		c.state = .New
		c.server = s
		c.socket = client_fd
		// Peer address discarded by accept (addr=nil); leave client zeroed.

		td.conns[c.socket] = c
		log.debugf("accepted fd=%v conns=%d", c.socket, len(td.conns))
		conn_handle_reqs(c)
	}
}

@(private)
host_on_recv :: proc(conn: ^Connection, result: i32) {
	when ODIN_OS != .Linux {
		_ = conn
		_ = result
	} else {
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
}

@(private)
host_on_send :: proc(conn: ^Connection, result: i32) {
	when ODIN_OS != .Linux {
		_ = conn
		_ = result
	} else {
		context.temp_allocator = virtual.arena_allocator(&conn.temp_allocator)

		if result < 0 {
			log.errorf("send error fd=%v res=%d", conn.socket, result)
			connection_close(conn)
			return
		}

		n := int(result)
		if n < len(conn.pending_send) {
			// Partial send — advance and resubmit. Buffer still owned by request arena.
			conn.pending_send = conn.pending_send[n:]
			if err := host_submit_send(conn); err != .None {
				log.errorf("submit_send (partial) failed: %v", err)
				connection_close(conn)
			}
			return
		}

		conn.pending_send = nil
		// Full response delivered; free request state only now.
		clean_request_loop(conn)
	}
}

@(private)
host_on_close :: proc(conn: ^Connection) {
	when ODIN_OS != .Linux {
		_ = conn
	} else {
		conn.close_pending = false
		connection_destroy(conn)
	}
}

@(private)
connection_close :: proc(c: ^Connection, loc := #caller_location) {
	assert_has_td(loc)

	if c.state >= .Closing {
		log.debugf("connection %i already closing/closed", c.socket)
		return
	}

	log.debugf("closing connection: %i", c.socket)
	c.state = .Closing
	c.pending_send = nil

	when ODIN_OS != .Linux {
		connection_destroy(c)
	} else {
		if c.close_pending {
			return
		}
		_, err := proactr.submit_close(&td.ring, i32(c.socket), c)
		if err != .None {
			log.errorf("submit_close failed: %v", err)
			// Fall back to synchronous close + free.
			net.close(c.socket)
			connection_destroy(c)
			return
		}
		c.close_pending = true
	}
}

@(private)
connection_destroy :: proc(c: ^Connection) {
	c.state = .Closed
	virtual.arena_destroy(&c.temp_allocator)
	scanner_destroy(&c.scanner)
	if td != nil {
		delete_key(&td.conns, c.socket)
	}
	free(c, c.server.conn_allocator)
}

// Protocol request handling. Parsing is callback-driven via Scanner;
// I/O is submitted through the proactr host (submit_recv / CQE → scanner_on_bytes).
@(private)
conn_handle_reqs :: proc(c: ^Connection) {
	scanner_init(&c.scanner, c, c.server.conn_allocator)

	err := virtual.arena_init_growing(&c.temp_allocator)
	assert(err == nil)
	context.temp_allocator = virtual.arena_allocator(&c.temp_allocator)

	conn_handle_req(c, context.temp_allocator)
}

@(private)
conn_handle_req :: proc(c: ^Connection, allocator := context.temp_allocator) {
	on_rline1 :: proc(loop: rawptr, token: string, err: bufio.Scanner_Error) {
		l := cast(^Loop)loop

		if !connection_set_state(l.conn, .Active) { return }

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

		rline, err := requestline_parse(token, context.temp_allocator)
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

		if _, ok := header_parse(&l.req.headers, token); !ok {
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

			l.conn.server.handler.handle(&l.conn.server.handler, &l.req, &l.res)
		}
	}

	c.loop.conn = c
	c.loop.res._conn = c
	c.loop.req._scanner = &c.scanner
	request_init(&c.loop.req, allocator)
	response_init(&c.loop.res, allocator)

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
@(private)
server_date_refresh :: proc() {
	assert_has_td()
	td.date.buf.buf = slice.into_dynamic(td.date.buf_backing[:])
	bytes.buffer_reset(&td.date.buf)
	date_write(bytes.buffer_to_stream(&td.date.buf), time.now())
	td.date_updated = time.now()
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
