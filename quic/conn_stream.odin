package quic

// Single bidirectional QUIC stream state machine.
// zenoh-odin uses exactly one bidi stream per QUIC connection (the
// `zenoh-mr` ALPN / single-stream mode). The client opens stream 0 via
// `connection.open_bi()` at connect time, and all reliable zenoh messages
// flow through it for the session's lifetime.
// Ownership: the Stream is heap-allocated and owned by the Conn. It is
// created in `stream_open` and destroyed in `stream_free`. Access is
// single-threaded — the caller of the Conn drives send/recv via the same
// event loop that owns the UDP socket, so no locks are needed.

// Default flow control windows. These are advertised in our transport
// parameters and are the hard limit on the peer's send rate per stream and
// per connection.
DEFAULT_STREAM_WINDOW :: u64(1 * 1024 * 1024)    //  1 MiB per stream
DEFAULT_CONN_WINDOW   :: u64(10 * 1024 * 1024)   // 10 MiB per connection

// Sent_Range tracks a contiguous [offset, offset+len) range of stream bytes
// that we've placed into a packet but haven't yet seen acknowledged. On ACK
// of the containing packet number, the range is removed from the list. On
// PTO expiry or explicit loss signaling, the range is marked for retransmit.
// `fin` is set when this range carried the STREAM FIN bit (including FIN-only
// empty frames with len == 0); loss requeues clear `tx_fin_sent` so FIN is
// re-emitted.
Sent_Range :: struct {
	stream_id:     u64, // which stream the [offset, offset+len) belongs to
	offset:        u64,
	len:           u64,
	packet_number: u64, // 1-RTT packet number space
	fin:           bool, // STREAM FIN bit was set on the frame in this packet
}

// Rx_Fragment holds one out-of-order piece of received stream data that
// can't yet be delivered because earlier bytes haven't arrived. Keyed by
// its absolute stream offset. Owns its data buffer (freed on consume).
Rx_Fragment :: struct {
	offset: u64,
	data:   []u8,
}

Stream :: struct {
	id: u64, // always 0 for our single client-bidi stream

	// --- Send side ---
	// Bytes are retained in tx_buffered until ACKed so a lost packet can be
	// retransmitted by rewinding tx_sent_off (see _stream_requeue_range).
	//   tx_buffered: everything written via stream_write, not yet fully ACKed
	//   tx_sent_off: index into tx_buffered of the next byte to put on the wire
	//   tx_acked_off: index of the lowest byte still unacked; compaction
	//                 watermark (bytes [0, tx_acked_off) are freed periodically)
	//   tx_abs_base:  absolute QUIC stream offset of tx_buffered[0]; grows by
	//                 tx_acked_off on each compaction. tx_next_offset below is
	//                 the absolute offset of the next wire byte.
	tx_buffered:      [dynamic]u8,
	tx_sent_off:      u64,              // next index within tx_buffered to send
	tx_acked_off:     u64,              // prefix of tx_buffered ACKed (compaction watermark)
	tx_abs_base:      u64,              // absolute offset of tx_buffered[0]
	tx_next_offset:   u64,              // next absolute offset to put on the wire
	tx_unacked:       [dynamic]Sent_Range,
	tx_peer_max_data: u64,              // peer's advertised MAX_STREAM_DATA for us
	tx_fin:           bool,             // caller has closed the send side (stream_close_send)
	tx_fin_sent:      bool,             // FIN bit has been emitted on the wire
	tx_fin_acked:     bool,             // peer ACK'd the FIN-bearing packet

	// --- Recv side ---
	rx_next_offset:   u64,              // next byte to hand to the caller
	rx_fragments:     [dynamic]Rx_Fragment,
	rx_delivered:     [dynamic]u8,      // contiguous bytes ready for stream_read
	rx_our_max_data:  u64,              // limit we advertised to the peer
	rx_fin_offset:    Maybe(u64),       // the offset the peer's FIN is at, once seen
	rx_closed:        bool,

	// Stream-level abort flags. `rx_aborted` is set when the peer
	// RESET_STREAM'd us — no more bytes will arrive on this stream and
	// any pending fragments are dropped. `tx_aborted` is set when the
	// peer STOP_SENDING'd us — we drop the queued payload and stop
	// emitting STREAM frames here. Both are local to one stream; the
	// connection survives.
	rx_aborted:       bool,
	tx_aborted:       bool,
}

// Open (or look up) the control stream — id 0, client-initiated bidi.
// This is the only stream in single-stream (zenoh-mr) mode, and the
// out-of-band control channel in multi-stream modes. The first STREAM
// frame we send implicitly creates the stream on the peer side
// (RFC 9000 §2.1 "streams are created implicitly").
conn_open_stream :: proc(conn: ^Conn, allocator := context.allocator) -> ^Stream {
	return conn_get_or_open_stream(conn, 0, allocator)
}

// Registry lookup, creating a Stream entry on demand. Used by both the
// sender (when opening a known stream id) and the receiver (when an
// inbound STREAM frame arrives for an id we haven't seen before).
conn_get_or_open_stream :: proc(conn: ^Conn, id: u64, allocator := context.allocator) -> ^Stream {
	if existing, found := conn.streams[id]; found do return existing
	s := stream_new(id, allocator)
	conn.streams[id] = s

	// If this is a peer-initiated unidirectional stream, count it against
	// the cap we advertised so the outbound MAX_STREAMS_UNI loop can
	// raise it before the peer runs out.
	peer_uni_mask: u64 = conn.is_server ? 2 : 3 // peer-uni from our role
	if id & 3 == peer_uni_mask {
		conn.rx_uni_count += 1
		if conn.rx_uni_count > conn.rx_uni_max_advertised / 2 {
			// Slide the cap forward by another initial window.
			conn.rx_uni_max_advertised = conn.rx_uni_count + conn.local_tp.initial_max_streams_uni
			conn.rx_max_streams_uni_pending = true
		}
	}
	return s
}

// Pure lookup — nil if the stream hasn't been created.
conn_get_stream :: proc(conn: ^Conn, id: u64) -> ^Stream {
	if s, found := conn.streams[id]; found do return s
	return nil
}

// Number of priority streams in multi-stream mode. zenoh has 8 priorities
// (Control + 7 user priorities); Control rides the bidi stream (id 0)
// and priorities 1..7 each get a uni stream.
NUM_PRIORITY_UNI_STREAMS :: 7

// Allocate and open a new locally-initiated unidirectional stream. Used
// by multi-stream mode (zenoh-ms / zenoh-ms-mr) to give each user priority
// its own send channel. Caller is responsible for calling this in
// priority order so the natural stream-id ordering matches priority
// ordering on the peer side (zenoh-rs relies on the same convention).
// Returns nil if the peer's initial_max_streams_uni budget has been
// exhausted — caller must back off or fall back to the control stream.
conn_open_uni :: proc(conn: ^Conn, allocator := context.allocator) -> ^Stream {
	if !conn.next_local_uni_id_inited {
		// Client-initiated: 2; server-initiated: 3.
		conn.next_local_uni_id = conn.is_server ? 3 : 2
		conn.next_local_uni_id_inited = true
	}

	// Count uni streams we've already opened on our side. The peer's
	// initial_max_streams_uni is an absolute cap on stream id count, not
	// on concurrently-open streams — but since we never close any, the
	// two coincide for our use case.
	opened := 0
	for id, _ in conn.streams {
		// Locally-initiated uni: 4k+2 (client) or 4k+3 (server).
		mask: u64 = conn.is_server ? 3 : 2
		if id & 3 == mask do opened += 1
	}
	if u64(opened) >= conn.peer_tp.initial_max_streams_uni do return nil

	id := conn.next_local_uni_id
	conn.next_local_uni_id += 4
	s := stream_new(id, allocator)
	// Apply the peer's per-uni-stream send window.
	if conn.peer_tp.initial_max_stream_data_uni > 0 {
		s.tx_peer_max_data = conn.peer_tp.initial_max_stream_data_uni
	}
	conn.streams[id] = s
	return s
}

// Allocate and open a new locally-initiated BIDIRECTIONAL stream — one per
// HTTP/3 request. Client-bidi IDs are 4n+0, server-bidi IDs are 4n+1.
// Returns nil if the peer's initial_max_streams_bidi budget is exhausted.
// (zenoh itself only ever uses bidi id 0 via conn_open_stream; this is the
// multi-request allocator HTTP/3 needs.)
conn_open_bidi :: proc(conn: ^Conn, allocator := context.allocator) -> ^Stream {
	if !conn.next_local_bidi_id_inited {
		conn.next_local_bidi_id = conn.is_server ? 1 : 0
		conn.next_local_bidi_id_inited = true
	}

	mask: u64 = conn.is_server ? 1 : 0
	opened := 0
	for id, _ in conn.streams {
		if id & 3 == mask do opened += 1
	}
	if u64(opened) >= conn.peer_tp.initial_max_streams_bidi do return nil

	id := conn.next_local_bidi_id
	conn.next_local_bidi_id += 4
	s := stream_new(id, allocator)
	// Locally-initiated bidi: peer's bidi_remote is the credit they grant us
	// on streams we open (RFC 9000 initial_max_stream_data_bidi_remote).
	if conn.peer_tp.initial_max_stream_data_bidi_remote > s.tx_peer_max_data {
		s.tx_peer_max_data = conn.peer_tp.initial_max_stream_data_bidi_remote
	}
	conn.streams[id] = s
	return s
}

// Map a zenoh Priority (0=Control, 1..7=user) to the QUIC stream that
// should carry its frames. In single-stream mode every priority uses
// the control bidi (id 0). In multi-stream mode Control stays on id 0
// and priorities 1..7 use the locally-opened uni streams in open order.
// Returns nil if the corresponding stream hasn't been opened yet. Callers
// in multi-stream mode are expected to open all 7 uni streams up front
// (zenoh-rs does this in UniStreams::try_open) so the lookup is hit-only
// in steady state.
conn_stream_for_priority :: proc(conn: ^Conn, priority: u8) -> ^Stream {
	if priority == 0 || !conn_alpn_is_multi_stream(conn) {
		return conn_get_stream(conn, 0)
	}
	// Locally-initiated uni base: 2 for client, 3 for server. Priority 1
	// → first uni opened, Priority 7 → seventh. Stride is 4.
	base: u64 = conn.is_server ? 3 : 2
	id := base + u64(priority - 1) * 4
	return conn_get_stream(conn, id)
}

// Allocate and initialize a Stream. Caller must eventually call stream_free.
stream_new :: proc(id: u64, allocator := context.allocator) -> ^Stream {
	s := new(Stream, allocator)
	s.id = id
	s.tx_peer_max_data = DEFAULT_STREAM_WINDOW
	s.rx_our_max_data  = DEFAULT_STREAM_WINDOW
	return s
}

stream_free :: proc(s: ^Stream, allocator := context.allocator) {
	if s == nil do return
	delete(s.tx_buffered)
	delete(s.tx_unacked)
	delete(s.rx_delivered)
	for frag in s.rx_fragments {
		delete(frag.data)
	}
	delete(s.rx_fragments)
	free(s, allocator)
}

// Queue bytes for transmission. Actual wire emission happens when the Conn
// builds an outgoing 1-RTT packet via conn_build_one_rtt_packet. Bytes are
// RETAINED in tx_buffered until ACKed so a lost packet can be retransmitted
// by rewinding tx_sent_off (see _stream_requeue_range in conn_loss.odin).
stream_write :: proc(s: ^Stream, data: []u8) {
	if len(data) == 0 do return
	// Pre-grow: bulk writers (bench / H3 bodies) often write multi-MiB at once;
	// avoid geometric realloc + copy churn (quic-go similarly grows buffers).
	need := len(s.tx_buffered) + len(data)
	if cap(s.tx_buffered) < need {
		reserve(&s.tx_buffered, need)
	}
	append(&s.tx_buffered, ..data)
	// Stats are tracked on the Conn — caller updates conn.stats.stream_bytes_written.
}

// Free the ACKed prefix of tx_buffered once it's at least half the buffer,
// and slide everything down. Keeps amortized cost O(1) per byte (each byte
// is shifted at most once before it's reclaimed) while avoiding a shift on
// every single ACK. Offsets in any in-flight Sent_Range are absolute; they
// stay correct because tx_abs_base grows by the reclaimed prefix.
stream_compact :: proc(s: ^Stream) {
	if s.tx_acked_off == 0 do return
	if s.tx_acked_off < u64(len(s.tx_buffered)) / 2 do return
	reclaimed := s.tx_acked_off
	keep := len(s.tx_buffered) - int(reclaimed)
	if keep > 0 {
		copy(s.tx_buffered[:], s.tx_buffered[reclaimed:])
	}
	resize(&s.tx_buffered, keep)
	// tx_sent_off is an index into tx_buffered; shift it down by the reclaimed
	// prefix (clamped — sent can't precede acked in practice).
	if s.tx_sent_off > reclaimed {
		s.tx_sent_off -= reclaimed
	} else {
		s.tx_sent_off = 0
	}
	s.tx_acked_off = 0
	s.tx_abs_base += reclaimed
}

// Mark this stream's send half as closed (RFC 9000 §2.3). The packet
// builder will set the FIN bit on the STREAM frame carrying the last
// queued byte; if there are no more bytes pending the next packet emits
// an empty FIN frame. Idempotent — calling twice is safe.
stream_close_send :: proc(s: ^Stream) {
	s.tx_fin = true
}

// Copy up to len(buf) contiguous bytes out of rx_delivered into buf.
// Returns the number of bytes written. Returns 0 and ok=false when the
// stream has been closed and no more bytes will arrive.
stream_read :: proc(s: ^Stream, buf: []u8) -> (n: int, ok: bool) {
	if len(s.rx_delivered) == 0 {
		if s.rx_closed do return 0, false
		return 0, true
	}
	n = min(len(s.rx_delivered), len(buf))
	copy(buf, s.rx_delivered[:n])
	// Remove consumed bytes from the head of rx_delivered.
	copy(s.rx_delivered[:], s.rx_delivered[n:])
	resize(&s.rx_delivered, len(s.rx_delivered) - n)
	return n, true
}

// Accept an inbound STREAM frame. Insert the bytes at the correct absolute
// offset, re-contiguate as far as possible, and advance `rx_next_offset`.
stream_on_stream_frame :: proc(s: ^Stream, frame: Stream_Frame) {
	if s.rx_closed do return

	// Fast path: frame starts exactly at the next expected offset.
	if frame.offset == s.rx_next_offset {
		append(&s.rx_delivered, ..frame.data)
		s.rx_next_offset += u64(len(frame.data))

		if frame.fin {
			s.rx_fin_offset = s.rx_next_offset
		}

		// After advancing rx_next_offset, pull any fragments that now
		// become contiguous.
		_stream_flush_fragments(s)
	} else if frame.offset > s.rx_next_offset {
		// Gap — buffer the fragment for later.
		copy_data := make([]u8, len(frame.data))
		copy(copy_data, frame.data)
		append(&s.rx_fragments, Rx_Fragment{offset = frame.offset, data = copy_data})

		if frame.fin {
			s.rx_fin_offset = frame.offset + u64(len(frame.data))
		}
	}
	// else: entirely before rx_next_offset — already delivered, ignore.

	// FIN with no more pending data closes the stream.
	if fin_off, has_fin := s.rx_fin_offset.?; has_fin {
		if s.rx_next_offset >= fin_off && len(s.rx_fragments) == 0 {
			s.rx_closed = true
		}
	}
}

// Pull any buffered fragments whose start offset now equals rx_next_offset.
// Drains in a loop so a chain of contiguous fragments all get promoted.
@(private)
_stream_flush_fragments :: proc(s: ^Stream) {
	for {
		found := -1
		for frag, i in s.rx_fragments {
			if frag.offset == s.rx_next_offset {
				found = i
				break
			}
		}
		if found == -1 do break

		frag := s.rx_fragments[found]
		append(&s.rx_delivered, ..frag.data)
		s.rx_next_offset += u64(len(frag.data))
		delete(frag.data)
		// Remove from the fragments array (swap-remove).
		ordered_remove(&s.rx_fragments, found)
	}
}

// Return true if we should emit a MAX_STREAM_DATA update — triggered when
// the caller has drained more than half of the advertised window.
stream_needs_flow_control_update :: proc(s: ^Stream) -> bool {
	return s.rx_next_offset > s.rx_our_max_data / 2
}

// Bump our advertised limit by the amount the caller has drained, returning
// the new limit to put in the outgoing MAX_STREAM_DATA frame.
stream_new_flow_control_limit :: proc(s: ^Stream) -> u64 {
	s.rx_our_max_data = s.rx_next_offset + DEFAULT_STREAM_WINDOW
	return s.rx_our_max_data
}
