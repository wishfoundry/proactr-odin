// Fortunes phase profiling. Enable:
//   odin build . -out:tfb-proactr.bin -o:speed -define:FORTUNES_PROFILE=true
// Logs every FORTUNES_PROFILE_EVERY requests (default 100000).
package main

import "base:intrinsics"
import "core:fmt"
import "core:log"
import "core:sync"
import "core:time"

FORTUNES_PROFILE :: #config(FORTUNES_PROFILE, false)
FORTUNES_PROFILE_EVERY :: #config(FORTUNES_PROFILE_EVERY, 100_000)

when FORTUNES_PROFILE {
	prof_n:          u64
	prof_lock_ns:    u64
	prof_query_ns:   u64 // sqlite step + column + clone messages
	prof_sort_ns:    u64
	prof_html_ns:    u64
	prof_respond_ns: u64
	prof_total_ns:   u64
}

prof_now :: #force_inline proc() -> i64 {
	when FORTUNES_PROFILE {
		return time.tick_now()._nsec
	} else {
		return 0
	}
}

// Prefer cycle counter for short sections if tick resolution is coarse.
prof_cyc :: #force_inline proc "contextless" () -> u64 {
	return u64(intrinsics.read_cycle_counter())
}

when FORTUNES_PROFILE {
	prof_lock_cyc:    u64
	prof_query_cyc:   u64
	prof_sort_cyc:    u64
	prof_html_cyc:    u64
	prof_respond_cyc: u64
	prof_total_cyc:   u64
}

prof_add :: proc(
	lock_c, query_c, sort_c, html_c, respond_c, total_c: u64,
	lock_ns, query_ns, sort_ns, html_ns, respond_ns, total_ns: u64,
) {
	when FORTUNES_PROFILE {
		if lock_c != 0 do sync.atomic_add(&prof_lock_cyc, lock_c)
		if query_c != 0 do sync.atomic_add(&prof_query_cyc, query_c)
		if sort_c != 0 do sync.atomic_add(&prof_sort_cyc, sort_c)
		if html_c != 0 do sync.atomic_add(&prof_html_cyc, html_c)
		if respond_c != 0 do sync.atomic_add(&prof_respond_cyc, respond_c)
		if total_c != 0 do sync.atomic_add(&prof_total_cyc, total_c)
		if lock_ns != 0 do sync.atomic_add(&prof_lock_ns, lock_ns)
		if query_ns != 0 do sync.atomic_add(&prof_query_ns, query_ns)
		if sort_ns != 0 do sync.atomic_add(&prof_sort_ns, sort_ns)
		if html_ns != 0 do sync.atomic_add(&prof_html_ns, html_ns)
		if respond_ns != 0 do sync.atomic_add(&prof_respond_ns, respond_ns)
		if total_ns != 0 do sync.atomic_add(&prof_total_ns, total_ns)

		prev := sync.atomic_add(&prof_n, 1)
		n := prev + 1
		if n % u64(FORTUNES_PROFILE_EVERY) == 0 {
			prof_log(n)
		}
	}
}

prof_log :: proc(n: u64) {
	when FORTUNES_PROFILE {
		f := f64(n)
		total_c := f64(sync.atomic_load(&prof_total_cyc))
		pct :: proc(part, total: f64) -> f64 {
			if total <= 0 do return 0
			return 100 * part / total
		}
		lock_c := f64(sync.atomic_load(&prof_lock_cyc))
		query_c := f64(sync.atomic_load(&prof_query_cyc))
		sort_c := f64(sync.atomic_load(&prof_sort_cyc))
		html_c := f64(sync.atomic_load(&prof_html_cyc))
		respond_c := f64(sync.atomic_load(&prof_respond_cyc))
		lock_ns := f64(sync.atomic_load(&prof_lock_ns))
		query_ns := f64(sync.atomic_load(&prof_query_ns))
		sort_ns := f64(sync.atomic_load(&prof_sort_ns))
		html_ns := f64(sync.atomic_load(&prof_html_ns))
		respond_ns := f64(sync.atomic_load(&prof_respond_ns))
		total_ns := f64(sync.atomic_load(&prof_total_ns))

		log.infof(
			"fortunes_profile n=%d  avg_ns: total=%.0f lock=%.0f query=%.0f sort=%.0f html=%.0f respond=%.0f",
			n,
			total_ns / f,
			lock_ns / f,
			query_ns / f,
			sort_ns / f,
			html_ns / f,
			respond_ns / f,
		)
		log.infof(
			"fortunes_profile cyc%%: lock=%.1f query=%.1f sort=%.1f html=%.1f respond=%.1f  (avg total cyc=%.0f)",
			pct(lock_c, total_c),
			pct(query_c, total_c),
			pct(sort_c, total_c),
			pct(html_c, total_c),
			pct(respond_c, total_c),
			total_c / f,
		)
		// Approximate RPS ceiling if only handler work (single core): 1e9 / avg_ns
		if total_ns > 0 {
			log.infof(
				"fortunes_profile serial_rps_ceiling≈%.0f  (1e9/avg_total_ns; multi-worker can exceed)",
				1e9 / (total_ns / f),
			)
		}
		_ = fmt.tprintf
	}
}
