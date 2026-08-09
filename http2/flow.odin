// HTTP/2 outbound flow control (RFC 9113 §6.9) — the streaming response path.
//
// DATA a peer will accept is bounded by two send windows: a per-stream window
// and a single connection-level window, each advertised initially and grown by
// WINDOW_UPDATE frames. A handler streaming a large body therefore cannot just
// dump bytes; it produces into `stream.pending`, and `_flush_stream` emits only
// as many DATA frames as min(stream window, conn window, max frame) allows. When
// a WINDOW_UPDATE later arrives (see conn_feed → FRAME_WINDOW_UPDATE), the
// buffer drains further. This is the kernel of async backpressure: the write
// side (the handler) and the read side (WINDOW_UPDATE) meet here.
//
// Hosts use `conn_send_body` as a streaming sink; its return value is the
// backpressure signal (how many bytes are still buffered) used to pause the
// producer until WINDOW_UPDATE arrives.
//
// Bulk perf: unread body is tracked with `pending_off` (cursor). Advancing the
// cursor is O(1); remove_range(front) was O(n) memmove per DATA frame and
// dominated H2 s1m CPU on bastion (~72% memmove).
package http2

import "core:slice"

import "../hpack"

DEFAULT_WINDOW :: i64(65535) // RFC 9113 §6.9.2 initial connection/stream window

// Compact dead prefix only when large, so long-lived streams (SSE) don't retain
// unbounded sealed bytes. Bulk oneshots clear fully when drained (no compact).
PENDING_COMPACT_OFF :: 256 * 1024

// Send response/request HEADERS on `sid`. Pass `end_stream` for a bodyless
// message; otherwise follow with conn_send_body.
//
// When end_stream is set on HEADERS, mark the stream half-closed local and
// close if the peer already finished (open_streams accounting). Missing this
// leaked open streams → REFUSED_STREAM after MAX_CONCURRENT_STREAMS empties.
conn_send_headers :: proc(c: ^Http2_Connection, dst: ^[dynamic]u8, sid: u32, headers: []Header, end_stream := false) {
	s := _get_or_make_stream(c, sid) // ensure the stream (and its window) exists
	block: [dynamic]u8
	block.allocator = context.temp_allocator
	// Use connection encoder dynamic table so repeated response headers compress.
	hpack.encode(&block, headers, &c.enc)
	flags := FLAG_END_HEADERS
	if end_stream do flags |= FLAG_END_STREAM
	frame_write(dst, FRAME_HEADERS, flags, sid, block[:])
	if end_stream {
		s.end_sent = true
		_stream_maybe_close(c, s)
	}
	// Handler finished this stream (empty body); drop map entry when safe.
	if end_stream do conn_reap_streams(c)
}

// Count streams that still have DATA (or pending END_STREAM) to emit.
@(private)
_n_pending_streams :: proc(c: ^Http2_Connection) -> int {
	if c == nil do return 0
	n := 0
	for _, s in c.streams {
		if s == nil || s.failed || s.closed do continue
		if stream_pending_len(s) > 0 || (s.end_pending && !s.end_sent) {
			n += 1
		}
	}
	return n
}

// Stream a chunk of body on `sid` under flow control. Bytes that don't fit the
// current windows are buffered; `end_stream` marks the logical end (the actual
// END_STREAM frame is emitted only once the buffer fully drains). Returns the
// number of bytes still buffered — i.e. the backpressure: >0 means the windows
// are full and the caller should stop producing until a WINDOW_UPDATE arrives.
//
// When ≥2 streams already have pending, flush uses fair RR quanta so the first
// writer cannot monopolize residual connection window on the multi-pending path
// (PR9 PERF-M1). A sole pending stream still drains fully via `_flush_stream`.
conn_send_body :: proc(c: ^Http2_Connection, dst: ^[dynamic]u8, sid: u32, data: []u8, end_stream := false) -> (buffered: int) {
	s := _get_or_make_stream(c, sid)
	if len(data) > 0 {
		append(&s.pending, ..data)
	}
	if end_stream do s.end_pending = true
	_flush_stream(c, dst, s)
	buffered = stream_pending_len(s)
	// After END_STREAM drains, free the stream so bulk/mux load doesn't retain
	// every historical stream in the connection map (F16).
	if end_stream || s.closed do conn_reap_streams(c)
	return buffered
}

// Advance pending_off by n; clear or compact dead prefix when useful.
@(private)
_stream_pending_consume :: proc(s: ^Http2_Stream, n: int) {
	if s == nil || n <= 0 {
		return
	}
	s.pending_off += n
	rem := stream_pending_len(s)
	if rem == 0 {
		// Fully drained — free the buffer (bulk oneshot path).
		clear(&s.pending)
		s.pending_off = 0
		return
	}
	// Bound dead prefix for long-lived partial drains (SSE / multi-chunk).
	if s.pending_off >= PENDING_COMPACT_OFF {
		copy(s.pending[:], s.pending[s.pending_off:])
		resize(&s.pending, rem)
		s.pending_off = 0
	}
}

// Emit at most one DATA frame for `s` under current windows. `quantum` caps the
// frame payload (0 = use peer max frame only). Returns true if a frame was
// written (including zero-length END_STREAM). Used by single-stream drain and
// by fair multi-stream RR (one quantum per turn).
@(private)
_flush_stream_one_frame :: proc(c: ^Http2_Connection, dst: ^[dynamic]u8, s: ^Http2_Stream, quantum: i64 = 0) -> bool {
	if s == nil || s.failed || s.closed {
		return false
	}
	// Peer SETTINGS_MAX_FRAME_SIZE caps outbound DATA; fall back to default.
	frame_cap := i64(c.peer_settings.max_frame_size)
	if frame_cap <= 0 do frame_cap = i64(DEFAULT_MAX_FRAME_SIZE)
	if quantum > 0 {
		frame_cap = min(frame_cap, quantum)
	}

	rem := stream_pending_len(s)
	if rem > 0 {
		allowed := min(s.send_window, c.send_window, frame_cap)
		if allowed <= 0 do return false // windows exhausted — wait for WINDOW_UPDATE

		n := min(int(allowed), rem)
		last := n == rem
		end := s.end_pending && last
		flags: u8 = end ? FLAG_END_STREAM : 0
		// Slice unsent prefix only — no front delete.
		payload := s.pending[s.pending_off:s.pending_off + n]
		frame_write(dst, FRAME_DATA, flags, s.id, payload)
		if end {
			s.end_sent = true
			// Our response is fully flushed; if the request was already
			// complete (s.end_stream), the stream is now closed both ways.
			_stream_maybe_close(c, s)
		}

		s.send_window -= i64(n)
		c.send_window -= i64(n)
		_stream_pending_consume(s, n)
		return true
	}

	// Zero-length-body end (or end requested after the buffer already drained).
	if s.end_pending && stream_pending_len(s) == 0 && !s.end_sent {
		frame_write(dst, FRAME_DATA, FLAG_END_STREAM, s.id, nil)
		s.end_sent = true
		_stream_maybe_close(c, s)
		return true
	}
	return false
}

// Emit DATA frames for `s` up to what the stream + connection windows permit,
// decrementing both. Carries END_STREAM on the final frame once the buffer is
// empty and the end was requested.
//
// When multiple streams have pending, always use the fair RR quantum path so a
// single stream cannot take the entire residual connection window on first
// flush after bodies are buffered (PR9 PERF-M1). Sole-pending streams drain
// fully (one-frame loop with no quantum cap).
@(private)
_flush_stream :: proc(c: ^Http2_Connection, dst: ^[dynamic]u8, s: ^Http2_Stream) {
	if _n_pending_streams(c) > 1 {
		_flush_pending_rr(c, dst)
		return
	}
	for _flush_stream_one_frame(c, dst, s, 0) {}
}

// Fair round-robin drain of all streams with pending DATA under a shared
// connection window (PR9 M3 / PERF-M1). Used whenever ≥2 streams have pending
// (conn_send_body / stream WINDOW_UPDATE via `_flush_stream`, plus conn-level
// WINDOW_UPDATE / SETTINGS). Base: one DATA quantum per stream turn so a fat
// body cannot monopolize residual conn credit. Quantum = max(1, conn_window /
// n_pending). Cursor `c.flush_rr` is the next preferred stream id (0 = lowest
// id first).
//
// PR10 optional weights: interactive (SSE) streams emit up to weight_interactive
// frames per turn; bulk oneshots use weight_bulk (defaults 2 / 1 when 0).
@(private)
_flush_pending_rr :: proc(c: ^Http2_Connection, dst: ^[dynamic]u8) {
	if c == nil || len(c.streams) == 0 {
		return
	}

	w_inter := int(c.weight_interactive)
	if w_inter <= 0 do w_inter = 2
	w_bulk := int(c.weight_bulk)
	if w_bulk <= 0 do w_bulk = 1

	// Outer loop: keep RR turns until a full pass emits nothing (windows dry
	// or all pending drained).
	for {
		sids: [dynamic]u32
		sids.allocator = context.temp_allocator
		for id, s in c.streams {
			if s == nil || s.failed || s.closed do continue
			if stream_pending_len(s) > 0 || (s.end_pending && !s.end_sent) {
				append(&sids, id)
			}
		}
		if len(sids) == 0 {
			return
		}
		// Stable order so RR is deterministic (map iteration is not).
		slice.sort(sids[:])

		start := 0
		for i in 0 ..< len(sids) {
			if sids[i] >= c.flush_rr {
				start = i
				break
			}
		}

		// Fair share of current conn credit across pending streams this pass.
		quantum: i64 = 0
		if len(sids) > 1 && c.send_window > 0 {
			quantum = c.send_window / i64(len(sids))
			if quantum <= 0 do quantum = 1
		}

		made := false
		for k in 0 ..< len(sids) {
			if c.send_window <= 0 {
				return
			}
			i := (start + k) % len(sids)
			sid := sids[i]
			s, ok := c.streams[sid]
			if !ok || s == nil do continue
			// Weighted quanta: interactive gets more DATA frames per turn.
			turns := s.interactive ? w_inter : w_bulk
			if turns < 1 do turns = 1
			stream_made := false
			for _ in 0 ..< turns {
				if c.send_window <= 0 {
					break
				}
				if _flush_stream_one_frame(c, dst, s, quantum) {
					stream_made = true
					made = true
				} else {
					break
				}
			}
			if stream_made {
				// Next multi-stream flush prefers the stream after this one.
				c.flush_rr = sid + 1
			}
		}
		if !made {
			return
		}
	}
}
