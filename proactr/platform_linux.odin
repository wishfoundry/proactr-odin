#+build linux
package proactr

// Linux io_uring backend: raw syscalls via core:sys/linux only.
// No liburing. No core:nbio. No core:sys/linux/uring wrapper — we own SQ/CQ mapping.

import "base:intrinsics"

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

// Kernel struct for IORING_REGISTER_FILES_UPDATE.
Files_Update :: struct {
	offset: u32,
	resv:   u32,
	fds:    u64, // pointer to []i32 (s32 fds)
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

	// Registered files (slot 0 = listen; 1.. = connections). Optional.
	files:     []i32,
	files_ok:  bool,
	file_free: [dynamic]u32, // free slots >= 1

	// Registered recv buffer pool. Optional.
	recv_pool:      []u8,
	recv_iovs:      []linux.IO_Vec,
	recv_buf_size:  u32,
	buffers_ok:     bool,
	buf_free:       [dynamic]u32,
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
		files_ok    = false,
		buffers_ok  = false,
	}

	// Best-effort REGISTER_FILES; non-fatal if the kernel/rlimit rejects it.
	_try_register_files(r)
	return .None
}

_try_register_files :: proc(r: ^Ring) {
	// REGISTER_FILES is charged against RLIMIT_NOFILE; requesting more than
	// the soft limit fails entirely (common default soft limit is 1024).
	count := int(FIXED_FILE_SLOTS)
	lim: linux.RLimit
	if linux.getrlimit(.NOFILE, &lim) == .NONE {
		// Headroom for stdio, ring fd, listen fd, misc opens.
		headroom: uint = 64
		avail := lim.cur
		if avail > headroom {
			avail -= headroom
		} else if avail > 2 {
			avail -= 2
		}
		if uint(count) > avail {
			count = int(avail)
		}
	}
	if count < 2 {
		// Need at least slot 0 (listen) + one connection slot.
		r.impl.files = nil
		r.impl.files_ok = false
		return
	}

	fds := make([]i32, count, r.allocator)
	for i in 0 ..< count {
		fds[i] = -1
	}
	errno := linux.io_uring_register(r.impl.ring_fd, .REGISTER_FILES, raw_data(fds), u32(count))
	if errno != .NONE {
		delete(fds)
		r.impl.files = nil
		r.impl.files_ok = false
		return
	}
	r.impl.files = fds
	r.impl.files_ok = true
	r.impl.file_free = make([dynamic]u32, 0, count - 1, r.allocator)
	// Slot 0 reserved for listen; free list is 1..count-1
	for i in 1 ..< count {
		append(&r.impl.file_free, u32(i))
	}
}

_ring_destroy_platform :: proc(r: ^Ring) {
	if r.impl.active || r.impl.ring_fd >= 0 {
		if r.impl.buffers_ok {
			_ = linux.io_uring_register(r.impl.ring_fd, .UNREGISTER_BUFFERS, nil, 0)
		}
		if r.impl.files_ok {
			_ = linux.io_uring_register(r.impl.ring_fd, .UNREGISTER_FILES, nil, 0)
		}
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
	if r.impl.files != nil {
		delete(r.impl.files)
	}
	delete(r.impl.file_free)
	if r.impl.recv_pool != nil {
		delete(r.impl.recv_pool)
	}
	if r.impl.recv_iovs != nil {
		delete(r.impl.recv_iovs)
	}
	delete(r.impl.buf_free)
	r.impl = {
		ring_fd = -1,
		active  = false,
	}
}

// --- Registration (Linux public API; sole home for these symbols) -----------
// REGISTER_FILES / REGISTER_BUFFERS. Non-Linux: registration_stub.odin.

// Max fixed-file table size (clamped to RLIMIT_NOFILE − headroom at init).
FIXED_FILE_SLOTS :: 4096

ring_has_fixed_files :: proc(r: ^Ring) -> bool {
	return r.impl.files_ok
}

ring_set_listen_file :: proc(r: ^Ring, fd: i32) -> Error {
	if !r.impl.files_ok {
		return .Unsupported
	}
	return _files_update(r, 0, fd)
}

ring_file_alloc :: proc(r: ^Ring) -> (slot: i32, ok: bool) {
	if !r.impl.files_ok || len(r.impl.file_free) == 0 {
		return -1, false
	}
	s := pop(&r.impl.file_free)
	return i32(s), true
}

ring_file_set :: proc(r: ^Ring, slot: i32, fd: i32) -> Error {
	if !r.impl.files_ok || slot < 0 || int(slot) >= len(r.impl.files) {
		return .Invalid_Op
	}
	return _files_update(r, u32(slot), fd)
}

ring_file_clear :: proc(r: ^Ring, slot: i32) -> Error {
	if !r.impl.files_ok || slot < 1 || int(slot) >= len(r.impl.files) {
		return .Invalid_Op
	}
	// Idempotent: already free → success without free-list append (no duplicates).
	if r.impl.files[slot] < 0 {
		return .None
	}
	err := _files_update(r, u32(slot), -1)
	if err != .None {
		return err
	}
	append(&r.impl.file_free, u32(slot))
	return .None
}

_files_update :: proc(r: ^Ring, offset: u32, fd: i32) -> Error {
	if !r.impl.files_ok {
		return .Unsupported
	}
	if int(offset) >= len(r.impl.files) {
		return .Invalid_Op
	}
	// Keep local mirror in sync before/after kernel update.
	// Note: IORING_REGISTER_FILES_UPDATE returns the number of fds updated
	// (positive) on success — not 0. core:sys/linux.io_uring_register maps
	// ret → Errno(-ret), so a successful update of 1 fd looks like an error.
	// Use the raw syscall and treat ret >= 0 as success.
	fd_storage := fd
	upd := Files_Update {
		offset = offset,
		resv   = 0,
		fds    = u64(uintptr(&fd_storage)),
	}
	ret := int(
		intrinsics.syscall(
			uintptr(linux.SYS_io_uring_register),
			uintptr(r.impl.ring_fd),
			uintptr(linux.IO_Uring_Register_Opcode.REGISTER_FILES_UPDATE),
			uintptr(&upd),
			uintptr(1),
		),
	)
	if ret < 0 {
		return .Register_Failed
	}
	r.impl.files[offset] = fd
	return .None
}

ring_has_fixed_buffers :: proc(r: ^Ring) -> bool {
	return r.impl.buffers_ok
}

ring_register_recv_pool :: proc(
	r: ^Ring,
	count: u32 = DEFAULT_REG_BUF_COUNT,
	buf_size: u32 = DEFAULT_RECV_BUF_SIZE,
) -> Error {
	if !r.impl.active {
		return .Unsupported
	}
	if count == 0 || buf_size == 0 {
		return .Invalid_Op
	}
	// Replace existing pool if any.
	if r.impl.buffers_ok {
		_ = linux.io_uring_register(r.impl.ring_fd, .UNREGISTER_BUFFERS, nil, 0)
		r.impl.buffers_ok = false
	}
	if r.impl.recv_pool != nil {
		delete(r.impl.recv_pool)
		r.impl.recv_pool = nil
	}
	if r.impl.recv_iovs != nil {
		delete(r.impl.recv_iovs)
		r.impl.recv_iovs = nil
	}
	clear(&r.impl.buf_free)

	total := int(count) * int(buf_size)
	pool := make([]u8, total, r.allocator)
	iovs := make([]linux.IO_Vec, count, r.allocator)
	for i in 0 ..< int(count) {
		base := &pool[i * int(buf_size)]
		iovs[i] = linux.IO_Vec {
			base = cast([^]byte)base,
			len  = uint(buf_size),
		}
	}
	errno := linux.io_uring_register(
		r.impl.ring_fd,
		.REGISTER_BUFFERS,
		raw_data(iovs),
		count,
	)
	if errno != .NONE {
		delete(pool)
		delete(iovs)
		return .Register_Failed
	}
	r.impl.recv_pool = pool
	r.impl.recv_iovs = iovs
	r.impl.recv_buf_size = buf_size
	r.impl.buffers_ok = true
	if r.impl.buf_free.allocator.procedure == nil {
		r.impl.buf_free = make([dynamic]u32, 0, int(count), r.allocator)
	}
	// Push in reverse so index 0 is allocated first (stable for debugging).
	for i := int(count) - 1; i >= 0; i -= 1 {
		append(&r.impl.buf_free, u32(i))
	}
	return .None
}

ring_recv_buf_alloc :: proc(r: ^Ring) -> (index: i32, slice: []u8, ok: bool) {
	if !r.impl.buffers_ok || len(r.impl.buf_free) == 0 {
		return -1, nil, false
	}
	idx := pop(&r.impl.buf_free)
	return i32(idx), ring_recv_buf_slice(r, i32(idx)), true
}

ring_recv_buf_free :: proc(r: ^Ring, index: i32) {
	if !r.impl.buffers_ok || index < 0 || int(index) >= len(r.impl.recv_iovs) {
		return
	}
	append(&r.impl.buf_free, u32(index))
}

ring_recv_buf_slice :: proc(r: ^Ring, index: i32) -> []u8 {
	if !r.impl.buffers_ok || index < 0 || int(index) >= len(r.impl.recv_iovs) {
		return nil
	}
	bs := int(r.impl.recv_buf_size)
	off := int(index) * bs
	return r.impl.recv_pool[off:off + bs]
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

_apply_fixed_file :: proc(sqe: ^linux.IO_Uring_SQE, fixed_idx: i32, raw_fd: i32) {
	if fixed_idx >= 0 {
		sqe.flags += {.FIXED_FILE}
		sqe.fd = linux.Fd(fixed_idx)
	} else {
		sqe.fd = linux.Fd(raw_fd)
	}
}

_prep_nop :: proc(r: ^Ring, id: u32) -> Error {
	sqe := _get_sqe(r) or_return
	sqe.opcode = .NOP
	sqe.user_data = u64(id)
	return .None
}

_prep_accept :: proc(r: ^Ring, id: u32, op: ^Operation) -> Error {
	sqe := _get_sqe(r) or_return
	sqe.opcode = .ACCEPT
	_apply_fixed_file(sqe, op.fixed_idx, op.fd)
	// addr / addr_len nil → kernel still accepts; peer address discarded.
	sqe.addr = 0
	sqe.off = 0
	// Non-blocking accepted sockets with cloexec (server default).
	sqe.accept_flags = {.CLOEXEC, .NONBLOCK}
	if op.continuous {
		sqe.sq_accept_flags = {.MULTISHOT}
	}
	sqe.user_data = u64(id)
	return .None
}

_prep_recv :: proc(r: ^Ring, id: u32, op: ^Operation) -> Error {
	sqe := _get_sqe(r) or_return
	sqe.opcode = .RECV
	_apply_fixed_file(sqe, op.fixed_idx, op.fd)
	// Always pointer-RECV into the provided window. When the window is backed by
	// ring_register_recv_pool memory this still avoids per-request malloc; the
	// IORING_RECVSEND_FIXED_BUF path returned -EINVAL on 6.14 in bastion smoke
	// (investigated separately — pointer RECV into the registered pool is correct).
	sqe.addr = cast(u64)uintptr(raw_data(op.buf))
	sqe.len = u32(len(op.buf))
	sqe.msg_flags = {}
	sqe.user_data = u64(id)
	return .None
}

_prep_send :: proc(r: ^Ring, id: u32, op: ^Operation) -> Error {
	sqe := _get_sqe(r) or_return
	sqe.opcode = .SEND
	_apply_fixed_file(sqe, op.fixed_idx, op.fd)
	sqe.addr = cast(u64)uintptr(raw_data(op.buf))
	sqe.len = u32(len(op.buf))
	sqe.msg_flags = {}
	sqe.user_data = u64(id)
	return .None
}

_prep_close :: proc(r: ^Ring, id: u32, op: ^Operation) -> Error {
	sqe := _get_sqe(r) or_return
	sqe.opcode = .CLOSE
	_apply_fixed_file(sqe, op.fixed_idx, op.fd)
	sqe.user_data = u64(id)
	return .None
}

_submit_nop :: proc(r: ^Ring, id: u32, op: ^Operation) -> Error {
	if !r.impl.active {
		return .Unsupported
	}
	_ = op
	return _prep_nop(r, id)
}

_submit_accept :: proc(r: ^Ring, id: u32, op: ^Operation) -> Error {
	if !r.impl.active {
		return .Unsupported
	}
	return _prep_accept(r, id, op)
}

_submit_recv :: proc(r: ^Ring, id: u32, op: ^Operation) -> Error {
	if !r.impl.active {
		return .Unsupported
	}
	return _prep_recv(r, id, op)
}

_submit_send :: proc(r: ^Ring, id: u32, op: ^Operation) -> Error {
	if !r.impl.active {
		return .Unsupported
	}
	return _prep_send(r, id, op)
}

_submit_close :: proc(r: ^Ring, id: u32, op: ^Operation) -> Error {
	if !r.impl.active {
		return .Unsupported
	}
	return _prep_close(r, id, op)
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
			// EINTR: soft return so hosts can observe shutdown flags (crash listener).
			if errno == .EINTR {
				n2 := _copy_cqes_ready(r, out[n:])
				return n + n2, .None
			}
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
