#+build darwin, freebsd, openbsd, netbsd
package proactr

// kqueue proactor façade: readiness + nonblocking perform → Completions.
// Sockets must already be O_NONBLOCK (host responsibility).

import "core:c"
import "core:sys/kqueue"
import "core:sys/posix"

_ETIME :: i32(62)
_EINVAL :: i32(22)
MAX_EVENTS :: 64

Ring_Impl :: struct {
	kq:         posix.FD,
	active:     bool,
	entries:    u32,
	cq:         [dynamic]Completion,
	changelist: [dynamic]kqueue.KEvent,
}

_ring_init_platform :: proc(r: ^Ring, entries: u32) -> Error {
	kq, err := kqueue.kqueue()
	if err != nil {
		r.impl = {kq = -1, active = false}
		return .Init_Failed
	}
	want := entries if entries > 0 else DEFAULT_ENTRIES
	r.impl = {
		kq         = kq,
		active     = true,
		entries    = want,
		cq         = make([dynamic]Completion, 0, int(want), r.allocator),
		changelist = make([dynamic]kqueue.KEvent, 0, 32, r.allocator),
	}
	return .None
}

_ring_destroy_platform :: proc(r: ^Ring) {
	if r.impl.kq >= 0 {
		_ = posix.close(r.impl.kq)
		r.impl.kq = -1
	}
	delete(r.impl.cq)
	delete(r.impl.changelist)
	r.impl.active = false
}


// --- helpers ----------------------------------------------------------------

_kq_post :: proc(r: ^Ring, id: u32, result: i32, flags: u32 = 0) {
	append(&r.impl.cq, Completion{op_id = id, result = result, flags = flags})
}

_kq_errno_neg :: proc() -> i32 {
	e := posix.errno()
	if e == .NONE {
		return -_EINVAL
	}
	return -i32(e)
}

// udata packs op_id+1 so a zero udata is never a valid op.
_kq_udata :: proc(op_id: u32) -> rawptr {
	return transmute(rawptr)uintptr(op_id + 1)
}

_kq_op_id :: proc(udata: rawptr) -> (id: u32, ok: bool) {
	v := u32(uintptr(udata))
	if v == 0 {
		return 0, false
	}
	return v - 1, true
}

_kq_arm :: proc(r: ^Ring, fd: i32, filter: kqueue.Filter, op_id: u32) {
	ev: kqueue.KEvent
	ev.ident = uintptr(fd)
	ev.filter = filter
	ev.flags = {.Add, .One_Shot, .Enable}
	ev.udata = _kq_udata(op_id)
	append(&r.impl.changelist, ev)
}

_kq_try_recv :: proc(fd: i32, buf: []u8) -> (n: i32, again: bool) {
	if len(buf) == 0 {
		return 0, false
	}
	rn := posix.recv(posix.FD(fd), raw_data(buf), c.size_t(len(buf)), {})
	if rn >= 0 {
		return i32(rn), false
	}
	e := posix.errno()
	if e == .EAGAIN || e == .EWOULDBLOCK {
		return 0, true
	}
	return _kq_errno_neg(), false
}

_kq_try_send :: proc(fd: i32, buf: []u8) -> (n: i32, again: bool) {
	if len(buf) == 0 {
		return 0, false
	}
	sn := posix.send(posix.FD(fd), raw_data(buf), c.size_t(len(buf)), {})
	if sn >= 0 {
		return i32(sn), false
	}
	e := posix.errno()
	if e == .EAGAIN || e == .EWOULDBLOCK {
		return 0, true
	}
	return _kq_errno_neg(), false
}

_kq_try_accept :: proc(listen_fd: i32) -> (client: i32, again: bool) {
	cfd := posix.accept(posix.FD(listen_fd), nil, nil)
	if cfd >= 0 {
		return i32(cfd), false
	}
	e := posix.errno()
	if e == .EAGAIN || e == .EWOULDBLOCK {
		return -1, true
	}
	return _kq_errno_neg(), false
}

_kq_drain :: proc(r: ^Ring, out: []Completion) -> int {
	n := 0
	for n < len(out) && len(r.impl.cq) > 0 {
		out[n] = pop_front(&r.impl.cq)
		n += 1
	}
	return n
}

_kq_flush_changes :: proc(r: ^Ring) -> Error {
	if len(r.impl.changelist) == 0 {
		return .None
	}
	_, err := kqueue.kevent(r.impl.kq, r.impl.changelist[:], nil, nil)
	clear(&r.impl.changelist)
	if err != nil {
		return .Submit_Failed
	}
	return .None
}

// --- submit -----------------------------------------------------------------

_submit_nop :: proc(r: ^Ring, id: u32, op: ^Operation) -> Error {
	if !r.impl.active {
		return .Unsupported
	}
	_ = op
	_kq_post(r, id, 0)
	return .None
}

_submit_accept :: proc(r: ^Ring, id: u32, op: ^Operation) -> Error {
	if !r.impl.active {
		return .Unsupported
	}
	client, again := _kq_try_accept(op.fd)
	if again {
		_kq_arm(r, op.fd, .Read, id)
		return .None
	}
	if client >= 0 && op.continuous {
		_kq_post(r, id, client, COMPLETION_MORE)
		_kq_arm(r, op.fd, .Read, id)
	} else {
		_kq_post(r, id, client, 0)
	}
	return .None
}

_submit_recv :: proc(r: ^Ring, id: u32, op: ^Operation) -> Error {
	if !r.impl.active {
		return .Unsupported
	}
	n, again := _kq_try_recv(op.fd, op.buf)
	if again {
		_kq_arm(r, op.fd, .Read, id)
		return .None
	}
	_kq_post(r, id, n)
	return .None
}

_submit_send :: proc(r: ^Ring, id: u32, op: ^Operation) -> Error {
	if !r.impl.active {
		return .Unsupported
	}
	n, again := _kq_try_send(op.fd, op.buf)
	if again {
		_kq_arm(r, op.fd, .Write, id)
		return .None
	}
	_kq_post(r, id, n)
	return .None
}

_submit_close :: proc(r: ^Ring, id: u32, op: ^Operation) -> Error {
	if !r.impl.active {
		return .Unsupported
	}
	rc := posix.close(posix.FD(op.fd))
	if rc != .OK {
		_kq_post(r, id, _kq_errno_neg())
	} else {
		_kq_post(r, id, 0)
	}
	return .None
}

_ring_submit :: proc(r: ^Ring) -> Error {
	if !r.impl.active {
		return .Unsupported
	}
	return _kq_flush_changes(r)
}

_kq_handle_event :: proc(r: ^Ring, ev: kqueue.KEvent) {
	op_id, ok := _kq_op_id(ev.udata)
	if !ok {
		return
	}
	op := operation_get(r, op_id)
	if op == nil || op.status != .Submitted {
		return
	}

	if .Error in ev.flags {
		eno := i32(ev.data)
		if eno == 0 {
			eno = _EINVAL
		}
		_kq_post(r, op_id, -eno)
		return
	}

	switch op.kind {
	case .Accept:
		client, again := _kq_try_accept(op.fd)
		if again {
			_kq_arm(r, op.fd, .Read, op_id)
			return
		}
		if client >= 0 && op.continuous {
			_kq_post(r, op_id, client, COMPLETION_MORE)
			_kq_arm(r, op.fd, .Read, op_id)
		} else {
			_kq_post(r, op_id, client, 0)
		}
	case .Recv:
		n, again := _kq_try_recv(op.fd, op.buf)
		if again {
			_kq_arm(r, op.fd, .Read, op_id)
			return
		}
		_kq_post(r, op_id, n)
	case .Send:
		n, again := _kq_try_send(op.fd, op.buf)
		if again {
			_kq_arm(r, op.fd, .Write, op_id)
			return
		}
		_kq_post(r, op_id, n)
	case .Nop, .Close, .Timeout:
		// Not kevent-driven (Timeout is software).
		_kq_post(r, op_id, 0)
	}
}

// Platform wait: harvest at most one kevent batch into software CQ, then drain.
// Portable ring_wait handles min_complete / timers around this.
_ring_wait :: proc(
	r: ^Ring,
	out: []Completion,
	min_complete: u32,
	timeout_ms: i32,
) -> (n: int, err: Error) {
	if !r.impl.active {
		return 0, .Unsupported
	}
	if len(out) == 0 {
		return 0, .None
	}

	// Already-queued synthetic completions.
	n = _kq_drain(r, out)
	if u32(n) >= min_complete || (min_complete == 0 && timeout_ms == 0 && n > 0) {
		return n, .None
	}
	if min_complete == 0 && timeout_ms == 0 && n == 0 {
		// Peek with empty CQ: still flush changelist non-blocking.
		_ = _kq_flush_changes(r)
		return _kq_drain(r, out), .None
	}

	if serr := _kq_flush_changes(r); serr != .None {
		return n, serr
	}

	events: [MAX_EVENTS]kqueue.KEvent
	ts: posix.timespec
	tsp: ^posix.timespec
	if timeout_ms < 0 {
		tsp = nil
	} else {
		ts.tv_sec = posix.time_t(timeout_ms / 1000)
		ts.tv_nsec = i64((timeout_ms % 1000) * 1_000_000)
		tsp = &ts
	}

	// Apply re-arms from previous handle without blocking if any slipped in.
	changes := r.impl.changelist[:]
	ne, kerr := kqueue.kevent(r.impl.kq, changes, events[:], tsp)
	clear(&r.impl.changelist)
	if kerr != nil {
		// EINTR (e.g. SIGINT/SIGTERM): soft return so the host can check shutdown flags.
		if kerr == posix.Errno.EINTR {
			return n, .None
		}
		if n > 0 {
			return n, .None
		}
		return n, .Wait_Failed
	}
	for i in 0 ..< int(ne) {
		_kq_handle_event(r, events[i])
	}
	_ = _kq_flush_changes(r)

	got := _kq_drain(r, out[n:])
	return n + got, .None
}
