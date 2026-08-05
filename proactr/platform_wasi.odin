#+build wasi
package proactr

// WASI proactor *façade* — the only WASM backend (wasmtime, browsers via WASI,
// or any host that loads wasi_wasm32 and posts completions).
//
// No kernel CQ. Completions go through portable soft_cq via ring_wasi_complete
// (same drain path as software timers). There is no separate js_wasm32 port.
//
//   1. Park Accept/Recv/Send as Submitted
//   2. Host/runtime performs I/O or wires wasi-sockets + pollables
//   3. ring_wasi_complete → _soft_post → soft_cq
//   4. ring_wait drains soft_cq; _ring_wait sleeps when empty (timer re-fire)
//
// TODO when wasi-sockets is stable:
//   - map pollables to op_id
//   - optional: poll_oneoff with clock + pollable subscriptions inside _ring_wait
//   - perform sock_recv/send on readiness, then ring_wasi_complete

import "core:time"

Ring_Impl :: struct {
	active:  bool,
	entries: u32,
	// Future: pollable handles keyed by op_id, listen fd table, etc.
}

// Runtime bridge when a parked op finishes.
ring_wasi_complete :: proc(r: ^Ring, op_id: u32, result: i32, flags: u32 = 0) {
	if r == nil || !r.impl.active {
		return
	}
	_ = _soft_post(r, op_id, result, flags)
}

_ring_init_platform :: proc(r: ^Ring, entries: u32) -> Error {
	want := entries if entries > 0 else DEFAULT_ENTRIES
	r.impl = {
		active  = true,
		entries = want,
	}
	return .None
}

_ring_destroy_platform :: proc(r: ^Ring) {
	r.impl.active = false
}

_submit_nop :: proc(r: ^Ring, id: u32, op: ^Operation) -> Error {
	if !r.impl.active {
		return .Unsupported
	}
	_ = op
	_ = _soft_post(r, id, 0)
	return .None
}

_submit_accept :: proc(r: ^Ring, id: u32, op: ^Operation) -> Error {
	if !r.impl.active {
		return .Unsupported
	}
	_ = id
	_ = op
	// continuous ignored — host re-submits after each complete
	return .None
}

_submit_recv :: proc(r: ^Ring, id: u32, op: ^Operation) -> Error {
	if !r.impl.active {
		return .Unsupported
	}
	_ = id
	_ = op
	return .None
}

_submit_send :: proc(r: ^Ring, id: u32, op: ^Operation) -> Error {
	if !r.impl.active {
		return .Unsupported
	}
	_ = id
	_ = op
	return .None
}

_submit_close :: proc(r: ^Ring, id: u32, op: ^Operation) -> Error {
	if !r.impl.active {
		return .Unsupported
	}
	_ = op
	// Sketch: immediate success on soft_cq. Prefer host close + complete if fd is real.
	_ = _soft_post(r, id, 0)
	return .None
}

_submit_writev :: proc(r: ^Ring, id: u32, op: ^Operation) -> Error {
	_ = r
	_ = id
	_ = op
	return .Unsupported
}

_submit_sendfile :: proc(r: ^Ring, id: u32, op: ^Operation) -> Error {
	_ = r
	_ = id
	_ = op
	return .Unsupported
}

_ring_submit :: proc(r: ^Ring) -> Error {
	if !r.impl.active {
		return .Unsupported
	}
	return .None
}

// Completions are only on soft_cq (portable drain). When empty, sleep the wait
// budget (or 1ms if infinite). Replace sleep with wasi poll_oneoff when wired.
_ring_wait :: proc(
	r: ^Ring,
	out: []Completion,
	min_complete: u32,
	timeout_ms: i32,
) -> (n: int, err: Error) {
	_ = out
	_ = min_complete
	if !r.impl.active {
		return 0, .Unsupported
	}
	if timeout_ms == 0 {
		return 0, .None
	}
	if timeout_ms > 0 {
		time.sleep(time.Duration(timeout_ms) * time.Millisecond)
	} else {
		time.sleep(time.Millisecond)
	}
	return 0, .None
}
