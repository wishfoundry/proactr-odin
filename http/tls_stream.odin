// Progressive stream / SSE / WS over TLS H1 (dual-CT seal∥send).
package http

import "core:sync"

import tls_server "../tls_server"

// tls_host_stream_ct_recv: CT arrived while progressive stream/session is live.
// Probe close_notify / unexpected PT; resume seal if flush pending; else hangup arm.
@(private)
tls_host_stream_ct_recv :: proc(conn: ^Connection) {
	if conn == nil || conn.tls_ssl == nil {
		return
	}
	if conn.state >= .Closing {
		return
	}
	// Small probe window — SSE/WS v1 is send-oriented (no inbound frame parse).
	probe: [512]u8
	n_pt := tls_host_ssl_read_burst(conn, probe[:])
	if conn.state >= .Closing {
		return
	}
	if n_pt > 0 {
		// Unexpected client app data while session/stream owns wire → Client_Gone.
		tls_host_session_client_gone(conn)
		return
	}
	if conn.slot.session == nil && !conn.slot.stream_open {
		return
	}
	// Resume progressive seal if plain remains or WANT_READ unblocked a write.
	// stream_sent is the delivered plain cursor; dual-CT ready / residual CT also count.
	d := conn.dual_ct
	more := len(conn.resp_buf) > conn.slot.stream_sent ||
		conn.tls_stream_plain_n > 0 ||
		d.tx_plain_n > 0 ||
		d.hold_plain_n > 0 ||
		d.hold_n > 0 ||
		d.tx_ready_n > 0 ||
		conn.slot.stream_flush_pending ||
		conn.slot.stream_ending
	if more && !_conn_wire_in_flight(conn) {
		conn.slot.stream_flush_pending = false
		tls_host_stream_try_submit(conn)
		return
	}
	// Still live and idle: re-arm CT recv hangup watch.
	_session_arm_hangup_watch(conn)
}

// tls_host_stream_long_lived: progressive stream / session owns the wire.
// CT send complete must not call clean_request_loop mid-session.
@(private)
tls_host_stream_long_lived :: proc(conn: ^Connection) -> bool {
	return conn != nil && (conn.slot.stream_open || conn.slot.session != nil)
}

// Stream plain_off / set_slab_plain live in tls_dual_ct.odin with the seal engine.

// tls_host_stream_try_submit: progressive SSE/WS over TLS H1 (dual-CT seal∥send).
// Encrypts plain from resp_buf[plain_off:] via SSL_write (no stream_pool slabs),
// drains wBIO CT into free slab + tls_host_submit_ct (.Send — completion hits
// tls_host_on_send_complete). CQE advances stream_sent by the completed slab's plain_n.
@(private)
tls_host_stream_try_submit :: proc(conn: ^Connection) {
	if conn == nil || conn.state >= .Closing {
		return
	}
	if conn.tls_ssl == nil {
		// Ciphered flag without SSL: cannot seal — mark pending for later.
		conn.slot.stream_flush_pending = true
		return
	}

	// Keep resp_buf synced from response binding when present.
	r := &conn.slot.res
	if r._buf.buf != nil {
		conn.resp_buf = r._buf.buf
	}

	// Live dual-CT: while a CT send is in flight, drain residual / seal ahead into free slab.
	if _conn_wire_in_flight(conn) {
		conn.slot.stream_flush_pending = true
		if tls_server.bio_pending_out(conn.server.tls_provider, conn.tls_ssl) > 0 {
			_ = tls_host_try_drain_out(conn, hs = false)
		}
		tls_dual_ct_try_ahead(conn, .Stream)
		return
	}

	p := conn.server.tls_provider
	ssl := conn.tls_ssl
	d := &conn.dual_ct

	// Ordering: promote already-sealed CT before residual wBIO / new seal (CRITIC C2).
	if dual_ct_has_ready(d^) {
		if tls_host_promote_hold(conn) {
			tls_dual_ct_try_ahead(conn, .Stream)
			return
		}
	}

	// Prefer draining residual CT from a prior SSL_write before sealing more plain.
	if tls_server.bio_pending_out(p, ssl) > 0 {
		if !tls_host_try_drain_out(conn, hs = false) {
			if _conn_wire_in_flight(conn) {
				tls_dual_ct_try_ahead(conn, .Stream)
			}
			return
		}
		if _conn_wire_in_flight(conn) {
			tls_dual_ct_try_ahead(conn, .Stream)
			return
		}
	}

	unsent := len(conn.resp_buf) - tls_host_stream_plain_off(conn)
	if unsent <= 0 {
		// No new plain to seal. Finish only when all sealed plain is CQE-advanced
		// and no CT remains ready / inflight.
		if conn.slot.stream_ending &&
		   conn.slot.stream_sent >= len(conn.resp_buf) &&
		   conn.tls_stream_plain_n == 0 &&
		   d.tx_plain_n == 0 &&
		   d.hold_plain_n == 0 {
			_stream_finish(conn)
		} else if !conn.slot.stream_ending &&
		          conn.slot.stream_sent >= len(conn.resp_buf) &&
		          conn.tls_stream_plain_n == 0 &&
		          d.tx_plain_n == 0 &&
		          d.hold_plain_n == 0 {
			// Mid-session idle: arm CT recv for peer close/hangup.
			_session_arm_hangup_watch(conn)
		} else {
			conn.slot.stream_flush_pending = true
		}
		return
	}

	conn.slot.stream_open = true
	conn.slot.stream_flush_pending = false

	// First flush: on_respond once (same as clear path).
	if !conn.slot.stream_respond_fired {
		conn.slot.stream_respond_fired = true
		_response_fire_respond_hooks(r)
	}

	dst := d.tx
	if len(dst) == 0 {
		conn.slot.stream_flush_pending = true
		return
	}
	n_ct, plain_n, ok := tls_seal_window(conn, dst, .Stream)
	if !ok {
		tls_host_session_client_gone(conn)
		return
	}
	if plain_n <= 0 {
		// WANT_* or nothing sealed — drain / retry / arm.
		if tls_server.bio_pending_out(p, ssl) > 0 {
			if !tls_host_try_drain_out(conn, hs = false) {
				if _conn_wire_in_flight(conn) {
					tls_dual_ct_try_ahead(conn, .Stream)
				} else {
					conn.slot.stream_flush_pending = true
				}
				return
			}
			if _conn_wire_in_flight(conn) {
				tls_dual_ct_try_ahead(conn, .Stream)
				return
			}
		}
		// WANT_READ path may have armed recv; keep flush_pending for resume.
		if len(conn.resp_buf) > tls_host_stream_plain_off(conn) {
			conn.slot.stream_flush_pending = true
		}
		return
	}

	if n_ct <= 0 {
		// Sealed but no CT yet — advance stream_sent (idle path; no prior pending plain).
		conn.slot.stream_sent += plain_n
		_stream_compact_delivered(conn)
		if conn.slot.session != nil {
			_session_on_writable(conn)
		}
		more := len(conn.resp_buf) > conn.slot.stream_sent
		if more || conn.slot.stream_ending {
			tls_host_stream_try_submit(conn)
		} else {
			_session_arm_hangup_watch(conn)
		}
		return
	}

	// Record plain on primary slab, submit via shared dual-CT helper.
	d.tx_plain_n = plain_n
	// Explicitly inactive multi-op queue so a prior path cannot leak exec_n.
	conn.wire.exec_i = 0
	conn.wire.exec_n = 0
	if !tls_host_submit_ct(conn, dst, n_ct, hs = false) {
		d.tx_plain_n = 0
		// submit_ct already _wire_fail'd; session Client_Gone if session owns wire.
		if conn.slot.session != nil && conn.state < .Closing {
			sync.atomic_add(&session_metrics_client_gone, 1)
			_session_drive(conn, Session_Event{kind = .Client_Gone})
		}
		return
	}
	// Dual-CT: seal next window into hold while this CT sends.
	tls_dual_ct_try_ahead(conn, .Stream)
}

