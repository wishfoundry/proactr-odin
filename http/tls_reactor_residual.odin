package http

// Shared residual CT helpers for dense TLS flush (Darwin kqueue + Linux io_uring).
//
// Single residual region lives in dual_ct.tx[reactor_res_off:][:reactor_res_n].
// Residual WRITE arm is platform-specific (see reactor_arm_write_residual):
//   Darwin: level EVFILT_WRITE on reactor kq
//   Linux:  host_submit_send (io_uring) with reactor_h1 so CQE is not soft_cq

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
			return false, true
		}
		off, n := reactor_residual_advance(conn.reactor_res_off, conn.reactor_res_n, sent)
		conn.reactor_res_off = off
		conn.reactor_res_n = n
	}
	return false, false
}

// reactor_sync_residual_from_pending: keep residual meta aligned with pending_send.
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
	if uintptr(p) < uintptr(base) || uintptr(p)+uintptr(len(ps)) > uintptr(base)+uintptr(len(tx)) {
		return
	}
	off := int(uintptr(p) - uintptr(base))
	reactor_residual_set(conn, off, len(ps))
}

// reactor_arm_write_residual: stage residual on the wire after EAGAIN.
// Contract: set reactor_h1 before arm so soft_cq_send_completes is never charged.
//
// Darwin: level EVFILT_WRITE until residual empty (native reactor kq).
// Linux:  host_submit_send (io_uring); residual CQE demuxes via reactor_on_send_complete.
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
	// reactor_h1 before any arm so soft_cq is never charged on the residual CQE.
	conn.reactor_h1 = true
	conn.wire.pending_send = view

	when ODIN_OS == .Darwin {
		if conn.wire.kind == .None {
			conn.wire.kind = .Send
		}
		if conn.reactor_write_armed && conn.reactor_write_level {
			// Level already enabled — no re-arm.
			return true
		}
		// Upgrade to level residual WRITE (delete oneshot if any, then level add).
		if conn.reactor_write_armed && !conn.reactor_write_level {
			reactor_delete_filters(i32(conn.socket), false, true)
			conn.reactor_write_armed = false
		}
		reactor_arm_filter(i32(conn.socket), .Write, nil, oneshot = false)
		conn.reactor_write_armed = true
		conn.reactor_write_level = true
		path_metrics_note_eagain_arm()
		return true
	} else when ODIN_OS == .Linux {
		// Partial residual resubmit uses host_submit_send from _host_on_wire_send;
		// do not double-submit while an SQE is already outstanding.
		if _conn_wire_in_flight(conn) {
			path_metrics_note_eagain_arm()
			return true
		}
		// host_submit_send sets wire.kind = .Send on success (do not set kind first —
		// that would make in_flight true and skip submit).
		if err := host_submit_send(conn); err != .None {
			_wire_fail(conn, "reactor residual submit_send failed: %v", err)
			return false
		}
		path_metrics_note_eagain_arm()
		return true
	} else {
		return false
	}
}
