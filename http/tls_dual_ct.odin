// Live dual-CT seal∥send engine (PR5.1).
//
// Two CT slabs on Connection.dual_ct: while one sock send is in flight, seal the
// next plain window into the free slab. Shared by H1 oneshot, progressive stream,
// and H2 frame flush — one SSL_write window + one ahead-seal path each.
//
// Promote-before-residual ordering (CRITIC C2) stays at flush/CQE call sites;
// this file owns slab ready/hold bookkeeping and seal physics only.
package http

import "base:runtime"
import "core:c"
import "core:log"
import "core:sync"

import tls_server "../tls_server"

// ---------------------------------------------------------------------------
// Dual_Ct — primary + hold CT slabs and sealed-not-submitted lengths
// ---------------------------------------------------------------------------

// Dual_Ct groups live seal∥send ciphertext state. tx = primary; hold = second.
// A slab currently in wire.pending_send is "sending" (not ready); do not overwrite
// until its CQE completes. plain_n fields are progressive-stream only (oneshot/H2
// advance their own plain cursors inside tls_seal_window).
Dual_Ct :: struct {
	tx, hold:             []u8,
	tx_ready_n, hold_n:   int,
	send_is_hold:         bool,
	tx_plain_n, hold_plain_n: int,
}

// Plain source for the single seal engine.
Tls_Seal_Plain :: enum u8 {
	Oneshot, // tls_plain_* cursor (heading + borrowed body)
	Stream,  // resp_buf progressive; plain_off = stream_sent + slab/deferred plain
	H2_Out,  // h2_out cursor
}

// dual_ct_has_ready: any sealed CT waiting for promote/submit.
@(private)
dual_ct_has_ready :: #force_inline proc(d: Dual_Ct) -> bool {
	return d.hold_n > 0 || d.tx_ready_n > 0
}

// dual_ct_set_ready: mark free slab as sealed-not-submitted (ahead-seal / drain stash).
@(private)
dual_ct_set_ready :: proc(d: ^Dual_Ct, mark_hold: bool, n_ct: int) {
	if d == nil || n_ct <= 0 {
		return
	}
	if mark_hold {
		d.hold_n = n_ct
	} else {
		d.tx_ready_n = n_ct
	}
}

// dual_ct_set_slab_plain: associate progressive plain_n with a CT slab.
@(private)
dual_ct_set_slab_plain :: proc(d: ^Dual_Ct, mark_hold: bool, plain_n: int) {
	if d == nil {
		return
	}
	if mark_hold {
		d.hold_plain_n = plain_n
	} else {
		d.tx_plain_n = plain_n
	}
}

// dual_ct_free_slabs: delete tx/hold allocations (conn destroy).
@(private)
dual_ct_free_slabs :: proc(d: ^Dual_Ct, alloc: runtime.Allocator) {
	if d == nil {
		return
	}
	if d.tx != nil {
		delete(d.tx, alloc)
		d.tx = nil
	}
	if d.hold != nil {
		delete(d.hold, alloc)
		d.hold = nil
	}
	d.tx_ready_n = 0
	d.hold_n = 0
	d.send_is_hold = false
	d.tx_plain_n = 0
	d.hold_plain_n = 0
}

// dual_ct_clear_meta: zero ready/plain without freeing slabs (reuse / finish).
@(private)
dual_ct_clear_meta :: proc(d: ^Dual_Ct) {
	if d == nil {
		return
	}
	d.tx_ready_n = 0
	d.hold_n = 0
	d.send_is_hold = false
	d.tx_plain_n = 0
	d.hold_plain_n = 0
}

// ---------------------------------------------------------------------------
// Shared dual-CT wire ops
// ---------------------------------------------------------------------------

// Submit ciphertext from a slab. Marks which slab is in flight; clears that slab's ready len.
@(private)
tls_host_submit_ct :: proc(conn: ^Connection, buf: []u8, n: int, hs: bool) -> bool {
	if conn == nil || n <= 0 || len(buf) < n {
		return false
	}
	d := &conn.dual_ct
	is_hold := len(d.hold) > 0 && raw_data(buf) == raw_data(d.hold)
	conn.wire.pending_send = buf[:n]
	conn.tls_hs_send = hs
	d.send_is_hold = is_hold
	if is_hold {
		d.hold_n = 0
	} else {
		d.tx_ready_n = 0
	}
	if err := host_submit_send(conn); err != .None {
		_wire_fail(conn, "TLS submit_send CT failed: %v", err)
		return false
	}
	return true
}

// Free slab for sealing while a send may be in flight (not ready, not sending).
@(private)
tls_host_seal_dst_for_ahead :: proc(conn: ^Connection) -> (dst: []u8, mark_hold: bool) {
	if conn == nil || !_conn_wire_in_flight(conn) {
		return nil, false
	}
	d := &conn.dual_ct
	// Prefer filling whichever slab is free.
	if d.send_is_hold {
		// Hold is sending → seal into primary if free.
		if d.tx_ready_n == 0 && len(d.tx) > 0 {
			return d.tx, false
		}
		return nil, false
	}
	// Primary is sending → seal into hold if free.
	if d.hold_n == 0 && len(d.hold) > 0 {
		return d.hold, true
	}
	return nil, false
}

// Drain wBIO into free slab; if sock free submit immediately, else mark ready.
// Returns false if connection closed or send armed (caller must wait CQE).
// Returns true if idle (no CT pending / nothing submitted).
@(private)
tls_host_try_drain_out :: proc(conn: ^Connection, hs: bool) -> bool {
	if conn == nil || conn.tls_ssl == nil {
		return true
	}
	if conn.state >= .Closing {
		return false
	}
	p := conn.server.tls_provider
	ssl := conn.tls_ssl
	pending := tls_server.bio_pending_out(p, ssl)
	if pending <= 0 {
		return true
	}

	d := &conn.dual_ct
	dst: []u8
	mark_hold := false
	if !_conn_wire_in_flight(conn) {
		// Prefer submitting via primary.
		if d.tx_ready_n == 0 && len(d.tx) > 0 {
			dst = d.tx
		} else if d.hold_n == 0 && len(d.hold) > 0 {
			dst = d.hold
			mark_hold = true
		} else {
			return true
		}
	} else {
		dst, mark_hold = tls_host_seal_dst_for_ahead(conn)
		if len(dst) == 0 {
			return false // both busy
		}
	}
	n := tls_server.bio_read_net(p, ssl, dst)
	if n <= 0 {
		return true
	}
	tls_metrics_note_ct(conn.server, u64(n))
	tls_metrics_inc_seal(conn.server)
	path_metrics_note_ct_send(u64(n))

	if _conn_wire_in_flight(conn) {
		dual_ct_set_ready(d, mark_hold, n)
		return false
	}
	if !tls_host_submit_ct(conn, dst, n, hs) {
		return false
	}
	return false // wait CQE
}

// After sock send CQE: submit any ready CT (hold preferred, then primary).
// Returns true if a new send was armed.
@(private)
tls_host_promote_hold :: proc(conn: ^Connection) -> bool {
	if conn == nil {
		return false
	}
	d := &conn.dual_ct
	d.send_is_hold = false
	conn.wire.pending_send = nil
	// Prefer hold then primary ready.
	if d.hold_n > 0 && len(d.hold) > 0 {
		n := d.hold_n
		return tls_host_submit_ct(conn, d.hold, n, hs = false)
	}
	if d.tx_ready_n > 0 && len(d.tx) > 0 {
		n := d.tx_ready_n
		return tls_host_submit_ct(conn, d.tx, n, hs = false)
	}
	return false
}

// ---------------------------------------------------------------------------
// Progressive stream plain cursor (dual-CT aware)
// ---------------------------------------------------------------------------

// Plain offset for the next progressive SSL_write: stream_sent plus plain already
// sealed into dual-CT slabs (or deferred residual) but not yet CQE-advanced.
@(private)
tls_host_stream_plain_off :: proc(conn: ^Connection) -> int {
	if conn == nil {
		return 0
	}
	d := conn.dual_ct
	return conn.slot.stream_sent +
		conn.tls_stream_plain_n +
		d.tx_plain_n +
		d.hold_plain_n
}

// Associate plain_n with a CT slab (tx or hold). Residual drains leave plain at 0.
@(private)
tls_host_stream_set_slab_plain :: proc(conn: ^Connection, mark_hold: bool, plain_n: int) {
	if conn == nil {
		return
	}
	dual_ct_set_slab_plain(&conn.dual_ct, mark_hold, plain_n)
}

// ---------------------------------------------------------------------------
// Single seal engine: SSL_write plain window → bio_read CT into dst
// ---------------------------------------------------------------------------

// tls_seal_window: SSL_write from plain source into OpenSSL; drain wBIO CT into dst.
// Returns (n_ct, plain_consumed, ok).
//
// Oneshot: advances tls_plain_* + pt_admit (as before).
// Stream: does NOT advance stream_sent (caller sets slab plain_n / deferred).
// H2: advances h2_out cursor via h2_out_consume.
@(private)
tls_seal_window :: proc(conn: ^Connection, dst: []u8, plain: Tls_Seal_Plain) -> (n_ct: int, plain_n: int, ok: bool) {
	switch plain {
	case .Oneshot:
		return tls_seal_window_oneshot(conn, dst)
	case .Stream:
		return tls_seal_window_stream(conn, dst)
	case .H2_Out:
		return tls_seal_window_h2(conn, dst)
	}
	return 0, 0, false
}

@(private)
tls_seal_window_oneshot :: proc(conn: ^Connection, dst: []u8) -> (n_ct: int, pt_n: int, ok: bool) {
	if conn == nil || conn.tls_ssl == nil || len(dst) == 0 {
		return 0, 0, false
	}
	if tls_plain_total_remaining(conn) == 0 {
		return 0, 0, true
	}
	p := conn.server.tls_provider
	ssl := conn.tls_ssl
	win_slice := tls_plain_window(conn, TLS_SEAL_WINDOW_DEFAULT)
	win := len(win_slice)
	if win == 0 {
		return 0, 0, true
	}
	if !pt_admit(&conn.pt, u32(win)) {
		// Retry at one TLS record — re-window then admit exact slice size.
		win = int(min(u32(win), TLS_RECORD_PLAIN))
		if win == 0 {
			return 0, 0, false
		}
		win_slice = tls_plain_window(conn, win)
		win = len(win_slice)
		if win == 0 {
			return 0, 0, true
		}
		if !pt_admit(&conn.pt, u32(win)) {
			return 0, 0, false
		}
	}
	tls_metrics_note_pt(conn.server, u64(conn.pt.admitted))

	ret := tls_server.write(p, ssl, raw_data(win_slice), c.int(win))
	if ret <= 0 {
		pt_release(&conn.pt, u32(win))
		ge := tls_server.get_error(p, ssl, ret)
		if ge == p.ERROR_WANT_WRITE {
			// Caller drains / waits.
			return 0, 0, true
		}
		if ge == p.ERROR_WANT_READ {
			_ = tls_host_arm_recv(conn)
			return 0, 0, true
		}
		log.debugf("TLS SSL_write error fd=%v ret=%d ge=%d", conn.socket, ret, ge)
		return 0, 0, false
	}
	consumed := int(ret)
	if consumed > win {
		consumed = win
	}
	if consumed < win {
		pt_release(&conn.pt, u32(win - consumed))
	}
	tls_plain_advance(conn, consumed)
	path_metrics_note_ssl_write(u64(consumed))
	sync.atomic_add(&path_seal_calls, 1)

	pending := tls_server.bio_pending_out(p, ssl)
	if pending <= 0 {
		pt_release(&conn.pt, u32(consumed))
		return 0, consumed, true
	}
	n := tls_server.bio_read_net(p, ssl, dst)
	if n <= 0 {
		pt_release(&conn.pt, u32(consumed))
		return 0, consumed, true
	}
	tls_metrics_note_ct(conn.server, u64(n))
	tls_metrics_inc_seal(conn.server)
	path_metrics_note_ct_send(u64(n))
	pt_release(&conn.pt, u32(consumed))
	return n, consumed, true
}

// Seal one progressive stream plain window into dst CT slab.
// Plain starts at tls_host_stream_plain_off (not bare stream_sent) so dual-CT
// ahead-seal does not re-encrypt in-flight plain. Does not set slab plain_n —
// caller records plain_n on the slab that owns the CT.
@(private)
tls_seal_window_stream :: proc(conn: ^Connection, dst: []u8) -> (n_ct: int, plain_n: int, ok: bool) {
	if conn == nil || conn.tls_ssl == nil || len(dst) == 0 {
		return 0, 0, false
	}
	off := tls_host_stream_plain_off(conn)
	unsent := len(conn.resp_buf) - off
	if unsent <= 0 {
		return 0, 0, true
	}
	p := conn.server.tls_provider
	ssl := conn.tls_ssl
	win := unsent
	if win > TLS_SEAL_WINDOW_DEFAULT {
		win = TLS_SEAL_WINDOW_DEFAULT
	}
	plain := conn.resp_buf[off:][:win]
	ret := tls_server.write(p, ssl, raw_data(plain), c.int(win))
	if ret <= 0 {
		ge := tls_server.get_error(p, ssl, ret)
		if ge == p.ERROR_WANT_WRITE || ge == p.ERROR_WANT_READ {
			if ge == p.ERROR_WANT_READ {
				_ = tls_host_arm_recv(conn)
			}
			return 0, 0, true
		}
		log.debugf("TLS stream SSL_write error fd=%v ret=%d ge=%d", conn.socket, ret, ge)
		return 0, 0, false
	}
	consumed := int(ret)
	if consumed > win {
		consumed = win
	}

	pending := tls_server.bio_pending_out(p, ssl)
	if pending <= 0 {
		// Sealed but no CT yet (OpenSSL internal buffer) — plain is done for cursor.
		return 0, consumed, true
	}
	n := tls_server.bio_read_net(p, ssl, dst)
	if n <= 0 {
		// Fail-closed (CQ-M2): pending was > 0 but drain failed.
		log.debugf(
			"TLS stream bio_read_net fail after SSL_write fd=%v n=%d plain=%d",
			conn.socket,
			n,
			consumed,
		)
		return 0, 0, false
	}
	tls_metrics_note_ct(conn.server, u64(n))
	tls_metrics_inc_seal(conn.server)
	path_metrics_note_ct_send(u64(n))
	return n, consumed, true
}

// Seal one H2 plain window into dst CT slab. Advances h2_out cursor on SSL_write success.
@(private)
tls_seal_window_h2 :: proc(conn: ^Connection, dst: []u8) -> (n_ct: int, plain_n: int, ok: bool) {
	if conn == nil || conn.tls_ssl == nil || len(dst) == 0 {
		return 0, 0, false
	}
	avail := h2_out_pending_len(conn)
	if avail == 0 {
		return 0, 0, true
	}
	p := conn.server.tls_provider
	ssl := conn.tls_ssl
	win := avail
	if win > TLS_SEAL_WINDOW_DEFAULT {
		win = TLS_SEAL_WINDOW_DEFAULT
	}
	if !pt_admit(&conn.pt, u32(win)) {
		win = int(min(u32(win), TLS_RECORD_PLAIN))
		if win == 0 || !pt_admit(&conn.pt, u32(win)) {
			return 0, 0, false
		}
	}
	tls_metrics_note_pt(conn.server, u64(conn.pt.admitted))
	plain := conn.h2_out[conn.h2_out_off:conn.h2_out_off + win]
	ret := tls_server.write(p, ssl, raw_data(plain), c.int(win))
	if ret <= 0 {
		pt_release(&conn.pt, u32(win))
		ge := tls_server.get_error(p, ssl, ret)
		if ge == p.ERROR_WANT_WRITE || ge == p.ERROR_WANT_READ {
			if ge == p.ERROR_WANT_READ {
				_ = tls_host_arm_recv(conn)
			}
			return 0, 0, true
		}
		log.debugf("H2: SSL_write err fd=%v ret=%d ge=%d", conn.socket, ret, ge)
		return 0, 0, false
	}
	consumed := int(ret)
	if consumed > win {
		consumed = win
	}
	if consumed < win {
		pt_release(&conn.pt, u32(win - consumed))
	}
	h2_out_consume(conn, consumed)
	path_metrics_note_h2_flush(u64(consumed))
	sync.atomic_add(&path_seal_calls, 1)

	pending := tls_server.bio_pending_out(p, ssl)
	if pending <= 0 {
		pt_release(&conn.pt, u32(consumed))
		return 0, consumed, true
	}
	n := tls_server.bio_read_net(p, ssl, dst)
	if n <= 0 {
		pt_release(&conn.pt, u32(consumed))
		return 0, consumed, true
	}
	tls_metrics_note_ct(conn.server, u64(n))
	tls_metrics_inc_seal(conn.server)
	path_metrics_note_ct_send(u64(n))
	pt_release(&conn.pt, u32(consumed))
	return n, consumed, true
}

// ---------------------------------------------------------------------------
// Single ahead-seal (while sock send inflight)
// ---------------------------------------------------------------------------

// tls_dual_ct_try_ahead: seal next plain window into free CT slab while send is inflight.
// Failure: Stream → session Client_Gone; Oneshot/H2 → connection_close.
@(private)
tls_dual_ct_try_ahead :: proc(conn: ^Connection, plain: Tls_Seal_Plain) {
	if conn == nil {
		return
	}
	switch plain {
	case .Oneshot:
		if tls_plain_total_remaining(conn) == 0 {
			return
		}
	case .Stream:
		if len(conn.resp_buf) <= tls_host_stream_plain_off(conn) {
			return
		}
	case .H2_Out:
		if h2_out_pending_len(conn) == 0 {
			return
		}
	}

	dst, mark_hold := tls_host_seal_dst_for_ahead(conn)
	if len(dst) == 0 {
		return
	}
	n_ct, plain_n, ok := tls_seal_window(conn, dst, plain)
	if !ok {
		switch plain {
		case .Stream:
			tls_host_session_client_gone(conn)
		case .Oneshot, .H2_Out:
			connection_close(conn)
		}
		return
	}

	d := &conn.dual_ct
	switch plain {
	case .Stream:
		if plain_n <= 0 {
			return
		}
		if n_ct <= 0 {
			// Rare: SSL_write accepted plain with no CT while a prior send is inflight.
			// Do not advance stream_sent out of order; leave plain unaccounted only if
			// we can re-seal — but OpenSSL already consumed it. Account as deferred so
			// plain_off advances and CQE order still drains prior CT first.
			conn.tls_stream_plain_n += plain_n
			return
		}
		dual_ct_set_slab_plain(d, mark_hold, plain_n)
		dual_ct_set_ready(d, mark_hold, n_ct)
	case .Oneshot, .H2_Out:
		if n_ct > 0 {
			dual_ct_set_ready(d, mark_hold, n_ct)
		}
	}
}
