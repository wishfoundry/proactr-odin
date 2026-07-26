// Microbench for proactr software timers (baseline + after unify).
// Usage:
//   odin build examples/timer_bench -out:timer_bench -o:speed
//   ./timer_bench                 # all benches, human + CSV
//   ./timer_bench -bench=B3 -k=10000
package proactr:tests

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"

import proactr "../../proactr"

// Result codes we expect from software timers.
ETIME :: i32(-62)

Bench_ID :: enum {
	B1_Fire_Sparse,
	B2_Fire_Burst,
	B3_Next_Deadline,
	B4_Cancel_Storm,
	B5_Wait_Mix,
	B6_Flake,
}

main :: proc() {
	bench_filter := ""
	k_override := -1
	for a in os.args[1:] {
		if strings.has_prefix(a, "-bench=") {
			bench_filter = a[len("-bench="):]
		} else if strings.has_prefix(a, "-k=") {
			if v, ok := strconv.parse_int(a[len("-k="):]); ok {
				k_override = v
			}
		}
	}

	fmt.printf("timer_bench: backend=%s\n", proactr.ring_backend_name())
	fmt.println("bench,k,iters,metric,value,unit,notes")

	if want(bench_filter, "B1", "all") {
		// Real wall latency (no fire-grace): 5ms and 10ms arms.
		run_b1_fire_accuracy(5_000_000, 100)
		run_b1_fire_accuracy(10_000_000, 50)
	}
	if want(bench_filter, "B2", "all") {
		ks := []int{100, 1000, 10_000}
		if k_override > 0 {
			ks = []int{k_override}
		}
		for k in ks {
			run_b2_fire_burst(k)
		}
	}
	if want(bench_filter, "B3", "all") {
		ks := []int{10, 100, 1000, 10_000, 100_000}
		if k_override > 0 {
			ks = []int{k_override}
		}
		for k in ks {
			run_b3_next_deadline(k, 2000)
		}
	}
	if want(bench_filter, "B4", "all") {
		ks := []int{100, 1000, 10_000}
		if k_override > 0 {
			ks = []int{k_override}
		}
		for k in ks {
			run_b4_cancel_storm(k)
		}
	}
	if want(bench_filter, "B5", "all") {
		k := 1000
		if k_override > 0 {
			k = k_override
		}
		run_b5_wait_mix(k)
	}
	if want(bench_filter, "B6", "all") {
		run_b6_flake(500, 5_000_000) // 5ms × 500
	}
}

want :: proc(filter, name, all_token: string) -> bool {
	if filter == "" || filter == all_token {
		return true
	}
	return strings.to_upper(filter) == strings.to_upper(name) ||
		strings.contains(strings.to_upper(filter), strings.to_upper(name))
}

csv :: proc(bench: string, k, iters: int, metric: string, value: f64, unit: string, notes: string = "") {
	fmt.printf("%s,%d,%d,%s,%.4f,%s,%s\n", bench, k, iters, metric, value, unit, notes)
}

init_ring :: proc(entries: u32 = 4096) -> (ring: proactr.Ring, ok: bool) {
	err := proactr.ring_init(&ring, entries)
	if err == .Unsupported {
		fmt.eprintln("unsupported backend")
		return {}, false
	}
	if err != .None {
		fmt.eprintf("ring_init: %v\n", err)
		return {}, false
	}
	return ring, true
}

// --- B1: wall-clock fire accuracy (duration_ns must be real, not grace-dominated) ---
run_b1_fire_accuracy :: proc(duration_ns: i64, iters: int) {
	ring, ok := init_ring(64)
	if !ok {
		return
	}
	defer proactr.ring_destroy(&ring)

	samples := make([dynamic]f64, 0, iters)
	defer delete(samples)
	completions: [8]proactr.Completion
	// Allow 2s budget so remaining-time retry always wins over early wake.
	wait_budget_ms: i32 = 2000
	early := 0 // fired before 80% of requested duration

	for _ in 0 ..< iters {
		id, err := proactr.submit_timeout(&ring, duration_ns)
		if err != .None {
			fmt.eprintf("B1 submit_timeout: %v\n", err)
			return
		}
		t0 := time.tick_now()
		n, werr := proactr.ring_wait(&ring, completions[:], 1, wait_budget_ms)
		elapsed := time.duration_nanoseconds(time.tick_diff(t0, time.tick_now()))
		if werr != .None || n < 1 {
			fmt.eprintf("B1 wait failed n=%d err=%v\n", n, werr)
			return
		}
		c := completions[0]
		_ = proactr.complete_apply(&ring, c)
		proactr.op_free(&ring, c.op_id)
		_ = id
		append(&samples, f64(elapsed))
		if f64(elapsed) < f64(duration_ns) * 0.8 {
			early += 1
		}
	}

	p50, p99 := percentiles(samples[:])
	mean_ns := mean(samples[:])
	ms_label := fmt.tprintf("%dms_timer", duration_ns / 1_000_000)
	csv("B1_fire_accuracy", 1, iters, "p50_latency", p50, "ns", ms_label)
	csv("B1_fire_accuracy", 1, iters, "p99_latency", p99, "ns", ms_label)
	csv("B1_fire_accuracy", 1, iters, "mean_latency", mean_ns, "ns", ms_label)
	csv("B1_fire_accuracy", 1, iters, "mean_overshoot_ns", mean_ns - f64(duration_ns), "ns", ms_label)
	csv("B1_fire_accuracy", 1, iters, "early_lt_80pct", f64(early), "count", ms_label)
	// Error %: (mean - target) / target * 100
	err_pct := 100.0 * (mean_ns - f64(duration_ns)) / f64(duration_ns)
	csv("B1_fire_accuracy", 1, iters, "mean_error_pct", err_pct, "pct", ms_label)
}

// --- B2: K timers same deadline, one wait drains ---
run_b2_fire_burst :: proc(k: int) {
	// Need enough ops; ring entries is SQ size, ops grow dynamically.
	ring, ok := init_ring(256)
	if !ok {
		return
	}
	defer proactr.ring_destroy(&ring)

	ids := make([]u32, k)
	defer delete(ids)
	// Far enough that arming all finishes before first due; short enough for bench.
	// Arm with 2ms so batch arming of 10k may still complete in time on slow hosts.
	for i in 0 ..< k {
		id, err := proactr.submit_timeout(&ring, 2_000_000)
		if err != .None {
			fmt.eprintf("B2 submit k=%d i=%d: %v\n", k, i, err)
			return
		}
		ids[i] = id
	}

	out := make([]proactr.Completion, k)
	defer delete(out)

	t0 := time.tick_now()
	got := 0
	for got < k {
		n, werr := proactr.ring_wait(&ring, out[got:], 1, 5000)
		if werr != .None {
			fmt.eprintf("B2 wait: %v got=%d/%d\n", werr, got, k)
			return
		}
		if n == 0 {
			fmt.eprintf("B2 timeout draining got=%d/%d\n", got, k)
			return
		}
		for i in 0 ..< n {
			c := out[got + i]
			_ = proactr.complete_apply(&ring, c)
			proactr.op_free(&ring, c.op_id)
		}
		got += n
	}
	elapsed := time.duration_nanoseconds(time.tick_diff(t0, time.tick_now()))
	ns_per := f64(elapsed) / f64(k)
	csv("B2_fire_burst", k, 1, "total_wall", f64(elapsed), "ns", "drain_all")
	csv("B2_fire_burst", k, 1, "ns_per_fire", ns_per, "ns", "includes_wait")
	csv("B2_fire_burst", k, 1, "fires_per_s", 1e9 / ns_per, "1/s", "")
}

// --- B3: next-deadline / fire scan cost with far timers ---
// Arms K timers 1h out, then peeks N times (timeout_ms=0). Each peek scans timers.
run_b3_next_deadline :: proc(k: int, peeks: int) {
	ring, ok := init_ring(256)
	if !ok {
		return
	}
	defer proactr.ring_destroy(&ring)

	HOUR_NS :: i64(3_600) * 1_000_000_000
	for i in 0 ..< k {
		// Stagger slightly so heap/list isn't degenerate if sorted later.
		_, err := proactr.submit_timeout(&ring, HOUR_NS + i64(i))
		if err != .None {
			fmt.eprintf("B3 submit k=%d i=%d: %v\n", k, i, err)
			return
		}
	}

	completions: [8]proactr.Completion
	// Warm-up
	for _ in 0 ..< 10 {
		_, _ = proactr.ring_wait(&ring, completions[:], 0, 0)
	}

	t0 := time.tick_now()
	for _ in 0 ..< peeks {
		n, _ := proactr.ring_wait(&ring, completions[:], 0, 0)
		if n != 0 {
			// Far timers should not fire
			fmt.eprintf("B3 unexpected fire n=%d k=%d\n", n, k)
			return
		}
	}
	elapsed := time.duration_nanoseconds(time.tick_diff(t0, time.tick_now()))
	ns_per := f64(elapsed) / f64(peeks)
	csv("B3_next_deadline", k, peeks, "ns_per_peek", ns_per, "ns", "far_timers_scan")
	csv("B3_next_deadline", k, peeks, "total_wall", f64(elapsed), "ns", "")
}

// --- B4: cancel all armed timers ---
run_b4_cancel_storm :: proc(k: int) {
	ring, ok := init_ring(256)
	if !ok {
		return
	}
	defer proactr.ring_destroy(&ring)

	ids := make([]u32, k)
	defer delete(ids)
	HOUR_NS :: i64(3_600) * 1_000_000_000
	for i in 0 ..< k {
		id, err := proactr.submit_timeout(&ring, HOUR_NS)
		if err != .None {
			fmt.eprintf("B4 submit: %v\n", err)
			return
		}
		ids[i] = id
	}

	t0 := time.tick_now()
	freed_now := 0
	for id in ids {
		if proactr.cancel_timeout(&ring, id) {
			freed_now += 1
		}
	}
	// Drain any cancel CQEs if the new lifecycle posts them (baseline: free-now, no CQEs).
	out := make([]proactr.Completion, min(k, 4096))
	defer delete(out)
	drained := 0
	for {
		n, _ := proactr.ring_wait(&ring, out[:], 0, 0)
		if n == 0 {
			break
		}
		for i in 0 ..< n {
			c := out[i]
			_ = proactr.complete_apply(&ring, c)
			proactr.op_free(&ring, c.op_id)
		}
		drained += n
	}
	elapsed := time.duration_nanoseconds(time.tick_diff(t0, time.tick_now()))
	csv("B4_cancel_storm", k, 1, "total_wall", f64(elapsed), "ns", "")
	csv("B4_cancel_storm", k, 1, "ns_per_cancel", f64(elapsed) / f64(k), "ns", "")
	csv("B4_cancel_storm", k, 1, "cancel_true", f64(freed_now), "count", "true_returns")
	csv("B4_cancel_storm", k, 1, "cqes_drained", f64(drained), "count", "0_means_free_on_cancel")
}

// --- B5: mixed deadlines, wait until all complete ---
run_b5_wait_mix :: proc(k: int) {
	ring, ok := init_ring(256)
	if !ok {
		return
	}
	defer proactr.ring_destroy(&ring)

	for i in 0 ..< k {
		// 1..50 ms
		ms := 1 + (i % 50)
		_, err := proactr.submit_timeout(&ring, i64(ms) * 1_000_000)
		if err != .None {
			fmt.eprintf("B5 submit: %v\n", err)
			return
		}
	}

	out := make([]proactr.Completion, 256)
	defer delete(out)
	got := 0
	t0 := time.tick_now()
	for got < k {
		n, werr := proactr.ring_wait(&ring, out[:], 1, 100)
		if werr != .None {
			fmt.eprintf("B5 wait: %v\n", werr)
			return
		}
		if n == 0 {
			continue
		}
		for i in 0 ..< n {
			c := out[i]
			_ = proactr.complete_apply(&ring, c)
			proactr.op_free(&ring, c.op_id)
		}
		got += n
	}
	elapsed := time.duration_nanoseconds(time.tick_diff(t0, time.tick_now()))
	csv("B5_wait_mix", k, 1, "total_wall", f64(elapsed), "ns", "1to50ms_uniform")
	csv("B5_wait_mix", k, 1, "ns_per_timer", f64(elapsed) / f64(k), "ns", "")
}

// --- B6: flake rate for short timers ---
run_b6_flake :: proc(iters: int, duration_ns: i64) {
	ring, ok := init_ring(64)
	if !ok {
		return
	}
	defer proactr.ring_destroy(&ring)

	completions: [8]proactr.Completion
	// User wait budget: 2s should always be enough if retry works.
	fails := 0
	for _ in 0 ..< iters {
		id, err := proactr.submit_timeout(&ring, duration_ns)
		if err != .None {
			fails += 1
			continue
		}
		n, werr := proactr.ring_wait(&ring, completions[:], 1, 2000)
		if werr != .None || n < 1 {
			fails += 1
			// Try to not leak: best-effort cancel
			_ = proactr.cancel_timeout(&ring, id)
			continue
		}
		c := completions[0]
		_ = proactr.complete_apply(&ring, c)
		proactr.op_free(&ring, c.op_id)
	}
	rate := 100.0 * f64(fails) / f64(iters)
	csv("B6_flake", 1, iters, "fail_rate_pct", rate, "pct", "5ms_timer_2s_budget")
	csv("B6_flake", 1, iters, "fails", f64(fails), "count", "")
}

// --- stats ---
mean :: proc(s: []f64) -> f64 {
	if len(s) == 0 {
		return 0
	}
	sum: f64
	for v in s {
		sum += v
	}
	return sum / f64(len(s))
}

percentiles :: proc(s: []f64) -> (p50, p99: f64) {
	if len(s) == 0 {
		return 0, 0
	}
	tmp := make([]f64, len(s))
	defer delete(tmp)
	copy(tmp, s)
	slice.sort(tmp)
	p50 = tmp[len(tmp) * 50 / 100]
	idx99 := len(tmp) * 99 / 100
	if idx99 >= len(tmp) {
		idx99 = len(tmp) - 1
	}
	p99 = tmp[idx99]
	return
}
