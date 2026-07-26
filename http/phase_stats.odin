// Optional per-request phase timers (cycle counters). Enable with:
//   odin build … -define:HTTP_PHASE_STATS=true
// Aggregates every HTTP_PHASE_STATS_EVERY completed requests.
// Hot path: lock-free atomic adds only.
package http

import "base:intrinsics"
import "core:log"
import "core:sync"

HTTP_PHASE_STATS :: #config(HTTP_PHASE_STATS, false)
HTTP_PHASE_STATS_EVERY :: #config(HTTP_PHASE_STATS_EVERY, 50_000)

@(private)
phase_n:                u64
phase_parse_cyc:        u64
phase_header_parse_cyc: u64
phase_rline_parse_cyc:  u64
phase_handle_cyc:       u64
phase_build_cyc:        u64
phase_reset_cyc:        u64

// Per-connection in-flight marks (only when HTTP_PHASE_STATS).
@(private)
Phase_Conn :: struct {
	parse_t0:  u64,
	handle_t0: u64,
	in_parse:  bool,
	in_handle: bool,
}

@(private)
phase_now :: #force_inline proc "contextless" () -> u64 {
	return u64(intrinsics.read_cycle_counter())
}

@(private)
phase_add :: proc(n, parse, hdr, rline, handle, build, reset: u64) {
	when HTTP_PHASE_STATS {
		if parse != 0 {
			sync.atomic_add(&phase_parse_cyc, parse)
		}
		if hdr != 0 {
			sync.atomic_add(&phase_header_parse_cyc, hdr)
		}
		if rline != 0 {
			sync.atomic_add(&phase_rline_parse_cyc, rline)
		}
		if handle != 0 {
			sync.atomic_add(&phase_handle_cyc, handle)
		}
		if build != 0 {
			sync.atomic_add(&phase_build_cyc, build)
		}
		if reset != 0 {
			sync.atomic_add(&phase_reset_cyc, reset)
		}
		if n != 0 {
			// atomic_add returns previous value
			prev := sync.atomic_add(&phase_n, n)
			total := prev + n
			if total % u64(HTTP_PHASE_STATS_EVERY) == 0 {
				phase_stats_log()
			}
		}
	}
}

phase_stats_log :: proc() {
	when HTTP_PHASE_STATS {
		n := sync.atomic_load(&phase_n)
		if n == 0 {
			return
		}
		parse := sync.atomic_load(&phase_parse_cyc)
		hdr := sync.atomic_load(&phase_header_parse_cyc)
		rline := sync.atomic_load(&phase_rline_parse_cyc)
		handle := sync.atomic_load(&phase_handle_cyc)
		build := sync.atomic_load(&phase_build_cyc)
		reset := sync.atomic_load(&phase_reset_cyc)
		den := parse + handle + reset
		if den == 0 {
			den = 1
		}
		nf := f64(n)
		pct :: proc(part, whole: u64) -> f64 {
			return 100.0 * f64(part) / f64(whole)
		}
		log.infof(
			"PHASE n=%d  cyc/req: parse=%.0f (hdr=%.0f rline=%.0f) handle=%.0f (build=%.0f) reset=%.0f  | share parse=%.1f%% handle=%.1f%% reset=%.1f%%  | hdr_of_parse=%.1f%%",
			n,
			f64(parse) / nf,
			f64(hdr) / nf,
			f64(rline) / nf,
			f64(handle) / nf,
			f64(build) / nf,
			f64(reset) / nf,
			pct(parse, den),
			pct(handle, den),
			pct(reset, den),
			pct(hdr, parse if parse > 0 else 1),
		)
	}
}
