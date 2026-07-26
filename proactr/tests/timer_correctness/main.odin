// Correctness checks for proactr software timers (lifecycle + flake).
// Exit 0 only if all checks pass.
package proactr:tests

import "core:fmt"
import "core:os"
import "core:time"

import proactr "../proactr"

ETIME :: i32(-62)
// After unify: cancel posts this. Baseline may free without CQE.
ECANCELED :: i32(-125)

fails: int

main :: proc() {
	fmt.printf("timer_correctness: backend=%s\n", proactr.ring_backend_name())

	ring: proactr.Ring
	err := proactr.ring_init(&ring, 256)
	if err == .Unsupported {
		fmt.println("unsupported — skip OK")
		os.exit(0)
	}
	if err != .None {
		fmt.eprintf("ring_init: %v\n", err)
		os.exit(1)
	}
	defer proactr.ring_destroy(&ring)

	check_fire(&ring)
	check_fire_not_early(&ring, 5_000_000, 10)
	check_cancel_before_fire(&ring)
	check_cancel_idempotent(&ring)
	check_no_leak_arm_cancel(&ring, 200)
	check_flake(&ring, 200, 5_000_000)

	if fails > 0 {
		fmt.eprintf("FAILED checks=%d\n", fails)
		os.exit(1)
	}
	fmt.println("timer_correctness: OK")
}

failf :: proc(fmt_str: string, args: ..any) {
	fails += 1
	fmt.eprintf("FAIL: ")
	fmt.eprintf(fmt_str, ..args)
	fmt.eprintln()
}

check_fire :: proc(r: ^proactr.Ring) {
	id, err := proactr.submit_timeout(r, 3_000_000)
	if err != .None {
		failf("fire submit: %v", err)
		return
	}
	completions: [4]proactr.Completion
	n, werr := proactr.ring_wait(r, completions[:], 1, 2000)
	if werr != .None || n < 1 {
		failf("fire wait n=%d err=%v", n, werr)
		return
	}
	c := completions[0]
	if c.op_id != id {
		failf("fire op_id got=%v want=%v", c.op_id, id)
	}
	if c.result != ETIME && c.result != proactr.TIMEOUT_ETIME {
		fmt.printf("  note: fire result=%d (expected %d)\n", c.result, ETIME)
	}
	_ = proactr.complete_apply(r, c)
	proactr.op_free(r, c.op_id)
	fmt.println("  fire ok")
}

// Wall clock: a D-duration timer must not complete in under 70% of D (no 1ms grace).
check_fire_not_early :: proc(r: ^proactr.Ring, duration_ns: i64, iters: int) {
	completions: [4]proactr.Completion
	floor := i64(f64(duration_ns) * 0.7)
	for i in 0 ..< iters {
		id, err := proactr.submit_timeout(r, duration_ns)
		if err != .None {
			failf("not_early submit: %v", err)
			return
		}
		t0 := time.tick_now()
		n, werr := proactr.ring_wait(r, completions[:], 1, 2000)
		elapsed := time.duration_nanoseconds(time.tick_diff(t0, time.tick_now()))
		if werr != .None || n < 1 {
			failf("not_early wait n=%d err=%v", n, werr)
			return
		}
		c := completions[0]
		_ = proactr.complete_apply(r, c)
		proactr.op_free(r, c.op_id)
		_ = id
		if elapsed < floor {
			failf("not_early iter=%d elapsed=%d ns < floor=%d (duration=%d)", i, elapsed, floor, duration_ns)
			return
		}
	}
	fmt.printf("  fire_not_early ok duration_ms=%d iters=%d\n", duration_ns / 1_000_000, iters)
}

check_cancel_before_fire :: proc(r: ^proactr.Ring) {
	id, err := proactr.submit_timeout(r, 60_000_000_000) // 60s
	if err != .None {
		failf("cancel submit: %v", err)
		return
	}
	ok := proactr.cancel_timeout(r, id)
	if !ok {
		failf("cancel_timeout returned false for live timer")
		return
	}
	// Baseline: free-on-cancel → no CQE. Unified: cancel CQE.
	completions: [4]proactr.Completion
	n, _ := proactr.ring_wait(r, completions[:], 0, 0)
	if n == 0 {
		// free-on-cancel path (baseline)
		fmt.println("  cancel_before_fire ok (free-on-cancel, no CQE)")
		return
	}
	// soft CQ path
	c := completions[0]
	if c.op_id != id {
		failf("cancel CQE op_id mismatch")
	}
	_ = proactr.complete_apply(r, c)
	proactr.op_free(r, c.op_id)
	// drain rest
	for {
		n2, _ := proactr.ring_wait(r, completions[:], 0, 0)
		if n2 == 0 {
			break
		}
		for i in 0 ..< n2 {
			cc := completions[i]
			_ = proactr.complete_apply(r, cc)
			proactr.op_free(r, cc.op_id)
		}
	}
	fmt.println("  cancel_before_fire ok (CQE path)")
}

check_cancel_idempotent :: proc(r: ^proactr.Ring) {
	id, err := proactr.submit_timeout(r, 60_000_000_000)
	if err != .None {
		failf("idempotent submit: %v", err)
		return
	}
	_ = proactr.cancel_timeout(r, id)
	// Second cancel should be false (already gone / not Submitted)
	ok2 := proactr.cancel_timeout(r, id)
	if ok2 {
		// If first path posted CQE without freeing, second might still see Submitted
		// Drain first
		completions: [4]proactr.Completion
		for {
			n, _ := proactr.ring_wait(r, completions[:], 0, 0)
			if n == 0 {
				break
			}
			for i in 0 ..< n {
				c := completions[i]
				_ = proactr.complete_apply(r, c)
				proactr.op_free(r, c.op_id)
			}
		}
		ok3 := proactr.cancel_timeout(r, id)
		if ok3 {
			failf("cancel still true after drain")
		}
	}
	// Drain any remaining
	completions: [4]proactr.Completion
	for {
		n, _ := proactr.ring_wait(r, completions[:], 0, 0)
		if n == 0 {
			break
		}
		for i in 0 ..< n {
			c := completions[i]
			_ = proactr.complete_apply(r, c)
			proactr.op_free(r, c.op_id)
		}
	}
	fmt.println("  cancel_idempotent ok")
}

check_no_leak_arm_cancel :: proc(r: ^proactr.Ring, n: int) {
	for i in 0 ..< n {
		id, err := proactr.submit_timeout(r, 60_000_000_000)
		if err != .None {
			failf("leak arm i=%d: %v", i, err)
			return
		}
		_ = proactr.cancel_timeout(r, id)
		// Drain CQEs if any
		completions: [8]proactr.Completion
		for {
			cn, _ := proactr.ring_wait(r, completions[:], 0, 0)
			if cn == 0 {
				break
			}
			for j in 0 ..< cn {
				c := completions[j]
				_ = proactr.complete_apply(r, c)
				proactr.op_free(r, c.op_id)
			}
		}
	}
	// If we leaked ops, a large further alloc batch might still work — weak check:
	// arm one short timer and free via fire.
	id, err := proactr.submit_timeout(r, 1_000_000)
	if err != .None {
		failf("leak follow-up submit: %v", err)
		return
	}
	completions: [4]proactr.Completion
	nn, _ := proactr.ring_wait(r, completions[:], 1, 2000)
	if nn < 1 {
		failf("leak follow-up wait empty")
		return
	}
	c := completions[0]
	_ = proactr.complete_apply(r, c)
	proactr.op_free(r, c.op_id)
	_ = id
	fmt.printf("  no_leak arm_cancel×%d ok\n", n)
}

check_flake :: proc(r: ^proactr.Ring, iters: int, duration_ns: i64) {
	completions: [4]proactr.Completion
	miss := 0
	t0 := time.tick_now()
	for _ in 0 ..< iters {
		id, err := proactr.submit_timeout(r, duration_ns)
		if err != .None {
			miss += 1
			continue
		}
		n, werr := proactr.ring_wait(r, completions[:], 1, 2000)
		if werr != .None || n < 1 {
			miss += 1
			_ = proactr.cancel_timeout(r, id)
			continue
		}
		c := completions[0]
		_ = proactr.complete_apply(r, c)
		proactr.op_free(r, c.op_id)
	}
	elapsed := time.duration_milliseconds(time.tick_diff(t0, time.tick_now()))
	if miss != 0 {
		failf("flake misses=%d/%d", miss, iters)
	}
	fmt.printf("  flake ok misses=0/%d wall_ms=%.1f\n", iters, elapsed)
}
