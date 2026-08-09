#+build darwin
package http

// Darwin reactor I/O helpers: residual CT region + nonblocking write + WRITE arm.
// Product sockets still share the worker proactr kqueue for accept/recv/timers (hybrid).
// Residual EAGAIN arms EVFILT_WRITE via host_submit_send with conn.reactor_h1 set so
// soft_cq_send_completes is not charged (H1/H2 bulk + HS/stream residual law).

import "core:log"

import proactr "../proactr"

// reactor_residual_clear drops the single residual CT region meta.
@(private)
reactor_residual_clear :: #force_inline proc(conn: ^Connection) {
	if conn == nil {
		return
	}
	conn.reactor_res_off = 0
	conn.reactor_res_n = 0
}

// reactor_residual_view: dual_ct.tx[off:off+n] when residual present.
@(private)
reactor_residual_view :: proc(conn: ^Connection) -> []u8 {
	if conn == nil || conn.reactor_res_n <= 0 {
		return nil
	}
	tx := conn.dual_ct.tx
	off := conn.reactor_res_off
	n := conn.reactor_res_n
	if off < 0 || n <= 0 || off + n > len(tx) {
		return nil
	}
	return tx[off:][:n]
}

// reactor_residual_set records residual CT in dual_ct.tx[off:off+n].
@(private)
reactor_residual_set :: proc(conn: ^Connection, off, n: int) {
	if conn == nil {
		return
	}
	if n <= 0 {
		reactor_residual_clear(conn)
		return
	}
	conn.reactor_res_off = off
	conn.reactor_res_n = n
}

// reactor_write_residual: write residual CT until empty, EAGAIN, or hard error.
// Returns (again, hard). again=true → residual still pending (caller must arm WRITE).
@(private)
reactor_write_residual :: proc(conn: ^Connection) -> (again: bool, hard: bool) {
	if conn == nil {
		return false, false
	}
	for conn.reactor_res_n > 0 {
		view := reactor_residual_view(conn)
		if len(view) == 0 {
			reactor_residual_clear(conn)
			return false, false
		}
		sent, would_block, err := host_try_send_nb(conn, view)
		if err {
			return false, true
		}
		if would_block {
			return true, false
		}
		if sent <= 0 {
			// Zero progress without EAGAIN: treat as hard (peer closed / stall).
			return false, true
		}
		off, n := reactor_residual_advance(conn.reactor_res_off, conn.reactor_res_n, sent)
		conn.reactor_res_off = off
		conn.reactor_res_n = n
	}
	return false, false
}

// reactor_arm_write_residual: residual already set; arm façade WRITE for re-entry.
// Does not soft-complete full windows — only residual remainder.
//
// Contract: set reactor_h1 *before* host_submit_send so the eventual send CQE is
// demuxed by reactor_on_send_complete and is **not** charged as soft_cq_send_completes
// (see host_submit_send / _host_on_wire_send). This is still a proactr submit_send
// (P5-lite hybrid: residual arm rides façade; bulk windows do not).
@(private)
reactor_arm_write_residual :: proc(conn: ^Connection) -> bool {
	if conn == nil {
		return false
	}
	view := reactor_residual_view(conn)
	if len(view) == 0 {
		return false
	}
	if conn.state >= .Closing {
		return false
	}
	if _conn_wire_in_flight(conn) {
		// Already armed — residual stays until CQE. Keep reactor_h1 if set.
		return true
	}
	conn.wire.pending_send = view
	conn.reactor_h1 = true // must precede host_submit_send (metric + CQE demux)
	if err := host_submit_send(conn); err != .None {
		conn.reactor_h1 = false
		_wire_fail(conn, "reactor residual arm submit_send failed: %v", err)
		return false
	}
	path_metrics_note_eagain_arm()
	return true
}

// reactor_sync_residual_from_pending: after partial façade SEND, keep residual meta
// as the single source of truth matching pending_send (plan: one residual region).
@(private)
reactor_sync_residual_from_pending :: proc(conn: ^Connection) {
	if conn == nil || !conn.reactor_h1 {
		return
	}
	ps := conn.wire.pending_send
	if len(ps) == 0 {
		reactor_residual_clear(conn)
		return
	}
	tx := conn.dual_ct.tx
	if len(tx) == 0 {
		return
	}
	base := raw_data(tx)
	p := raw_data(ps)
	// pending_send must be a subslice of dual_ct.tx.
	if uintptr(p) < uintptr(base) || uintptr(p)+uintptr(len(ps)) > uintptr(base)+uintptr(len(tx)) {
		return
	}
	off := int(uintptr(p) - uintptr(base))
	reactor_residual_set(conn, off, len(ps))
}
