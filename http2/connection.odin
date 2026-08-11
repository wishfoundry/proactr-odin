// HTTP/2 multiplexes logical streams over ONE byte stream: unlike HTTP/3, the
// transport hands us a single ordered pipe and WE demux frames into per-stream
// state and maintain the (single, order-dependent) HPACK decoder table. This
// type is transport-agnostic: feed it received bytes + an out buffer for
// auto-replies (SETTINGS/PING ACKs); the caller owns the socket / event loop.
// Scope: HEADERS + CONTINUATION reassembly, stream state / SETTINGS validation,
// GOAWAY/RST (strict unit pins — not a full h2spec suite). Padding and PRIORITY
// are stripped; PUSH is SETTINGS-disabled. Outbound DATA respects peer windows
// (flow.odin). Inbound DATA is auto-granted 1:1 via WINDOW_UPDATE (buffering
// engine; not peer-throttle receive windows). Closed streams are reaped from
// the map (conn_reap_streams) so multiplexed load does not grow unbounded. No
// host/TLS wiring — pure sans-I/O engine.
package http2


import "core:mem"
import "core:slice"
import "core:strconv"

import "../hpack"

H2_Error :: enum {
	None,
	Protocol,
	Hpack,
	Frame,
}

// Wire error codes (RFC 9113 §7) — what goes in GOAWAY/RST_STREAM. On any
// conn_feed failure, `fail_code` holds the one to send.
H2_NO_ERROR            :: u32(0x0)
H2_PROTOCOL_ERROR      :: u32(0x1)
H2_INTERNAL_ERROR      :: u32(0x2)
H2_FLOW_CONTROL_ERROR  :: u32(0x3)
H2_STREAM_CLOSED       :: u32(0x5)
H2_FRAME_SIZE_ERROR    :: u32(0x6)
H2_REFUSED_STREAM      :: u32(0x7)
H2_CANCEL              :: u32(0x8)
H2_COMPRESSION_ERROR   :: u32(0x9)

// Mark the connection failed with a wire error code; the transport runtime
// sends GOAWAY(c.fail_code) and closes. We treat stream-level violations as
// connection errors too — RFC 9113 §5.4.2 permits it, and one strict path
// beats two lenient ones.
@(private)
_fail :: proc(c: ^Http2_Connection, code: u32, kind := H2_Error.Protocol) -> H2_Error {
	if c.fail_code == 0 do c.fail_code = code
	return kind
}

Http2_Stream :: struct {
	id:           u32,
	headers:      [dynamic]Header,
	body:         [dynamic]u8,
	headers_done: bool,
	end_stream:   bool, // peer set END_STREAM (message complete from their side)
	delivered:    bool, // server: handed to the application
	// Host finished using slices from take (handler returned). Header/body
	// storage must survive until this is set — respond may close+reap mid-handler.
	app_released: bool,

	// Outbound flow control (RFC 9113 §6.9). `send_window` is how many DATA
	// bytes the PEER will currently accept on this stream; `pending` holds body
	// the handler produced that the window won't yet allow out.
	// `pending_off` is a read cursor into `pending` — DATA frames advance the
	// cursor instead of remove_range(front), which was O(n) memmove per frame
	// and dominated bulk H2 CPU (bastion profile: ~72% memmove on s1m).
	send_window:  i64,
	pending:      [dynamic]u8,
	pending_off:  int,
	end_pending:  bool, // END_STREAM owed once `pending` drains
	end_sent:     bool, // END_STREAM already emitted

	// Peer reset the stream (§6.4): the exchange failed, body/headers are
	// not coming. `error_code` is the RST_STREAM/GOAWAY code for diagnostics.
	failed:       bool,
	error_code:   u32,
	// Terminal: the stream has been counted out of open_streams (closed both
	// ways, reset, or GOAWAY-failed). Guards _stream_close against double-count.
	closed:       bool,

	// Declared content-length (-1 = none): the buffered body must match it
	// by END_STREAM or the message is malformed (§8.1.1).
	expected_len: i64,

	// Fairness: SSE / session streams get more RR quanta than bulk oneshots.
	// Set by host (e.g. sse_start); default false = bulk weight.
	interactive:  bool,

	// Inbound WINDOW_UPDATE credit coalesced across DATA frames in one
	// conn_feed (item 5). Flushed at end of feed — fewer 13-byte frames than
	// 1:1 per DATA when a peer ships multi-frame bodies in one read.
	wu_pending:   u32,
}

Http2_Connection :: struct {
	is_server:      bool,
	allocator:      mem.Allocator,
	dec:            hpack.HPackDynamicTable, // HPACK decoder table (mirrors peer insertions)
	enc:            hpack.HPackEncoder,      // HPACK encoder dynamic table (peer decoder view)
	local_settings: Settings,
	peer_settings:  Settings,
	rx:             [dynamic]u8,
	streams:        map[u32]^Http2_Stream,
	next_stream_id: u32,
	// Count of currently-open inbound streams (server: peer-initiated). Used
	// to enforce MAX_CONCURRENT_STREAMS (§5.1.2) — incremented on stream
	// creation, decremented when a stream reaches a terminal state (closed
	// both ways, reset, or GOAWAY-failed).
	open_streams:   int,
	preface_seen:   bool, // server: client connection preface consumed
	send_window:    i64,  // connection-level outbound window (shared by all streams)

	// Header block in flight across HEADERS + CONTINUATION frames (§6.10).
	// While `cont_sid` is set, no other frame may arrive on the connection —
	// header blocks are contiguous because HPACK state is order-dependent.
	cont_sid:        u32, // 0 = no block in flight
	cont_frag:       [dynamic]u8,
	cont_end_stream: bool,

	// Graceful shutdown (§6.8): the peer sent GOAWAY. Streams above
	// `goaway_last_sid` were not and will not be processed.
	goaway_received: bool,
	goaway_last_sid: u32,
	goaway_code:     u32,

	// Local GOAWAY we sent (graceful drain or connection error). Once set,
	// new peer streams with id > goaway_sent_last are REFUSED_STREAM; existing
	// streams at or below last continue (RFC 9113 §6.8).
	goaway_sent:      bool,
	goaway_sent_last: u32,
	goaway_sent_code: u32,

	// Highest peer-initiated stream id seen — the `last_sid` for a GOAWAY we
	// send when shutting down gracefully.
	last_peer_sid:   u32,

	// Inbound limits. `conn_init(is_server=true)` sets safe defaults
	// (1 MiB body / 64 KiB headers). Explicit 0 after init means unbounded.
	// Exceeding either is a connection error: we buffer whole messages.
	max_body_bytes:   int, // per-stream buffered body cap (0 = unbounded)
	max_header_bytes: int, // header block cap incl. CONTINUATION (0 = unbounded)

	// RFC 9113 §7 error code explaining a conn_feed failure (0 = none) —
	// send it in GOAWAY before closing.
	fail_code: u32,

	// Fair flush RR cursor: next preferred stream id when draining
	// multiple pending bodies under a shared connection window. Advanced past
	// the stream that last received a DATA quantum so one fat stream cannot
	// starve others on conn-level WINDOW_UPDATE / SETTINGS window growth.
	// (Host Connection has no separate cursor — engine owns multi-stream flush.)
	flush_rr: u32,

	// Optional SSE-vs-bulk fairness weights. 0 → engine default (2 / 1).
	// Interactive streams get weight_interactive DATA frames per RR turn;
	// bulk gets weight_bulk. Host copies from Server_Opts on open.
	weight_interactive: u8,
	weight_bulk:        u8,

	// Connection-level inbound WINDOW_UPDATE credit pending flush (item 5).
	// Coalesced across all DATA in one conn_feed; see _flush_window_credits.
	wu_conn_pending: u32,
}

conn_init :: proc(c: ^Http2_Connection, is_server: bool, allocator := context.allocator) {
	c.is_server = is_server
	c.allocator = allocator
	c.rx.allocator = allocator
	c.streams.allocator = allocator
	c.cont_frag.allocator = allocator
	c.local_settings = default_settings()
	c.peer_settings = default_settings()
	// Decoder table max/limit match SETTINGS_HEADER_TABLE_SIZE we advertise.
	hpack.init(&c.dec, int(c.local_settings.header_table_size), allocator)
	// Encoder table max tracks peer SETTINGS_HEADER_TABLE_SIZE (default 4096).
	hpack.encoder_init(&c.enc, int(c.peer_settings.header_table_size), allocator)
	c.next_stream_id = is_server ? 2 : 1
	c.preface_seen = !is_server
	c.send_window = DEFAULT_WINDOW
	// Server defaults bound memory; set either field to 0 after init for unlimited.
	if is_server {
		c.max_body_bytes = 1 << 20   // 1 MiB per-stream body
		c.max_header_bytes = 64 << 10 // 64 KiB header block
	}
}

conn_destroy :: proc(c: ^Http2_Connection) {
	for _, s in c.streams {
		hpack.headers_destroy(s.headers[:], c.allocator)
		delete(s.headers)
		delete(s.body)
		delete(s.pending)
		free(s, c.allocator)
	}
	delete(c.streams)
	hpack.encoder_destroy(&c.enc)
	hpack.destroy(&c.dec)
	delete(c.rx)
	delete(c.cont_frag)
}

// Write the connection preface: the client magic (client only) + our SETTINGS.
conn_send_preface :: proc(c: ^Http2_Connection, dst: ^[dynamic]u8) {
	if !c.is_server {
		append(dst, ..transmute([]u8)string(CLIENT_PREFACE))
	}
	settings_write(dst, c.local_settings)
}

// Send GOAWAY once (idempotent). last_sid = last_peer_sid at send time.
// After this, new peer streams with id > last are refused (REFUSED_STREAM);
// streams at or below last continue until complete (graceful drain).
// Host owns flush/close; engine only records sent state + refuses new takes.
conn_send_goaway :: proc(c: ^Http2_Connection, dst: ^[dynamic]u8, code: u32 = H2_NO_ERROR) {
	if c == nil || dst == nil {
		return
	}
	if c.goaway_sent {
		return
	}
	last := c.last_peer_sid
	goaway_write(dst, last, code)
	c.goaway_sent = true
	c.goaway_sent_last = last
	c.goaway_sent_code = code
}

// Mark stream as interactive (SSE / session) for weighted RR flush. No-op if unknown.
conn_stream_set_interactive :: proc(c: ^Http2_Connection, sid: u32, interactive := true) {
	if c == nil || sid == 0 {
		return
	}
	if s, ok := c.streams[sid]; ok && s != nil {
		s.interactive = interactive
	}
}

// Client: open a new stream and send HEADERS [+ DATA]. Returns the stream id.
// Always flow-aware: DATA goes through conn_send_body / peer windows.
conn_send_request :: proc(
	c: ^Http2_Connection, dst: ^[dynamic]u8, headers: []Header, body: []u8 = nil,
) -> u32 {
	sid := c.next_stream_id
	c.next_stream_id += 2
	end := len(body) == 0
	conn_send_headers(c, dst, sid, headers, end)
	if len(body) > 0 {
		_ = conn_send_body(c, dst, sid, body, true)
	}
	return sid
}

// Server: send a response on `sid`. Always flow-aware (same path as
// conn_send_headers + conn_send_body) — large bodies respect peer windows.
conn_send_response :: proc(
	c: ^Http2_Connection, dst: ^[dynamic]u8, sid: u32, headers: []Header, body: []u8 = nil,
) {
	end := len(body) == 0
	conn_send_headers(c, dst, sid, headers, end)
	if len(body) > 0 {
		_ = conn_send_body(c, dst, sid, body, true)
	}
}

// Feed received bytes; parse all complete frames, update state, and append any
// automatic replies (SETTINGS/PING ACKs) to `out`.
// Inbound DATA WINDOW_UPDATE grants are coalesced for the duration of this
// call and flushed once before return (item 5) — same total credit, fewer frames
// when a peer ships multi-frame bodies in one read.
conn_feed :: proc(c: ^Http2_Connection, data: []u8, out: ^[dynamic]u8) -> H2_Error {
	append(&c.rx, ..data)

	if c.is_server && !c.preface_seen {
		pre := transmute([]u8)string(CLIENT_PREFACE)
		if len(c.rx) < len(pre) do return .None
		if !slice.equal(c.rx[:len(pre)], pre) do return .Protocol
		remove_range(&c.rx, 0, len(pre))
		c.preface_seen = true
	}

	pos := 0
	// Decode against our advertised SETTINGS_MAX_FRAME_SIZE (local).
	max_frame := c.local_settings.max_frame_size
	if max_frame == 0 do max_frame = DEFAULT_MAX_FRAME_SIZE
	for {
		h, payload, consumed, ferr := frame_decode(c.rx[pos:], max_frame)
		if ferr == .Incomplete do break
		if ferr == .Too_Large do return _fail(c, H2_FRAME_SIZE_ERROR, .Frame)
		if ferr != .None do return _fail(c, H2_PROTOCOL_ERROR, .Frame)
		if err := _handle_frame(c, h, payload, out); err != .None {
			// Drop unflushed credits on hard fail (GOAWAY path); peer is done.
			c.wu_conn_pending = 0
			return err
		}
		pos += consumed
	}
	if pos > 0 do remove_range(&c.rx, 0, pos)
	// Coalesced inbound flow-control grants for this feed.
	_flush_window_credits(c, out)
	// WINDOW_UPDATE / RST / completed responses may have closed streams.
	conn_reap_streams(c)
	return .None
}

// Emit pending connection + stream WINDOW_UPDATE frames accumulated during
// conn_feed. Cap each increment at 2^31-1 (RFC 9113 §6.9.1).
@(private)
_flush_window_credits :: proc(c: ^Http2_Connection, out: ^[dynamic]u8) {
	if c == nil || out == nil {
		return
	}
	// Rough upper bound: 1 conn WU + 1 per open stream (13 bytes each).
	n_stream := 0
	for _, s in c.streams {
		if s != nil && s.wu_pending > 0 {
			n_stream += 1
		}
	}
	if c.wu_conn_pending > 0 || n_stream > 0 {
		// Reserve once so multi-stream bulk feed doesn't grow per WU.
		want := len(out^) + (1 + n_stream) * (FRAME_HEADER_LEN + 4)
		if cap(out^) < want {
			reserve(out, want)
		}
	}
	if c.wu_conn_pending > 0 {
		inc := c.wu_conn_pending
		c.wu_conn_pending = 0
		// Split if somehow over the max legal increment (pathological).
		for inc > 0 {
			chunk := min(inc, u32(0x7fff_ffff))
			window_update_write(out, 0, chunk)
			inc -= chunk
		}
	}
	for id, s in c.streams {
		if s == nil || s.wu_pending == 0 {
			continue
		}
		inc := s.wu_pending
		s.wu_pending = 0
		for inc > 0 {
			chunk := min(inc, u32(0x7fff_ffff))
			window_update_write(out, id, chunk)
			inc -= chunk
		}
	}
}

@(private)
_handle_frame :: proc(c: ^Http2_Connection, h: Frame_Header, payload: []u8, out: ^[dynamic]u8) -> H2_Error {
	// A header block in flight (HEADERS sans END_HEADERS) admits ONLY
	// CONTINUATION frames on the same stream until it completes (§6.10).
	if c.cont_sid != 0 && (h.type != FRAME_CONTINUATION || h.stream_id != c.cont_sid) {
		return .Protocol
	}

	switch h.type {
	case FRAME_SETTINGS:
		if h.stream_id != 0 do return _fail(c, H2_PROTOCOL_ERROR)
		if h.flags & FLAG_ACK != 0 {
			if len(payload) != 0 do return _fail(c, H2_FRAME_SIZE_ERROR, .Frame)
			return .None
		}
		if len(payload) % 6 != 0 do return _fail(c, H2_FRAME_SIZE_ERROR, .Frame)
		// Validate values before applying (§6.5.2).
		for i := 0; i + 6 <= len(payload); i += 6 {
			id := u16(payload[i]) << 8 | u16(payload[i + 1])
			val := get_u32(payload[i + 2:i + 6])
			switch id {
			case SETTINGS_ENABLE_PUSH:
				if val > 1 do return _fail(c, H2_PROTOCOL_ERROR)
			case SETTINGS_INITIAL_WINDOW_SIZE:
				if val > 0x7fff_ffff do return _fail(c, H2_FLOW_CONTROL_ERROR)
			case SETTINGS_MAX_FRAME_SIZE:
				if val < 16384 || val > 16777215 do return _fail(c, H2_PROTOCOL_ERROR)
			}
		}
		// A changed INITIAL_WINDOW_SIZE retroactively adjusts every stream's
		// send window by the delta (§6.9.2) — and a positive delta may have
		// just made buffered body sendable, so flush.
		old_window := i64(c.peer_settings.initial_window_size)
		old_table := c.peer_settings.header_table_size
		settings_decode(payload, &c.peer_settings)
		// Peer HEADER_TABLE_SIZE caps what we may put in our encoder dynamic table.
		// Cap absurd values so a peer cannot force multi-GB encoder tables.
		if c.peer_settings.header_table_size != old_table {
			table_cap := c.peer_settings.header_table_size
			if table_cap > 16 << 20 {
				table_cap = 16 << 20 // 16 MiB hard ceiling
			}
			hpack.encoder_set_max(&c.enc, int(table_cap))
		}
		if delta := i64(c.peer_settings.initial_window_size) - old_window; delta != 0 {
			for _, s in c.streams {
				s.send_window += delta
			}
			// Positive delta may unblock buffered bodies — fair multi-stream flush.
			if delta > 0 {
				_flush_pending_rr(c, out)
			}
		}
		settings_write_ack(out)

	case FRAME_HEADERS:
		if h.stream_id == 0 do return _fail(c, H2_PROTOCOL_ERROR)
		if c.is_server {
			// Peer-initiated ids must be odd and strictly increasing for NEW
			// streams (§5.1.1) — id must be > last opened (≤ rejects reuse after GC).
			if h.stream_id & 1 == 0 do return _fail(c, H2_PROTOCOL_ERROR)
			_, known := c.streams[h.stream_id]
			if !known && h.stream_id <= c.last_peer_sid {
				return _fail(c, H2_PROTOCOL_ERROR)
			}
			// MAX_CONCURRENT_STREAMS refusal is applied in _finish_header_block
			// AFTER the full header block is HPACK-decoded (table sync).
		}
		if existing, ok := c.streams[h.stream_id]; ok {
			if existing.failed || existing.end_stream do return _fail(c, H2_STREAM_CLOSED)
			// A second block (trailers) must carry END_STREAM (§8.1).
			if existing.headers_done && h.flags & FLAG_END_STREAM == 0 {
				return _fail(c, H2_PROTOCOL_ERROR)
			}
		}
		frag, prio_dep, has_prio := _strip_headers(h.flags, payload) or_return
		if has_prio && prio_dep == h.stream_id do return _fail(c, H2_PROTOCOL_ERROR) // self-dependency (§5.3.1)
		if c.max_header_bytes > 0 && len(frag) > c.max_header_bytes do return _fail(c, H2_PROTOCOL_ERROR)
		if h.flags & FLAG_END_HEADERS == 0 {
			// Block continues in CONTINUATION frames — buffer the fragment.
			c.cont_sid = h.stream_id
			c.cont_end_stream = h.flags & FLAG_END_STREAM != 0
			clear(&c.cont_frag)
			append(&c.cont_frag, ..frag)
			return .None
		}
		return _finish_header_block(c, h.stream_id, frag, h.flags & FLAG_END_STREAM != 0, out)

	case FRAME_CONTINUATION:
		if c.cont_sid == 0 do return _fail(c, H2_PROTOCOL_ERROR) // no block open
		if c.max_header_bytes > 0 && len(c.cont_frag) + len(payload) > c.max_header_bytes {
			return _fail(c, H2_PROTOCOL_ERROR)
		}
		append(&c.cont_frag, ..payload) // no padding/priority in CONTINUATION
		if h.flags & FLAG_END_HEADERS == 0 do return .None
		sid, end := c.cont_sid, c.cont_end_stream
		c.cont_sid = 0
		return _finish_header_block(c, sid, c.cont_frag[:], end, out)

	case FRAME_DATA:
		if h.stream_id == 0 do return _fail(c, H2_PROTOCOL_ERROR)
		s, known := c.streams[h.stream_id]
		if !known do return _fail(c, H2_PROTOCOL_ERROR)                  // idle stream (§5.1)
		if s.failed || s.end_stream do return _fail(c, H2_STREAM_CLOSED) // closed / half-closed (remote)
		d := _strip_data(h.flags, payload) or_return
		if c.max_body_bytes > 0 && len(s.body) + len(d) > c.max_body_bytes do return _fail(c, H2_PROTOCOL_ERROR)
		append(&s.body, ..d)
		if h.flags & FLAG_END_STREAM != 0 {
			s.end_stream = true
			// Declared content-length must match the delivered body (§8.1.1).
			if s.expected_len >= 0 && i64(len(s.body)) != s.expected_len {
				return _fail(c, H2_PROTOCOL_ERROR)
			}
			// If we've already flushed our response end too, the stream is done.
			_stream_maybe_close(c, s)
		}
		// Inbound flow control: we buffer everything we're sent, so grant the
		// peer back exactly what this frame consumed (the FULL payload length —
		// padding counts, §6.9.1). Without this the peer stalls after one
		// initial window (65535 bytes) and gives up.
		// Coalesce across DATA frames in this conn_feed (item 5); flushed once
		// in _flush_window_credits — same total credit, fewer frames on bulk.
		if h.length > 0 {
			c.wu_conn_pending += h.length
			// Stream credit only while the stream remains open remotely; the
			// END_STREAM DATA itself still needs connection credit only.
			if !s.end_stream {
				s.wu_pending += h.length
			}
		}

	case FRAME_PING:
		if h.stream_id != 0 do return _fail(c, H2_PROTOCOL_ERROR)
		if len(payload) != 8 do return _fail(c, H2_FRAME_SIZE_ERROR, .Frame)
		if h.flags & FLAG_ACK == 0 do frame_write(out, FRAME_PING, FLAG_ACK, 0, payload)

	case FRAME_WINDOW_UPDATE:
		// Peer grew our send window — for the connection (stream 0) or one
		// stream — so drain whatever body we'd buffered against it.
		if len(payload) != 4 do return _fail(c, H2_FRAME_SIZE_ERROR, .Frame)
		incr := i64(get_u32(payload[:4]) & 0x7fff_ffff)
		if incr == 0 do return _fail(c, H2_PROTOCOL_ERROR) // §6.9
		if h.stream_id == 0 {
			if c.send_window + incr > 0x7fff_ffff do return _fail(c, H2_FLOW_CONTROL_ERROR)
			c.send_window += incr
			// Fair RR over streams with pending — not map-order drain.
			_flush_pending_rr(c, out)
		} else {
			s, known := c.streams[h.stream_id]
			// id is unknown — ignore rather than PROTOCOL_ERROR (F16 GC).
			if !known || s.closed do return .None
			if s.send_window + incr > 0x7fff_ffff {
				// STREAM error, not connection error (§6.9.1): RST this
				// stream and keep serving the rest.
				rst_stream_write(out, h.stream_id, H2_FLOW_CONTROL_ERROR)
				s.failed = true
				s.error_code = H2_FLOW_CONTROL_ERROR
				stream_pending_clear(s)
				s.end_pending = false
				s.wu_pending = 0
				_stream_close(c, s)
				return .None
			}
			s.send_window += incr
			_flush_stream(c, out, s)
		}

	case FRAME_RST_STREAM:
		// Peer aborted the stream: the exchange failed, nothing more is
		// coming. Drop anything we still owed it.
		if h.stream_id == 0 do return _fail(c, H2_PROTOCOL_ERROR)
		if len(payload) != 4 do return _fail(c, H2_FRAME_SIZE_ERROR, .Frame)
		s, known := c.streams[h.stream_id]
		// RST after we reaped a closed stream: ignore (id was open once).
		if !known {
			if h.stream_id <= c.last_peer_sid do return .None
			return _fail(c, H2_PROTOCOL_ERROR) // RST on an idle stream (§6.4)
		}
		s.failed = true
		s.error_code = get_u32(payload[:4])
		stream_pending_clear(s)
		s.end_pending = false
		s.wu_pending = 0 // no stream WU after RST
		_stream_close(c, s)

	case FRAME_GOAWAY:
		// Graceful shutdown: streams above last_sid were not processed and
		// never will be — fail any we have in flight.
		if h.stream_id != 0 do return _fail(c, H2_PROTOCOL_ERROR)
		if len(payload) < 8 do return _fail(c, H2_FRAME_SIZE_ERROR, .Frame)
		c.goaway_received = true
		c.goaway_last_sid = get_u32(payload[:4]) & 0x7fff_ffff
		c.goaway_code = get_u32(payload[4:8])
		for id, s in c.streams {
			if id > c.goaway_last_sid && !s.end_stream {
				s.failed = true
				s.error_code = c.goaway_code
				stream_pending_clear(s)
				s.end_pending = false
				_stream_close(c, s)
			}
		}

	case FRAME_PUSH_PROMISE:
		// We advertise ENABLE_PUSH=0, so receiving one is a connection error
		// (§8.4) — and we MUST not skip it silently anyway: its header block
		// would desync the shared HPACK decoder table.
		return _fail(c, H2_PROTOCOL_ERROR)

	case FRAME_PRIORITY:
		// Advisory — but its shape is still validated (§6.3, §5.3.1).
		if h.stream_id == 0 do return _fail(c, H2_PROTOCOL_ERROR)
		if len(payload) != 5 do return _fail(c, H2_FRAME_SIZE_ERROR, .Frame)
		if get_u32(payload[:4]) & 0x7fff_ffff == h.stream_id do return _fail(c, H2_PROTOCOL_ERROR) // self-dependency
	}
	return .None
}

// Decode a complete header block (single frame or reassembled CONTINUATIONs)
// into the stream, then validate it (servers: §8.1.2 request rules).
// MAX_CONCURRENT_STREAMS (§5.1.2): refuse NEW streams only AFTER HPACK decode
// so the shared compression context stays in sync with the peer encoder.
@(private)
_finish_header_block :: proc(
	c: ^Http2_Connection, sid: u32, frag: []u8, end_stream: bool, out: ^[dynamic]u8,
) -> H2_Error {
	_, known := c.streams[sid]
	// After local GOAWAY: refuse NEW streams above advertised last_sid.
	// Still HPACK-decode so the shared table stays in sync, then RST REFUSED_STREAM.
	refuse_goaway := c.is_server && c.goaway_sent && !known && sid > c.goaway_sent_last
	refuse_max :=
		c.is_server &&
		!known &&
		c.local_settings.max_concurrent_streams > 0 &&
		c.open_streams >= int(c.local_settings.max_concurrent_streams)
	refuse_new := refuse_goaway || refuse_max

	// Decoded list budget: wire block cap doubles as HPACK entry-size budget
	// when set; also honour advertised SETTINGS_MAX_HEADER_LIST_SIZE.
	max_list := 0
	if c.max_header_bytes > 0 {
		max_list = c.max_header_bytes
	}
	if c.local_settings.max_header_list_size > 0 {
		mls := int(c.local_settings.max_header_list_size)
		if max_list == 0 || mls < max_list {
			max_list = mls
		}
	}

	if refuse_new {
		// Decode for table sync only — do not open the stream or deliver.
		tmp: [dynamic]Header
		tmp.allocator = c.allocator
		defer {
			hpack.headers_destroy(tmp[:], c.allocator)
			delete(tmp)
		}
		if hpack.decode(&c.dec, frag, &tmp, c.allocator, max_list) != .None {
			return _fail(c, H2_COMPRESSION_ERROR, .Hpack)
		}
		// Peer did open this id; track it so reuse is PROTOCOL_ERROR.
		peer_parity := u32(c.is_server ? 1 : 0)
		if sid & 1 == peer_parity && sid > c.last_peer_sid {
			c.last_peer_sid = sid
		}
		rst_stream_write(out, sid, H2_REFUSED_STREAM)
		return .None
	}

	s := _get_or_make_stream(c, sid)
	is_trailers := s.headers_done
	first_new := len(s.headers)
	if hpack.decode(&c.dec, frag, &s.headers, c.allocator, max_list) != .None {
		return _fail(c, H2_COMPRESSION_ERROR, .Hpack)
	}
	if c.is_server {
		_validate_request_headers(c, s, s.headers[first_new:], is_trailers) or_return
	}
	s.headers_done = true
	if end_stream {
		s.end_stream = true
		// HEADERS carried END_STREAM: a declared non-zero content-length can
		// never be satisfied (§8.1.1).
		if c.is_server && s.expected_len >= 0 && i64(len(s.body)) != s.expected_len {
			return _fail(c, H2_PROTOCOL_ERROR)
		}
		// Bodyless request fully received — if our response end is also sent,
		// the stream is complete.
		_stream_maybe_close(c, s)
	}
	return .None
}

// Server-side request semantics (RFC 9113 §8.1.2, §8.2.x): malformed
// messages are protocol errors, not 4xx responses — the framing layer is the
// wrong place to be forgiving (request smuggling lives in that gap).
@(private)
_validate_request_headers :: proc(c: ^Http2_Connection, s: ^Http2_Stream, new_headers: []Header, is_trailers: bool) -> H2_Error {
	seen_regular := false
	has_method, has_scheme, has_path := false, false, false
	for h in new_headers {
		// Field names must be lowercase on the wire (§8.2.1).
		for ch in h.name {
			if ch >= 'A' && ch <= 'Z' do return _fail(c, H2_PROTOCOL_ERROR)
		}

		if len(h.name) > 0 && h.name[0] == ':' {
			if is_trailers do return _fail(c, H2_PROTOCOL_ERROR)   // no pseudo-headers in trailers
			if seen_regular do return _fail(c, H2_PROTOCOL_ERROR) // pseudo after regular field
			switch h.name {
			case ":method":
				if has_method do return _fail(c, H2_PROTOCOL_ERROR) // duplicate
				has_method = true
			case ":scheme":
				if has_scheme do return _fail(c, H2_PROTOCOL_ERROR)
				has_scheme = true
			case ":path":
				if has_path || len(h.value) == 0 do return _fail(c, H2_PROTOCOL_ERROR)
				has_path = true
			case ":authority":
			case:
				// Unknown pseudo-header, or a response one (:status) in a request.
				return _fail(c, H2_PROTOCOL_ERROR)
			}
			continue
		}

		seen_regular = true
		switch h.name {
		case "connection":
			return _fail(c, H2_PROTOCOL_ERROR) // connection-specific fields are h1-only (§8.2.2)
		case "te":
			if h.value != "trailers" do return _fail(c, H2_PROTOCOL_ERROR)
		case "content-length":
			n, ok := strconv.parse_i64_of_base(h.value, 10)
			if !ok || n < 0 do return _fail(c, H2_PROTOCOL_ERROR)
			s.expected_len = n
		}
	}
	if !is_trailers && (!has_method || !has_scheme || !has_path) {
		return _fail(c, H2_PROTOCOL_ERROR) // mandatory request pseudo-headers (§8.3.1)
	}
	return .None
}

// Did the peer kill this exchange (RST_STREAM, or GOAWAY past it)? Callers
// polling conn_response should also poll this — a failed stream never
// completes.
conn_stream_failed :: proc(c: ^Http2_Connection, sid: u32) -> (code: u32, failed: bool) {
	if s, ok := c.streams[sid]; ok && s.failed do return s.error_code, true
	if c.goaway_received && sid > c.goaway_last_sid do return c.goaway_code, true
	return 0, false
}

// Host cannot admit this stream (e.g. multi-slot full). Sends
// RST_STREAM(REFUSED_STREAM), marks failed, closes for open_streams accounting.
// Does not tear down the connection. Safe after conn_take_request (delivered);
// reaps when closed && (delivered || failed) and no caller holds slices.
conn_refuse_stream :: proc(c: ^Http2_Connection, out: ^[dynamic]u8, sid: u32) {
	if c == nil || out == nil || sid == 0 {
		return
	}
	rst_stream_write(out, sid, H2_REFUSED_STREAM)
	if s, ok := c.streams[sid]; ok {
		s.failed = true
		s.error_code = H2_REFUSED_STREAM
		// If already taken, host is dropping without a handler — release now.
		if s.delivered {
			s.app_released = true
		}
		stream_pending_clear(s)
		s.end_pending = false
		_stream_close(c, s)
	}
	conn_reap_streams(c)
}

// Server: next fully-received request not yet handed out.
// Returned headers/body slices are borrowed from stream storage until
// conn_app_release(c, sid) (or refuse/destroy). Do not free via headers_destroy
// on the caller's side.
conn_take_request :: proc(
	c: ^Http2_Connection,
) -> (sid: u32, headers: []Header, body: []u8, ok: bool) {
	for id, s in c.streams {
		if s.failed || s.closed do continue
		if s.end_stream && s.headers_done && !s.delivered {
			s.delivered = true
			s.app_released = false
			return id, s.headers[:], s.body[:], true
		}
	}
	return 0, nil, nil, false
}

// Host finished using the slices from conn_take_request (after handler return).
// Enables conn_reap_streams to free header/body storage once the stream is closed.
conn_app_release :: proc(c: ^Http2_Connection, sid: u32) {
	if c == nil || sid == 0 do return
	if s, ok := c.streams[sid]; ok {
		s.app_released = true
	}
	conn_reap_streams(c)
}

// Client: response for `sid`, once fully received. Marks the stream delivered
// so conn_reap_streams may free it after the caller no longer holds the
// returned slices (same contract as conn_take_request on the server).
conn_response :: proc(
	c: ^Http2_Connection, sid: u32,
) -> (headers: []Header, body: []u8, done: bool) {
	s, ok := c.streams[sid]
	if !ok || !s.end_stream do return nil, nil, false
	s.delivered = true
	s.app_released = false
	return s.headers[:], s.body[:], true
}

// Unsent bytes remaining in stream.pending (after pending_off).
stream_pending_len :: proc(s: ^Http2_Stream) -> int {
	if s == nil do return 0
	n := len(s.pending) - s.pending_off
	return n if n > 0 else 0
}

// Drop all pending body bytes and reset the read cursor.
stream_pending_clear :: proc(s: ^Http2_Stream) {
	if s == nil do return
	clear(&s.pending)
	s.pending_off = 0
}

// True if any stream has body bytes buffered in `pending` that the peer's
// flow-control windows haven't yet allowed out. The server's response loop
// uses this to know when to stop and read for WINDOW_UPDATEs (backpressure)
// rather than charging on to the next request.
conn_has_pending_body :: proc(c: ^Http2_Connection) -> bool {
	for _, s in c.streams {
		if !s.closed && stream_pending_len(s) > 0 do return true
	}
	return false
}

// Drop closed streams that the application has consumed (or that failed) so
// the map does not grow with every exchange. Applies to both server and client:
// server marks delivered via conn_take_request; client via conn_response.
// WINDOW_UPDATE / has_pending scan every entry — unbounded growth inverted
// H2 bulk RPS under concurrency (F16).
// Header/body bytes are freed only when safe for the host:
//   - failed and never delivered → free immediately when closed
//   - delivered → free only after conn_app_release (handler finished)
// This allows Request to borrow stream header strings without cloning.
// Two-pass so map iteration is stable.
conn_reap_streams :: proc(c: ^Http2_Connection) {
	if len(c.streams) == 0 do return
	ids: [dynamic]u32
	ids.allocator = context.temp_allocator
	for id, s in c.streams {
		if !s.closed do continue
		// Never taken: refuse/reset/GOAWAY can free when closed.
		if s.failed && !s.delivered {
			append(&ids, id)
			continue
		}
		// Taken by app: wait until host releases borrowed header/body slices.
		if s.delivered && s.app_released {
			append(&ids, id)
			continue
		}
	}
	for id in ids {
		s, ok := c.streams[id]
		if !ok do continue
		delete_key(&c.streams, id)
		hpack.headers_destroy(s.headers[:], c.allocator)
		delete(s.headers)
		delete(s.body)
		delete(s.pending)
		free(s, c.allocator)
	}
}

@(private)
_get_or_make_stream :: proc(c: ^Http2_Connection, id: u32) -> ^Http2_Stream {
	if s, ok := c.streams[id]; ok do return s
	// Peer-initiated ids are odd from a client, even from a server.
	peer_parity := u32(c.is_server ? 1 : 0)
	is_peer_initiated := id & 1 == peer_parity
	if is_peer_initiated && id > c.last_peer_sid do c.last_peer_sid = id
	s := new(Http2_Stream, c.allocator)
	s.id = id
	s.headers.allocator = c.allocator
	s.body.allocator = c.allocator
	s.pending.allocator = c.allocator
	s.expected_len = -1
	// Initial send window = the peer's advertised SETTINGS_INITIAL_WINDOW_SIZE.
	s.send_window = i64(c.peer_settings.initial_window_size)
	c.streams[id] = s
	// Count inbound (peer-initiated) streams against MAX_CONCURRENT_STREAMS.
	// Outbound streams (we initiated) don't count against OUR limit.
	if is_peer_initiated do c.open_streams += 1
	return s
}

// Mark a stream closed and decrement the open-stream counter once. Safe to
// call from any terminal transition (RST received/sent, GOAWAY, natural
// completion); idempotent via the `closed` flag. Map entry is freed later by
// conn_reap_streams (not here — callers may be iterating c.streams).
@(private)
_stream_close :: proc(c: ^Http2_Connection, s: ^Http2_Stream) {
	if s.closed do return
	s.closed = true
	peer_parity := u32(c.is_server ? 1 : 0)
	if s.id & 1 == peer_parity && c.open_streams > 0 {
		c.open_streams -= 1
	}
}

// Natural completion: a stream closes once BOTH halves are done — the peer
// sent END_STREAM (s.end_stream, request fully received) and we have sent
// END_STREAM (s.end_sent, response fully flushed). Called from the DATA
// END_STREAM path and from _flush_stream when end_sent flips.
@(private)
_stream_maybe_close :: proc(c: ^Http2_Connection, s: ^Http2_Stream) {
	if !s.closed && s.end_stream && s.end_sent {
		_stream_close(c, s)
	}
}

@(private)
_strip_headers :: proc(flags: u8, payload: []u8) -> (frag: []u8, prio_dep: u32, has_prio: bool, err: H2_Error) {
	p := payload
	if flags & FLAG_PADDED != 0 {
		if len(p) < 1 do return nil, 0, false, .Protocol
		pad := int(p[0])
		p = p[1:]
		if pad > len(p) do return nil, 0, false, .Protocol
		p = p[:len(p) - pad]
	}
	if flags & FLAG_PRIORITY != 0 {
		if len(p) < 5 do return nil, 0, false, .Protocol
		prio_dep = get_u32(p[:4]) & 0x7fff_ffff
		has_prio = true
		p = p[5:]
	}
	return p, prio_dep, has_prio, .None
}

@(private)
_strip_data :: proc(flags: u8, payload: []u8) -> (data: []u8, err: H2_Error) {
	p := payload
	if flags & FLAG_PADDED != 0 {
		if len(p) < 1 do return nil, .Protocol
		pad := int(p[0])
		p = p[1:]
		if pad > len(p) do return nil, .Protocol
		p = p[:len(p) - pad]
	}
	return p, .None
}
