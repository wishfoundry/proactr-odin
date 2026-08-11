package http

// Dense TLS bulk flush — reactor law (Plan R2 §4).
// NO soft_cq between full CT windows. NO dual_ct_try_ahead on this path.
// Platforms:
//   Darwin H1 oneshot + H2: product path (EVFILT_WRITE residual arm via kqueue).
//   Linux H1 oneshot only: same dense loop; residual arm = host_submit_send + reactor_h1
//     so residual CQE is not charged as soft_cq_send_completes (CRITIC_IO_URING A5).
//   Linux H2 / stream: stay dual-CT (not this multi-window loop).
// Progressive stream: residual-first in tls_stream.odin (Darwin).

import "core:c"
import "core:log"
import "core:sync"

import tls_server "../tls_server"

// reactor_bio_pending: wBIO CT bytes waiting.
// Prefer cached tls_wbio + Provider bio_pending_out_bio; else ssl-based pending.
@(private)
reactor_bio_pending :: #force_inline proc(conn: ^Connection) -> int {
	if conn == nil || conn.server == nil {
		return 0
	}
	p := conn.server.tls_provider
	if conn.tls_wbio != nil && p != nil && p.bio_pending_out_bio != nil {
		return tls_server.bio_pending_out_bio(p, conn.tls_wbio)
	}
	return tls_server.bio_pending_out(p, conn.tls_ssl)
}

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
	if conn.reactor_h1 && _conn_wire_in_flight(conn) {
		return
	}
	// Non-reactor in-flight op: do not interleave.
	if _conn_wire_in_flight(conn) {
		return
	}
	if conn.reactor_h1 && len(conn.wire.pending_send) == 0 {
		reactor_residual_clear(conn)
		conn.reactor_h1 = false
	}

	path_metrics_note_kevent_turn()
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
			continue
		}

		// Drain any wBIO left from a prior seal (multi-record) without SSL_write.
		if reactor_bio_pending(conn) > 0 {
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

		// Fairness preempt (D9): stop this entry (2 MiB / 16×128KiB). No soft-CQ.
		// Darwin: re-arm WRITE for re-entry (bodies >2MiB / multi-conn); s1m under cap.
		// Linux: no empty-residual WRITE; keep sealing until EAGAIN residual arm or done
		// (natural yield at residual CQE re-entry resets counters).
		if reactor_fairness_hit(plain_sealed, windows) {
			when ODIN_OS == .Darwin {
				if h2 || tls_plain_total_remaining(conn) > 0 {
					_ = reactor_arm_fairness_continue(conn)
					if h2 {
						_ = tls_host_arm_recv(conn)
					}
				}
				return
			} else {
				// Continue dense multi-window until backpressure or plain drained.
			}
		}

		// SSL_write one trunk window (REACTOR_SEAL_WINDOW).
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
		if reactor_bio_pending(conn) > 0 {
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
			if reactor_bio_pending(conn) > 0 {
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
// Part-boundary window via tls_plain_window (heading then body). Does not drain wBIO.
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
	if conn.tls_first_seal_pending {
		conn.tls_first_seal_pending = false
		path_metrics_note_first_seal_pt(u64(consumed))
	}
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

	ssl := conn.tls_ssl
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

// reactor_send_ct_view: push CT view bytes to the socket.
// On EAGAIN: stage remainder into dual_ct.tx residual and return again=true.
// Does not touch BIO — caller resets after full view send or residual stage.
@(private)
reactor_send_ct_view :: proc(conn: ^Connection, view: []u8) -> (again: bool, hard: bool) {
	if conn == nil || len(view) == 0 {
		return false, false
	}
	dst := conn.dual_ct.tx
	off := 0
	for off < len(view) {
		sent, would_block, err := host_try_send_nb(conn, view[off:])
		if err {
			_wire_fail(conn, "reactor CT write failed fd=%v", conn.socket)
			return false, true
		}
		if would_block {
			rem := view[off:]
			if len(dst) == 0 || len(rem) > len(dst) {
				_wire_fail(conn, "reactor CT residual too large fd=%v rem=%d slab=%d", conn.socket, len(rem), len(dst))
				return false, true
			}
			copy(dst, rem)
			reactor_residual_set(conn, 0, len(rem))
			return true, false
		}
		if sent <= 0 {
			_wire_fail(conn, "reactor CT write zero fd=%v", conn.socket)
			return false, true
		}
		off += sent
	}
	return false, false
}

// reactor_drain_wbio: push wBIO CT to the socket until empty or EAGAIN.
// Product bulk path (item 3 — peek-only, no full CT memmove):
//   cached tls_wbio + bio_pending/peek/reset_out_bio → reactor_send_ct_view → bio_reset
//   Full window: zero-copy send from mem-BIO; partial: copy rem only into residual.
// Never falls through to BIO_read when peek is available (healthy OpenSSL product).
// Cold path only: provider without peek support → BIO_read into dual_ct.tx (counted;
// expect 0 on bulk matrix). Dual-CT seal engines still use bio_read_net for hold staging
// (not this drain).
// R-ORDER: residual in dual_ct.tx forbids SSL_write until drained (caller residual-first).
// Used by H1/H2 reactor flush and Darwin HS WANT_WRITE drain.
@(private)
reactor_drain_wbio :: proc(conn: ^Connection) -> (again: bool, hard: bool) {
	if conn == nil || conn.tls_ssl == nil {
		return false, false
	}
	p := conn.server.tls_provider
	ssl := conn.tls_ssl
	wbio := conn.tls_wbio
	// Prefer direct-bio ops when wbio cached and Provider wires bio_*_out_bio.
	use_bio := wbio != nil && p != nil && p.bio_pending_out_bio != nil &&
		p.bio_peek_out_bio != nil && p.bio_reset_out_bio != nil
	// Lazy re-cache: accept always sets tls_wbio; if cleared but get_wbio lives, recover.
	if !use_bio && wbio == nil && p != nil && p.get_wbio != nil && ssl != nil {
		wbio = tls_server.get_wbio(p, ssl)
		if wbio != nil {
			conn.tls_wbio = wbio
			use_bio = p.bio_pending_out_bio != nil &&
				p.bio_peek_out_bio != nil && p.bio_reset_out_bio != nil
		}
	}
	use_peek := use_bio || tls_server.bio_peek_supported(p)

	// --- Zero-copy peek path (product bulk; no BIO_read) ---
	if use_peek {
		for {
			pending := 0
			if use_bio {
				pending = tls_server.bio_pending_out_bio(p, wbio)
			} else {
				pending = tls_server.bio_pending_out(p, ssl)
			}
			if pending <= 0 {
				return false, false
			}
			t_bio0 := path_metrics_cyc_now()
			view: []u8
			if use_bio {
				view = tls_server.bio_peek_out_bio(p, wbio)
			} else {
				view = tls_server.bio_peek_out(p, ssl)
			}
			t_bio1 := path_metrics_cyc_now()
			path_metrics_note_seal_cycles(0, t_bio1 - t_bio0)
			if len(view) == 0 {
				// Pending but no mem view — pathological; do not BIO_read (memmove tax).
				path_metrics_note_wbio_peek_empty()
				_wire_fail(conn, "reactor wBIO peek empty pending=%d fd=%v", pending, conn.socket)
				return false, true
			}
			tls_metrics_note_ct(conn.server, u64(len(view)))
			tls_metrics_inc_seal(conn.server)
			path_metrics_note_ct_send(u64(len(view)))

			again, hard = reactor_send_ct_view(conn, view)
			if hard {
				return false, true
			}
			// Reset BIO after full send or residual staged (view no longer needed).
			if use_bio {
				_ = tls_server.bio_reset_out_bio(p, wbio)
			} else {
				_ = tls_server.bio_reset_out(p, ssl)
			}
			if again {
				return true, false
			}
		}
	}

	// --- Cold: no peek support → BIO_read into dual_ct.tx (counted; product expect 0) ---
	path_metrics_note_wbio_bio_read_fallback()
	dst := conn.dual_ct.tx
	if len(dst) == 0 {
		return false, true
	}
	for reactor_bio_pending(conn) > 0 {
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

		off := 0
		left := n
		for left > 0 {
			sent, would_block, err := host_try_send_nb(conn, dst[off:][:left])
			if err {
				_wire_fail(conn, "reactor CT write failed fd=%v", conn.socket)
				return false, true
			}
			if would_block {
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
	}
	return false, false
}

// reactor_finish_oneshot: clean oneshot exchange after full CT + plain drained.
// Darwin: defer clean_request_loop to end of kevent turn — sync finish often runs
// nested inside scanner/handler (respond → flush → here); reentrant conn_handle_req UAF.
// Linux: dual-CT already finished with direct clean_request_loop; same here.
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
	when ODIN_OS == .Darwin {
		reactor_defer_clean(conn)
	} else {
		clean_request_loop(conn)
	}
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
			if reactor_bio_pending(conn) > 0 {
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
