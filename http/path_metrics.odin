// Basic path instrumentation for TLS/H2 matrix and performance tuning.
// Always compiled; atomic adds only (cheap). Log/scrape via path_metrics_*.
//
// Buckets (where time/bytes go on the ciphered path):
//   seal_calls / pt_bytes / ct_bytes  — SSL_write + wBIO CT produced
//   h2_flush / h2_pt_bytes            — H2 frame plain into SSL_write
//   ct_sends                          — ciphertext submit_send ops
//   materialize                       — plan materialize (clear path cousin)
//   reqs                              — completed response seal cycles (approx)
package http

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
	// Expansion ratios help spot seal overhead.
	ratio: f64 = 0
	if pt > 0 {
		ratio = f64(ct) / f64(pt)
	}
	b: strings.Builder
	strings.builder_init(&b, allocator)
	fmt.sbprintf(&b, "peer=proactr\n")
	fmt.sbprintf(&b, "reqs=%d\n", reqs)
	fmt.sbprintf(&b, "seal_calls=%d\n", seal)
	fmt.sbprintf(&b, "ssl_write_ok=%d\n", sslw)
	fmt.sbprintf(&b, "pt_bytes=%d\n", pt)
	fmt.sbprintf(&b, "ct_bytes=%d\n", ct)
	fmt.sbprintf(&b, "ct_pt_ratio=%.4f\n", ratio)
	fmt.sbprintf(&b, "h2_flush=%d\n", h2f)
	fmt.sbprintf(&b, "h2_pt_bytes=%d\n", h2pt)
	fmt.sbprintf(&b, "ct_sends=%d\n", cts)
	fmt.sbprintf(&b, "materialize=%d\n", mat)
	return strings.to_string(b)
}

path_metrics_log :: proc() {
	s := path_metrics_format(context.temp_allocator)
	log.infof("PATH_METRICS\n%s", s)
}
