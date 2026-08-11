// H2 dual-CT flush, h2_out cursor, send-complete, and exchange finish.
package http

import "core:log"

import http2 "../http2"
import tls_server "../tls_server"

// ---------------------------------------------------------------------------
// Flush / send-complete
// ---------------------------------------------------------------------------

// Unsealed plaintext still waiting in h2_out (after h2_out_off).
// Defensive: if a caller cleared h2_out without resetting the cursor (tests /
// legacy), clamp so newly appended frames are not invisible.
@(private)
h2_out_pending_len :: #force_inline proc(conn: ^Connection) -> int {
	if conn == nil do return 0
	if conn.h2_out_off < 0 || conn.h2_out_off > len(conn.h2_out) {
		conn.h2_out_off = 0
	}
	n := len(conn.h2_out) - conn.h2_out_off
	return n if n > 0 else 0
}

// Consume sealed prefix of h2_out via cursor (no front memmove every SSL_write).
@(private)
h2_out_consume :: proc(conn: ^Connection, n: int) {
	if conn == nil || n <= 0 {
		return
	}
	conn.h2_out_off += n
	rem := h2_out_pending_len(conn)
	if rem == 0 {
		clear(&conn.h2_out)
		conn.h2_out_off = 0
		return
	}
	// Bound dead prefix if many small SSL_writes leave a large sealed head.
	if conn.h2_out_off >= 256 * 1024 {
		copy(conn.h2_out[:], conn.h2_out[conn.h2_out_off:])
		resize(&conn.h2_out, rem)
		conn.h2_out_off = 0
	}
}

// H2 seal window + try_seal_hold live in tls_dual_ct.odin (tls_seal_window /
// tls_dual_ct_try_ahead with .H2_Out). h2_out cursor helpers stay here.

// h2_host_flush_out: SSL_write frame bytes from h2_out (windowed).
// Darwin: reactor residual-first until-EAGAIN (Plan R2 P4) — no dual_ct_try_ahead,
// no soft-CQ between full windows. Linux: dual-CT seal∥send.
// When tls_ssl is nil (unit tests), leaves bytes in h2_out for the test harness.
@(private)
h2_host_flush_out :: proc(conn: ^Connection) {
	if conn == nil || !conn.h2_active {
		return
	}
	if conn.state >= .Closing {
		return
	}
	// Pure/offline: no TLS — caller reads h2_out.
	if conn.tls_ssl == nil {
		return
	}

	when ODIN_OS == .Darwin {
		// Reactor law: multi SSL_write(64KiB) + write until EAGAIN; single residual CT.
		// Finishes with duplex CT recv arm (reactor_finish_h2 / residual re-arm path).
		reactor_tls_flush(conn)
		return
	}

	// Live dual-CT (Linux proactor): seal into free slab while a CT send is in flight.
	if _conn_wire_in_flight(conn) {
		if tls_server.bio_pending_out(conn.server.tls_provider, conn.tls_ssl) > 0 {
			_ = tls_host_try_drain_out(conn, hs = false)
		}
		tls_dual_ct_try_ahead(conn, .H2_Out)
		_ = tls_host_arm_recv(conn)
		return
	}

	p := conn.server.tls_provider
	ssl := conn.tls_ssl
	d := &conn.dual_ct

	// Ordering: promote sealed CT before residual wBIO (CRITIC C2).
	if dual_ct_has_ready(d^) {
		if tls_host_promote_hold(conn) {
			tls_dual_ct_try_ahead(conn, .H2_Out)
			_ = tls_host_arm_recv(conn)
			return
		}
	}

	// Drain residual CT from a prior SSL_write.
	if tls_server.bio_pending_out(p, ssl) > 0 {
		if !tls_host_try_drain_out(conn, hs = false) {
			if _conn_wire_in_flight(conn) {
				tls_dual_ct_try_ahead(conn, .H2_Out)
			}
			_ = tls_host_arm_recv(conn)
			return
		}
		if _conn_wire_in_flight(conn) {
			tls_dual_ct_try_ahead(conn, .H2_Out)
			_ = tls_host_arm_recv(conn)
			return
		}
	}

	// Dense seal∥send (H2 only): while wire idle, seal + nonblocking send full CT
	// windows until EAGAIN or TLS_DENSE_MAX_WINDOWS. H1 oneshot stays classic path.
	for _ in 0 ..< TLS_DENSE_MAX_WINDOWS {
		if conn.state >= .Closing {
			return
		}
		if h2_out_pending_len(conn) == 0 {
			path_metrics_note_req()
			_ = tls_host_arm_recv(conn)
			return
		}
		dst := d.tx
		if len(dst) == 0 {
			_ = tls_host_arm_recv(conn)
			return
		}
		n_ct, _, ok := tls_seal_window(conn, dst, .H2_Out)
		if !ok {
			log.errorf("H2: PT high-water refuse fd=%v", conn.socket)
			connection_close(conn)
			return
		}
		if n_ct <= 0 {
			if tls_server.bio_pending_out(p, ssl) > 0 {
				_ = tls_host_try_drain_out(conn, hs = false)
				if _conn_wire_in_flight(conn) {
					tls_dual_ct_try_ahead(conn, .H2_Out)
					_ = tls_host_arm_recv(conn)
					return
				}
			}
			if h2_out_pending_len(conn) == 0 {
				path_metrics_note_req()
				_ = tls_host_arm_recv(conn)
				return
			}
			if !_conn_wire_in_flight(conn) {
				continue
			}
			_ = tls_host_arm_recv(conn)
			return
		}

		last := h2_out_pending_len(conn) == 0
		if last {
			path_metrics_note_req()
		}
		full := tls_host_send_ct_or_arm(conn, dst, n_ct, hs = false)
		if conn.state >= .Closing {
			return
		}
		if !full {
			if _conn_wire_in_flight(conn) {
				tls_dual_ct_try_ahead(conn, .H2_Out)
			}
			_ = tls_host_arm_recv(conn)
			return
		}
		// Full sync CT delivery — seal next window while idle, or done.
		if last {
			_ = tls_host_arm_recv(conn)
			return
		}
	}

	// Fairness cap: more h2_out after max windows — classic arm so CQE re-enters.
	if conn.state >= .Closing {
		return
	}
	if h2_out_pending_len(conn) == 0 {
		path_metrics_note_req()
		_ = tls_host_arm_recv(conn)
		return
	}
	if _conn_wire_in_flight(conn) {
		tls_dual_ct_try_ahead(conn, .H2_Out)
		_ = tls_host_arm_recv(conn)
		return
	}
	dst := d.tx
	if len(dst) == 0 {
		_ = tls_host_arm_recv(conn)
		return
	}
	n_ct, _, ok := tls_seal_window(conn, dst, .H2_Out)
	if !ok {
		log.errorf("H2: PT high-water refuse fd=%v", conn.socket)
		connection_close(conn)
		return
	}
	if n_ct <= 0 {
		_ = tls_host_arm_recv(conn)
		return
	}
	if h2_out_pending_len(conn) == 0 {
		path_metrics_note_req()
	}
	if !tls_host_submit_ct(conn, dst, n_ct, hs = false) {
		return
	}
	tls_dual_ct_try_ahead(conn, .H2_Out)
	_ = tls_host_arm_recv(conn)
}

// h2_host_on_send_complete: after CT buffer delivered. Continue flush; re-arm recv.
// Returns true if handled (caller skips H1 clean path).
// Darwin reactor residual CQE is handled earlier via reactor_on_send_complete.
// This path is dual-CT promote (Linux) or offline tests (nil SSL / no reactor_h1).
@(private)
h2_host_on_send_complete :: proc(conn: ^Connection) -> bool {
	if conn == nil || !conn.h2_active {
		return false
	}
	when ODIN_OS == .Darwin {
		// Should rarely hit: residual CQE uses reactor_on_send_complete first.
		// If product flush re-entered without residual flag, use reactor flush.
		conn.wire.pending_send = nil
		conn.dual_ct.send_is_hold = false
		h2_host_flush_out(conn)
		h2_host_maybe_finish_exchange(conn)
		h2_host_dispatch_available(conn)
		h2_host_maybe_goaway_from_closing(conn)
		if conn.state < .Closing && conn.tls_pipe.state == .Open {
			h2_test_arm_recv_count += 1
			_ = tls_host_arm_recv(conn)
		}
		return true
	}
	// Dual-CT (Linux): promote hold before general flush.
	if tls_host_promote_hold(conn) {
		tls_dual_ct_try_ahead(conn, .H2_Out)
	} else {
		conn.wire.pending_send = nil
		conn.dual_ct.send_is_hold = false
		// Continue sealing remaining frames / residual CT.
		h2_host_flush_out(conn)
	}
	h2_host_maybe_finish_exchange(conn)
	h2_host_dispatch_available(conn)
	h2_host_maybe_goaway_from_closing(conn)

	// Duplex law: after any H2 send complete, re-arm CT recv while Open.
	// Count arm attempts for offline M4 (tls_host_arm_recv may no-op without SSL).
	if conn.state < .Closing && conn.tls_pipe.state == .Open {
		h2_test_arm_recv_count += 1
		_ = tls_host_arm_recv(conn)
	}
	return true
}

// ---------------------------------------------------------------------------
// Exchange complete / slot map (multi-sid)
// ---------------------------------------------------------------------------

// h2_host_conn_drained: no outbound frames / ready CT / ring send holding the pipe.
@(private)
h2_host_conn_drained :: proc(conn: ^Connection) -> bool {
	if conn == nil {
		return true
	}
	if h2_out_pending_len(conn) > 0 {
		return false
	}
	if dual_ct_has_ready(conn.dual_ct) {
		return false
	}
	// Darwin reactor residual CT not yet on wire.
	when ODIN_OS == .Darwin {
		if conn.reactor_res_n > 0 || conn.reactor_h1 {
			return false
		}
	}
	if _conn_wire_in_flight(conn) {
		return false
	}
	if conn.tls_ssl != nil && conn.server != nil {
		if tls_server.bio_pending_out(conn.server.tls_provider, conn.tls_ssl) > 0 {
			return false
		}
	}
	return true
}

// h2_host_stream_oneshot_done: server has finished sending on sid (end_sent, no pending).
// Streams already reaped from the map count as done. Long-lived (no end_sent) is not done.
@(private)
h2_host_stream_oneshot_done :: proc(conn: ^Connection, sid: u32) -> bool {
	if conn == nil || sid == 0 {
		return false
	}
	s, ok := conn.h2.streams[sid]
	if !ok {
		// Stream gone from map — treat as complete for slot free.
		return true
	}
	if http2.stream_pending_len(s) > 0 {
		return false
	}
	return s.end_sent
}

// h2_host_maybe_finish_exchange: free slots whose oneshot exchange is fully out,
// clear serial busy for completed sids, then dispatch more pending takes.
@(private)
h2_host_maybe_finish_exchange :: proc(conn: ^Connection) {
	if conn == nil || !conn.h2_active || conn.state >= .Closing {
		return
	}
	// Outbound must be drained before free (frames delivered / offline cleared).
	if !h2_host_conn_drained(conn) {
		return
	}

	serial := h2_host_serial_mode(conn)
	freed_any := false

	// Multi-sid: free every used slot whose stream oneshot has end_sent + empty pending.
	if conn.h2_slots != nil {
		for i in 0 ..< H2_SLOT_CAP {
			if !conn.h2_slot_used[i] {
				continue
			}
			sid := conn.h2_slot_sids[i]
			if sid == 0 {
				continue
			}
			// Long-lived session / progressive: keep the slot; do not free.
			if conn.h2_slots[i].session != nil || conn.h2_slots[i].res._session_attached {
				continue
			}
			if conn.h2_slots[i].stream_open && !conn.h2_slots[i].res._stream_ended {
				continue
			}
			if !h2_host_stream_oneshot_done(conn, sid) {
				continue
			}
			h2_host_exchange_done_slot(conn, u8(i), sid)
			freed_any = true
		}
	}

	// Serial / 400 path: busy with no slot (slot freed before 400 frames) — clear when done.
	if conn.h2_serial_busy && conn.h2_dispatch_sid != 0 {
		sid := conn.h2_dispatch_sid
		if _, has := h2_host_slot_find(conn, sid); !has {
			if h2_host_stream_oneshot_done(conn, sid) {
				conn.h2_serial_busy = false
				conn.h2_dispatch_sid = 0
				freed_any = true
			}
		}
	} else if conn.h2_serial_busy && conn.h2_dispatch_sid == 0 && !serial {
		// Defensive: concurrent should not hold serial_busy without a sid.
		conn.h2_serial_busy = false
	}

	if !freed_any {
		return
	}

	// Scrap reset when no exchange remains in flight.
	if !h2_host_any_slot_used(conn) {
		if conn.temp_slot < 0 {
			_ = conn_temp_attach(conn)
		} else {
			conn_temp_reset(conn)
		}
		client := conn.loop.req.client
		conn.loop.req = {}
		conn.loop.req.client = client

		if conn.state == .Will_Close {
			if conn.h2_goaway_drain || conn.h2.goaway_sent {
				h2_host_maybe_close_after_goaway_drain(conn)
				return
			}
			connection_close(conn)
			return
		}
		_ = connection_set_state(conn, .Idle)
	}

	// Take more pending complete requests into free slots (not after local GOAWAY
	// if no work remains — dispatch still delivers streams ≤ last_sid).
	h2_host_dispatch_available(conn)
	if conn.h2_goaway_drain || conn.h2.goaway_sent {
		h2_host_maybe_close_after_goaway_drain(conn)
	}
}


