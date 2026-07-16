#+build linux
package proactr

// Linux io_uring backend.
//
// v0: structure + stubs that return Unsupported until syscall bindings land.
// Next: raw io_uring_setup / enter / register without liburing, or thin FFI.

Ring_Impl :: struct {
	ring_fd:   i32,
	entries:   u32,
	// SQ/CQ mmap pointers — filled when setup lands.
	sq_ptr:    rawptr,
	cq_ptr:    rawptr,
	sq_mask:   u32,
	cq_mask:   u32,
	// Features flags from io_uring_params.
	features:  u32,
	active:    bool,
}

_ring_init_platform :: proc(r: ^Ring, entries: u32) -> Error {
	// TODO: io_uring_setup(entries, &params); mmap SQ/CQ; store ring_fd.
	// Until then, ring is not active — ops fail with Unsupported so benches
	// don't silently no-op.
	r.impl = {
		ring_fd = -1,
		entries = entries,
		active  = false,
	}
	return .Unsupported
}

_ring_destroy_platform :: proc(r: ^Ring) {
	if r.impl.ring_fd >= 0 {
		// TODO: close(ring_fd); munmap
		r.impl.ring_fd = -1
	}
	r.impl.active = false
}

_submit_accept :: proc(r: ^Ring, id: u32, op: ^Op) -> Error {
	if !r.impl.active {
		return .Unsupported
	}
	// TODO: SQE IORING_OP_ACCEPT, user_data = id
	_ = id
	_ = op
	return .Unsupported
}

_submit_recv :: proc(r: ^Ring, id: u32, op: ^Op) -> Error {
	if !r.impl.active {
		return .Unsupported
	}
	_ = id
	_ = op
	return .Unsupported
}

_submit_send :: proc(r: ^Ring, id: u32, op: ^Op) -> Error {
	if !r.impl.active {
		return .Unsupported
	}
	_ = id
	_ = op
	return .Unsupported
}

_submit_close :: proc(r: ^Ring, id: u32, op: ^Op) -> Error {
	if !r.impl.active {
		return .Unsupported
	}
	_ = id
	_ = op
	return .Unsupported
}

_ring_submit :: proc(r: ^Ring) -> Error {
	if !r.impl.active {
		return .Unsupported
	}
	// TODO: io_uring_enter(fd, to_submit, 0, 0, nil)
	return .Unsupported
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
	_ = out
	_ = min_complete
	_ = timeout_ms
	// TODO: peek/wait CQ, copy into out, advance cq head
	return 0, .Unsupported
}
