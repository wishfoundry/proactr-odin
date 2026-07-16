#+build !linux
package proactr

// Non-Linux stub: proactr is Linux/io_uring-first. Compile succeeds; init fails.

Ring_Impl :: struct {
	active: bool,
}

_ring_init_platform :: proc(r: ^Ring, entries: u32) -> Error {
	r.impl = {active = false}
	_ = entries
	return .Unsupported
}

_ring_destroy_platform :: proc(r: ^Ring) {
	r.impl.active = false
}

_submit_accept :: proc(r: ^Ring, id: u32, op: ^Op) -> Error {
	_ = r
	_ = id
	_ = op
	return .Unsupported
}

_submit_recv :: proc(r: ^Ring, id: u32, op: ^Op) -> Error {
	_ = r
	_ = id
	_ = op
	return .Unsupported
}

_submit_send :: proc(r: ^Ring, id: u32, op: ^Op) -> Error {
	_ = r
	_ = id
	_ = op
	return .Unsupported
}

_submit_close :: proc(r: ^Ring, id: u32, op: ^Op) -> Error {
	_ = r
	_ = id
	_ = op
	return .Unsupported
}

_ring_submit :: proc(r: ^Ring) -> Error {
	_ = r
	return .Unsupported
}

_ring_wait :: proc(
	r: ^Ring,
	out: []Completion,
	min_complete: u32,
	timeout_ms: i32,
) -> (n: int, err: Error) {
	_ = r
	_ = out
	_ = min_complete
	_ = timeout_ms
	return 0, .Unsupported
}
