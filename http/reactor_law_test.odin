// Plan R2 pure residual / fairness law tests (no OpenSSL, no ring).
package http

import "core:testing"

@(test)
test_reactor_may_ssl_write_residual_first :: proc(t: ^testing.T) {
	testing.expect(t, reactor_may_ssl_write(0), "empty residual may SSL_write")
	testing.expect(t, reactor_may_ssl_write(-1), "negative residual treated empty")
	testing.expect(t, !reactor_may_ssl_write(1), "residual forbids SSL_write")
	testing.expect(t, !reactor_may_ssl_write(64 * 1024), "any residual forbids SSL_write")
}

@(test)
test_reactor_residual_advance_and_stash :: proc(t: ^testing.T) {
	off, n := reactor_residual_advance(0, 100, 40)
	testing.expect_value(t, off, 40)
	testing.expect_value(t, n, 60)

	off, n = reactor_residual_advance(40, 60, 60)
	testing.expect_value(t, off, 0)
	testing.expect_value(t, n, 0)

	off, n = reactor_residual_advance(0, 50, 0)
	testing.expect_value(t, off, 0)
	testing.expect_value(t, n, 50)

	off, n = reactor_residual_stash(1000, 0)
	testing.expect_value(t, off, 0)
	testing.expect_value(t, n, 1000)

	off, n = reactor_residual_stash(1000, 250)
	testing.expect_value(t, off, 250)
	testing.expect_value(t, n, 750)

	off, n = reactor_residual_stash(1000, 1000)
	testing.expect_value(t, off, 0)
	testing.expect_value(t, n, 0)
}

@(test)
test_reactor_fairness_hit :: proc(t: ^testing.T) {
	testing.expect(t, !reactor_fairness_hit(0, 0))
	testing.expect(t, !reactor_fairness_hit(REACTOR_FAIR_PLAIN_BYTES - 1, REACTOR_FAIR_WINDOWS - 1))
	testing.expect(t, reactor_fairness_hit(0, REACTOR_FAIR_WINDOWS))
	testing.expect(t, reactor_fairness_hit(REACTOR_FAIR_PLAIN_BYTES, 0))
	testing.expect(t, reactor_fairness_hit(REACTOR_FAIR_PLAIN_BYTES + 1, 1))
}

@(test)
test_reactor_seal_window_constant :: proc(t: ^testing.T) {
	// D8: 128 KiB reactor trunk (still below dual-CT 256 KiB default).
	testing.expect_value(t, REACTOR_SEAL_WINDOW, 128 * 1024)
	testing.expect(t, REACTOR_SEAL_WINDOW < TLS_SEAL_WINDOW_DEFAULT)
	testing.expect_value(t, REACTOR_FAIR_WINDOWS, 16)
}
