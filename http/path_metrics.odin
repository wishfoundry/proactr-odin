// Basic path instrumentation for TLS/H2 matrix and performance tuning.
// Always compiled; atomic adds only (cheap). Log/scrape via path_metrics_*.
//
// Buckets (where time/bytes go on the ciphered path):
//   seal_calls / pt_bytes / ct_bytes  — SSL_write + wBIO CT produced
//   h2_flush / h2_pt_bytes            — H2 frame plain into SSL_write
//   ct_sends                          — ciphertext submit_send ops
//   materialize                       — plan materialize (clear path cousin)
//   reqs                              — completed response seal cycles (approx)
//
// Cycle counters (HTTP_PHASE_STATS only — profiling builds):
//   seal_cyc / ssl_write_cyc / bio_read_cyc / materialize_cyc / ahead_seals
package http

import "base:intrinsics"
import "core:fmt"
import "core:log"
import "core:strings"
import "core:sync"

path_reqs:           u64
path_seal_calls:     u64
path_pt_bytes:       u64
path_ct_bytes:       u64
path_h2_flush:       u64
path_h2_pt_bytes:    u64
path_ssl_write_ok:   u64
path_ct_sends:       u64
path_materialize:    u64

// Duty-cycle / reactor law counters (Plan R2). Always live; atomic adds only.
// seal_windows: SSL_write windows on reactor_tls_flush (H1 oneshot + H2); not stream.
// kevent_turns: reactor_tls_flush entries (proxy for seal_windows_per_kevent_turn).
// soft_cq_send_completes: proactor send CQE without reactor_h1 — expect ~0 on Darwin
//   pure H1/H2 TLS bulk matrix cells; clear-H1 cells still charge; residual arms do not.
// eagain_arms: residual WRITE arms after EAGAIN (reactor_arm_write_residual).
path_seal_windows:            u64
path_kevent_turns:            u64
path_soft_cq_send_completes:  u64
path_eagain_arms:             u64

// Profiling cycles (only accumulated when HTTP_PHASE_STATS).
path_seal_cyc:         u64 // full seal window: SSL_write + bio_read
path_ssl_write_cyc:    u64
path_bio_read_cyc:     u64
path_materialize_cyc:  u64
path_ahead_seals:      u64 // dual-CT try_ahead seal successes (n_ct > 0)
path_promote:          u64 // promote_hold submitted a ready slab

path_metrics_note_req :: #force_inline proc "contextless" () {
	sync.atomic_add(&path_reqs, 1)
}

path_metrics_note_seal :: #force_inline proc "contextless" (pt, ct: u64) {
	sync.atomic_add(&path_seal_calls, 1)
	if pt != 0 {
		sync.atomic_add(&path_pt_bytes, pt)
	}
	if ct != 0 {
		sync.atomic_add(&path_ct_bytes, ct)
	}
}

// H1/TLS: SSL_write success — counts PT plain into OpenSSL.
path_metrics_note_ssl_write :: #force_inline proc "contextless" (pt: u64) {
	sync.atomic_add(&path_ssl_write_ok, 1)
	if pt != 0 {
		sync.atomic_add(&path_pt_bytes, pt)
	}
}

// H2: frame plain fed to SSL_write (also counted in pt_bytes for total seal input).
path_metrics_note_h2_flush :: #force_inline proc "contextless" (pt: u64) {
	sync.atomic_add(&path_h2_flush, 1)
	if pt != 0 {
		sync.atomic_add(&path_h2_pt_bytes, pt)
		sync.atomic_add(&path_pt_bytes, pt)
	}
}

// Ciphertext drained from wBIO and submitted to the wire.
path_metrics_note_ct_send :: #force_inline proc "contextless" (ct: u64) {
	sync.atomic_add(&path_ct_sends, 1)
	if ct != 0 {
		sync.atomic_add(&path_ct_bytes, ct)
	}
}

path_metrics_note_materialize :: #force_inline proc "contextless" () {
	sync.atomic_add(&path_materialize, 1)
}

// Cycle helpers — no-op cost when HTTP_PHASE_STATS is false (compile-time strip).
path_metrics_cyc_now :: #force_inline proc "contextless" () -> u64 {
	when HTTP_PHASE_STATS {
		return u64(intrinsics.read_cycle_counter())
	} else {
		return 0
	}
}

path_metrics_note_seal_cycles :: #force_inline proc "contextless" (ssl_write_c, bio_read_c: u64) {
	when HTTP_PHASE_STATS {
		if ssl_write_c != 0 {
			sync.atomic_add(&path_ssl_write_cyc, ssl_write_c)
		}
		if bio_read_c != 0 {
			sync.atomic_add(&path_bio_read_cyc, bio_read_c)
		}
		total := ssl_write_c + bio_read_c
		if total != 0 {
			sync.atomic_add(&path_seal_cyc, total)
		}
	}
}

path_metrics_note_materialize_cycles :: #force_inline proc "contextless" (c: u64) {
	when HTTP_PHASE_STATS {
		if c != 0 {
			sync.atomic_add(&path_materialize_cyc, c)
		}
	}
}

path_metrics_note_ahead_seal :: #force_inline proc "contextless" () {
	when HTTP_PHASE_STATS {
		sync.atomic_add(&path_ahead_seals, 1)
	}
}

path_metrics_note_promote :: #force_inline proc "contextless" () {
	when HTTP_PHASE_STATS {
		sync.atomic_add(&path_promote, 1)
	}
}

path_metrics_note_seal_window :: #force_inline proc "contextless" () {
	sync.atomic_add(&path_seal_windows, 1)
}

path_metrics_note_kevent_turn :: #force_inline proc "contextless" () {
	sync.atomic_add(&path_kevent_turns, 1)
}

// Proactor send CQE only — never call from Darwin H1 reactor residual path.
path_metrics_note_soft_cq_send_complete :: #force_inline proc "contextless" () {
	sync.atomic_add(&path_soft_cq_send_completes, 1)
}

path_metrics_note_eagain_arm :: #force_inline proc "contextless" () {
	sync.atomic_add(&path_eagain_arms, 1)
}

// Operator-facing engine label (not APP_CONTRACT; never use in handlers/examples).
path_metrics_io_engine :: proc() -> string {
	when ODIN_OS == .Linux {
		return "proactor-uring"
	} else when ODIN_OS == .Darwin {
		// P5: native reactor kqueue wait ownership for product sockets; timers soft_cq.
		return "reactor-kqueue"
	} else when ODIN_OS == .FreeBSD || ODIN_OS == .OpenBSD || ODIN_OS == .NetBSD {
		return "proactor-kqueue-facade"
	} else when ODIN_OS == .Windows {
		return "proactor-iocp"
	} else {
		return "unknown"
	}
}

// Operator scrape note (not APP_CONTRACT). Keep short; expand in INVENTORY.md.
path_metrics_io_engine_note :: proc() -> string {
	when ODIN_OS == .Darwin {
		// P5 full wait: product sockets on native reactor kqueue; timers soft_cq only.
		return "reactor_kqueue_wait;level_residual_write;timers_merged_wait;wbio_peek_drain;seal_128k;fairness_write_rearm;darwin_no_hold_slab;plain_split_8k;no_proactr_socket_submit;no_dual_ct_ahead"
	} else {
		return ""
	}
}

path_metrics_reset :: proc() {
	sync.atomic_store(&path_reqs, 0)
	sync.atomic_store(&path_seal_calls, 0)
	sync.atomic_store(&path_pt_bytes, 0)
	sync.atomic_store(&path_ct_bytes, 0)
	sync.atomic_store(&path_h2_flush, 0)
	sync.atomic_store(&path_h2_pt_bytes, 0)
	sync.atomic_store(&path_ssl_write_ok, 0)
	sync.atomic_store(&path_ct_sends, 0)
	sync.atomic_store(&path_materialize, 0)
	sync.atomic_store(&path_seal_windows, 0)
	sync.atomic_store(&path_kevent_turns, 0)
	sync.atomic_store(&path_soft_cq_send_completes, 0)
	sync.atomic_store(&path_eagain_arms, 0)
	sync.atomic_store(&path_seal_cyc, 0)
	sync.atomic_store(&path_ssl_write_cyc, 0)
	sync.atomic_store(&path_bio_read_cyc, 0)
	sync.atomic_store(&path_materialize_cyc, 0)
	sync.atomic_store(&path_ahead_seals, 0)
	sync.atomic_store(&path_promote, 0)
	when HTTP_PHASE_STATS {
		// Also clear HTTP request phase buckets so /_matrix/reset is a full baseline.
		sync.atomic_store(&phase_n, 0)
		sync.atomic_store(&phase_parse_cyc, 0)
		sync.atomic_store(&phase_header_parse_cyc, 0)
		sync.atomic_store(&phase_rline_parse_cyc, 0)
		sync.atomic_store(&phase_handle_cyc, 0)
		sync.atomic_store(&phase_build_cyc, 0)
		sync.atomic_store(&phase_reset_cyc, 0)
	}
}

// path_metrics_format returns a text/plain scrape (key=value lines).
path_metrics_format :: proc(allocator := context.allocator) -> string {
	reqs := sync.atomic_load(&path_reqs)
	seal := sync.atomic_load(&path_seal_calls)
	pt := sync.atomic_load(&path_pt_bytes)
	ct := sync.atomic_load(&path_ct_bytes)
	h2f := sync.atomic_load(&path_h2_flush)
	h2pt := sync.atomic_load(&path_h2_pt_bytes)
	sslw := sync.atomic_load(&path_ssl_write_ok)
	cts := sync.atomic_load(&path_ct_sends)
	mat := sync.atomic_load(&path_materialize)
	swin := sync.atomic_load(&path_seal_windows)
	kturns := sync.atomic_load(&path_kevent_turns)
	soft_cq := sync.atomic_load(&path_soft_cq_send_completes)
	eagain := sync.atomic_load(&path_eagain_arms)
	// Expansion ratios help spot seal overhead.
	ratio: f64 = 0
	if pt > 0 {
		ratio = f64(ct) / f64(pt)
	}
	seals_per_req: f64 = 0
	if reqs > 0 {
		seals_per_req = f64(seal) / f64(reqs)
	}
	// Duty: seal windows per reactor turn (0 if no reactor turns).
	sw_per_turn: f64 = 0
	if kturns > 0 {
		sw_per_turn = f64(swin) / f64(kturns)
	}
	b: strings.Builder
	strings.builder_init(&b, allocator)
	fmt.sbprintf(&b, "peer=proactr\n")
	fmt.sbprintf(&b, "io_engine=%s\n", path_metrics_io_engine())
	if note := path_metrics_io_engine_note(); note != "" {
		fmt.sbprintf(&b, "io_engine_note=%s\n", note)
	}
	fmt.sbprintf(&b, "reqs=%d\n", reqs)
	fmt.sbprintf(&b, "seal_calls=%d\n", seal)
	fmt.sbprintf(&b, "seals_per_req=%.3f\n", seals_per_req)
	fmt.sbprintf(&b, "ssl_write_ok=%d\n", sslw)
	fmt.sbprintf(&b, "pt_bytes=%d\n", pt)
	fmt.sbprintf(&b, "ct_bytes=%d\n", ct)
	fmt.sbprintf(&b, "ct_pt_ratio=%.4f\n", ratio)
	fmt.sbprintf(&b, "h2_flush=%d\n", h2f)
	fmt.sbprintf(&b, "h2_pt_bytes=%d\n", h2pt)
	fmt.sbprintf(&b, "ct_sends=%d\n", cts)
	fmt.sbprintf(&b, "materialize=%d\n", mat)
	fmt.sbprintf(&b, "seal_windows=%d\n", swin)
	fmt.sbprintf(&b, "kevent_turns=%d\n", kturns)
	fmt.sbprintf(&b, "seal_windows_per_kevent_turn=%.3f\n", sw_per_turn)
	fmt.sbprintf(&b, "soft_cq_send_completes=%d\n", soft_cq)
	fmt.sbprintf(&b, "eagain_arms=%d\n", eagain)
	when HTTP_PHASE_STATS {
		seal_c := sync.atomic_load(&path_seal_cyc)
		ssl_c := sync.atomic_load(&path_ssl_write_cyc)
		bio_c := sync.atomic_load(&path_bio_read_cyc)
		mat_c := sync.atomic_load(&path_materialize_cyc)
		ahead := sync.atomic_load(&path_ahead_seals)
		promo := sync.atomic_load(&path_promote)
		// Denominators: prefer seal_calls for seal stages; materialize count for mat.
		sf := f64(seal) if seal > 0 else 1.0
		mf := f64(mat) if mat > 0 else 1.0
		rf := f64(reqs) if reqs > 0 else 1.0
		fmt.sbprintf(&b, "seal_cyc=%d\n", seal_c)
		fmt.sbprintf(&b, "ssl_write_cyc=%d\n", ssl_c)
		fmt.sbprintf(&b, "bio_read_cyc=%d\n", bio_c)
		fmt.sbprintf(&b, "materialize_cyc=%d\n", mat_c)
		fmt.sbprintf(&b, "ahead_seals=%d\n", ahead)
		fmt.sbprintf(&b, "promote=%d\n", promo)
		fmt.sbprintf(&b, "cyc_per_seal=%.0f\n", f64(seal_c) / sf)
		fmt.sbprintf(&b, "cyc_ssl_write_per_seal=%.0f\n", f64(ssl_c) / sf)
		fmt.sbprintf(&b, "cyc_bio_read_per_seal=%.0f\n", f64(bio_c) / sf)
		fmt.sbprintf(&b, "cyc_materialize_per=%.0f\n", f64(mat_c) / mf)
		// Share of seal window cycles.
		ssl_share := 100.0 * f64(ssl_c) / f64(seal_c if seal_c > 0 else 1)
		bio_share := 100.0 * f64(bio_c) / f64(seal_c if seal_c > 0 else 1)
		fmt.sbprintf(&b, "seal_share_ssl_write=%.1f\n", ssl_share)
		fmt.sbprintf(&b, "seal_share_bio_read=%.1f\n", bio_share)
		// HTTP request phases (parse/handle/build/reset).
		pn := sync.atomic_load(&phase_n)
		pp := sync.atomic_load(&phase_parse_cyc)
		ph := sync.atomic_load(&phase_handle_cyc)
		pb := sync.atomic_load(&phase_build_cyc)
		pr := sync.atomic_load(&phase_reset_cyc)
		pf := f64(pn) if pn > 0 else 1.0
		fmt.sbprintf(&b, "phase_n=%d\n", pn)
		fmt.sbprintf(&b, "phase_parse_cyc_per=%.0f\n", f64(pp) / pf)
		fmt.sbprintf(&b, "phase_handle_cyc_per=%.0f\n", f64(ph) / pf)
		fmt.sbprintf(&b, "phase_build_cyc_per=%.0f\n", f64(pb) / pf)
		fmt.sbprintf(&b, "phase_reset_cyc_per=%.0f\n", f64(pr) / pf)
		// seal cycles attributed per completed req (approx).
		fmt.sbprintf(&b, "seal_cyc_per_req=%.0f\n", f64(seal_c) / rf)
		// Ahead efficiency: seals that happened while send inflight.
		ahead_share := 100.0 * f64(ahead) / f64(seal if seal > 0 else 1)
		fmt.sbprintf(&b, "ahead_seal_share=%.1f\n", ahead_share)
	}
	return strings.to_string(b)
}

path_metrics_log :: proc() {
	s := path_metrics_format(context.temp_allocator)
	log.infof("PATH_METRICS\n%s", s)
}
