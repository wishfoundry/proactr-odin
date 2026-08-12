// Streaming quantile / quartile helpers for app middleware and handlers.
// Live path (fixed memory, O(1) per sample):
package quantile

import "core:math"
import "core:slice"

// Target quantiles for Set (fixed product surface).
SET_P50 :: 0.50
SET_P75 :: 0.75
SET_P90 :: 0.90
SET_P99 :: 0.99

// Est is a Frugal-2 streaming estimate for one quantile q ∈ (0, 1).
// Units are whatever the caller observes (ns, µs, req/s, …).
Est :: struct {
	estimate: f64,
	step:     f64,
	sign:     i8, // -1, 0, +1 — last move direction (Frugal-2 step adapt)
	seeded:   bool,
	n:        u64, // samples seen by this Est
}

// Set holds the common ops four-pack. Observe latency on one Set and RPS on
// another — never feed both sample kinds into the same Set.
Set :: struct {
	p50, p75, p90, p99: Est,
	n:                  u64, // total set_observe calls
}

// Snapshot is a plain read-out of estimated values (and sample count).
Snapshot :: struct {
	p50, p75, p90, p99: f64,
	n:                  u64,
}

// Quartiles is classical Q1 / median / Q3 (offline).
Quartiles :: struct {
	q1, q2, q3: f64,
	n:          int,
}


est_init :: proc(e: ^Est) {
	e^ = {}
}

est_reset :: proc(e: ^Est) {
	e^ = {}
}

// est_observe updates e toward quantile q using sample.
// q must be in (0, 1); typical values: 0.5, 0.75, 0.9, 0.99.
est_observe :: proc(e: ^Est, sample: f64, q: f64) {
	e.n += 1
	if !e.seeded {
		e.estimate = sample
		e.step = 1
		e.sign = 0
		e.seeded = true
		return
	}
	if math.is_nan(sample) || math.is_inf(sample) {
		return
	}

	// Clamp q to open unit interval so coin thresholds stay meaningful.
	qq := q
	if qq <= 0 {
		qq = 0.001
	} else if qq >= 1 {
		qq = 0.999
	}

	r := frugal_coin(e.n, sample)
	if sample > e.estimate && r > (1 - qq) {
		if e.sign > 0 {
			e.step += 1
		} else if e.sign < 0 {
			e.step = max_f64(1, e.step * 0.5)
		}
		e.estimate += e.step
		// Frugal-2U: do not overshoot the current sample.
		if e.estimate > sample {
			e.estimate = sample
			e.step = 1
		}
		e.sign = 1
	} else if sample < e.estimate && r > qq {
		if e.sign < 0 {
			e.step += 1
		} else if e.sign > 0 {
			e.step = max_f64(1, e.step * 0.5)
		}
		e.estimate -= e.step
		if e.estimate < sample {
			e.estimate = sample
			e.step = 1
		}
		e.sign = -1
	}
	if e.step < 1 {
		e.step = 1
	}
}

est_value :: #force_inline proc(e: Est) -> f64 {
	return e.estimate
}


set_init :: proc(s: ^Set) {
	s^ = {}
}

set_reset :: proc(s: ^Set) {
	s^ = {}
}

// set_observe feeds one sample into all four estimators.
set_observe :: proc(s: ^Set, sample: f64) {
	s.n += 1
	est_observe(&s.p50, sample, SET_P50)
	est_observe(&s.p75, sample, SET_P75)
	est_observe(&s.p90, sample, SET_P90)
	est_observe(&s.p99, sample, SET_P99)
}

// set_observe_i64 is a convenience for integer latencies (e.g. ns, cycles).
set_observe_i64 :: #force_inline proc(s: ^Set, sample: i64) {
	set_observe(s, f64(sample))
}

set_snapshot :: proc(s: Set) -> Snapshot {
	return Snapshot {
		p50 = s.p50.estimate,
		p75 = s.p75.estimate,
		p90 = s.p90.estimate,
		p99 = s.p99.estimate,
		n   = s.n,
	}
}


// rate_from_counts converts a monotonic counter into a rate sample for a window.
// Pass the same counter (e.g. completed requests) at window boundaries:
//   sample := quantile.rate_from_counts(prev, now, dt_sec)
//   quantile.set_observe(&rps_set, sample)
//   prev = now
rate_from_counts :: proc(prev_count, now_count: u64, dt_sec: f64) -> f64 {
	if dt_sec <= 0 || now_count < prev_count {
		return 0
	}
	return f64(now_count - prev_count) / dt_sec
}

// Rate_Window pairs a Set with a previous counter for tick-based RPS estimates.
// Not required — rate_from_counts + set_observe is enough — but handy in middleware.
Rate_Window :: struct {
	set:        Set,
	prev_count: u64,
	started:    bool,
}

rate_window_init :: proc(w: ^Rate_Window) {
	w^ = {}
}

rate_window_reset :: proc(w: ^Rate_Window) {
	w^ = {}
}

// rate_window_tick observes one rate sample from the counter delta over dt_sec.
// First call only seeds prev_count (no observe) so the first full window is clean.
rate_window_tick :: proc(w: ^Rate_Window, now_count: u64, dt_sec: f64) -> (sample: f64, observed: bool) {
	if !w.started {
		w.prev_count = now_count
		w.started = true
		return 0, false
	}
	sample = rate_from_counts(w.prev_count, now_count, dt_sec)
	w.prev_count = now_count
	if dt_sec > 0 {
		set_observe(&w.set, sample)
		return sample, true
	}
	return sample, false
}

rate_window_snapshot :: proc(w: Rate_Window) -> Snapshot {
	return set_snapshot(w.set)
}


// percentile returns the p-quantile of samples (p in [0, 1]).
// Copies and sorts; empty input → 0.
percentile :: proc(samples: []f64, p: f64, allocator := context.allocator) -> f64 {
	if len(samples) == 0 {
		return 0
	}
	tmp := make([]f64, len(samples), allocator)
	defer delete(tmp, allocator)
	copy(tmp, samples)
	slice.sort(tmp)
	return percentile_sorted(tmp, p)
}

// percentile_sorted assumes samples are sorted ascending. p in [0, 1].
percentile_sorted :: proc(sorted: []f64, p: f64) -> f64 {
	n := len(sorted)
	if n == 0 {
		return 0
	}
	if n == 1 {
		return sorted[0]
	}
	pp := p
	if pp < 0 {
		pp = 0
	} else if pp > 1 {
		pp = 1
	}
	// Nearest-rank with linear interpolation between neighbors.
	pos := pp * f64(n - 1)
	lo := int(math.floor(pos))
	hi := int(math.ceil(pos))
	if lo < 0 {
		lo = 0
	}
	if hi >= n {
		hi = n - 1
	}
	if lo == hi {
		return sorted[lo]
	}
	frac := pos - f64(lo)
	return sorted[lo] * (1 - frac) + sorted[hi] * frac
}

// percentiles fills out[i] with quantile ps[i]. len(out) must be >= len(ps).
// One sort of a copy of samples. Returns false if out is too short.
percentiles :: proc(samples: []f64, ps: []f64, out: []f64, allocator := context.allocator) -> bool {
	if len(out) < len(ps) {
		return false
	}
	if len(samples) == 0 {
		for i in 0 ..< len(ps) {
			out[i] = 0
		}
		return true
	}
	tmp := make([]f64, len(samples), allocator)
	defer delete(tmp, allocator)
	copy(tmp, samples)
	slice.sort(tmp)
	for p, i in ps {
		out[i] = percentile_sorted(tmp, p)
	}
	return true
}

// quartiles returns Q1 (p25), Q2/median (p50), Q3 (p75).
quartiles :: proc(samples: []f64, allocator := context.allocator) -> Quartiles {
	if len(samples) == 0 {
		return {}
	}
	tmp := make([]f64, len(samples), allocator)
	defer delete(tmp, allocator)
	copy(tmp, samples)
	slice.sort(tmp)
	return Quartiles {
		q1 = percentile_sorted(tmp, 0.25),
		q2 = percentile_sorted(tmp, 0.50),
		q3 = percentile_sorted(tmp, 0.75),
		n  = len(samples),
	}
}

// set_percentiles is the offline analogue of Set: true p50/p75/p90/p99 from samples.
set_percentiles :: proc(samples: []f64, allocator := context.allocator) -> Snapshot {
	if len(samples) == 0 {
		return {}
	}
	tmp := make([]f64, len(samples), allocator)
	defer delete(tmp, allocator)
	copy(tmp, samples)
	slice.sort(tmp)
	return Snapshot {
		p50 = percentile_sorted(tmp, SET_P50),
		p75 = percentile_sorted(tmp, SET_P75),
		p90 = percentile_sorted(tmp, SET_P90),
		p99 = percentile_sorted(tmp, SET_P99),
		n   = u64(len(samples)),
	}
}


@(private)
max_f64 :: #force_inline proc(a, b: f64) -> f64 {
	return a if a > b else b
}

// Deterministic pseudo-coin in [0, 1) from sample index + bits of the value.
// Avoids RNG / context so est_observe stays usable on hot paths and in tests.
@(private)
frugal_coin :: proc(n: u64, sample: f64) -> f64 {
	bits := transmute(u64)sample
	x := n ~ bits ~ (bits >> 33)
	// splitmix64 finalizer-ish
	x = (x ~ (x >> 30)) * 0xbf58476d1ce4e5b9
	x = (x ~ (x >> 27)) * 0x94d049bb133111eb
	x = x ~ (x >> 31)
	// top 53 bits → [0, 1)
	return f64(x >> 11) * (1.0 / 9007199254740992.0)
}
