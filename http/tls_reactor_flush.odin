#+build darwin
package http

// Darwin H1 TLS oneshot flush — reactor law (Plan R2 §4).
// residual-first → SSL_write(64KiB) → drain wBIO write until EAGAIN → single residual.
// NO soft_cq between full CT windows. NO dual_ct_try_ahead. Dual-CT remains Linux-only.

import "core:c"
import "core:log"
import "core:sync"

import tls_server "../tls_server"

// reactor_tls_flush: Plan R2 hot path for ciphered H1 oneshot on Darwin.
@(private)
reactor_tls_flush :: proc(conn: ^Connection) {
	if conn == nil || conn.tls_ssl == nil {
		return
	}
	if conn.state >= .Closing {
		return
	}
	// H2 / progressive stream stay on dual-CT façade until P4.
	if conn.h2_active || tls_host_stream_long_lived(conn) {
		return
	}
	// Residual WRITE still armed: wait for CQE (do not double-send over EVFILT_WRITE).
	if conn.reactor_h1 && _conn_wire_in_flight(conn) {
		return
	}
	// Non-reactor in-flight op: do not interleave.
	if _conn_wire_in_flight(conn) {
		return
	}
	// Residual WRITE CQE fully delivered: host_on_wire cleared pending; clear residual meta.
	if conn.reactor_h1 && len(conn.wire.pending_send) == 0 {
		reactor_residual_clear(conn)
		conn.reactor_h1 = false
	}

	path_metrics_note_kevent_turn()
	p := conn.server.tls_provider
	ssl := conn.tls_ssl
	plain_sealed := 0
	windows := 0

	for {
		if conn.state >= .Closing {
			return
		}

		// --- residual first (R-ORDER): write only; no SSL_write while residual > 0 ---
		if conn.reactor_res_n > 0 {
			if !reactor_may_ssl_write(conn.reactor_res_n) {
				// gate holds — write residual
			}
			again, hard := reactor_write_residual(conn)
			if hard {
				_wire_fail(conn, "reactor residual write failed fd=%v", conn.socket)
				return
			}
			if again {
				_ = reactor_arm_write_residual(conn)
				return
			}
			// residual empty — continue (may still have wBIO or more plain)
			continue
		}

		// Drain any wBIO left from a prior seal (multi-record) without SSL_write.
		if tls_server.bio_pending_out(p, ssl) > 0 {
			again, hard := reactor_drain_wbio(conn)
			if hard {
				return
			}
			if again {
				_ = reactor_arm_write_residual(conn)
				return
			}
			continue
		}

		// Done: no residual, no wBIO, no plain.
		if tls_plain_total_remaining(conn) == 0 {
			reactor_finish_oneshot(conn)
			return
		}

		// Fairness preempt (D9): stop this entry (cap covers 2MiB / 32×64KiB).
		// No soft-CQ yield (impl critic M1). Cap sized so matrix s1m completes without yield.
		if reactor_fairness_hit(plain_sealed, windows) {
			return
		}

		// SSL_write one trunk window (64 KiB).
		if !reactor_may_ssl_write(conn.reactor_res_n) {
			// Should be unreachable (residual cleared above).
			_ = reactor_arm_write_residual(conn)
			return
		}

		ok, consumed := reactor_ssl_write_window(conn)
		if !ok {
			log.errorf("TLS reactor SSL_write fail fd=%v", conn.socket)
			connection_close(conn)
			return
		}
		if consumed > 0 {
			windows += 1
			plain_sealed += consumed
			path_metrics_note_seal_window()
		}

		// Drain CT produced by this seal (and any remaining wBIO).
		if tls_server.bio_pending_out(p, ssl) > 0 {
			again, hard := reactor_drain_wbio(conn)
			if hard {
				return
			}
			if again {
				_ = reactor_arm_write_residual(conn)
				return
			}
		}

		// Zero consume: WANT_WRITE → drain residual; WANT_READ → arm recv (R-DUPLEX).
		if consumed == 0 && tls_plain_total_remaining(conn) > 0 {
			if tls_server.bio_pending_out(p, ssl) > 0 {
				again, hard := reactor_drain_wbio(conn)
				if hard {
					return
				}
				if again {
					if !reactor_arm_write_residual(conn) {
						_wire_fail(conn, "reactor arm WRITE after WANT_WRITE failed fd=%v", conn.socket)
					}
					return
				}
				continue
			}
			// No CT pending — peer may need to send (WANT_READ path already armed recv in ssl_write).
			_ = tls_host_arm_recv(conn)
			return
		}
	}
}

// reactor_ssl_write_window: SSL_write up to REACTOR_SEAL_WINDOW plain; advance cursor.
// Does not drain wBIO (caller drains). Returns (ok, plain_consumed).
@(private)
reactor_ssl_write_window :: proc(conn: ^Connection) -> (ok: bool, consumed: int) {
	if conn == nil || conn.tls_ssl == nil {
		return false, 0
	}
	if tls_plain_total_remaining(conn) == 0 {
		return true, 0
	}
	p := conn.server.tls_provider
	ssl := conn.tls_ssl
	win_slice := tls_plain_window(conn, REACTOR_SEAL_WINDOW)
	win := len(win_slice)
	if win == 0 {
		return true, 0
	}
	if !pt_admit(&conn.pt, u32(win)) {
		win = int(min(u32(win), TLS_RECORD_PLAIN))
		if win == 0 {
			return false, 0
		}
		win_slice = tls_plain_window(conn, win)
		win = len(win_slice)
		if win == 0 {
			return true, 0
		}
		if !pt_admit(&conn.pt, u32(win)) {
			return false, 0
		}
	}
	tls_metrics_note_pt(conn.server, u64(conn.pt.admitted))

	t_ssl0 := path_metrics_cyc_now()
	ret := tls_server.write(p, ssl, raw_data(win_slice), c.int(win))
	t_ssl1 := path_metrics_cyc_now()
	if ret <= 0 {
		pt_release(&conn.pt, u32(win))
		ge := tls_server.get_error(p, ssl, ret)
		if ge == p.ERROR_WANT_WRITE {
			// Caller drains residual / arms WRITE.
			path_metrics_note_seal_cycles(t_ssl1 - t_ssl0, 0)
			return true, 0
		}
		if ge == p.ERROR_WANT_READ {
			_ = tls_host_arm_recv(conn)
			path_metrics_note_seal_cycles(t_ssl1 - t_ssl0, 0)
			return true, 0
		}
		log.debugf("reactor SSL_write error fd=%v ret=%d ge=%d", conn.socket, ret, ge)
		return false, 0
	}
	consumed = int(ret)
	if consumed > win {
		consumed = win
	}
	if consumed < win {
		pt_release(&conn.pt, u32(win - consumed))
	}
	tls_plain_advance(conn, consumed)
	path_metrics_note_ssl_write(u64(consumed))
	sync.atomic_add(&path_seal_calls, 1)
	path_metrics_note_seal_cycles(t_ssl1 - t_ssl0, 0)
	pt_release(&conn.pt, u32(consumed))
	return true, consumed
}

// reactor_drain_wbio: bio_read into dual_ct.tx, write until wBIO empty or EAGAIN.
// On EAGAIN: residual set; returns again=true. Hard fail closes connection.
@(private)
reactor_drain_wbio :: proc(conn: ^Connection) -> (again: bool, hard: bool) {
	if conn == nil || conn.tls_ssl == nil {
		return false, false
	}
	p := conn.server.tls_provider
	ssl := conn.tls_ssl
	dst := conn.dual_ct.tx
	if len(dst) == 0 {
		return false, true
	}

	for tls_server.bio_pending_out(p, ssl) > 0 {
		t_bio0 := path_metrics_cyc_now()
		n := tls_server.bio_read_net(p, ssl, dst)
		t_bio1 := path_metrics_cyc_now()
		path_metrics_note_seal_cycles(0, t_bio1 - t_bio0)
		if n <= 0 {
			return false, false
		}
		tls_metrics_note_ct(conn.server, u64(n))
		tls_metrics_inc_seal(conn.server)
		path_metrics_note_ct_send(u64(n))

		// Write this CT chunk fully or stash residual on EAGAIN.
		off := 0
		left := n
		for left > 0 {
			sent, would_block, err := host_try_send_nb(conn, dst[off:][:left])
			if err {
				_wire_fail(conn, "reactor CT write failed fd=%v", conn.socket)
				return false, true
			}
			if would_block {
				// Stash remainder as the single residual region (dst[off:off+left]).
				reactor_residual_set(conn, off, left)
				return true, false
			}
			if sent <= 0 {
				_wire_fail(conn, "reactor CT write zero fd=%v", conn.socket)
				return false, true
			}
			off += sent
			left -= sent
		}
		// Full chunk on wire — continue draining wBIO (no soft_cq).
	}
	return false, false
}

// reactor_finish_oneshot: clean oneshot exchange after full CT + plain drained.
@(private)
reactor_finish_oneshot :: proc(conn: ^Connection) {
	if conn == nil {
		return
	}
	tls_plain_clear(conn)
	reactor_residual_clear(conn)
	conn.reactor_h1 = false
	conn.reactor_fairness_yield = false
	if conn.pt.admitted > 0 {
		pt_release(&conn.pt, conn.pt.admitted)
	}
	path_metrics_note_req()
	clean_request_loop(conn)
}

// reactor_on_send_complete: residual WRITE CQE fully delivered → continue flush.
// Returns true if handled (caller must not run clear-H1 finish).
@(private)
reactor_on_send_complete :: proc(conn: ^Connection) -> bool {
	if conn == nil || !conn.reactor_h1 {
		return false
	}
	// host_on_wire already cleared pending_send on full buffer; residual meta must clear.
	reactor_residual_clear(conn)
	conn.reactor_h1 = false
	conn.wire.pending_send = nil
	reactor_tls_flush(conn)
	return true
}


