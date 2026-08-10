// Ciphered H1 oneshot plain cursor + dual-CT response flush (from tls_host).
package http

import "core:log"

import tls_server "../tls_server"

// ---------------------------------------------------------------------------
// Ciphered oneshot plain cursor: heading (tls_plain_rest) then borrowed body.
// ---------------------------------------------------------------------------

// Total remaining plain bytes across rest + body parts.
@(private)
tls_plain_total_remaining :: proc(conn: ^Connection) -> int {
	if conn == nil {
		return 0
	}
	n := len(conn.tls_plain_rest)
	body := conn.tls_plain_body
	if len(body) > 0 {
		off := conn.tls_plain_body_off
		if off < 0 {
			off = 0
		}
		if off < len(body) {
			n += len(body) - off
		}
	}
	return n
}

// View of the next contiguous plain bytes up to max (stops at part boundary).
@(private)
tls_plain_window :: proc(conn: ^Connection, max: int) -> []u8 {
	if conn == nil || max <= 0 {
		return nil
	}
	rest := conn.tls_plain_rest
	if len(rest) > 0 {
		n := min(len(rest), max)
		return rest[:n]
	}
	body := conn.tls_plain_body
	if len(body) == 0 {
		return nil
	}
	off := conn.tls_plain_body_off
	if off < 0 {
		off = 0
	}
	if off >= len(body) {
		return nil
	}
	rem := len(body) - off
	n := min(rem, max)
	return body[off:][:n]
}

// Advance plain cursor by n bytes across rest then body.
@(private)
tls_plain_advance :: proc(conn: ^Connection, n: int) {
	if conn == nil || n <= 0 {
		return
	}
	left := n
	rest := conn.tls_plain_rest
	if len(rest) > 0 {
		take := min(left, len(rest))
		conn.tls_plain_rest = rest[take:]
		left -= take
		if left == 0 {
			return
		}
	}
	body := conn.tls_plain_body
	if len(body) == 0 {
		return
	}
	off := conn.tls_plain_body_off
	if off < 0 {
		off = 0
	}
	if off >= len(body) {
		return
	}
	take := min(left, len(body) - off)
	conn.tls_plain_body_off = off + take
}

// Clear oneshot plain cursor (heading + borrowed body).
@(private)
tls_plain_clear :: proc(conn: ^Connection) {
	if conn == nil {
		return
	}
	conn.tls_plain_rest = nil
	conn.tls_plain_body = nil
	conn.tls_plain_body_off = 0
	conn.tls_first_seal_pending = false
}

// Oneshot seal window + try_seal_hold live in tls_dual_ct.odin (tls_seal_window /
// tls_dual_ct_try_ahead with .Oneshot).

// tls_host_flush_response: window plain → SSL_write → drain CT → submit.
// Linux: dual-CT (try_ahead while send inflight). Darwin H1 oneshot: reactor_tls_flush
// (until-EAGAIN + single residual; no soft-CQ between windows). Clear-H1 is non-TLS
// and never enters here. Stream/H2 use their own flush entry points.
@(private)
tls_host_flush_response :: proc(conn: ^Connection) {
	if conn == nil || conn.tls_ssl == nil {
		return
	}
	if conn.state >= .Closing {
		return
	}

	when ODIN_OS == .Darwin {
		// H1 oneshot product path → reactor. (H2: h2_host_flush_out; stream: tls_stream.)
		if !conn.h2_active && !tls_host_stream_long_lived(conn) {
			reactor_tls_flush(conn)
			return
		}
	}

	// Live dual-CT: keep encrypting into free slab while a CT send is on the wire.
	if _conn_wire_in_flight(conn) {
		// Residual wBIO → free slab if any.
		if tls_server.bio_pending_out(conn.server.tls_provider, conn.tls_ssl) > 0 {
			_ = tls_host_try_drain_out(conn, hs = false)
		}
		tls_dual_ct_try_ahead(conn, .Oneshot)
		return
	}

	p := conn.server.tls_provider
	ssl := conn.tls_ssl
	d := &conn.dual_ct

	// Ordering: promote already-sealed CT before draining newer wBIO residual
	// (CRITIC C2 — residual-before-promote reorders records).
	if dual_ct_has_ready(d^) {
		if tls_host_promote_hold(conn) {
			tls_dual_ct_try_ahead(conn, .Oneshot)
			return
		}
	}

	// Drain residual CT from prior SSL_write into free slab / submit.
	if tls_server.bio_pending_out(p, ssl) > 0 {
		if !tls_host_try_drain_out(conn, hs = false) {
			if _conn_wire_in_flight(conn) {
				tls_dual_ct_try_ahead(conn, .Oneshot)
			}
			return
		}
		if _conn_wire_in_flight(conn) {
			tls_dual_ct_try_ahead(conn, .Oneshot)
			return
		}
	}

	if tls_plain_total_remaining(conn) == 0 {
		tls_plain_clear(conn)
		if conn.pt.admitted > 0 {
			pt_release(&conn.pt, conn.pt.admitted)
		}
		path_metrics_note_req()
		clean_request_loop(conn)
		return
	}

	dst := d.tx
	if len(dst) == 0 {
		return
	}
	n_ct, _, ok := tls_seal_window(conn, dst, .Oneshot)
	if !ok {
		if conn.pt.admitted > 0 {
			// seal failed hard
		}
		log.errorf("TLS: PT high-water refuse or SSL_write fail fd=%v admitted=%d", conn.socket, conn.pt.admitted)
		connection_close(conn)
		return
	}
	if n_ct <= 0 {
		// Buffered / WANT — drain or continue.
		if tls_server.bio_pending_out(p, ssl) > 0 {
			_ = tls_host_try_drain_out(conn, hs = false)
			if _conn_wire_in_flight(conn) {
				tls_dual_ct_try_ahead(conn, .Oneshot)
				return
			}
		}
		if tls_plain_total_remaining(conn) > 0 && !_conn_wire_in_flight(conn) {
			tls_host_flush_response(conn)
			return
		}
		if tls_plain_total_remaining(conn) == 0 {
			tls_plain_clear(conn)
			path_metrics_note_req()
			clean_request_loop(conn)
		}
		return
	}

	if tls_plain_total_remaining(conn) == 0 {
		path_metrics_note_req()
	}
	if !tls_host_submit_ct(conn, dst, n_ct, hs = false) {
		return
	}
	// Dual-CT: immediately seal next window into hold while send is armed.
	tls_dual_ct_try_ahead(conn, .Oneshot)
}

