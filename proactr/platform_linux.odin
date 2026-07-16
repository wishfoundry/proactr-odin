#+build linux
package proactr

// Linux io_uring backend: raw syscalls via core:sys/linux only.
// No liburing. No core:nbio. No core:sys/linux/uring wrapper — we own SQ/CQ mapping.

import "core:math"
import "core:sync"
import "core:sys/linux"

// Max SQ entries we request (kernel may clamp further with CLAMP).
MAX_ENTRIES :: 4096

// Setup flags for v1 (see docs/PROACTR_RING.md).
// Prefer one-issuer + deferred taskrun when the kernel supports them; fall back.
_SETUP_FLAG_SETS := [?]linux.IO_Uring_Setup_Flags{
	{.CLAMP, .SINGLE_ISSUER, .COOP_TASKRUN, .DEFER_TASKRUN},
	{.CLAMP, .SINGLE_ISSUER, .COOP_TASKRUN},
	{.CLAMP, .COOP_TASKRUN},
	{.CLAMP},
}

Ring_Impl :: struct {
	ring_fd:     linux.Fd,
	entries:     u32, // actual sq_entries after setup
	features:    linux.IO_Uring_Features,
	setup_flags: linux.IO_Uring_Setup_Flags,
	active:      bool,

	// Submission queue (mapped + local head/tail for batching).
	sq_head:  ^u32,
	sq_tail:  ^u32,
	sq_mask:  u32,
	sq_flags: ^linux.IO_Uring_Submission_Queue_Flags,
	sq_array: []u32,
	sqes:     []linux.IO_Uring_SQE,
	sqe_head: u32,
	sqe_tail: u32,

	// Completion queue.
	cq_head: ^u32,
	cq_tail: ^u32,
	cq_mask: u32,
	cqes:    []linux.IO_Uring_CQE,

	// mmap regions (SINGLE_MMAP: rings share one mapping; SQEs are separate).
	ring_mmap: []u8,
	sqes_mmap: []u8,
}

_ring_init_platform :: proc(r: ^Ring, entries: u32) -> Error {
	want := entries
	if want == 0 {
		want = DEFAULT_ENTRIES
	}
	if want > MAX_ENTRIES {
		want = MAX_ENTRIES
	}
	// Prefer power-of-two; CLAMP still lets older kernels accept odd sizes safely.
	if !math.is_power_of_two(int(want)) {
		want = u32(math.next_power_of_two(int(want)))
		if want > MAX_ENTRIES {
			want = MAX_ENTRIES
		}
	}

	params: linux.IO_Uring_Params
	fd: linux.Fd
	errno: linux.Errno
	ok := false
	for flags in _SETUP_FLAG_SETS {
		params = {}
		params.flags = flags
		fd, errno = linux.io_uring_setup(want, &params)
		if errno == .NONE {
			ok = true
			break
		}
		// EINVAL: unsupported flags / entries. Try next set.
		if errno != .EINVAL {
			r.impl = {ring_fd = -1, entries = want, active = false}
			return .Init_Failed
		}
	}
	if !ok {
		r.impl = {ring_fd = -1, entries = want, active = false}
		return .Init_Failed
	}

	// Require SINGLE_MMAP (kernel 5.4+); dual-map is not implemented in v1.
	if .SINGLE_MMAP not_in params.features {
		linux.close(fd)
		r.impl = {ring_fd = -1, entries = want, active = false}
		return .Init_Failed
	}

	sq_size := params.sq_off.array + params.sq_entries * size_of(u32)
	cq_size := params.cq_off.cqes + params.cq_entries * size_of(linux.IO_Uring_CQE)
	ring_size := max(sq_size, cq_size)

	ring_ptr, merr := linux.mmap(
		0,
		uint(ring_size),
		{.READ, .WRITE},
		{.SHARED, .POPULATE},
		fd,
		i64(linux.IORING_OFF_SQ_RING),
	)
	if merr != .NONE {
		linux.close(fd)
		r.impl = {ring_fd = -1, entries = want, active = false}
		return .Init_Failed
	}

	sqes_bytes := params.sq_entries * size_of(linux.IO_Uring_SQE)
	sqes_ptr, serr := linux.mmap(
		0,
		uint(sqes_bytes),
		{.READ, .WRITE},
		{.SHARED, .POPULATE},
		fd,
		i64(linux.IORING_OFF_SQES),
	)
	if serr != .NONE {
		linux.munmap(ring_ptr, uint(ring_size))
		linux.close(fd)
		r.impl = {ring_fd = -1, entries = want, active = false}
		return .Init_Failed
	}

	ring_bytes := cast([^]u8)ring_ptr
	sqe_bytes := cast([^]u8)sqes_ptr
	array := cast([^]u32)ring_bytes[params.sq_off.array:]
	sqes := cast([^]linux.IO_Uring_SQE)sqes_ptr
	cqes := cast([^]linux.IO_Uring_CQE)&ring_bytes[params.cq_off.cqes]

	r.impl = {
		ring_fd     = fd,
		entries     = params.sq_entries,
		features    = params.features,
		setup_flags = params.flags,
		active      = true,
		sq_head     = cast(^u32)&ring_bytes[params.sq_off.head],
		sq_tail     = cast(^u32)&ring_bytes[params.sq_off.tail],
		sq_mask     = (cast(^u32)&ring_bytes[params.sq_off.ring_mask])^,
		sq_flags    = cast(^linux.IO_Uring_Submission_Queue_Flags)&ring_bytes[params.sq_off.flags],
		sq_array    = array[:params.sq_entries],
		sqes        = sqes[:params.sq_entries],
		sqe_head    = 0,
		sqe_tail    = 0,
		cq_head     = cast(^u32)&ring_bytes[params.cq_off.head],
		cq_tail     = cast(^u32)&ring_bytes[params.cq_off.tail],
		cq_mask     = (cast(^u32)&ring_bytes[params.cq_off.ring_mask])^,
		cqes        = cqes[:params.cq_entries],
		ring_mmap   = ring_bytes[:ring_size],
		sqes_mmap   = sqe_bytes[:sqes_bytes],
	}
	return .None
}

_ring_destroy_platform :: proc(r: ^Ring) {
	if r.impl.active || r.impl.ring_fd >= 0 {
		if len(r.impl.ring_mmap) > 0 {
			linux.munmap(raw_data(r.impl.ring_mmap), uint(len(r.impl.ring_mmap)))
		}
		if len(r.impl.sqes_mmap) > 0 {
			linux.munmap(raw_data(r.impl.sqes_mmap), uint(len(r.impl.sqes_mmap)))
		}
		if r.impl.ring_fd >= 0 {
			linux.close(r.impl.ring_fd)
		}
	}
	r.impl = {
		ring_fd = -1,
		active  = false,
	}
}

// --- SQE acquisition / prep -------------------------------------------------

_get_sqe :: proc(r: ^Ring) -> (sqe: ^linux.IO_Uring_SQE, err: Error) {
	impl := &r.impl
	head := sync.atomic_load_explicit(impl.sq_head, .Acquire)
	next := impl.sqe_tail + 1
	if int(next - head) > len(impl.sqes) {
		return nil, .Submit_Failed
	}
	sqe = &impl.sqes[impl.sqe_tail & impl.sq_mask]
	sqe^ = {}
	impl.sqe_tail = next
	return sqe, .None
}

_prep_nop :: proc(r: ^Ring, id: u32) -> Error {
	sqe := _get_sqe(r) or_return
	sqe.opcode = .NOP
	sqe.user_data = u64(id)
	return .None
}

_prep_accept :: proc(r: ^Ring, id: u32, listen_fd: i32) -> Error {
	sqe := _get_sqe(r) or_return
	sqe.opcode = .ACCEPT
	sqe.fd = linux.Fd(listen_fd)
	// addr / addr_len nil → kernel still accepts; peer address discarded.
	sqe.addr = 0
	sqe.off = 0
	// Non-blocking accepted sockets with cloexec (server default).
	sqe.accept_flags = {.CLOEXEC, .NONBLOCK}
	sqe.user_data = u64(id)
	return .None
}

_prep_recv :: proc(r: ^Ring, id: u32, fd: i32, buf: []u8) -> Error {
	sqe := _get_sqe(r) or_return
	sqe.opcode = .RECV
	sqe.fd = linux.Fd(fd)
	sqe.addr = cast(u64)uintptr(raw_data(buf))
	sqe.len = u32(len(buf))
	sqe.msg_flags = {}
	sqe.user_data = u64(id)
	return .None
}

_prep_send :: proc(r: ^Ring, id: u32, fd: i32, buf: []u8) -> Error {
	sqe := _get_sqe(r) or_return
	sqe.opcode = .SEND
	sqe.fd = linux.Fd(fd)
	sqe.addr = cast(u64)uintptr(raw_data(buf))
	sqe.len = u32(len(buf))
	sqe.msg_flags = {}
	sqe.user_data = u64(id)
	return .None
}

_prep_close :: proc(r: ^Ring, id: u32, fd: i32) -> Error {
	sqe := _get_sqe(r) or_return
	sqe.opcode = .CLOSE
	sqe.fd = linux.Fd(fd)
	sqe.user_data = u64(id)
	return .None
}

_submit_nop :: proc(r: ^Ring, id: u32, op: ^Op) -> Error {
	if !r.impl.active {
		return .Unsupported
	}
	_ = op
	return _prep_nop(r, id)
}

_submit_accept :: proc(r: ^Ring, id: u32, op: ^Op) -> Error {
	if !r.impl.active {
		return .Unsupported
	}
	return _prep_accept(r, id, op.fd)
}

_submit_recv :: proc(r: ^Ring, id: u32, op: ^Op) -> Error {
	if !r.impl.active {
		return .Unsupported
	}
	return _prep_recv(r, id, op.fd, op.buf)
}

_submit_send :: proc(r: ^Ring, id: u32, op: ^Op) -> Error {
	if !r.impl.active {
		return .Unsupported
	}
	return _prep_send(r, id, op.fd, op.buf)
}

_submit_close :: proc(r: ^Ring, id: u32, op: ^Op) -> Error {
	if !r.impl.active {
		return .Unsupported
	}
	return _prep_close(r, id, op.fd)
}

// --- Submit / wait / peek ---------------------------------------------------

// Push local SQE range into the kernel SQ ring array; return pending count.
_flush_sq :: proc(r: ^Ring) -> u32 {
	impl := &r.impl
	to_submit := impl.sqe_tail - impl.sqe_head
	if to_submit != 0 {
		tail := impl.sq_tail^
		for i: u32 = 0; i < to_submit; i += 1 {
			impl.sq_array[tail & impl.sq_mask] = impl.sqe_head & impl.sq_mask
			tail += 1
			impl.sqe_head += 1
		}
		sync.atomic_store_explicit(impl.sq_tail, tail, .Release)
	}
	// Pending = local tail − kernel head (liburing style).
	return impl.sqe_tail - sync.atomic_load_explicit(impl.sq_head, .Acquire)
}

_sq_needs_enter :: proc(r: ^Ring, flags: ^linux.IO_Uring_Enter_Flags) -> bool {
	// No SQPOLL in v1 → always need enter to submit.
	if .SQPOLL not_in r.impl.setup_flags {
		return true
	}
	if .NEED_WAKEUP in sync.atomic_load_explicit(r.impl.sq_flags, .Relaxed) {
		flags^ += {.SQ_WAKEUP}
		return true
	}
	return false
}

_ring_submit :: proc(r: ^Ring) -> Error {
	if !r.impl.active {
		return .Unsupported
	}
	pending := _flush_sq(r)
	flags: linux.IO_Uring_Enter_Flags
	if !_sq_needs_enter(r, &flags) && pending > 0 {
		// SQPOLL path (unused in v1 defaults).
		return .None
	}
	if pending == 0 && flags == {} {
		return .None
	}
	_, errno := linux.io_uring_enter(r.impl.ring_fd, pending, 0, flags, nil)
	if errno != .NONE {
		return .Submit_Failed
	}
	return .None
}

_cq_ready :: proc(r: ^Ring) -> u32 {
	return sync.atomic_load_explicit(r.impl.cq_tail, .Acquire) - r.impl.cq_head^
}

_cq_needs_flush :: proc(r: ^Ring) -> bool {
	return .CQ_OVERFLOW in sync.atomic_load_explicit(r.impl.sq_flags, .Relaxed)
}

_copy_cqes_ready :: proc(r: ^Ring, out: []Completion) -> int {
	n_ready := _cq_ready(r)
	n := min(u32(len(out)), n_ready)
	if n == 0 {
		return 0
	}
	head := r.impl.cq_head^
	for i: u32 = 0; i < n; i += 1 {
		cqe := r.impl.cqes[(head + i) & r.impl.cq_mask]
		out[i] = Completion {
			op_id  = u32(cqe.user_data),
			result = cqe.res,
			flags  = transmute(u32)cqe.flags,
		}
	}
	sync.atomic_store_explicit(r.impl.cq_head, head + n, .Release)
	return int(n)
}

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

	// DEFER_TASKRUN: completions stay deferred until enter+GETEVENTS.
	// IORING_SQ_TASKRUN (TASKRUN_FLAG setups): kernel asks us to enter for task work.
	defer_taskrun := .DEFER_TASKRUN in r.impl.setup_flags
	taskrun_needed := .TASKRUN in sync.atomic_load_explicit(r.impl.sq_flags, .Relaxed)

	// Fast path: harvest already-ready CQEs (covers ring_peek and non-empty CQ).
	// Never take this path with n==0 under DEFER_TASKRUN / TASKRUN — those need
	// at least one enter+GETEVENTS so deferred work can post CQEs.
	n = _copy_cqes_ready(r, out)
	if n > 0 && (min_complete == 0 || u32(n) >= min_complete) {
		// Still flush any pending SQEs without waiting if we already have enough.
		_ = _ring_submit(r)
		return n, .None
	}

	pending := _flush_sq(r)
	flags: linux.IO_Uring_Enter_Flags
	needs := _sq_needs_enter(r, &flags)

	// Remaining completions to wait for after partial harvest, clamped to out capacity.
	wait_nr: u32 = 0
	if min_complete > u32(n) {
		wait_nr = min_complete - u32(n)
	}
	cap_left := u32(len(out) - n)
	if wait_nr > cap_left {
		wait_nr = cap_left
	}

	// GETEVENTS: needed to wait, flush overflow, or run deferred / SQ task work.
	// Under DEFER_TASKRUN always include GETEVENTS on enter — even min_complete=0 peek.
	need_getevents :=
		wait_nr > 0 || _cq_needs_flush(r) || defer_taskrun || taskrun_needed
	if need_getevents {
		flags += {.GETEVENTS}
	} else if pending == 0 && !needs {
		return n, .None
	}

	// timeout_ms < 0 → block; == 0 → no wait (GETEVENTS with wait_nr 0 still runs task work);
	// > 0 → relative timeout via enter2 EXT_ARG when available.
	if wait_nr > 0 && timeout_ms == 0 {
		// Non-blocking: do not block for completions.
		wait_nr = 0
		// Keep GETEVENTS when deferred task work or overflow may still need processing.
		if !_cq_needs_flush(r) && !defer_taskrun && !taskrun_needed {
			flags -= {.GETEVENTS}
		}
	}

	if wait_nr > 0 && timeout_ms > 0 && .EXT_ARG in r.impl.features {
		ts := linux.Time_Spec {
			time_sec  = uint(timeout_ms / 1000),
			time_nsec = uint((timeout_ms % 1000) * 1_000_000),
		}
		arg := linux.IO_Uring_Getevents_Arg {
			ts = &ts,
		}
		enter_flags := flags + {.EXT_ARG}
		_, errno := linux.io_uring_enter2(r.impl.ring_fd, pending, wait_nr, enter_flags, &arg)
		if errno != .NONE && errno != .ETIME {
			return n, .Wait_Failed
		}
	} else if pending > 0 || .GETEVENTS in flags {
		_, errno := linux.io_uring_enter(r.impl.ring_fd, pending, wait_nr, flags, nil)
		if errno != .NONE {
			// EINTR: treat as soft failure so caller can retry.
			if errno == .EINTR {
				n2 := _copy_cqes_ready(r, out[n:])
				return n + n2, .None
			}
			return n, .Wait_Failed
		}
	}

	n2 := _copy_cqes_ready(r, out[n:])
	return n + n2, .None
}
