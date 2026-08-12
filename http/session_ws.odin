// WebSocket session adapter (D3) on the same progressive Stream engine as SSE.
// Minimal framing: text/binary data frames, close frame. No extensions / permessage-deflate.
package http

import "core:bytes"
import "core:crypto/hash"
import "core:encoding/base64"
import "core:strings"
import "core:sync"

// RFC 6455 §1.3 magic GUID.
WS_GUID :: "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

effect_ws_text :: proc(data: string) -> Effect {
	return Effect{kind = .Ws_Text, data = data}
}

effect_ws_binary :: proc(data: string) -> Effect {
	return Effect{kind = .Ws_Binary, data = data}
}

// code 0 → 1000 normal closure.
effect_ws_close :: proc(code: u16 = 1000, reason: string = "") -> Effect {
	return Effect{kind = .Ws_Close, data = reason, ws_code = code}
}

// Validate Upgrade request and set 101 Switching Protocols headers + accept key.
ws_accept_upgrade :: proc(req: ^Request, res: ^Response) -> bool {
	if req == nil || res == nil {
		return false
	}
	up, ok := headers_get(req.headers, "upgrade")
	if !ok || !strings.equal_fold(up, "websocket") {
		return false
	}
	conn_h, ok2 := headers_get(req.headers, "connection")
	if !ok2 {
		return false
	}
	// Connection may list multiple tokens; require "upgrade".
	lower := strings.to_lower(conn_h, context.temp_allocator)
	if !strings.contains(lower, "upgrade") {
		return false
	}
	key, ok3 := headers_get(req.headers, "sec-websocket-key")
	if !ok3 || len(key) == 0 {
		return false
	}
	raw := strings.concatenate({key, WS_GUID}, context.temp_allocator)
	digest: [20]byte
	hash.hash_bytes_to_buffer(.Insecure_SHA1, transmute([]byte)raw, digest[:])
	accept := base64.encode(digest[:], allocator = context.temp_allocator)

	res.status = .Switching_Protocols
	headers_set(&res.headers, "upgrade", "websocket")
	headers_set(&res.headers, "connection", "Upgrade")
	headers_set(&res.headers, "sec-websocket-accept", accept)
	return true
}

/*
Start a WebSocket session after a successful ws_accept_upgrade.

Writes the 101 heading (no chunked TE), attaches Session_State with proto=.Ws,
drives Start. App uses effect_ws_text / effect_ws_binary / effect_ws_close / effect_end.

Soft admission: same session cap as sse_start. Over cap → 503 (not 101), returns
Session{} (id=0). Callers should check session_status or id != 0.
*/
ws_start :: proc(
	res:      ^Response,
	on_event: Session_On_Event,
	hooks:    Session_Hooks = {},
	loc := #caller_location,
) -> Session {
	assert(res != nil && res._conn != nil, "ws_start: nil response", loc)
	assert(on_event != nil, "ws_start: nil on_event", loc)
	assert(!res.sent, "ws_start: already sent", loc)
	assert(!res._session_attached, "ws_start: session already attached", loc)
	assert(res.status == .Switching_Protocols, "ws_start: call ws_accept_upgrade first", loc)
	conn := res._conn
	assert(!conn.h2_active, "ws_start: WebSocket over HTTP/2 is not supported", loc)
	ex := response_slot(res)
	assert(ex != nil, "ws_start: no exchange slot", loc)
	assert(ex.session == nil, "ws_start: session exists", loc)
	assert(conn.server != nil, "ws_start: no server", loc)

	// Soft admission (same global live gauge as SSE). Over cap → 503, not assert.
	if !_session_admission_ok(conn) {
		return _session_soft_reject(res, loc)
	}

	// 101 heading without chunked TE (raw WS frames follow).
	if headers_has_unsafe(res.headers, "transfer-encoding") {
		headers_delete_unsafe(&res.headers, "transfer-encoding")
	}
	if headers_has_unsafe(res.headers, "content-length") {
		headers_delete_unsafe(&res.headers, "content-length")
	}
	_response_write_heading(res, -1)
	res._streaming = true
	res._session_attached = true

	st := new(Session_State, conn.server.conn_allocator)
	st^ = {}
	st.allocator = conn.server.conn_allocator
	st.on_event = on_event
	st.hooks = hooks
	st.proto = .Ws
	// Monotonic per-slot gen (ABA-safe across free-list reuse); Session.id uses this.
	st.gen = stream_slot_bump_gen(ex)
	st.public = Session{_conn = conn, _slot = ex, id = st.gen}
	idle_ms := conn.server.opts.stream_idle_timeout_ms
	if idle_ms <= 0 {
		idle_ms = SESSION_IDLE_TIMEOUT_MS_DEFAULT
	}
	st.idle_ns = i64(idle_ms) * 1_000_000
	ex.session = st
	sync.atomic_add(&session_metrics_started, 1)
	sync.atomic_add(&session_metrics_live, 1)

	_stream_shrink_resp_for_session(conn)
	_session_drive_st(st, Session_Event{kind = .Start})
	if td != nil && td.state != .Uninitialized && conn.temp_slot >= 0 {
		conn_temp_detach(conn)
	}
	if st.timer_op == 0 && st.idle_ns > 0 && !st.closed && !st.ending &&
	   td != nil && td.state != .Uninitialized && td.ring.ops != nil {
		_session_arm_timer_st(st, st.idle_ns, .Idle)
	}
	// Ciphered Open: arm CT recv so peer FIN / close_notify → Client_Gone.
	if !st.closed && !st.ending {
		_session_arm_hangup_watch(conn)
	}
	return st.public
}

// Format a WS data frame (server→client: unmasked) into out.
@(private)
_ws_write_frame :: proc(out: ^[dynamic]u8, opcode: u8, payload: []u8) {
	append(out, 0x80 | (opcode & 0x0f))
	n := len(payload)
	if n < 126 {
		append(out, u8(n))
	} else if n < 65536 {
		append(out, 126)
		append(out, u8(n >> 8), u8(n))
	} else {
		append(out, 127)
		nn := u64(n)
		for shift := uint(56); ; shift -= 8 {
			append(out, u8(nn >> shift))
			if shift == 0 {
				break
			}
		}
	}
	if n > 0 {
		append(out, ..payload)
	}
}

@(private)
_ws_apply_effect :: proc(conn: ^Connection, e: Effect) {
	r := &conn.slot.res
	frame: [dynamic]u8
	frame.allocator = context.temp_allocator
	switch e.kind {
	case .Ws_Text:
		_ws_write_frame(&frame, 0x1, transmute([]u8)e.data)
	case .Ws_Binary:
		_ws_write_frame(&frame, 0x2, transmute([]u8)e.data)
	case .Ws_Close:
		code := e.ws_code if e.ws_code != 0 else 1000
		pl: [dynamic]u8
		pl.allocator = context.temp_allocator
		append(&pl, u8(code >> 8), u8(code))
		if len(e.data) > 0 {
			append(&pl, ..transmute([]u8)e.data)
		}
		_ws_write_frame(&frame, 0x8, pl[:])
	case .None, .Sse_Data, .Sse_Event, .Sse_Comment, .Arm, .End, .Abort:
		return
	}
	if len(frame) > 0 {
		// Raw bytes (not HTTP-chunked) into response wire buffer.
		_, _ = bytes.buffer_write(&r._buf, frame[:])
		conn.resp_buf = r._buf.buf
	}
}
