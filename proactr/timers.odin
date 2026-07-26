package proactr

// Portable software timers (all backends).
//
// Lifecycle (same as Recv/Send):
//   submit_timeout → min-heap by monotonic deadline
//   fire / cancel_timeout → soft_cq Completion
//   ring_wait drains soft_cq → complete_apply → operation_free
//
// cancel_timeout never frees; it posts TIMEOUT_CANCELED.
// Early platform wakes are handled by ring_wait remaining-time retry, not by
// firing timers before their deadline.

import "core:time"

// Timer_Entry is a pending submit_timeout; deadline is monotonic nanoseconds.
Timer_Entry :: struct {
	op_id:    u32,
	deadline: i64,
}

// Software timeout completion results (Linux errno convention, portable).
TIMEOUT_ETIME    :: i32(-62)  // expiry
TIMEOUT_CANCELED :: i32(-125) // cancel_timeout

// Fire only when deadline has been reached (or passed). No multi-ms grace:
// short timers must remain meaningful; early kevent wakes re-enter ring_wait.
TIMER_FIRE_GRACE_NS :: i64(0)

// Monotonic clock origin (process-wide; first _mono_ns wins).
@(private)
_mono_epoch: time.Tick
@(private)
_mono_ready: bool

_mono_ns :: proc() -> i64 {
	if !_mono_ready {
		_mono_epoch = time.tick_now()
		_mono_ready = true
		return 0
	}
	return time.duration_nanoseconds(time.tick_diff(_mono_epoch, time.tick_now()))
}

// --- min-heap by deadline (tie-break op_id) ----------------------------------

_timer_less :: #force_inline proc(a, b: Timer_Entry) -> bool {
	if a.deadline != b.deadline {
		return a.deadline < b.deadline
	}
	return a.op_id < b.op_id
}

_timer_sift_up :: proc(r: ^Ring, i: int) {
	j := i
	for j > 0 {
		p := (j - 1) / 2
		if !_timer_less(r.timers[j], r.timers[p]) {
			break
		}
		r.timers[j], r.timers[p] = r.timers[p], r.timers[j]
		j = p
	}
}

_timer_sift_down :: proc(r: ^Ring, i: int) {
	j := i
	n := len(r.timers)
	for {
		l := 2 * j + 1
		if l >= n {
			break
		}
		smallest := l
		ri := l + 1
		if ri < n && _timer_less(r.timers[ri], r.timers[l]) {
			smallest = ri
		}
		if !_timer_less(r.timers[smallest], r.timers[j]) {
			break
		}
		r.timers[j], r.timers[smallest] = r.timers[smallest], r.timers[j]
		j = smallest
	}
}

_timer_heap_push :: proc(r: ^Ring, e: Timer_Entry) {
	append(&r.timers, e)
	_timer_sift_up(r, len(r.timers) - 1)
}

_timer_heap_pop :: proc(r: ^Ring) -> (e: Timer_Entry, ok: bool) {
	if len(r.timers) == 0 {
		return {}, false
	}
	e = r.timers[0]
	last := pop(&r.timers)
	if len(r.timers) == 0 {
		return e, true
	}
	r.timers[0] = last
	_timer_sift_down(r, 0)
	return e, true
}

_timer_heap_peek :: proc(r: ^Ring) -> (e: Timer_Entry, ok: bool) {
	if len(r.timers) == 0 {
		return {}, false
	}
	return r.timers[0], true
}

// Eager remove by op_id so cancel storms do not leave dead heap nodes.
_timer_cancel :: proc(r: ^Ring, op_id: u32) {
	for i := 0; i < len(r.timers); i += 1 {
		if r.timers[i].op_id != op_id {
			continue
		}
		last := pop(&r.timers)
		if i >= len(r.timers) {
			return
		}
		r.timers[i] = last
		_timer_sift_up(r, i)
		_timer_sift_down(r, i)
		return
	}
}

_timer_next_ms :: proc(r: ^Ring) -> (ms: i32, has: bool) {
	// Drop stale heap heads (already completed/cancelled).
	for {
		e, ok := _timer_heap_peek(r)
		if !ok {
			return 0, false
		}
		op := operation_get(r, e.op_id)
		if op != nil && op.status == .Submitted && op.kind == .Timeout {
			break
		}
		_, _ = _timer_heap_pop(r)
	}
	e, ok := _timer_heap_peek(r)
	if !ok {
		return 0, false
	}
	now := _mono_ns()
	if e.deadline <= now + TIMER_FIRE_GRACE_NS {
		return 0, true
	}
	d := (e.deadline - now) / 1_000_000
	if d < 1 {
		d = 1
	}
	if d > i64(max(i32)) {
		d = i64(max(i32))
	}
	return i32(d), true
}

// Posts one software completion for any Submitted op (timers + WASI façade).
// Marks Completed so a second post cannot double-fire. Host still complete_apply + free.
// Drain path is soft_cq_head (amortised O(1)), not ordered_remove(0).
_soft_post :: proc(r: ^Ring, id: u32, result: i32, flags: u32 = 0) -> bool {
	op := operation_get(r, id)
	if op == nil || op.status != .Submitted {
		return false
	}
	op.status = .Completed
	op.result = result
	op.flags = flags
	append(&r.soft_cq, Completion{op_id = id, result = result, flags = flags})
	return true
}

_soft_post_timeout :: proc(r: ^Ring, id: u32, result: i32) -> bool {
	op := operation_get(r, id)
	if op == nil || op.kind != .Timeout {
		return false
	}
	return _soft_post(r, id, result, 0)
}

_timer_fire_due :: proc(r: ^Ring) {
	now := _mono_ns()
	for {
		e, ok := _timer_heap_peek(r)
		if !ok {
			return
		}
		if e.deadline > now + TIMER_FIRE_GRACE_NS {
			return
		}
		_, _ = _timer_heap_pop(r)
		_ = _soft_post_timeout(r, e.op_id, TIMEOUT_ETIME)
	}
}

_soft_drain :: proc(r: ^Ring, out: []Completion, start: int) -> int {
	n := start
	for n < len(out) && r.soft_cq_head < len(r.soft_cq) {
		out[n] = r.soft_cq[r.soft_cq_head]
		r.soft_cq_head += 1
		n += 1
	}
	// Compact when half the buffer is consumed.
	if r.soft_cq_head > 0 && r.soft_cq_head * 2 >= len(r.soft_cq) {
		if r.soft_cq_head >= len(r.soft_cq) {
			clear(&r.soft_cq)
		} else {
			copy(r.soft_cq[:], r.soft_cq[r.soft_cq_head:])
			resize(&r.soft_cq, len(r.soft_cq) - r.soft_cq_head)
		}
		r.soft_cq_head = 0
	}
	return n
}

// Platform wait budget: min(remaining user timeout, next live timer).
_ring_wait_budget_ms :: proc(r: ^Ring, timeout_ms: i32, deadline_ns: i64) -> i32 {
	wait_ms := timeout_ms
	if timeout_ms > 0 && deadline_ns > 0 {
		now := _mono_ns()
		if now >= deadline_ns {
			return 0
		}
		rem := (deadline_ns - now) / 1_000_000
		if rem < 1 {
			rem = 1
		}
		if rem > i64(max(i32)) {
			rem = i64(max(i32))
		}
		wait_ms = i32(rem)
	}
	if tms, has := _timer_next_ms(r); has {
		if wait_ms < 0 || tms < wait_ms {
			wait_ms = tms
		}
	}
	return wait_ms
}

// True when ring_wait should return without (another) blocking platform wait.
_ring_wait_should_stop :: proc(
	r: ^Ring,
	n: int,
	min_complete: u32,
	timeout_ms: i32,
	deadline_ns: i64,
	wait_ms: i32,
) -> bool {
	if u32(n) >= min_complete {
		return true
	}
	// Peek: one fire/drain only.
	if min_complete == 0 && timeout_ms == 0 {
		return true
	}
	// Infinite wait: never stop for budget.
	if timeout_ms < 0 {
		return false
	}
	// Still willing to block.
	if wait_ms != 0 {
		return false
	}
	// wait_ms == 0: due timer that could not drain (out full), or user deadline done.
	if tms, has := _timer_next_ms(r); has && tms == 0 {
		return true
	}
	if timeout_ms == 0 {
		return true
	}
	if deadline_ns > 0 && _mono_ns() >= deadline_ns {
		return true
	}
	// Sub-ms user budget remaining: allow one non-blocking platform poll.
	return false
}

// --- public API -------------------------------------------------------------

// submit_timeout arms a portable software timer.
// Completes with TIMEOUT_ETIME on expiry (via soft_cq / ring_wait).
submit_timeout :: proc(
	r: ^Ring,
	duration_ns: i64,
	user: rawptr = nil,
) -> (id: u32, err: Error) {
	oid, op, e := _begin_submit(r, .Timeout, user)
	if e != .None {
		return 0, e
	}
	ns := duration_ns if duration_ns > 0 else 1
	_timer_heap_push(r, Timer_Entry{op_id = oid, deadline = _mono_ns() + ns})
	_ = op
	return oid, .None
}

// cancel_timeout posts TIMEOUT_CANCELED if the timer is still live.
// Never frees — host must harvest the CQE and operation_free.
// Returns true if a cancel completion was posted.
cancel_timeout :: proc(r: ^Ring, id: u32) -> bool {
	if !_soft_post_timeout(r, id, TIMEOUT_CANCELED) {
		return false
	}
	_timer_cancel(r, id)
	return true
}
