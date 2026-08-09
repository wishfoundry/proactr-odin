// Plan R2 pure reactor law helpers (OS-invariant; unit-testable without kqueue/OpenSSL).
// Darwin live path: tls_reactor_flush.odin (+build darwin). Linux ignores these for dual-CT.
package http

// Reactor TLS seal trunk (D8): start 64 KiB plain per SSL_write (drogon-shaped).
REACTOR_SEAL_WINDOW :: 64 * 1024

// Fairness cap (D9): first of 2 MiB plain or 32 SSL_write windows per flush entry.
// 32×64KiB covers 2 MiB without a soft-CQ yield (impl critic: no soft Nop between windows).
// True kevent WRITE re-arm for fairness is a follow-up; do not soft-Nop.
REACTOR_FAIR_PLAIN_BYTES :: 2 * 1024 * 1024
REACTOR_FAIR_WINDOWS :: 32

// R-ORDER residual gate: SSL_write forbidden while residual CT remains.
reactor_may_ssl_write :: #force_inline proc(residual_n: int) -> bool {
	return residual_n <= 0
}

// Fairness preempt: more plain/windows would exceed per-turn budget.
reactor_fairness_hit :: #force_inline proc(plain_sealed: int, windows: int) -> bool {
	if windows >= REACTOR_FAIR_WINDOWS {
		return true
	}
	if plain_sealed >= REACTOR_FAIR_PLAIN_BYTES {
		return true
	}
	return false
}

// Advance residual cursor after a partial write; returns new (off, n).
// Pure: does not touch sockets. n_sent clamped to residual_n.
reactor_residual_advance :: proc(off, residual_n, n_sent: int) -> (new_off, new_n: int) {
	if residual_n <= 0 {
		return 0, 0
	}
	if n_sent <= 0 {
		return off, residual_n
	}
	if n_sent >= residual_n {
		return 0, 0
	}
	return off + n_sent, residual_n - n_sent
}

// Stash residual CT after partial/EAGAIN write of a sealed slab.
// sealed_n = bytes just sealed into the slab; sent = bytes already on the wire.
reactor_residual_stash :: proc(sealed_n, sent: int) -> (off, n: int) {
	if sealed_n <= 0 {
		return 0, 0
	}
	if sent <= 0 {
		return 0, sealed_n
	}
	if sent >= sealed_n {
		return 0, 0
	}
	return sent, sealed_n - sent
}
