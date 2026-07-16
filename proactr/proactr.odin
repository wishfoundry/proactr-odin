// Package proactr: completion-based (proactor) async I/O, io_uring-first.
//
// Model: submit ops → reap CQEs → dispatch. No readiness re-arm on the hot path.
package proactr

import "core:mem"

// Ring is the proactor handle. One ring per worker is the intended v1 model.
Ring :: struct {
	// Platform-private fields filled by platform_* files.
	impl: Ring_Impl,
	// In-flight ops slab (dense ids → user_data).
	ops:  [dynamic]Op,
	// Free list of op indices.
	free: [dynamic]u32,
	// Allocator for op buffers / dynamic state.
	allocator: mem.Allocator,
}

Op_Kind :: enum u8 {
	Nop,
	Accept,
	Recv,
	Send,
	Close,
	Cancel,
	Timeout,
	// Future: Connect, Writev, Openat, Statx, …
}

Op_Status :: enum u8 {
	Idle,
	Submitted,
	Completed,
	Cancelled,
}

// Op is user-visible state keyed by user_data on the CQ.
Op :: struct {
	kind:   Op_Kind,
	status: Op_Status,
	// Caller-supplied cookie (e.g. ^Conn). Opaque to the ring.
	user:   rawptr,
	// Result after completion (bytes / fd / -errno style).
	result: i32,
	// Buffer for Recv/Send (caller owns memory; hard rule: valid until CQE).
	buf:    []u8,
	// Accept: listening fd. Recv/Send/Close: connection fd.
	fd:     i32,
	flags:  u32,
}

Error :: enum {
	None,
	Unsupported, // non-Linux / missing io_uring
	Init_Failed,
	Submit_Failed,
	Wait_Failed,
	Invalid_Op,
	Out_Of_Ops,
	Closed,
}

// Completion is a drained CQ entry mapped to an Op.
Completion :: struct {
	op_id:  u32,
	result: i32, // bytes transferred, new fd, or negative errno
	flags:  u32, // platform CQ flags
}

DEFAULT_ENTRIES :: 256

// ring_init creates a proactor ring. entries is SQ/CQ sizing hint.
ring_init :: proc(
	r: ^Ring,
	entries: u32 = DEFAULT_ENTRIES,
	allocator := context.allocator,
) -> Error {
	r^ = {}
	r.allocator = allocator
	context.allocator = allocator
	r.ops = make([dynamic]Op, 0, int(entries), allocator)
	r.free = make([dynamic]u32, 0, int(entries), allocator)
	return _ring_init_platform(r, entries)
}

ring_destroy :: proc(r: ^Ring) {
	_ring_destroy_platform(r)
	delete(r.ops)
	delete(r.free)
	r^ = {}
}

// op_alloc reserves an Op slot; returns dense id used as user_data.
op_alloc :: proc(r: ^Ring) -> (id: u32, op: ^Op, err: Error) {
	if len(r.free) > 0 {
		id = pop(&r.free)
		op = &r.ops[id]
		op^ = {}
		return id, op, .None
	}
	if len(r.ops) >= int(max(u32)) {
		return 0, nil, .Out_Of_Ops
	}
	id = u32(len(r.ops))
	append(&r.ops, Op{})
	return id, &r.ops[id], .None
}

// op_free returns an op slot to the free list.
// Only Idle / Completed / Cancelled may be freed. Submitted (in-flight) is refused:
// recycling the id while a CQE can still arrive would corrupt user_data.
op_free :: proc(r: ^Ring, id: u32) {
	if int(id) >= len(r.ops) {
		return
	}
	op := &r.ops[id]
	if op.status == .Submitted {
		assert(false, "op_free: refuse free of Submitted op")
		return
	}
	op^ = {}
	append(&r.free, id)
}

op_get :: proc(r: ^Ring, id: u32) -> ^Op {
	if int(id) >= len(r.ops) {
		return nil
	}
	return &r.ops[id]
}

// submit_* enqueue SQEs (may not enter the kernel until ring_submit / ring_wait).
// On platform error the reserved op is freed and id is zero.

submit_nop :: proc(r: ^Ring, user: rawptr = nil) -> (id: u32, err: Error) {
	op: ^Op
	id, op, err = op_alloc(r)
	if err != .None {
		return 0, err
	}
	op.kind = .Nop
	op.status = .Submitted
	op.user = user
	err = _submit_nop(r, id, op)
	if err != .None {
		// Prep failed before any SQE was reserved; not in-flight.
		op.status = .Idle
		op_free(r, id)
		return 0, err
	}
	return id, .None
}

submit_accept :: proc(r: ^Ring, listen_fd: i32, user: rawptr = nil) -> (id: u32, err: Error) {
	op: ^Op
	id, op, err = op_alloc(r)
	if err != .None {
		return 0, err
	}
	op.kind = .Accept
	op.status = .Submitted
	op.user = user
	op.fd = listen_fd
	err = _submit_accept(r, id, op)
	if err != .None {
		op.status = .Idle
		op_free(r, id)
		return 0, err
	}
	return id, .None
}

submit_recv :: proc(r: ^Ring, fd: i32, buf: []u8, user: rawptr = nil) -> (id: u32, err: Error) {
	op: ^Op
	id, op, err = op_alloc(r)
	if err != .None {
		return 0, err
	}
	op.kind = .Recv
	op.status = .Submitted
	op.user = user
	op.fd = fd
	op.buf = buf
	err = _submit_recv(r, id, op)
	if err != .None {
		op.status = .Idle
		op_free(r, id)
		return 0, err
	}
	return id, .None
}

submit_send :: proc(r: ^Ring, fd: i32, buf: []u8, user: rawptr = nil) -> (id: u32, err: Error) {
	op: ^Op
	id, op, err = op_alloc(r)
	if err != .None {
		return 0, err
	}
	op.kind = .Send
	op.status = .Submitted
	op.user = user
	op.fd = fd
	op.buf = buf
	err = _submit_send(r, id, op)
	if err != .None {
		op.status = .Idle
		op_free(r, id)
		return 0, err
	}
	return id, .None
}

submit_close :: proc(r: ^Ring, fd: i32, user: rawptr = nil) -> (id: u32, err: Error) {
	op: ^Op
	id, op, err = op_alloc(r)
	if err != .None {
		return 0, err
	}
	op.kind = .Close
	op.status = .Submitted
	op.user = user
	op.fd = fd
	err = _submit_close(r, id, op)
	if err != .None {
		op.status = .Idle
		op_free(r, id)
		return 0, err
	}
	return id, .None
}

// ring_submit flushes the SQ (io_uring_enter submit).
ring_submit :: proc(r: ^Ring) -> Error {
	return _ring_submit(r)
}

// ring_wait blocks until at least min_complete CQEs (or timeout_ms if >= 0).
// Completions are written into out (up to len(out)); returns count.
ring_wait :: proc(
	r: ^Ring,
	out: []Completion,
	min_complete: u32 = 1,
	timeout_ms: i32 = -1,
) -> (n: int, err: Error) {
	return _ring_wait(r, out, min_complete, timeout_ms)
}

// ring_peek drains available CQEs without blocking.
ring_peek :: proc(r: ^Ring, out: []Completion) -> (n: int, err: Error) {
	return _ring_wait(r, out, 0, 0)
}

// complete_apply marks the Op completed and stores result; caller dispatches.
complete_apply :: proc(r: ^Ring, c: Completion) -> ^Op {
	op := op_get(r, c.op_id)
	if op == nil {
		return nil
	}
	op.status = .Completed
	op.result = c.result
	return op
}
