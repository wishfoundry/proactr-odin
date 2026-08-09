// H2 GOAWAY: hard close on protocol error + PR10 graceful drain on server.closing.
package http

import "core:log"

import http2 "../http2"

// h2_host_emit_goaway_and_close: real GOAWAY on connection error, flush once, then close.
// Engine _fail only sets fail_code; host owns the wire GOAWAY (never claim GOAWAY if not written).
// Offline/unit (no worker td): GOAWAY lands in h2_out; state → Closing without ring close.
// Unlike graceful drain, this is hard close after one flush (protocol error path).
@(private)
h2_host_emit_goaway_and_close :: proc(conn: ^Connection, feed_err: http2.H2_Error) {
	if conn == nil || !conn.h2_active {
		return
	}
	code := conn.h2.fail_code
	if code == 0 {
		// Preface mismatch / contiguity may return Protocol without _fail.
		code = http2.H2_PROTOCOL_ERROR
	}
	last := conn.h2.last_peer_sid
	log.debugf(
		"H2: conn_feed err=%v code=%d last_peer_sid=%d fd=%v — GOAWAY then close",
		feed_err, code, last, conn.socket,
	)
	http2.conn_send_goaway(&conn.h2, &conn.h2_out, code)
	// Flush CT once if possible (TLS seals a window; offline leaves GOAWAY in h2_out).
	h2_host_flush_out(conn)
	if td != nil && td.state != .Uninitialized {
		connection_close(conn)
	} else {
		// Unit path: no ring — mark Closing so callers stop.
		_ = connection_set_state(conn, .Closing)
	}
}

// ---------------------------------------------------------------------------
// PR10 graceful GOAWAY drain (server.closing)
// ---------------------------------------------------------------------------

// h2_host_on_server_closing: once when Server.closing is observed for this conn.
// Writes GOAWAY(last_peer_sid, NO_ERROR) once; existing streams (incl. SSE) continue;
// new streams above last_sid are REFUSED by the engine. Closes when fully idle.
@(private)
h2_host_on_server_closing :: proc(conn: ^Connection) {
	if conn == nil || !conn.h2_active || conn.state >= .Closing {
		return
	}
	conn.h2_goaway_drain = true
	if !conn.h2.goaway_sent {
		log.debugf(
			"H2: graceful GOAWAY NO_ERROR last_peer_sid=%d fd=%v",
			conn.h2.last_peer_sid, conn.socket,
		)
		http2.conn_send_goaway(&conn.h2, &conn.h2_out, http2.H2_NO_ERROR)
		h2_host_flush_out(conn)
	}
	// Do not set close_on_io: mid-drain recv must still feed WINDOW_UPDATE / RST.
	// Mark Will_Close so oneshot finish path does not re-Idle for new work forever.
	if conn.state < .Will_Close {
		_ = connection_set_state(conn, .Will_Close)
	}
	h2_host_maybe_close_after_goaway_drain(conn)
}

// h2_host_maybe_goaway_from_closing: if server is shutting down and this H2 conn
// has not started drain, begin it. Called from recv/send complete cold paths.
@(private)
h2_host_maybe_goaway_from_closing :: proc(conn: ^Connection) {
	if conn == nil || !conn.h2_active || conn.state >= .Closing {
		return
	}
	if conn.h2_goaway_drain || conn.h2.goaway_sent {
		h2_host_maybe_close_after_goaway_drain(conn)
		return
	}
	if conn.server == nil {
		return
	}
	if !atomic_load(&conn.server.closing) {
		return
	}
	h2_host_on_server_closing(conn)
}

// Idle after graceful GOAWAY: no used slots, no serial busy, no pending body, out drained.
// Offline (no TLS): h2_out is a harness inspection buffer (flush is a no-op) — do not
// block close on residual GOAWAY bytes the unit test still wants to scan.
@(private)
h2_host_goaway_drain_idle :: proc(conn: ^Connection) -> bool {
	if conn == nil || !conn.h2_active {
		return true
	}
	if conn.h2_serial_busy {
		return false
	}
	if h2_host_any_slot_used(conn) {
		return false
	}
	if http2.conn_has_pending_body(&conn.h2) {
		return false
	}
	if conn.h2.open_streams > 0 {
		return false
	}
	if conn.tls_ssl != nil {
		if !h2_host_conn_drained(conn) {
			return false
		}
	} else if _conn_wire_in_flight(conn) {
		return false
	}
	return true
}

// Close when GOAWAY drain is idle (or offline → Closing). Safe to call often.
@(private)
h2_host_maybe_close_after_goaway_drain :: proc(conn: ^Connection) {
	if conn == nil || !conn.h2_active || conn.state >= .Closing {
		return
	}
	if !conn.h2.goaway_sent && !conn.h2_goaway_drain {
		return
	}
	if !h2_host_goaway_drain_idle(conn) {
		return
	}
	log.debugf("H2: GOAWAY drain idle — close fd=%v", conn.socket)
	if td != nil && td.state != .Uninitialized {
		connection_close(conn)
	} else {
		_ = connection_set_state(conn, .Closing)
	}
}

