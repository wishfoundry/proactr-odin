// PR8/PR9 H2 host — TLS ALPN h2 → sans-I/O http2 engine on the ring.
//
// Scope:
//   - After TLS Open, if ALPN is h2: drive Http2_Connection instead of H1 scanner
//   - Multi-slot slab (H2_SLOT_CAP) allocated only on h2 open (lazy; clear/TLS H1 free)
//   - Default concurrent unary (h2_serial_dispatch=false): take while free slots
//   - Opt-in serial (h2_serial_dispatch=true): single in-flight oneshot (eng/debug)
//   - Live windows: feed WINDOW_UPDATE; flush pending body on update
//   - Duplex: keep CT recv armed while CT send may be in flight under H2
//   - Unary GET/POST oneshot handlers via the same server.handler
//   - On conn_feed error / fail_code: real GOAWAY then flush-once then close
//
// PR9 product: concurrent unary (default) + multi-SSE (M1–M6 offline gates).
// PR10: graceful GOAWAY drain on server.closing + optional SSE-vs-bulk RR weights.
// WS-on-H2 unsupported. Baseline: docs/design/dual-tls-h2/H2_PRODUCT_BASELINE.md
package http

import "core:log"
import "core:mem/virtual"
import "core:strconv"
import "core:strings"
import "core:sync"

import http2 "../http2"

// Note: Response._buf is core:bytes.Buffer; body scrap reuses Connection.resp_buf.
// Concurrent oneshot materialize is safe because handlers on one worker are
// strictly sequential (no nested respond): each respond finishes copy into
// engine pending before the next take/handler runs. Shared resp_buf is not
// concurrent-write; "concurrent" H2 = interleaved CQEs / multi-slot hold, not
// re-entrant handlers (MEM-M2 honesty).

// Test observability: increments whenever h2_host_on_send_complete would arm
// CT recv (duplex law). Offline tests assert the arm path without a live SSL*.
@(private)
h2_test_arm_recv_count: int

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------

// h2_host_ensure_slots: allocate multi-slot slab once (on open or unit setup).
// Clear/TLS-H1 Connections leave h2_slots nil — no H2_SLOT_CAP × Stream_Slot tax.
@(private)
h2_host_ensure_slots :: proc(conn: ^Connection) -> bool {
	if conn == nil {
		return false
	}
	if conn.h2_slots != nil {
		return true
	}
	alloc := context.allocator
	if conn.server != nil {
		alloc = conn.server.conn_allocator
	}
	slots, err := new([H2_SLOT_CAP]Stream_Slot, alloc)
	if err != nil || slots == nil {
		return false
	}
	conn.h2_slots = slots
	return true
}

// h2_host_on_open: ALPN h2 after handshake. Init engine, send SETTINGS, arm duplex.
@(private)
h2_host_on_open :: proc(conn: ^Connection) {
	if conn == nil || conn.server == nil || conn.state >= .Closing {
		return
	}
	alloc := conn.server.conn_allocator
	http2.conn_init(&conn.h2, true, alloc)
	conn.h2_out.allocator = alloc
	clear(&conn.h2_out)
	conn.h2_out_off = 0
	conn.h2_active = true
	conn.h2_serial_busy = false
	conn.h2_dispatch_sid = 0
	conn.h2_goaway_drain = false

	// PR10 fairness weights (0 opts → engine defaults 2 / 1).
	if conn.server != nil {
		conn.h2.weight_interactive = conn.server.opts.h2_weight_interactive
		conn.h2.weight_bulk = conn.server.opts.h2_weight_bulk
	}

	// Lazy multi-slot: allocate only when H2 is negotiated (not on every Connection).
	if !h2_host_ensure_slots(conn) {
		log.errorf("H2: slot slab alloc failed fd=%v", conn.socket)
		connection_close(conn)
		return
	}
	for i in 0 ..< H2_SLOT_CAP {
		conn.h2_slot_used[i] = false
		conn.h2_slot_sids[i] = 0
		stream_slot_reset_exchange(&conn.h2_slots[i], conn)
	}

	// PT scratch for SSL_read under H2 (scanner is unused for framing).
	if conn.h2_pt_buf == nil {
		n := conn.server.opts.recv_buf_size
		if n <= 0 {
			n = TLS_CT_RX_DEFAULT
		}
		buf, err := make([]u8, n, alloc)
		if err != nil || buf == nil {
			log.errorf("H2: PT buf alloc failed fd=%v", conn.socket)
			connection_close(conn)
			return
		}
		conn.h2_pt_buf = buf
	}

	// Server connection preface = SETTINGS (no client magic).
	http2.conn_send_preface(&conn.h2, &conn.h2_out)

	if !connection_set_state(conn, .Idle) {
		return
	}

	// Seal SETTINGS + arm CT recv (duplex).
	h2_host_flush_out(conn)
	if conn.state >= .Closing {
		return
	}
	// Arm recv even if a CT send is still inflight (H2 duplex law).
	if !tls_host_arm_recv(conn) {
		// If send is inflight, arm may still succeed (recv is independent).
		// Fail only when truly unable and idle — try once more after send CQE.
		if !_conn_wire_in_flight(conn) {
			connection_close(conn)
		}
	}
	log.debugf("H2: Open eng unary host fd=%v", conn.socket)
}

// h2_host_destroy: free engine + slot slab + PT buf + out buffer. Safe if never H2.
@(private)
h2_host_destroy :: proc(conn: ^Connection) {
	if conn == nil {
		return
	}
	if conn.h2_active {
		http2.conn_destroy(&conn.h2)
		conn.h2 = {} // so a free-list reuse + re-open can conn_init cleanly
	}
	conn.h2_active = false
	conn.h2_serial_busy = false
	conn.h2_dispatch_sid = 0
	conn.h2_goaway_drain = false
	if conn.h2_out != nil {
		delete(conn.h2_out)
		conn.h2_out = {}
	}
	conn.h2_out_off = 0
	alloc := context.allocator
	if conn.server != nil {
		alloc = conn.server.conn_allocator
	}
	if conn.h2_slots != nil {
		for i in 0 ..< H2_SLOT_CAP {
			if conn.h2_slot_used[i] {
				stream_slot_reset_exchange(&conn.h2_slots[i], conn)
			}
			conn.h2_slot_used[i] = false
			conn.h2_slot_sids[i] = 0
		}
		free(conn.h2_slots, alloc)
		conn.h2_slots = nil
	}
	if conn.h2_pt_buf != nil {
		delete(conn.h2_pt_buf, alloc)
		conn.h2_pt_buf = nil
	}
}

// ---------------------------------------------------------------------------
// CT / PT path
// ---------------------------------------------------------------------------

// h2_host_on_ct_ready: ciphertext already fed to rBIO; SSL_read PT → conn_feed.
@(private)
h2_host_on_ct_ready :: proc(conn: ^Connection) {
	if conn == nil || !conn.h2_active || conn.tls_ssl == nil {
		return
	}
	if conn.state >= .Closing {
		return
	}
	if conn.temp_slot < 0 {
		_ = conn_temp_attach(conn)
	}
	context.temp_allocator = virtual.arena_allocator(&conn.temp_allocator)

	// Drain all available PT from SSL into the engine.
	for {
		if conn.state >= .Closing {
			return
		}
		n := tls_host_ssl_read_burst(conn, conn.h2_pt_buf)
		if n <= 0 {
			break
		}
		h2_host_on_pt(conn, conn.h2_pt_buf[:n])
		if conn.state >= .Closing {
			return
		}
	}

	// Flush any auto-replies / pending DATA produced by feed.
	h2_host_flush_out(conn)
	h2_host_maybe_finish_exchange(conn)
	h2_host_dispatch_available(conn)
	// PR10: if server.closing, ensure GOAWAY and close when idle.
	h2_host_maybe_goaway_from_closing(conn)

	// Duplex: re-arm CT recv even if a CT send is in flight or more plain out pending.
	if conn.state < .Closing {
		_ = tls_host_arm_recv(conn)
	}
}

// h2_host_on_pt: feed plaintext H2 bytes into the engine (also unit-testable sans TLS).
@(private)
h2_host_on_pt :: proc(conn: ^Connection, pt: []u8) {
	if conn == nil || !conn.h2_active {
		return
	}
	err := http2.conn_feed(&conn.h2, pt, &conn.h2_out)
	if err != .None || conn.h2.fail_code != 0 {
		h2_host_emit_goaway_and_close(conn, err)
		return
	}
	// Peer RST_STREAM / failed streams → .Client_Gone on matching SSE sessions (M6).
	h2_host_poll_session_resets(conn)
}


// ---------------------------------------------------------------------------
// Dispatch (concurrent default; serial opt-in)
// ---------------------------------------------------------------------------

// h2_host_serial_mode: true when Server_Opts.h2_serial_dispatch requests single-flight.
@(private)
h2_host_serial_mode :: proc(conn: ^Connection) -> bool {
	return conn != nil && conn.server != nil && conn.server.opts.h2_serial_dispatch
}

// h2_host_has_free_slot: any unused entry in the multi-slot slab.
@(private)
h2_host_has_free_slot :: proc(conn: ^Connection) -> bool {
	if conn == nil || conn.h2_slots == nil {
		return false
	}
	for i in 0 ..< H2_SLOT_CAP {
		if !conn.h2_slot_used[i] {
			return true
		}
	}
	return false
}

// h2_host_sid_for_response: resolve stream id from r._slot → h2_slot_sids[i].
// Falls back to h2_dispatch_sid (serial / 400 path without a live slot bind).
// (sid_for_slot / slot_find_by_ptr defined near slot map helpers below.)
@(private)
h2_host_sid_for_response :: proc(conn: ^Connection, r: ^Response) -> u32 {
	if conn != nil && r != nil && r._slot != nil {
		if sid, ok := h2_host_sid_for_slot(conn, r._slot); ok {
			return sid
		}
	}
	if conn != nil {
		return conn.h2_dispatch_sid
	}
	return 0
}

// h2_host_dispatch_available: take+handler while free slots and complete requests ready.
// Serial mode: at most one in-flight oneshot (h2_serial_busy). Concurrent: free slots
// only — a long-lived hold on one slot does not block other streams.
@(private)
h2_host_dispatch_available :: proc(conn: ^Connection) {
	if conn == nil || !conn.h2_active || conn.state >= .Closing {
		return
	}
	serial := h2_host_serial_mode(conn)

	for {
		if conn.state >= .Closing {
			return
		}
		if serial && conn.h2_serial_busy {
			return
		}
		// Soft refuse when multi-slot is full: RST_STREAM(REFUSED_STREAM) for one
		// ready request and keep the connection open (do not connection_close).
		// When no free slot and nothing ready, wait for a slot to free.
		if !h2_host_has_free_slot(conn) {
			sid_ref, _, _, ok_ref := http2.conn_take_request(&conn.h2)
			if !ok_ref {
				return
			}
			log.warnf("H2: no free slot for sid=%d fd=%v — REFUSED_STREAM", sid_ref, conn.socket)
			http2.conn_refuse_stream(&conn.h2, &conn.h2_out, sid_ref)
			h2_host_flush_out(conn)
			// Refuse further ready streams while still full; free slots resume take+handler.
			continue
		}

		sid, headers, body, ok := http2.conn_take_request(&conn.h2)
		if !ok {
			return
		}

		// Admit a multi-slot entry (slab allocated on open).
		slot_i, got := h2_host_slot_alloc(conn, sid)
		if !got {
			// Race / slab missing after take: refuse this stream, keep conn open.
			log.warnf("H2: slot alloc failed for sid=%d fd=%v — REFUSED_STREAM", sid, conn.socket)
			http2.conn_refuse_stream(&conn.h2, &conn.h2_out, sid)
			h2_host_flush_out(conn)
			continue
		}

		// Worker path: attach scrap from temp pool. Offline unit tests may pre-init
		// a Buffer arena and set temp_slot ≥ 0 to skip the pool.
		if conn.temp_slot < 0 {
			if td != nil && td.state != .Uninitialized {
				_ = conn_temp_attach(conn)
			}
		}
		if conn.temp_allocator.kind == .Buffer && conn.temp_allocator.curr_block != nil {
			conn_temp_reset(conn)
			context.temp_allocator = virtual.arena_allocator(&conn.temp_allocator)
		}
		// else: keep ambient context.temp_allocator (unit / no scrap slot)
		alloc := context.temp_allocator

		// Build Request into loop (handler-facing; sequential takes reuse scrap).
		conn.loop.conn = conn
		client := conn.loop.req.client
		conn.loop.req = {}
		conn.loop.req.client = client
		if !h2_request_from_headers(&conn.loop.req, headers, body, alloc) {
			log.warnf("H2: bad request headers sid=%d fd=%v", sid, conn.socket)
			h2_host_slot_free(conn, slot_i)
			// Minimal 400 on the stream (no slot; finish via dispatch_sid when serial).
			if serial {
				conn.h2_serial_busy = true
			}
			conn.h2_dispatch_sid = sid
			bad := []http2.Header{{name = ":status", value = "400"}}
			http2.conn_send_response(&conn.h2, &conn.h2_out, sid, bad, nil)
			h2_host_flush_out(conn)
			h2_host_maybe_finish_exchange(conn)
			// Borrowed headers no longer needed (no handler ran on this request).
			http2.conn_app_release(&conn.h2, sid)
			if serial {
				return // one flight in serial
			}
			continue
		}

		slot := &conn.h2_slots[slot_i] // h2_slots non-nil after successful slot_alloc
		response_init(&slot.res, conn, alloc, slot)

		if !connection_set_state(conn, .Active) {
			h2_host_slot_free(conn, slot_i)
			http2.conn_refuse_stream(&conn.h2, &conn.h2_out, sid)
			h2_host_flush_out(conn)
			return
		}

		if serial {
			conn.h2_serial_busy = true
		}
		conn.h2_dispatch_sid = sid // last taken; respond prefers r._slot map

		// HEAD → GET redirect for handler parity with H1.
		rline := &conn.loop.req.line.(Requestline)
		is_head := rline.method == .Head
		if is_head && conn.server != nil && conn.server.opts.redirect_head_to_get {
			conn.loop.req.is_head = true
			rline.method = .Get
		}

		// OPTIONS * short-circuit (same as H1).
		if rline.method == .Options {
			if t, tok := rline.target.(string); tok && t == "*" {
				slot.res.status = .OK
				respond(&slot.res)
				http2.conn_app_release(&conn.h2, sid)
				if serial {
					return
				}
				continue
			}
		}

		if conn.server != nil {
			conn.server.handler.handle(&conn.server.handler, &conn.loop.req, &slot.res)
		}
		// If handler did not respond (bug), fail closed with 500.
		// Long-lived session attach sets _session_attached and must not get a forced 500.
		if !slot.res.sent && !slot.res._session_attached && slot.session == nil {
			// Still bound to this sid?
			if si, ok := h2_host_slot_find(conn, sid); ok && si == slot_i {
				log.warnf("H2: handler did not respond sid=%d fd=%v", sid, conn.socket)
				slot.res.status = .Internal_Server_Error
				respond(&slot.res)
			}
		}

		// Release stream header/body borrow after handler (and any forced respond).
		// Safe even if respond already closed the stream mid-handler.
		http2.conn_app_release(&conn.h2, sid)

		if serial {
			return // max one in-flight oneshot under serial mode
		}
		// Concurrent: loop — free slots + ready requests continue even if this
		// slot remains used (oneshot pending finish or long-lived hold).
	}
}

// Back-compat name used by older call sites / mental model.
@(private)
h2_host_dispatch_one :: proc(conn: ^Connection) {
	h2_host_dispatch_available(conn)
}

// ---------------------------------------------------------------------------
// Response path
// ---------------------------------------------------------------------------

// h2_host_send_response: map Response → frames on the stream for r._slot; flush via SSL_write.
@(private)
h2_host_send_response :: proc(conn: ^Connection, r: ^Response) {
	if conn == nil || r == nil || !conn.h2_active {
		return
	}
	sid := h2_host_sid_for_response(conn, r)
	if sid == 0 {
		log.errorf("H2: respond with no stream sid fd=%v", conn.socket)
		return
	}
	// Keep last-respond sid for serial finish / HEAD view fallback.
	conn.h2_dispatch_sid = sid

	// Materialize body bytes without H1 heading.
	body := h2_host_materialize_body(r)
	if _response_is_head(conn) {
		body = nil // HEAD: headers only (RFC); CL still from original if set by handler
	}

	// Build HPACK header list (:status + app headers). Use temp scrap.
	hdrs: [dynamic]http2.Header
	hdrs.allocator = context.temp_allocator
	h2_response_headers_from(r, &hdrs)

	http2.conn_send_response(&conn.h2, &conn.h2_out, sid, hdrs[:], body)
	h2_host_flush_out(conn)
	h2_host_maybe_finish_exchange(conn)
	// Duplex: arm CT recv so WINDOW_UPDATE can arrive while more DATA pending.
	if conn.state < .Closing {
		_ = tls_host_arm_recv(conn)
	}
}

// h2_host_materialize_body returns body bytes for H2 send (no H1 status-line).
// Empty when no body cmds.
//
// P0-3 oneshot borrow: a single Static or Bytes cmd is returned as a view of
// c.bytes — no copy into resp_buf. The slice is only used through the sync
// conn_send_response → frame_write into h2_out (or pending append under flow
// control). Static is process-lifetime; handler-owned Bytes must remain valid
// until respond returns (matrix / oneshot handlers keep body until then).
//
// Multi-cmd Static/Bytes still concatenate into resp_buf. File cmds unsupported
// on H2 eng path. Shared resp_buf scrap for multi-cmd: handlers on a worker are
// sequential, so materialize → engine encode completes before the next handler.
// Nested/async respond while another slot still aliases resp_buf is unsupported.
@(private)
h2_host_materialize_body :: proc(r: ^Response) -> []u8 {
	if r == nil {
		return nil
	}
	// Already written body in buffer (body_reserve / writer) — eng oneshot rarely hits this.
	if r._heading_written {
		buf := r._buf.buf[:]
		for i := 0; i + 3 < len(buf); i += 1 {
			if buf[i] == '\r' && buf[i + 1] == '\n' && buf[i + 2] == '\r' && buf[i + 3] == '\n' {
				return buf[i + 4:]
			}
		}
		return nil
	}
	if r._cmd_count == 0 {
		return nil
	}
	cmds := r._cmds[:r._cmd_count]

	// Single Static/Bytes: borrow — skip resp_buf materialize (P0-3).
	if r._cmd_count == 1 {
		c := cmds[0]
		if c.kind == .Static || c.kind == .Bytes {
			return c.bytes
		}
		if c.kind == .File {
			log.warnf("H2 eng: body File cmd not supported; omitted")
			return nil
		}
	}

	// Multi-cmd: copy Static/Bytes only into resp_buf (eng unary concat).
	total: int
	for c in cmds {
		if c.kind == .Static || c.kind == .Bytes {
			total += len(c.bytes)
		}
	}
	if total == 0 {
		return nil
	}
	conn := r._conn
	if conn == nil {
		return nil
	}
	clear(&conn.resp_buf)
	if cap(conn.resp_buf) < total {
		reserve(&conn.resp_buf, total)
	}
	for c in cmds {
		switch c.kind {
		case .Static, .Bytes:
			append(&conn.resp_buf, ..c.bytes)
		case .File:
			log.warnf("H2 eng: body File cmd not supported; omitted")
		}
	}
	r._buf.buf = conn.resp_buf
	return conn.resp_buf[:]
}

// h2_response_headers_from builds :status + regular headers for HPACK encode.
// Skips hop-by-hop / H1-only fields. Status digits only in :status value.
h2_response_headers_from :: proc(r: ^Response, out: ^[dynamic]http2.Header) {
	if r == nil || out == nil {
		return
	}
	// :status — three digit code
	code := int(r.status)
	if code < 100 || code > 599 {
		code = 500
	}
	st_buf: [3]u8
	st_buf[0] = u8('0' + (code / 100) % 10)
	st_buf[1] = u8('0' + (code / 10) % 10)
	st_buf[2] = u8('0' + code % 10)
	// Clone into temp so the slice outlives the stack buffer across encode.
	st := strings.clone(string(st_buf[:]), context.temp_allocator)
	append(out, http2.Header{name = ":status", value = st})

	// Date for 2xx–5xx when not already set (parity with H1 heading).
	// server_date requires a worker thread — skip on offline/unit paths (td unset).
	if r.status >= .OK && r.status <= .Internal_Server_Error && !headers_has_unsafe(r.headers, "date") {
		if r._conn != nil && r._conn.server != nil && td != nil && td.state != .Uninitialized {
			append(out, http2.Header{name = "date", value = server_date(r._conn.server)})
		}
	}

	for k, v in r.headers._kv {
		// Skip hop-by-hop / framing headers that must not appear on H2.
		switch k {
		case "connection", "transfer-encoding", "keep-alive", "proxy-connection", "upgrade":
			continue
		case "host":
			// request-only
			continue
		}
		append(out, http2.Header{name = k, value = v})
	}
}


@(private)
h2_host_exchange_done_slot :: proc(conn: ^Connection, idx: u8, sid: u32) {
	if conn == nil || conn.h2_slots == nil || int(idx) >= H2_SLOT_CAP {
		return
	}
	_response_fire_complete_hooks(&conn.h2_slots[idx].res)
	h2_host_slot_free(conn, idx)
	if conn.h2_dispatch_sid == sid {
		conn.h2_dispatch_sid = 0
	}
	// Serial mode: at most one oneshot in flight — free clears the gate.
	if h2_host_serial_mode(conn) {
		conn.h2_serial_busy = false
	}
}

@(private)
h2_host_any_slot_used :: proc(conn: ^Connection) -> bool {
	if conn == nil || conn.h2_slots == nil {
		return false
	}
	for i in 0 ..< H2_SLOT_CAP {
		if conn.h2_slot_used[i] {
			return true
		}
	}
	return false
}

@(private)
h2_host_slot_alloc :: proc(conn: ^Connection, sid: u32) -> (idx: u8, ok: bool) {
	if conn == nil || conn.h2_slots == nil {
		return 0, false
	}
	for i in 0 ..< H2_SLOT_CAP {
		if !conn.h2_slot_used[i] {
			conn.h2_slot_used[i] = true
			conn.h2_slot_sids[i] = sid
			stream_slot_reset_exchange(&conn.h2_slots[i], conn)
			return u8(i), true
		}
	}
	return 0, false
}

@(private)
h2_host_slot_free :: proc(conn: ^Connection, idx: u8) {
	if conn == nil || conn.h2_slots == nil || int(idx) >= H2_SLOT_CAP {
		return
	}
	slot := &conn.h2_slots[idx]
	// Fail-closed: destroy live session before reset (pad/timer gen).
	if slot.session != nil {
		_session_destroy_st(slot.session, after_wire = false)
	}
	stream_slot_reset_exchange(slot, conn)
	conn.h2_slot_used[idx] = false
	conn.h2_slot_sids[idx] = 0
}

@(private)
h2_host_slot_find :: proc(conn: ^Connection, sid: u32) -> (idx: u8, ok: bool) {
	if conn == nil || conn.h2_slots == nil || sid == 0 {
		return 0, false
	}
	for i in 0 ..< H2_SLOT_CAP {
		if conn.h2_slot_used[i] && conn.h2_slot_sids[i] == sid {
			return u8(i), true
		}
	}
	return 0, false
}

// Stream id for an H2 exchange slot pointer (session apply path).
@(private)
h2_host_sid_for_slot :: proc(conn: ^Connection, slot: ^Stream_Slot) -> (sid: u32, ok: bool) {
	if conn == nil || conn.h2_slots == nil || slot == nil {
		return 0, false
	}
	for i in 0 ..< H2_SLOT_CAP {
		if conn.h2_slot_used[i] && &conn.h2_slots[i] == slot {
			sid = conn.h2_slot_sids[i]
			return sid, sid != 0
		}
	}
	return 0, false
}

// Inverse of sid_for_slot — index for a live slot pointer.
@(private)
h2_host_slot_find_by_ptr :: proc(conn: ^Connection, slot: ^Stream_Slot) -> (idx: u8, ok: bool) {
	if conn == nil || conn.h2_slots == nil || slot == nil {
		return 0, false
	}
	for i in 0 ..< H2_SLOT_CAP {
		if conn.h2_slot_used[i] && &conn.h2_slots[i] == slot {
			return u8(i), true
		}
	}
	return 0, false
}

// After conn_feed: map peer RST / failed streams → .Client_Gone once per session (M6).
// Only open SSE sessions on used slots are considered; ending/closed skip.
@(private)
h2_host_poll_session_resets :: proc(conn: ^Connection) {
	if conn == nil || !conn.h2_active || conn.h2_slots == nil {
		return
	}
	for i in 0 ..< H2_SLOT_CAP {
		if !conn.h2_slot_used[i] {
			continue
		}
		slot := &conn.h2_slots[i]
		st := slot.session
		if st == nil || st.closed || st.ending {
			continue
		}
		sid := conn.h2_slot_sids[i]
		if sid == 0 {
			continue
		}
		s, known := conn.h2.streams[sid]
		// Peer RST sets failed+closed then reaps. After Start (HEADERS sent), a missing
		// map entry means the stream was closed out from under us. Before Start, skip.
		gone := false
		if !known {
			gone = st.started
		} else if s.failed {
			gone = true
		}
		if !gone {
			continue
		}
		sync.atomic_add(&session_metrics_client_gone, 1)
		_session_drive_st(st, Session_Event{kind = .Client_Gone})
		// Force abort if app did not end/abort (same as H1 hangup).
		if slot.session == st && !st.closed && !st.ending {
			_session_abort_st(st)
		}
	}
}

// ---------------------------------------------------------------------------
// Request construction (public helper for unit tests)
// ---------------------------------------------------------------------------

// h2_request_from_headers builds a Request from H2 pseudo + regular headers.
// Version is HTTP/1.1 for handler compat (many handlers assume 1.x).
// Regular headers omit colon-prefixed pseudos; :authority is stored as host.
// Body is attached as _pre_body so body() / respond discard work without scanner.
h2_request_from_headers :: proc(
	req:      ^Request,
	headers:  []http2.Header,
	body:     []u8 = nil,
	allocator := context.temp_allocator,
) -> bool {
	if req == nil {
		return false
	}
	request_init(req, allocator)

	method_s: string
	path_s:   string
	auth_s:   string
	scheme_s: string

	for h in headers {
		switch h.name {
		case ":method":
			method_s = h.value
		case ":path":
			path_s = h.value
		case ":authority":
			auth_s = h.value
		case ":scheme":
			scheme_s = h.value
		case:
			// Skip other pseudos; store regular headers lowercased (H2 is lower).
			if len(h.name) > 0 && h.name[0] == ':' {
				continue
			}
			// Borrow stream-owned HPACK strings (valid until conn_app_release).
			// No second clone — scrap arena must not free these (they live on c.allocator).
			headers_set_unsafe(&req.headers, h.name, h.value)
		}
	}

	if method_s == "" || path_s == "" {
		return false
	}
	method, mok := method_parse(method_s)
	if !mok {
		return false
	}

	// Host from :authority or host header. Key is static; value borrows :authority.
	if auth_s != "" && !headers_has_unsafe(req.headers, "host") {
		headers_set_unsafe(&req.headers, "host", auth_s)
	}
	_ = scheme_s

	// H1 validation wants Host; require it.
	if !headers_has_unsafe(req.headers, "host") {
		return false
	}

	// Content-Length from body when missing (POST oneshot) — synthetic strings
	// must live on the request allocator (not stream storage).
	if len(body) > 0 && !headers_has_unsafe(req.headers, "content-length") {
		buf: [20]byte
		cl := strconv.write_int(buf[:], i64(len(body)), 10)
		headers_set_unsafe(
			&req.headers,
			strings.clone("content-length", allocator),
			strings.clone(cl, allocator),
		)
	}

	if !headers_validate_for_server(&req.headers) {
		return false
	}
	req.headers.readonly = true

	// Borrow :path for request line / url views (same lifetime as headers).
	target := path_s
	req.line = Requestline {
		method  = method,
		target  = target,
		version = Version{1, 1}, // eng: handler-compat (document as 1.1 view of H2)
	}
	req.url = url_parse(target)
	req.is_head = method == .Head

	if len(body) > 0 {
		// Borrow stream body — freed only after conn_app_release (post-handler).
		req._pre_body = body
	} else {
		req._pre_body = []u8{}
	}
	// Mark body available for respond path (got_body) — body() still works via _pre_body.
	// Leave _body_ok nil so body() can be called once; respond H2 path skips scanner drain.

	return true
}
