// Package proactr: portable completion-based (proactor) async I/O.
// Model: submit ops → reap completions → dispatch. Hosts never see readiness.
// Backends (same portable API; separate from core:nbio):
//   - Linux:   io_uring
//   - Windows: IOCP
//   - Darwin / FreeBSD / OpenBSD / NetBSD: kqueue façade
//   - WASI:    host façade (only WASM port; no js_wasm32)
// Buffer rule: for Recv/Send, caller-owned buffers stay valid until the matching
// completion is harvested and operation_free is called (or the op is recycled).
// Linux registration (REGISTER_FILES / REGISTER_BUFFERS): platform_linux.odin.
// Non-Linux no-ops: registration_stub.odin (+build !linux).
package proactr

import "core:mem"

// ring_backend_name is the compiled-in engine string (ODIN_OS).
ring_backend_name :: proc() -> string {
	when ODIN_OS == .Windows {
		return "iocp"
	} else when ODIN_OS == .Linux {
		return "io_uring"
	} else when ODIN_OS == .Darwin || ODIN_OS == .FreeBSD || ODIN_OS == .NetBSD || ODIN_OS == .OpenBSD {
		return "kqueue"
	} else when ODIN_OS == .WASI {
		return "wasi"
	} else {
		return "unknown"
	}
}

// Ring is the proactor handle. One ring per worker is the intended model.
Ring :: struct {
	impl:      Ring_Impl,
	ops:       [dynamic]Operation,
	free:      [dynamic]u32,
	allocator: mem.Allocator,
	// Software timers (see timers.odin): min-heap + soft completion queue.
	timers:       [dynamic]Timer_Entry,
	soft_cq:      [dynamic]Completion,
	soft_cq_head: int,
}

Operation_Kind :: enum u8 {
	Nop,
	Accept,
	Recv,
	Send,
	Close,
	Timeout,
	// Linux: IORING_OP_WRITEV gather write (socket or file).
	Writev,
	// Linux: zero-copy file→socket via sendfile(2); EAGAIN uses POLL_ADD.
	// Other platforms: submit_sendfile returns .Unsupported.
	Sendfile,
}

Operation_Status :: enum u8 {
	Idle,
	Submitted,
	Completed,
	Cancelled,
}

// Io_Vec is a portable gather element (Linux iovec layout-compatible).
// Caller-owned; must stay valid until the Writev CQE is harvested and the op freed.
Io_Vec :: struct {
	base: rawptr,
	len:  uint,
}

// Operation is the portable in-flight / completed work unit.
// Platform-private state is NOT stored here — backends use their own tables keyed by id.
Operation :: struct {
	kind:   Operation_Kind,
	status: Operation_Status,
	// Caller cookie (e.g. ^Connection).
	user:   rawptr,
	// Result after completion: bytes, new fd, or -errno style.
	result: i32,
	// Recv/Send buffer (caller owns; valid until completion applied + free).
	buf:    []u8,
	// Accept: listen fd. Recv/Send/Close/Writev/Sendfile: connection fd (raw).
	fd:     i32,
	// Completion flags (e.g. COMPLETION_MORE).
	flags:  u32,
	// Accept: keep accepting (uring multishot / kqueue re-arm). Default false.
	continuous: bool,
	// Linux fixed-file index; -1 = raw fd. Ignored on other backends.
	fixed_idx: i32,
	// Writev: pointer to Io_Vec array + count (caller-owned until CQE).
	iov_ptr:   rawptr,
	iov_count: u32,
	// Sendfile: input file fd + starting offset + remaining byte count for this submit.
	file_fd: i32,
	offset:  i64,
	nbytes:  u64,
	// Linux Sendfile: true while waiting on POLL_ADD (POLLOUT) after EAGAIN.
	awaiting_poll: bool,
}

// Backward-compatible aliases (prefer Operation / Operation_Kind).
Op :: Operation
Op_Kind :: Operation_Kind
Op_Status :: Operation_Status

Error :: enum {
	None,
	Unsupported,
	Init_Failed,
	Submit_Failed,
	Wait_Failed,
	Invalid_Op,
	Out_Of_Ops,
	Closed,
	Register_Failed,
}

Completion :: struct {
	op_id:  u32,
	result: i32,
	flags:  u32,
}

// COMPLETION_MORE: more completions will follow for this op (continuous accept).
// Value matches IORING_CQE_F_MORE so Linux host paths stay correct.
COMPLETION_MORE :: u32(1 << 1)
CQE_F_MORE :: COMPLETION_MORE // deprecated alias

DEFAULT_ENTRIES :: 256

// Host-facing buffer sizing defaults (scanner windows, register pool requests).
// REGISTER_FILES slot count lives in platform_linux only (FIXED_FILE_SLOTS).
DEFAULT_RECV_BUF_SIZE :: 16 * 1024
DEFAULT_REG_BUF_COUNT :: 1024

// --- lifecycle --------------------------------------------------------------

ring_init :: proc(
	r: ^Ring,
	entries: u32 = DEFAULT_ENTRIES,
	allocator := context.allocator,
) -> Error {
	r^ = {}
	r.allocator = allocator
	context.allocator = allocator
	cap := int(entries) if entries > 0 else int(DEFAULT_ENTRIES)
	r.ops = make([dynamic]Operation, 0, cap, allocator)
	r.free = make([dynamic]u32, 0, cap, allocator)
	r.timers = make([dynamic]Timer_Entry, 0, 16, allocator)
	r.soft_cq = make([dynamic]Completion, 0, 16, allocator)
	return _ring_init_platform(r, entries)
}

ring_destroy :: proc(r: ^Ring) {
	when ODIN_OS == .Windows {
	// Drop platform state for any still-allocated ops (best effort).
		for i in 0 ..< len(r.ops) {
			if r.ops[i].status != .Idle {
				_platform_operation_cleanup(r, u32(i), &r.ops[i])
			}
		}
	}
	_ring_destroy_platform(r)
	delete(r.ops)
	delete(r.free)
	delete(r.timers)
	delete(r.soft_cq)
	r^ = {}
}

// --- operation slab ---------------------------------------------------------

operation_alloc :: proc(r: ^Ring) -> (id: u32, op: ^Operation, err: Error) {
	if len(r.free) > 0 {
		id = pop(&r.free)
		op = &r.ops[id]
		op^ = {}
		return id, op, .None
	}
	// Op ids are u32. Cap to max(i32) so 32-bit int platforms (wasi wasm32)
	// compile — int(max(u32)) is not representable when size_of(int)==4.
	if len(r.ops) >= int(max(i32)) {
		return 0, nil, .Out_Of_Ops
	}
	id = u32(len(r.ops))
	append(&r.ops, Operation{})
	return id, &r.ops[id], .None
}

// Deprecated name.
op_alloc :: operation_alloc

// operation_free recycles an op. Only Idle/Completed/Cancelled.
// Calls backend cleanup once for any platform-private resources.
operation_free :: proc(r: ^Ring, id: u32) {
	if int(id) >= len(r.ops) {
		return
	}
	op := &r.ops[id]
	if op.status == .Submitted {
		assert(false, "operation_free: refuse free of Submitted op")
		return
	}
	when ODIN_OS == .Windows {
		_platform_operation_cleanup(r, id, op)
	}
	// Drop any timer entry pointing at this id.
	_timer_cancel(r, id)
	op^ = {}
	append(&r.free, id)
}

op_free :: operation_free

operation_get :: proc(r: ^Ring, id: u32) -> ^Operation {
	if int(id) >= len(r.ops) {
		return nil
	}
	return &r.ops[id]
}

op_get :: operation_get

completion_has_more :: #force_inline proc(c: Completion) -> bool {
	return (c.flags & COMPLETION_MORE) != 0
}

// Software timers: timers.odin (submit_timeout, cancel_timeout, soft_cq, heap).

// --- submit helpers ---------------------------------------------------------

// _begin_submit allocates and marks Submitted; caller fills fields then _finish_submit.
_begin_submit :: proc(r: ^Ring, kind: Operation_Kind, user: rawptr) -> (id: u32, op: ^Operation, err: Error) {
	id, op, err = operation_alloc(r)
	if err != .None {
		return 0, nil, err
	}
	op.kind = kind
	op.status = .Submitted
	op.user = user
	op.fixed_idx = -1
	op.continuous = false
	return id, op, .None
}

_finish_submit :: proc(r: ^Ring, id: u32, op: ^Operation, platform_err: Error) -> (u32, Error) {
	if platform_err != .None {
		op.status = .Idle
		when ODIN_OS == .Windows {
			// No platform resources yet if submit failed before arming — cleanup still safe.
			_platform_operation_cleanup(r, id, op)
		}
		_timer_cancel(r, id)
		op^ = {}
		append(&r.free, id)
		return 0, platform_err
	}
	return id, .None
}

submit_nop :: proc(r: ^Ring, user: rawptr = nil) -> (id: u32, err: Error) {
	oid, op, e := _begin_submit(r, .Nop, user)
	if e != .None {
		return 0, e
	}
	return _finish_submit(r, oid, op, _submit_nop(r, oid, op))
}

// continuous: keep accepting when the backend supports it (uring multishot / kqueue re-arm).
// fixed_listen_idx: Linux fixed-file slot for listen; -1 = raw fd.
submit_accept :: proc(
	r: ^Ring,
	listen_fd: i32,
	user: rawptr = nil,
	continuous := false,
	fixed_listen_idx: i32 = -1,
) -> (id: u32, err: Error) {
	oid, op, e := _begin_submit(r, .Accept, user)
	if e != .None {
		return 0, e
	}
	op.fd = listen_fd
	op.continuous = continuous
	op.fixed_idx = fixed_listen_idx
	return _finish_submit(r, oid, op, _submit_accept(r, oid, op))
}

submit_recv :: proc(
	r: ^Ring,
	fd: i32,
	buf: []u8,
	user: rawptr = nil,
	fixed_idx: i32 = -1,
) -> (id: u32, err: Error) {
	oid, op, e := _begin_submit(r, .Recv, user)
	if e != .None {
		return 0, e
	}
	op.fd = fd
	op.buf = buf
	op.fixed_idx = fixed_idx
	return _finish_submit(r, oid, op, _submit_recv(r, oid, op))
}

submit_send :: proc(
	r: ^Ring,
	fd: i32,
	buf: []u8,
	user: rawptr = nil,
	fixed_idx: i32 = -1,
) -> (id: u32, err: Error) {
	oid, op, e := _begin_submit(r, .Send, user)
	if e != .None {
		return 0, e
	}
	op.fd = fd
	op.buf = buf
	op.fixed_idx = fixed_idx
	return _finish_submit(r, oid, op, _submit_send(r, oid, op))
}

submit_close :: proc(
	r: ^Ring,
	fd: i32,
	user: rawptr = nil,
	fixed_idx: i32 = -1,
) -> (id: u32, err: Error) {
	oid, op, e := _begin_submit(r, .Close, user)
	if e != .None {
		return 0, e
	}
	op.fd = fd
	op.fixed_idx = fixed_idx
	return _finish_submit(r, oid, op, _submit_close(r, oid, op))
}

// submit_writev enqueues a gather write (Linux: IORING_OP_WRITEV).
// iovecs must remain valid until the matching completion is harvested and the op freed.
// fixed_idx: Linux fixed-file slot for the socket/fd; -1 = raw fd.
// Non-Linux backends return .Unsupported.
submit_writev :: proc(
	r: ^Ring,
	fd: i32,
	iovecs: []Io_Vec,
	user: rawptr = nil,
	fixed_idx: i32 = -1,
) -> (id: u32, err: Error) {
	if len(iovecs) == 0 {
		return 0, .Invalid_Op
	}
	oid, op, e := _begin_submit(r, .Writev, user)
	if e != .None {
		return 0, e
	}
	op.fd = fd
	op.fixed_idx = fixed_idx
	op.iov_ptr = raw_data(iovecs)
	op.iov_count = u32(len(iovecs))
	return _finish_submit(r, oid, op, _submit_writev(r, oid, op))
}

// submit_sendfile zero-copies file_fd[offset..offset+length) to sock_fd.
// Linux: sendfile(2) + soft_cq / POLL_ADD on EAGAIN.
// Darwin: sendfile(2) + kqueue EVFILT_WRITE on EAGAIN (kqueue façade).
// Platform drives until progress cap / EAGAIN / done; host advances remainder.
// Other backends return .Unsupported (host falls back to pread+send).
// fixed_idx: Linux POLL socket slot only; sendfile always uses raw fds.
submit_sendfile :: proc(
	r: ^Ring,
	sock_fd: i32,
	file_fd: i32,
	offset: i64,
	length: u64,
	user: rawptr = nil,
	fixed_idx: i32 = -1,
) -> (id: u32, err: Error) {
	if file_fd < 0 || length == 0 {
		return 0, .Invalid_Op
	}
	oid, op, e := _begin_submit(r, .Sendfile, user)
	if e != .None {
		return 0, e
	}
	op.fd = sock_fd
	op.fixed_idx = fixed_idx
	op.file_fd = file_fd
	op.offset = offset
	op.nbytes = length
	op.awaiting_poll = false
	return _finish_submit(r, oid, op, _submit_sendfile(r, oid, op))
}

// --- wait / complete --------------------------------------------------------
// submit_timeout / cancel_timeout: timers.odin

ring_submit :: proc(r: ^Ring) -> Error {
	return _ring_submit(r)
}

// ring_wait harvests software completions (timers) then platform CQEs.
// timeout_ms: <0 block, 0 peek, >0 max wait (monotonic remaining-time retry).
ring_wait :: proc(
	r: ^Ring,
	out: []Completion,
	min_complete: u32 = 1,
	timeout_ms: i32 = -1,
) -> (n: int, err: Error) {
	if len(out) == 0 {
		return 0, .None
	}

	deadline_ns: i64 = 0
	if timeout_ms > 0 {
		deadline_ns = _mono_ns() + i64(timeout_ms) * 1_000_000
	}

	n = 0
	for {
		_timer_fire_due(r)
		n = _soft_drain(r, out, n)

		wait_ms := _ring_wait_budget_ms(r, timeout_ms, deadline_ns)
		if _ring_wait_should_stop(r, n, min_complete, timeout_ms, deadline_ns, wait_ms) {
			return n, .None
		}

		pn, perr := _ring_wait(r, out[n:], 1 if min_complete > 0 else 0, wait_ms)
		if perr != .None && n == 0 {
			return n, perr
		}
		n += pn
		// Blocking backends (uring/kqueue/iocp) wait inside _ring_wait.
		// WASI _ring_wait sleeps when empty so timers can re-fire next iteration.
	}
}

ring_peek :: proc(r: ^Ring, out: []Completion) -> (n: int, err: Error) {
	return ring_wait(r, out, 0, 0)
}

// ring_next_timer_ms: ms until next software timer (D5 merge wait for reactor hosts).
// has=false when no pending timer. ms=0 means due now.
ring_next_timer_ms :: proc(r: ^Ring) -> (ms: i32, has: bool) {
	return _timer_next_ms(r)
}

complete_apply :: proc(r: ^Ring, c: Completion) -> ^Operation {
	op := operation_get(r, c.op_id)
	if op == nil {
		return nil
	}
	op.result = c.result
	op.flags = c.flags
	if completion_has_more(c) {
		return op
	}
	op.status = .Completed
	return op
}
