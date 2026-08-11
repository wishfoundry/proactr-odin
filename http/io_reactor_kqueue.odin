#+build darwin
package http

// Darwin native kqueue reactor I/O (Plan R2 P5 full wait ownership).
// Design (stable vs P5 crash): product sockets use a **per-worker reactor kqueue**
// separate from proactr's ring kqueue. udata is Connection* (or accept sentinel),
// never proactr op_id — so ring_wait/complete_apply cannot mis-decode socket events
// under multi-worker load (prior hybrid on shared kq → segfault / 0 RPS).
// Timers stay on proactr soft_cq (D5). Worker loop: kevent (reactor) + ring_wait(0)
// to harvest timeouts only. No proactr.submit_accept/recv/send/close from http/.

import "core:c"
import "core:log"
import "core:net"
import "core:sys/kqueue"
import "core:sys/posix"

import proactr "../proactr"

REACTOR_MAX_EVENTS :: 64

// udata for listen EVFILT_READ (never a valid heap pointer).
REACTOR_UDATA_ACCEPT :: rawptr(uintptr(1))

// Per-worker reactor wait state (thread-local; not on proactr Ring).
Reactor_Host :: struct {
	kq:         posix.FD,
	active:     bool,
	changelist: [dynamic]kqueue.KEvent,
	events:     [REACTOR_MAX_EVENTS]kqueue.KEvent,
	// Deferred clean_request_loop after sync oneshot finish (reentrancy guard).
	clean_q:    [dynamic]^Connection,
}

@(thread_local)
reactor_host: Reactor_Host

// (shared with Linux dense flush / io_uring residual arm).

// ---------------------------------------------------------------------------
// Reactor kqueue lifecycle
// ---------------------------------------------------------------------------

@(private)
reactor_host_init :: proc(allocator := context.allocator) -> bool {
	if reactor_host.active {
		return true
	}
	kq, err := kqueue.kqueue()
	if err != nil {
		log.errorf("reactor kqueue: %v", err)
		return false
	}
	reactor_host.kq = kq
	reactor_host.active = true
	reactor_host.changelist = make([dynamic]kqueue.KEvent, 0, 32, allocator)
	reactor_host.clean_q = make([dynamic]^Connection, 0, 16, allocator)
	return true
}

@(private)
reactor_host_destroy :: proc() {
	if !reactor_host.active {
		return
	}
	if reactor_host.kq >= 0 {
		_ = posix.close(reactor_host.kq)
		reactor_host.kq = -1
	}
	delete(reactor_host.changelist)
	reactor_host.changelist = nil
	delete(reactor_host.clean_q)
	reactor_host.clean_q = nil
	reactor_host.active = false
}

// reactor_defer_clean: queue keep-alive reentry after oneshot CT fully on wire.
// Must not call clean_request_loop while nested in scanner/handler (P5 segfault).
@(private)
reactor_defer_clean :: proc(conn: ^Connection) {
	if conn == nil || conn.state >= .Closing {
		return
	}
	if conn.reactor_need_clean {
		return
	}
	conn.reactor_need_clean = true
	append(&reactor_host.clean_q, conn)
}

// reactor_drain_deferred_clean: run after kevent batch (and after nested finishes).
@(private)
reactor_drain_deferred_clean :: proc() {
	// Loop: clean may sync-finish another pipelined oneshot → re-queue.
	for len(reactor_host.clean_q) > 0 {
		conn := pop_front(&reactor_host.clean_q)
		if conn == nil {
			continue
		}
		conn.reactor_need_clean = false
		if conn.state >= .Closing {
			continue
		}
		// Live check: may have closed between queue and drain.
		if c, ok := td.conns[conn.socket]; !ok || c != conn {
			continue
		}
		clean_request_loop(conn)
	}
}

@(private)
reactor_flush_changes :: proc() -> bool {
	if !reactor_host.active || len(reactor_host.changelist) == 0 {
		return true
	}
	_, err := kqueue.kevent(reactor_host.kq, reactor_host.changelist[:], nil, nil)
	clear(&reactor_host.changelist)
	if err != nil {
		// ENOENT: EV_DELETE for a filter that was already oneshot-delivered / never armed.
		// Not fatal — never log as error (storm under peer RST).
		if err == posix.Errno.ENOENT {
			return true
		}
		log.errorf("reactor kevent changelist: %v", err)
		return false
	}
	return true
}

// oneshot: fairness WRITE. !oneshot: product READ, residual WRITE, accept (all level).
@(private)
reactor_arm_filter :: proc(fd: i32, filter: kqueue.Filter, udata: rawptr, oneshot := true) {
	if !reactor_host.active {
		return
	}
	ev: kqueue.KEvent
	ev.ident = uintptr(fd)
	ev.filter = filter
	if oneshot {
		ev.flags = {.Add, .One_Shot, .Enable}
	} else {
		ev.flags = {.Add, .Enable}
	}
	// Product: udata unused (dispatch by fd → td.conns). Accept: REACTOR_UDATA_ACCEPT.
	ev.udata = udata
	append(&reactor_host.changelist, ev)
}

// reactor_changelist_drop_fd: remove pending arms for fd without applying kevent.
@(private)
reactor_changelist_drop_fd :: proc(fd: i32) {
	if !reactor_host.active || fd < 0 {
		return
	}
	dst := 0
	for i in 0 ..< len(reactor_host.changelist) {
		ev := reactor_host.changelist[i]
		if i32(ev.ident) == fd {
			continue
		}
		reactor_host.changelist[dst] = ev
		dst += 1
	}
	resize(&reactor_host.changelist, dst)
}

// reactor_delete_filters: EV_DELETE only filters that are still armed (oneshot may
// already be gone). Flushed in isolation so ENOENT cannot drop other fds' arms.
@(private)
reactor_delete_filters :: proc(fd: i32, del_read, del_write: bool) {
	if !reactor_host.active || fd < 0 {
		return
	}
	if !del_read && !del_write {
		return
	}
	// Apply pending arms for *other* fds first so we don't reorder unfairly,
	// then delete this fd alone.
	_ = reactor_flush_changes()

	dels: [2]kqueue.KEvent
	n := 0
	if del_read {
		dels[n].ident = uintptr(fd)
		dels[n].filter = .Read
		dels[n].flags = {.Delete}
		n += 1
	}
	if del_write {
		dels[n].ident = uintptr(fd)
		dels[n].filter = .Write
		dels[n].flags = {.Delete}
		n += 1
	}
	_, err := kqueue.kevent(reactor_host.kq, dels[:n], nil, nil)
	if err != nil && err != posix.Errno.ENOENT {
		// Non-ENOENT only; do not clear other state.
		log.debugf("reactor EV_DELETE fd=%v: %v", fd, err)
	}
}

// ---------------------------------------------------------------------------
// Accept / recv / write / close ownership
// ---------------------------------------------------------------------------

// reactor_host_submit_accept: level EVFILT_READ on shared listen (REACTOR_UDATA_ACCEPT).
// Multi-worker: each worker arms the same listen fd on its own reactor kq; nonblocking
// accept, EAGAIN = peer won. Level so idle workers see backlog without re-arm races.
@(private)
reactor_host_submit_accept :: proc(s: ^Server) -> bool {
	if !reactor_host.active {
		return false
	}
	if atomic_load(&s.closing) || td.state >= .Closing {
		return false
	}
	if atomic_load(&s.listen_closed) || td.listen_fd == {} {
		return false
	}
	reactor_arm_filter(i32(td.listen_fd), .Read, REACTOR_UDATA_ACCEPT, false)
	td.accept_pending = true
	td.needs_accept_rearm = false
	return true
}

// reactor_host_arm_recv: product READ is always level — leave armed until close.
// Already armed → refresh buffer only (no kevent). udata nil; dispatch by fd.
@(private)
reactor_host_arm_recv :: proc(conn: ^Connection, buf: []u8) -> bool {
	if conn == nil || conn.state >= .Closing {
		return false
	}
	if !reactor_host.active {
		return false
	}
	// Level already armed: refresh buffer only.
	if conn.reactor_read_armed {
		if len(buf) > 0 {
			conn.reactor_recv_buf = buf
		}
		if conn.tls_ssl != nil {
			conn.tls_ct_recv_inflight = true
		}
		return true
	}
	// First arm (TLS single-flight or clear-H1).
	if conn.tls_ssl != nil {
		if conn.tls_ct_recv_inflight {
			return true
		}
		if len(buf) == 0 {
			return false
		}
		conn.reactor_recv_buf = buf
		reactor_arm_filter(i32(conn.socket), .Read, nil, oneshot = false)
		conn.tls_ct_recv_inflight = true
		conn.reactor_read_armed = true
		conn.reactor_read_level = true
		return true
	}
	if len(buf) == 0 {
		return false
	}
	conn.reactor_recv_buf = buf
	reactor_arm_filter(i32(conn.socket), .Read, nil, oneshot = false)
	conn.reactor_read_armed = true
	conn.reactor_read_level = true
	return true
}

// reactor_host_submit_send: arm oneshot EVFILT_WRITE (clear-H1 / non-residual).
@(private)
reactor_host_submit_send :: proc(conn: ^Connection) -> proactr.Error {
	if conn == nil || conn.state >= .Closing {
		return .Closed
	}
	if !reactor_host.active {
		return .Unsupported
	}
	if len(conn.wire.pending_send) == 0 {
		return .None
	}
	if conn.wire.kind == .None {
		conn.wire.kind = .Send
	}
	// If residual level WRITE is up, leave it (covers clear after residual rare).
	if conn.reactor_write_armed {
		return .None
	}
	reactor_arm_filter(i32(conn.socket), .Write, nil, oneshot = true)
	conn.reactor_write_armed = true
	conn.reactor_write_level = false
	return .None
}

// reactor_arm_write_residual: shared in tls_reactor_residual.odin (Darwin kq branch).

// reactor_disable_write_level: EV_DELETE when residual drained (drogon disableWriting).
@(private)
reactor_disable_write_level :: proc(conn: ^Connection) {
	if conn == nil || !conn.reactor_write_level {
		conn.reactor_write_armed = false
		conn.reactor_write_level = false
		return
	}
	conn.reactor_write_armed = false
	conn.reactor_write_level = false
	reactor_delete_filters(i32(conn.socket), false, true)
}

// reactor_arm_fairness_continue: oneshot WRITE re-enters flush (not residual level).
@(private)
reactor_arm_fairness_continue :: proc(conn: ^Connection) -> bool {
	if conn == nil || conn.state >= .Closing || !reactor_host.active {
		return false
	}
	conn.reactor_fairness_yield = true
	if conn.reactor_write_armed {
		return true
	}
	reactor_arm_filter(i32(conn.socket), .Write, nil, oneshot = true)
	conn.reactor_write_armed = true
	conn.reactor_write_level = false
	return true
}

// reactor_host_close: purge kq interest, sync close + destroy (no submit_close).
// Product level READ/WRITE: EV_DELETE here only (never defer close solely for read_armed).
@(private)
reactor_host_close :: proc(conn: ^Connection) {
	if conn == nil {
		return
	}
	fd := i32(conn.socket)
	// Snapshot before clear — oneshot may already be gone (ENOENT OK); level needs EV_DELETE.
	del_r := conn.reactor_read_armed
	del_w := conn.reactor_write_armed
	conn.reactor_read_armed = false
	conn.reactor_write_armed = false
	conn.reactor_write_level = false
	conn.reactor_read_level = false
	conn.reactor_need_clean = false
	conn.reactor_recv_buf = nil
	conn.tls_ct_recv_inflight = false
	conn.close_pending = false
	reactor_changelist_drop_fd(fd)
	reactor_delete_filters(fd, del_r, del_w)
	net.close(conn.socket)
	if conn.fixed_idx >= 0 {
		_ = proactr.ring_file_clear(&td.ring, conn.fixed_idx)
		conn.fixed_idx = -1
	}
	connection_destroy(conn)
}

// ---------------------------------------------------------------------------
// Event dispatch (read before write; accept separate)
// ---------------------------------------------------------------------------

@(private)
reactor_try_accept_once :: proc() -> (client: i32, again: bool, hard: bool) {
	cfd := posix.accept(posix.FD(td.listen_fd), nil, nil)
	if cfd >= 0 {
		return i32(cfd), false, false
	}
	e := posix.errno()
	if e == .EAGAIN || e == .EWOULDBLOCK {
		return -1, true, false
	}
	return -1, false, true
}

@(private)
reactor_do_recv :: proc(conn: ^Connection) -> (n: i32, again: bool, hard: bool) {
	buf := conn.reactor_recv_buf
	if len(buf) == 0 {
		// TLS CT path: default to tls_ct_rx
		if conn.tls_ssl != nil && len(conn.tls_ct_rx) > 0 {
			buf = conn.tls_ct_rx
		} else {
			return 0, false, true
		}
	}
	rn := posix.recv(posix.FD(conn.socket), raw_data(buf), c.size_t(len(buf)), {})
	if rn >= 0 {
		return i32(rn), false, false
	}
	e := posix.errno()
	if e == .EAGAIN || e == .EWOULDBLOCK {
		return 0, true, false
	}
	if e == .EINTR {
		return 0, true, false
	}
	return -i32(e), false, true
}

// Fair accept budget per kevent turn on a shared listen fd.
// Multi-worker: take 1 so peer kqueues can win the race (avoid one worker drain-steal).
// Solo worker: deeper drain to cut kevent churn on connection storms.
REACTOR_ACCEPT_DRAIN_MULTI :: 1
REACTOR_ACCEPT_DRAIN_SOLO :: 64

@(private)
reactor_on_accept_ready :: proc(s: ^Server) {
	// Shared listen multi-kq: nonblocking accept race; EAGAIN = peer won (OK).
	// Level-triggered arm stays installed — do not clear accept_pending on success.
	accepted := 0
	limit := REACTOR_ACCEPT_DRAIN_SOLO
	if s.opts.thread_count > 1 || (s.threads != nil && len(s.threads) > 1) {
		limit = REACTOR_ACCEPT_DRAIN_MULTI
	}
	for accepted < limit {
		if atomic_load(&s.closing) || td.state >= .Closing {
			break
		}
		if atomic_load(&s.listen_closed) || td.listen_fd == {} {
			break
		}
		client, again, hard := reactor_try_accept_once()
		if again {
			// Peer worker accepted, or backlog empty.
			break
		}
		if hard {
			if !atomic_load(&s.closing) {
				log.errorf("reactor accept failed: errno")
			}
			// Disarm level filter so EMFILE/etc. cannot spin kevent forever.
			if td.listen_fd != {} {
				reactor_delete_filters(i32(td.listen_fd), true, false)
			}
			td.accept_pending = false
			td.needs_accept_rearm = !atomic_load(&s.closing) &&
				td.state < .Closing &&
				!atomic_load(&s.listen_closed)
			return
		}
		// more=true: host_on_accept must not re-arm via façade (level already armed).
		host_on_accept(s, client, proactr.COMPLETION_MORE)
		accepted += 1
	}
	if atomic_load(&s.closing) || td.state >= .Closing || atomic_load(&s.listen_closed) {
		td.accept_pending = false
		td.needs_accept_rearm = false
		return
	}
	// Level filter remains; keep accept_pending true so the host loop does not thrash re-arm.
	if !td.accept_pending {
		if !reactor_host_submit_accept(s) {
			td.needs_accept_rearm = true
		}
	}
}

// Lookup live Connection by socket fd (sole safe dispatch key after close/reuse).
@(private)
reactor_conn_by_fd :: #force_inline proc(fd: i32) -> ^Connection {
	if td == nil || fd < 0 {
		return nil
	}
	c, ok := td.conns[net.TCP_Socket(fd)]
	if !ok || c == nil || c.state >= .Closing {
		return nil
	}
	return c
}

// reactor_on_readable: product READ is always level — drain until EAGAIN; leave armed until close.
@(private)
reactor_on_readable :: proc(s: ^Server, fd: i32) {
	_ = s
	conn := reactor_conn_by_fd(fd)
	if conn == nil {
		return
	}
	if conn.close_on_io {
		connection_close(conn)
		return
	}
	// Recv until EAGAIN so level re-fires do not spin with data still pending.
	for {
		n, again, hard := reactor_do_recv(conn)
		if again {
			if conn.tls_ssl != nil && conn.state < .Closing {
				// Leave READ enabled; restore single-flight bit without kevent.
				conn.tls_ct_recv_inflight = true
				conn.reactor_read_armed = true
			}
			return
		}
		if hard {
			if n >= 0 {
				n = -1
			}
			if conn.tls_ssl != nil {
				conn.tls_ct_recv_inflight = false
			}
			host_on_recv(conn, n)
			return
		}
		// Deliver one chunk (n >= 0 includes peer EOF n==0).
		if conn.tls_ssl != nil {
			// host_on_recv may re-arm; clear inflight around the handoff.
			conn.tls_ct_recv_inflight = false
		}
		host_on_recv(conn, n)
		if conn.state >= .Closing {
			return
		}
		if conn.tls_ssl != nil {
			// Still interested in CT — keep single-flight bit without kevent re-add.
			conn.tls_ct_recv_inflight = true
			conn.reactor_read_armed = true
		}
		if n == 0 {
			return
		}
		// Clear-H1: one chunk per event (scanner window moves); level stays armed.
		// TLS: stable tls_ct_rx — loop until EAGAIN.
		if conn.tls_ssl == nil {
			return
		}
	}
}

@(private)
reactor_on_writable :: proc(s: ^Server, fd: i32) {
	_ = s
	conn := reactor_conn_by_fd(fd)
	if conn == nil {
		return
	}
	// Oneshot: clear armed. Level residual: stay armed until residual empty.
	if !conn.reactor_write_level {
		conn.reactor_write_armed = false
	}
	if conn.close_on_io {
		if conn.wire.kind == .Stream || conn.slot.stream_send_slab != nil {
			_stream_pool_abandon(conn)
		}
		_conn_clear_exec(conn)
		conn.reactor_h1 = false
		reactor_residual_clear(conn)
		reactor_disable_write_level(conn)
		conn.close_on_io = false
		if conn.state < .Closing {
			connection_close(conn)
		}
		return
	}

	// Fairness continue (empty residual): re-enter multi-window flush.
	if conn.reactor_fairness_yield && conn.tls_ssl != nil {
		conn.reactor_fairness_yield = false
		reactor_tls_flush(conn)
		return
	}

	// TLS residual: drain residual first, then continue flush (level or oneshot).
	if conn.reactor_h1 && conn.reactor_res_n > 0 {
		again, hard := reactor_write_residual(conn)
		if hard {
			_wire_fail(conn, "reactor residual WRITE failed fd=%v", conn.socket)
			return
		}
		if again {
			view := reactor_residual_view(conn)
			conn.wire.pending_send = view
			conn.reactor_h1 = true
			// Level: stay enabled. Oneshot: re-arm.
			if !conn.reactor_write_level {
				_ = reactor_arm_write_residual(conn)
			}
			return
		}
		reactor_residual_clear(conn)
		conn.wire.pending_send = nil
		conn.wire.kind = .None
		reactor_disable_write_level(conn)
		conn.reactor_h1 = true
		_ = reactor_on_send_complete(conn)
		return
	}

	// Clear-H1 / non-residual: nonblocking send of pending, then host_on_wire.
	if len(conn.wire.pending_send) == 0 {
		conn.wire.kind = .None
		return
	}
	kind := conn.wire.kind
	if kind == .None {
		kind = .Send
	}
	sent, would_block, hard := host_try_send_nb(conn, conn.wire.pending_send)
	if hard {
		_wire_fail(conn, "reactor WRITE hard fail fd=%v", conn.socket)
		return
	}
	if would_block {
		if err := reactor_host_submit_send(conn); err != .None {
			_wire_fail(conn, "reactor WRITE re-arm failed: %v", err)
		}
		return
	}
	if sent <= 0 {
		_wire_fail(conn, "reactor WRITE zero fd=%v pending=%d", conn.socket, len(conn.wire.pending_send))
		return
	}
	host_on_wire(conn, kind, i32(sent))
}

// reactor_wait: one kevent batch; process accept/read then write (R2 turn order).
// timeout_ms: <0 block, 0 peek, >0 max wait.
@(private)
reactor_wait :: proc(s: ^Server, timeout_ms: i32) -> int {
	if !reactor_host.active {
		return 0
	}
	if !reactor_flush_changes() {
		return 0
	}

	ts: posix.timespec
	tsp: ^posix.timespec
	if timeout_ms < 0 {
		tsp = nil
	} else {
		ts.tv_sec = posix.time_t(timeout_ms / 1000)
		ts.tv_nsec = i64((timeout_ms % 1000) * 1_000_000)
		tsp = &ts
	}

	ne, kerr := kqueue.kevent(reactor_host.kq, nil, reactor_host.events[:], tsp)
	if kerr != nil {
		if kerr == posix.Errno.EINTR {
			return 0
		}
		log.errorf("reactor kevent wait: %v", kerr)
		return 0
	}
	n := int(ne)
	if n <= 0 {
		return 0
	}

	// Pass 1: accept + readable (dispatch by fd → map, never raw udata Connection*)
	for i in 0 ..< n {
		ev := reactor_host.events[i]
		fd := i32(ev.ident)
		is_accept := ev.udata == REACTOR_UDATA_ACCEPT ||
			(td.listen_fd != {} && fd == i32(td.listen_fd) && ev.filter == .Read)

		if .Error in ev.flags {
			if is_accept {
				if !atomic_load(&s.closing) && !atomic_load(&s.listen_closed) {
					log.errorf("reactor accept kevent error data=%v", ev.data)
				}
				// Level filter may still be armed — drop to avoid spin after listen close.
				if td.listen_fd != {} {
					reactor_delete_filters(i32(td.listen_fd), true, false)
				}
				td.accept_pending = false
				td.needs_accept_rearm = !atomic_load(&s.closing) &&
					td.state < .Closing &&
					!atomic_load(&s.listen_closed)
				continue
			}
			if conn := reactor_conn_by_fd(fd); conn != nil {
				_wire_fail(conn, "reactor kevent error fd=%v data=%v", fd, ev.data)
			}
			continue
		}
		if ev.filter != .Read {
			continue
		}
		if is_accept {
			reactor_on_accept_ready(s)
			continue
		}
		reactor_on_readable(s, fd)
	}

	// Pass 2: writable (residual / clear send)
	for i in 0 ..< n {
		ev := reactor_host.events[i]
		if .Error in ev.flags {
			continue
		}
		if ev.filter != .Write {
			continue
		}
		fd := i32(ev.ident)
		if td.listen_fd != {} && fd == i32(td.listen_fd) {
			continue
		}
		reactor_on_writable(s, fd)
	}

	_ = reactor_flush_changes()
	// Keep-alive reentry after any sync oneshot finish in this batch.
	reactor_drain_deferred_clean()
	return n
}
