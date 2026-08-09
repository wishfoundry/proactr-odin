#+build darwin
package http

// Darwin TLS bulk flush — reactor law (Plan R2 §4), H1 oneshot + H2 frame out.
// residual-first → SSL_write(64KiB) → drain wBIO write until EAGAIN → single residual.
// NO soft_cq between full CT windows. NO dual_ct_try_ahead. Dual-CT remains Linux-only.
// Progressive stream: residual-first in tls_stream.odin (not this multi-window loop);
// residual WRITE arm still host_submit_send+reactor_h1 (P5-lite hybrid).

import "core:c"
import "core:log"
import "core:sync"

import tls_server "../tls_server"

// reactor_tls_flush: Plan R2 hot path for ciphered send on Darwin.
// Plain source auto: H2_Out when h2_active, else Oneshot (H1). Stream not multi-window here.
@(private)
reactor_tls_flush :: proc(conn: ^Connection) {
	if conn == nil || conn.tls_ssl == nil {
		return
	}
	if conn.state >= .Closing {
		return
	}
	// Progressive stream multi-window stays dual-CT until a dedicated reactor stream path.
	if !conn.h2_active && tls_host_stream_long_lived(conn) {
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
	h2 := conn.h2_active

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
				// H2 duplex: keep CT recv armed while WRITE residual pending (R-DUPLEX).
				if h2 {
					_ = tls_host_arm_recv(conn)
				}
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
				if h2 {
					_ = tls_host_arm_recv(conn)
				}
				return
			}
			continue
		}

		// Done: no residual, no wBIO, no plain.
		if h2 {
			if h2_out_pending_len(conn) == 0 {
				reactor_finish_h2(conn)
				return
			}
		} else if tls_plain_total_remaining(conn) == 0 {
			reactor_finish_oneshot(conn)
			return
		}

		// Fairness preempt (D9): stop this entry (cap covers 2MiB / 32×64KiB).
		// No soft-CQ yield (impl critic M1). Cap sized so matrix s1m completes without yield.
		if reactor_fairness_hit(plain_sealed, windows) {
			// Re-arm WRITE so kevent re-enters flush (H2 and H1 bulk).
			if h2 || tls_plain_total_remaining(conn) > 0 {
				// Empty residual arm is wrong; use a zero-len pending is banned.
				// Fairness: submit a 0-byte WRITE is illegal — leave pending work;
				// caller paths re-enter flush on next product event. For H2 duplex,
				// arm CT recv so peer WINDOW_UPDATE can arrive; next flush from
				// product entry (respond / window update) continues seal.
				if h2 {
					_ = tls_host_arm_recv(conn)
				}
			}
			return
		}

		// SSL_write one trunk window (64 KiB).
		if !reactor_may_ssl_write(conn.reactor_res_n) {
			// Should be unreachable (residual cleared above).
			_ = reactor_arm_write_residual(conn)
			return
		}

		ok: bool
		consumed: int
		if h2 {
			ok, consumed = reactor_ssl_write_window_h2(conn)
		} else {
			ok, consumed = reactor_ssl_write_window(conn)
		}
		if !ok {
			if h2 {
				log.errorf("H2 reactor SSL_write fail fd=%v", conn.socket)
			} else {
				log.errorf("TLS reactor SSL_write fail fd=%v", conn.socket)
			}
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
				if h2 {
					_ = tls_host_arm_recv(conn)
				}
				return
			}
		}

		// Zero consume: WANT_WRITE → drain residual; WANT_READ → arm recv (R-DUPLEX).
		more_plain := h2_out_pending_len(conn) > 0 if h2 else tls_plain_total_remaining(conn) > 0
		if consumed == 0 && more_plain {
			if tls_server.bio_pending_out(p, ssl) > 0 {
				again, hard := reactor_drain_wbio(conn)
				if hard {
					return
				}
				if again {
					if !reactor_arm_write_residual(conn) {
						_wire_fail(conn, "reactor arm WRITE after WANT_WRITE failed fd=%v", conn.socket)
					}
					if h2 {
						_ = tls_host_arm_recv(conn)
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

// reactor_ssl_write_window: SSL_write up to REACTOR_SEAL_WINDOW plain (H1 oneshot); advance cursor.
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

// reactor_ssl_write_window_h2: SSL_write up to REACTOR_SEAL_WINDOW from h2_out; advance cursor.
// Does not drain wBIO (caller drains). Mirrors dual-CT tls_seal_window_h2 admit/metrics.
@(private)
reactor_ssl_write_window_h2 :: proc(conn: ^Connection) -> (ok: bool, consumed: int) {
	if conn == nil || conn.tls_ssl == nil {
		return false, 0
	}
	avail := h2_out_pending_len(conn)
	if avail == 0 {
		return true, 0
	}
	p := conn.server.tls_provider
	ssl := conn.tls_ssl
	win := avail
	if win > REACTOR_SEAL_WINDOW {
		win = REACTOR_SEAL_WINDOW
	}
	if !pt_admit(&conn.pt, u32(win)) {
		win = int(min(u32(win), TLS_RECORD_PLAIN))
		if win == 0 {
			return false, 0
		}
		if !pt_admit(&conn.pt, u32(win)) {
			return false, 0
		}
	}
	tls_metrics_note_pt(conn.server, u64(conn.pt.admitted))
	plain := conn.h2_out[conn.h2_out_off:conn.h2_out_off + win]

	t_ssl0 := path_metrics_cyc_now()
	ret := tls_server.write(p, ssl, raw_data(plain), c.int(win))
	t_ssl1 := path_metrics_cyc_now()
	if ret <= 0 {
		pt_release(&conn.pt, u32(win))
		ge := tls_server.get_error(p, ssl, ret)
		if ge == p.ERROR_WANT_WRITE {
			path_metrics_note_seal_cycles(t_ssl1 - t_ssl0, 0)
			return true, 0
		}
		if ge == p.ERROR_WANT_READ {
			_ = tls_host_arm_recv(conn)
			path_metrics_note_seal_cycles(t_ssl1 - t_ssl0, 0)
			return true, 0
		}
		log.debugf("reactor H2 SSL_write error fd=%v ret=%d ge=%d", conn.socket, ret, ge)
		return false, 0
	}
	consumed = int(ret)
	if consumed > win {
		consumed = win
	}
	if consumed < win {
		pt_release(&conn.pt, u32(win - consumed))
	}
	h2_out_consume(conn, consumed)
	path_metrics_note_h2_flush(u64(consumed))
	path_metrics_note_ssl_write(u64(consumed))
	sync.atomic_add(&path_seal_calls, 1)
	path_metrics_note_seal_cycles(t_ssl1 - t_ssl0, 0)
	pt_release(&conn.pt, u32(consumed))
	return true, consumed
}

// reactor_drain_wbio: bio_read into dual_ct.tx, write until wBIO empty or EAGAIN.
// On EAGAIN: residual set; returns again=true. Hard fail closes connection.
// Used by H1/H2 reactor flush and Darwin P4b drain (handshake / WANT_WRITE).
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

// reactor_finish_h2: duplex arm + exchange finish after h2_out/wBIO/residual empty.
@(private)
reactor_finish_h2 :: proc(conn: ^Connection) {
	if conn == nil {
		return
	}
	reactor_residual_clear(conn)
	conn.reactor_h1 = false
	conn.reactor_fairness_yield = false
	path_metrics_note_req()
	h2_host_maybe_finish_exchange(conn)
	h2_host_dispatch_available(conn)
	h2_host_maybe_goaway_from_closing(conn)
	// Duplex law: arm CT recv while Open (same as h2_host_on_send_complete).
	if conn.state < .Closing && conn.tls_pipe.state == .Open {
		h2_test_arm_recv_count += 1
		_ = tls_host_arm_recv(conn)
	}
}

// reactor_on_send_complete: residual WRITE CQE fully delivered → continue flush.
// Returns true if handled (caller must not run dual-CT promote / clear-H1 finish).
// Demux: HS → drive handshake; H2 → reactor H2 flush; stream → stream submit; else oneshot.
@(private)
reactor_on_send_complete :: proc(conn: ^Connection) -> bool {
	if conn == nil || !conn.reactor_h1 {
		return false
	}
	// host_on_wire already cleared pending_send on full buffer; residual meta must clear.
	was_hs := conn.tls_hs_send
	reactor_residual_clear(conn)
	conn.reactor_h1 = false
	conn.wire.pending_send = nil
	conn.tls_hs_send = false

	// Handshake residual CT delivered — re-drive accept / open protocol.
	if was_hs || conn.tls_pipe.state == .Handshake {
		if conn.tls_pipe.state == .Handshake {
			tls_host_drive_handshake(conn)
			return true
		}
		// Open but last flight was HS CT.
		if conn.tls_pipe.state == .Open && conn.state == .New {
			if tls_server.bio_pending_out(conn.server.tls_provider, conn.tls_ssl) > 0 {
				again, hard := reactor_drain_wbio(conn)
				if hard {
					return true
				}
				if again {
					conn.tls_hs_send = true
					_ = reactor_arm_write_residual(conn)
					return true
				}
			}
			tls_host_open_start_protocol(conn)
			return true
		}
		// Fall through if Open+active protocol (should not be was_hs typically).
	}

	if conn.h2_active {
		reactor_tls_flush(conn)
		// If flush finished sync, reactor_finish_h2 already ran exchange/arm.
		// If residual re-armed, keep duplex interest when still Open.
		if conn.state < .Closing && conn.tls_pipe.state == .Open && conn.reactor_h1 {
			h2_test_arm_recv_count += 1
			_ = tls_host_arm_recv(conn)
		} else if conn.state < .Closing && conn.tls_pipe.state == .Open &&
			h2_out_pending_len(conn) == 0 && conn.reactor_res_n == 0 {
			// Flush returned without finish_h2 (e.g. fairness early return mid-work
			// already armed recv; empty case may need finish if flush exited on close).
			h2_host_maybe_finish_exchange(conn)
			h2_host_dispatch_available(conn)
			h2_host_maybe_goaway_from_closing(conn)
		}
		return true
	}

	if tls_host_stream_long_lived(conn) {
		// Residual CT for a progressive window fully on wire — advance deferred plain.
		if conn.tls_stream_plain_n > 0 {
			advance := conn.tls_stream_plain_n
			conn.tls_stream_plain_n = 0
			conn.slot.stream_sent += advance
			_stream_compact_delivered(conn)
			if conn.slot.session != nil {
				_session_on_writable(conn)
			}
		}
		// Continue seal or finish / hangup arm.
		tls_host_stream_try_submit(conn)
		return true
	}

	reactor_tls_flush(conn)
	return true
}
