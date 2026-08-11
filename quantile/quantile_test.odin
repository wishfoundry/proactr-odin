package quantile

import "core:math"
import "core:testing"

@(test)
test_offline_percentiles_sorted :: proc(t: ^testing.T) {
	// 0..99 inclusive
	s: [100]f64
	for i in 0 ..< 100 {
		s[i] = f64(i)
	}
	testing.expect_value(t, percentile_sorted(s[:], 0.0), 0)
	testing.expect_value(t, percentile_sorted(s[:], 1.0), 99)
	// p50 of 0..99 → midway between 49 and 50
	p50 := percentile_sorted(s[:], 0.5)
	testing.expect(t, math.abs(p50 - 49.5) < 0.01, "p50")
	p99 := percentile_sorted(s[:], 0.99)
	testing.expect(t, p99 >= 98 && p99 <= 99, "p99 near top")
}

@(test)
test_offline_quartiles :: proc(t: ^testing.T) {
	samples := []f64{1, 2, 3, 4, 5, 6, 7, 8, 9}
	q := quartiles(samples)
	testing.expect_value(t, q.n, 9)
	testing.expect(t, math.abs(q.q2 - 5) < 0.01, "median")
	testing.expect(t, q.q1 < q.q2 && q.q2 < q.q3, "q1 < q2 < q3")
}

@(test)
test_offline_set_percentiles :: proc(t: ^testing.T) {
	s: [1000]f64
	for i in 0 ..< 1000 {
		s[i] = f64(i + 1) // 1..1000
	}
	snap := set_percentiles(s[:])
	testing.expect_value(t, snap.n, 1000)
	testing.expect(t, math.abs(snap.p50 - 500.5) < 1, "p50")
	testing.expect(t, snap.p75 > snap.p50, "p75 > p50")
	testing.expect(t, snap.p90 > snap.p75, "p90 > p75")
	testing.expect(t, snap.p99 > snap.p90, "p99 > p90")
}

@(test)
test_streaming_set_monotonic_uniform :: proc(t: ^testing.T) {
	// Uniform 0..999 shuffled via LCG — streaming est should sit in band.
	s: Set
	set_init(&s)
	x: u64 = 1
	for i in 0 ..< 20_000 {
		x = x * 6364136223846793005 + 1
		sample := f64(x % 1000)
		set_observe(&s, sample)
	}
	snap := set_snapshot(s)
	testing.expect(t, snap.n == 20_000, "n")
	// Loose bands: Frugal is approximate.
	testing.expect(t, snap.p50 > 300 && snap.p50 < 700, "est p50 mid")
	testing.expect(t, snap.p75 > snap.p50, "est order p75")
	testing.expect(t, snap.p90 > snap.p75, "est order p90")
	testing.expect(t, snap.p99 > snap.p90, "est order p99")
	testing.expect(t, snap.p99 > 800, "est p99 high")
}

@(test)
test_streaming_constant :: proc(t: ^testing.T) {
	s: Set
	for i in 0 ..< 1000 {
		set_observe(&s, 42)
	}
	snap := set_snapshot(s)
	testing.expect(t, math.abs(snap.p50 - 42) < 0.01, "p50 const")
	testing.expect(t, math.abs(snap.p99 - 42) < 0.01, "p99 const")
}

@(test)
test_rate_from_counts :: proc(t: ^testing.T) {
	testing.expect_value(t, rate_from_counts(100, 200, 1.0), 100)
	testing.expect_value(t, rate_from_counts(100, 200, 0.5), 200)
	testing.expect_value(t, rate_from_counts(200, 100, 1.0), 0) // wrap guard
	testing.expect_value(t, rate_from_counts(0, 50, 0), 0)
}

@(test)
test_rate_window_tick :: proc(t: ^testing.T) {
	w: Rate_Window
	rate_window_init(&w)
	_, ok0 := rate_window_tick(&w, 0, 1.0)
	testing.expect(t, !ok0, "first tick seeds only")
	sample, ok1 := rate_window_tick(&w, 1000, 1.0)
	testing.expect(t, ok1, "second tick observes")
	testing.expect(t, math.abs(sample - 1000) < 0.01, "1000 rps")
	snap := rate_window_snapshot(w)
	testing.expect(t, snap.n == 1, "one rate sample")
	testing.expect(t, math.abs(snap.p50 - 1000) < 0.01, "rps p50")
}

@(test)
test_est_single_quantile :: proc(t: ^testing.T) {
	e: Est
	// Stream mostly small, rare large — p99 should climb above p50.
	for i in 0 ..< 5000 {
		est_observe(&e, 10, 0.99)
		if i % 100 == 0 {
			est_observe(&e, 1000, 0.99)
		}
	}
	testing.expect(t, e.estimate > 10, "p99 pulls up")
}
