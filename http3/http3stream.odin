// Package webstream is a thin, protocol-agnostic facade over the QUIC transport.
// It exposes streams as stable id-tokens, write/read/close, an io.Stream adapter
// (the seam the HTTP parser plugs into — same one odin-http uses for TCP/TLS
// sockets), and a level-triggered event poll. It is intentionally thin: QUIC
// already owns the stream buffers, flow control, and lifecycle, so this layer
// adds no buffers of its own.
// A `Stream` IS the wire stream id. QUIC stream ids are monotonic and never
// reused, so a stale token simply misses the connection's registry (→
// .Unknown_Stream) — there's no ABA hazard, hence no need for generational
// handles here. When an HTTP/2 backend is added later, the seam to generalize
// is a small Transport-hooks struct; that indirection is deliberately NOT built
// yet (a single backend doesn't justify it).
package http3

import "core:io"
import "core:testing"

import "../quic"


// A stream token. Equal to the QUIC wire stream id.
Http3_Stream :: distinct u64

Stream_Dir :: enum {
	Bidi, // client/server-initiated bidirectional (HTTP/3 request streams)
	Uni,  // unidirectional (HTTP/3 control + QPACK encoder/decoder streams)
}

Http3_Stream_Error :: enum {
	None,
	Stream_Budget_Exhausted, // peer's stream-count limit reached
	Unknown_Stream,          // id not present on the connection
	Reset,                   // peer RESET_STREAM'd (rx) or STOP_SENDING'd (tx) us
}

// Open a locally-initiated stream of the given direction.
stream_open :: proc(conn: ^quic.Conn, dir := Stream_Dir.Bidi) -> (Http3_Stream, Http3_Stream_Error) {
	qs: ^quic.Stream
	switch dir {
	case .Bidi:
		qs = quic.conn_open_bidi(conn) // 4n+0 (client) / 4n+1 (server), one per request
	case .Uni:
		qs = quic.conn_open_uni(conn)
	}
	if qs == nil do return Http3_Stream(0), .Stream_Budget_Exhausted
	return Http3_Stream(qs.id), .None
}

// Register (or look up) a peer-initiated stream id — e.g. one surfaced by poll.
stream_accept :: proc(conn: ^quic.Conn, id: u64) -> Http3_Stream {
	quic.conn_get_or_open_stream(conn, id)
	return Http3_Stream(id)
}

@(private)
resolve :: proc(conn: ^quic.Conn, s: Http3_Stream) -> (^quic.Stream, Http3_Stream_Error) {
	qs := quic.conn_get_stream(conn, u64(s))
	if qs == nil do return nil, .Unknown_Stream
	return qs, .None
}

// Queue bytes for sending. They are flushed onto the wire by the connection's
// packet-build loop, not synchronously here.
stream_write :: proc(conn: ^quic.Conn, s: Http3_Stream, data: []u8) -> Http3_Stream_Error {
	qs := resolve(conn, s) or_return
	if qs.tx_aborted do return .Reset
	// Seed / raise the per-stream send window from the peer's transport
	// parameters. stream_new defaults to DEFAULT_STREAM_WINDOW; once we know
	// the peer's real limits, use the correct one for this stream type:
	// RFC 9000: initial_max_stream_data_bidi_local  = credit on streams *we* initiate
	//            initial_max_stream_data_bidi_remote = credit on streams *peer* initiates
	//            (from the peer's perspective as the TP sender).
	// So for a stream the peer initiated, our send limit is peer's *local*.
	_seed_stream_send_window(conn, qs, u64(s))
	quic.stream_write(qs, data)
	return .None
}

@(private)
_seed_stream_send_window :: proc(conn: ^quic.Conn, qs: ^quic.Stream, id: u64) {
	// Uni bit (0x2): uni streams use initial_max_stream_data_uni.
	if id & 0x2 != 0 {
		lim := conn.peer_tp.initial_max_stream_data_uni
		if lim > qs.tx_peer_max_data do qs.tx_peer_max_data = lim
		return
	}
	// Bidi: low bit of id distinguishes initiator (client=0, server=1 for
	// the bottom bit of the type). Stream initiated by peer if
	// (id & 1) == (is_server ? 0 : 1).
	peer_initiated := (conn.is_server && (id & 1) == 0) || (!conn.is_server && (id & 1) == 1)
	lim := conn.peer_tp.initial_max_stream_data_bidi_remote
	if peer_initiated {
		// Peer opened this stream → their bidi_local is our send budget.
		lim = conn.peer_tp.initial_max_stream_data_bidi_local
	}
	if lim > qs.tx_peer_max_data do qs.tx_peer_max_data = lim
}

// Read already-delivered bytes (non-blocking). `eof` is true once the peer has
// finished the stream and all bytes have been consumed.
stream_read :: proc(conn: ^quic.Conn, s: Http3_Stream, buf: []u8) -> (n: int, eof: bool, err: Http3_Stream_Error) {
	qs := resolve(conn, s) or_return
	if qs.rx_aborted do return 0, false, .Reset
	got, ok := quic.stream_read(qs, buf)
	return got, !ok, .None // quic ok=false ⟺ empty AND peer-closed
}

// Close the send side (sends FIN). Idempotent.
stream_close :: proc(conn: ^quic.Conn, s: Http3_Stream) -> Http3_Stream_Error {
	qs := resolve(conn, s) or_return
	quic.stream_close_send(qs)
	return .None
}

// Bytes buffered for this stream but not yet placed on the wire (flow-control
// / cwnd backpressure signal for body pumps).
stream_tx_unsent_bytes :: proc(conn: ^quic.Conn, s: Http3_Stream) -> int {
	qs, err := resolve(conn, s)
	if err != .None || qs == nil do return 0
	if qs.tx_sent_off >= u64(len(qs.tx_buffered)) do return 0
	return int(u64(len(qs.tx_buffered)) - qs.tx_sent_off)
}

// True if the stream currently has buffered bytes ready to read.
stream_readable :: proc(conn: ^quic.Conn, s: Http3_Stream) -> bool {
	qs, err := resolve(conn, s)
	return err == .None && len(qs.rx_delivered) > 0
}

// ---- io.Stream adapter: the unifying seam ---------------------------------

// Wrap a stream as a core:io.Stream so the bufio.Scanner + HTTP parser consume
// it unchanged. Backed directly by the ^quic.Stream — no extra allocation.
stream_to_io :: proc(conn: ^quic.Conn, s: Http3_Stream) -> (ios: io.Stream, err: Http3_Stream_Error) {
	qs := resolve(conn, s) or_return
	return io.Stream{data = qs, procedure = _io_proc}, .None
}

@(private)
_io_proc :: proc(
	stream_data: rawptr,
	mode: io.Stream_Mode,
	p: []byte,
	offset: i64,
	whence: io.Seek_From,
) -> (n: i64, err: io.Error) {
	qs := (^quic.Stream)(stream_data)
	#partial switch mode {
	case .Query:
		return io.query_utility(io.Stream_Mode_Set{.Query, .Read, .Write, .Close})
	case .Read:
		if qs.rx_aborted do return 0, .Unexpected_EOF
		got, ok := quic.stream_read(qs, p)
		if got == 0 {
			if ok do return 0, .Empty // no data yet (would-block)
			return 0, .EOF            // peer finished + drained
		}
		return i64(got), .None
	case .Write:
		if qs.tx_aborted do return 0, .Unexpected_EOF
		quic.stream_write(qs, p)
		return i64(len(p)), .None
	case .Close:
		quic.stream_close_send(qs)
		return 0, .None
	}
	return 0, .Empty
}

// ---- Events (server / event-loop side): data, not callbacks ---------------

Http3_Stream_Event :: union {
	Opened,   // a stream id not seen before (peer- or locally-initiated)
	Readable, // has buffered rx bytes
	Finished, // peer finished (FIN) and rx is drained
	Reset,    // peer RESET_STREAM'd
}
Opened   :: struct { stream: Http3_Stream }
Readable :: struct { stream: Http3_Stream }
Finished :: struct { stream: Http3_Stream }
Reset    :: struct { stream: Http3_Stream }

// A Poller remembers which streams it has already announced via Opened, so that
// event is edge-triggered; Readable/Finished/Reset are level-triggered (the
// caller drains via stream_read and re-polls).
Http3_Stream_Poller :: struct {
	seen: map[u64]bool,
}

poller_init :: proc(p: ^Http3_Stream_Poller, allocator := context.allocator) {
	p.seen.allocator = allocator
}

poller_destroy :: proc(p: ^Http3_Stream_Poller) {
	delete(p.seen)
}

// Append the current connection events to `out`.
poll :: proc(p: ^Http3_Stream_Poller, conn: ^quic.Conn, out: ^[dynamic]Http3_Stream_Event) {
	for id, qs in conn.streams {
		if id not_in p.seen {
			p.seen[id] = true
			append(out, Opened{Http3_Stream(id)})
		}
		switch {
		case qs.rx_aborted:
			append(out, Reset{Http3_Stream(id)})
		case len(qs.rx_delivered) > 0:
			append(out, Readable{Http3_Stream(id)})
		case qs.rx_closed:
			append(out, Finished{Http3_Stream(id)})
		}
	}
}




//////////////////////////////////////////////////////////////////////
//                            Tests
// ///////////////////////////////////////////////////////////////////






// Build a bare client-side Conn with an initialized stream registry. No TLS
// handshake — we exercise the facade's delegation directly, seeding/inspecting
// the underlying quic.Stream buffers (the loopback harness lives in quic's
// test-only files and isn't importable here).
@(private = "file")
make_conn :: proc() -> quic.Conn {
	c: quic.Conn
	c.streams = make(map[u64]^quic.Stream)
	c.peer_tp.initial_max_streams_bidi = 16 // grant a bidi budget for stream_open(.Bidi)
	return c
}

@(private = "file")
free_conn :: proc(c: ^quic.Conn) {
	for _, s in c.streams do quic.stream_free(s)
	delete(c.streams)
}

@(test)
test_open_write_read_close :: proc(t: ^testing.T) {
	c := make_conn()
	defer free_conn(&c)

	s, err := stream_open(&c, .Bidi)
	testing.expect_value(t, err, Http3_Stream_Error.None)
	testing.expect_value(t, s, Http3_Stream(0)) // client-initiated bidi id 0

	testing.expect_value(t, stream_write(&c, s, transmute([]u8)string("hello")), Http3_Stream_Error.None)
	qs := quic.conn_get_stream(&c, 0)
	testing.expect_value(t, string(qs.tx_buffered[:]), "hello")

	// Simulate inbound delivery, then read back through the facade.
	append(&qs.rx_delivered, ..transmute([]u8)string("world"))
	buf: [16]u8
	n, eof, rerr := stream_read(&c, s, buf[:])
	testing.expect_value(t, rerr, Http3_Stream_Error.None)
	testing.expect_value(t, n, 5)
	testing.expect_value(t, string(buf[:n]), "world")
	testing.expect(t, !eof, "not eof while open")

	testing.expect_value(t, stream_close(&c, s), Http3_Stream_Error.None)
	testing.expect(t, qs.tx_fin, "close sets FIN")

	// Drained + peer-closed → eof.
	qs.rx_closed = true
	n2, eof2, _ := stream_read(&c, s, buf[:])
	testing.expect_value(t, n2, 0)
	testing.expect(t, eof2, "eof once closed + drained")
}

@(test)
test_unknown_and_reset :: proc(t: ^testing.T) {
	c := make_conn()
	defer free_conn(&c)

	buf: [4]u8
	_, _, err := stream_read(&c, Http3_Stream(99), buf[:])
	testing.expect_value(t, err, Http3_Stream_Error.Unknown_Stream)

	s, _ := stream_open(&c, .Bidi)
	qs := quic.conn_get_stream(&c, 0)
	qs.rx_aborted = true
	_, _, rerr := stream_read(&c, s, buf[:])
	testing.expect_value(t, rerr, Http3_Stream_Error.Reset)
	qs.tx_aborted = true
	testing.expect_value(t, stream_write(&c, s, []u8{1}), Http3_Stream_Error.Reset)
}

@(test)
test_uni_budget :: proc(t: ^testing.T) {
	c := make_conn()
	defer free_conn(&c)
	c.peer_tp.initial_max_streams_uni = 2

	a, ea := stream_open(&c, .Uni)
	b, eb := stream_open(&c, .Uni)
	_, ec := stream_open(&c, .Uni)
	testing.expect_value(t, ea, Http3_Stream_Error.None)
	testing.expect_value(t, eb, Http3_Stream_Error.None)
	testing.expect_value(t, ec, Http3_Stream_Error.Stream_Budget_Exhausted)
	testing.expect_value(t, a, Http3_Stream(2)) // client uni ids: 2, 6, 10
	testing.expect_value(t, b, Http3_Stream(6))
}

@(test)
test_bidi_alloc :: proc(t: ^testing.T) {
	// Each request gets a fresh client-bidi id: 0, 4, 8, ... (RFC 9000 §2.1).
	c := make_conn()
	defer free_conn(&c)
	a, ea := stream_open(&c, .Bidi)
	b, eb := stream_open(&c, .Bidi)
	d, ed := stream_open(&c, .Bidi)
	testing.expect_value(t, ea, Http3_Stream_Error.None)
	testing.expect_value(t, eb, Http3_Stream_Error.None)
	testing.expect_value(t, ed, Http3_Stream_Error.None)
	testing.expect_value(t, a, Http3_Stream(0))
	testing.expect_value(t, b, Http3_Stream(4))
	testing.expect_value(t, d, Http3_Stream(8))

	// Budget exhaustion.
	c.peer_tp.initial_max_streams_bidi = 3
	_, ex := stream_open(&c, .Bidi)
	testing.expect_value(t, ex, Http3_Stream_Error.Stream_Budget_Exhausted)
}

@(test)
test_io_stream_seam :: proc(t: ^testing.T) {
	c := make_conn()
	defer free_conn(&c)

	s, _ := stream_open(&c, .Bidi)
	qs := quic.conn_get_stream(&c, 0)

	ios, err := stream_to_io(&c, s)
	testing.expect_value(t, err, Http3_Stream_Error.None)

	// Write through the io.Stream writer → lands in the quic stream's tx queue.
	w := io.to_writer(ios)
	_, werr := io.write_string(w, "GET / HTTP/1.1\r\n")
	testing.expect_value(t, werr, io.Error.None)
	testing.expect_value(t, string(qs.tx_buffered[:]), "GET / HTTP/1.1\r\n")

	// Seed rx and read through the io.Stream reader.
	append(&qs.rx_delivered, ..transmute([]u8)string("hi there"))
	r := io.to_reader(ios)
	rbuf: [32]u8
	n, rerr := io.read(r, rbuf[:])
	testing.expect_value(t, rerr, io.Error.None)
	testing.expect_value(t, string(rbuf[:n]), "hi there")

	// No data left → .Empty (would-block), not EOF.
	_, e_empty := io.read(r, rbuf[:])
	testing.expect_value(t, e_empty, io.Error.Empty)

	// Peer finished + drained → EOF.
	qs.rx_closed = true
	_, e_eof := io.read(r, rbuf[:])
	testing.expect_value(t, e_eof, io.Error.EOF)
}

@(test)
test_poll :: proc(t: ^testing.T) {
	c := make_conn()
	defer free_conn(&c)
	p: Http3_Stream_Poller
	poller_init(&p)
	defer poller_destroy(&p)

	_, _ = stream_open(&c, .Bidi) // opens client-bidi id 0; we fetch it by id below
	qs := quic.conn_get_stream(&c, 0)
	append(&qs.rx_delivered, ..transmute([]u8)string("x"))

	ev: [dynamic]Http3_Stream_Event
	defer delete(ev)
	poll(&p, &c, &ev)

	opened, readable := 0, 0
	for e in ev {
		#partial switch _ in e {
		case Opened:   opened += 1
		case Readable: readable += 1
		}
	}
	testing.expect_value(t, opened, 1)
	testing.expect_value(t, readable, 1)

	// Drain + re-poll: Opened is edge-triggered (gone), Readable cleared.
	resize(&qs.rx_delivered, 0)
	clear(&ev)
	poll(&p, &c, &ev)
	testing.expect_value(t, len(ev), 0)
}
