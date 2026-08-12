// HTTP/3 connection layer (RFC 9114 §3–§6): brings up the control + QPACK
// unidirectional streams, exchanges SETTINGS, and maps requests/responses onto
package http3

import "core:mem"
import "core:testing"

import "../qpack"
import "../quic"

Http3_Error :: enum {
	None,
	Stream_Open_Failed,
	Transport,
	Frame,
	Qpack,
	Protocol,
}

@(private)
Stream_Role :: enum u8 {
	Unknown,
	Control,
	Qpack_Encoder,
	Qpack_Decoder,
}

// A request/response exchange carried on one bidi stream.
@(private)
Exchange :: struct {
	stream:       Http3_Stream,
	rx:           [dynamic]u8, // unparsed frame bytes
	headers:      [dynamic]qpack.Header,
	body:         [dynamic]u8,
	headers_done: bool,
	finished:     bool, // peer FIN seen
	delivered:    bool, // handed to the application (server side)
}

// An inbound peer unidirectional stream being classified + read.
@(private)
Uni_In :: struct {
	role:      Stream_Role,
	rx:        [dynamic]u8,
	type_read: bool,
}

Http3_Connection :: struct {
	conn:      ^quic.Conn,
	is_server: bool,
	allocator: mem.Allocator,

	// Local uni streams.
	control, qpack_enc, qpack_dec: Http3_Stream,

	local_settings:         Settings,
	peer_settings:          Settings,
	peer_settings_received: bool,

	// Decoder dynamic table (peer encoder stream instructions).
	qpack_dec_table:        qpack.Dynamic_Table,
	// Insert count last acknowledged via Insert Count Increment (our decoder stream).
	qpack_known_received:   u64,

	// Encoder dynamic table (our inserts on the QPACK encoder stream).
	qpack_enc_table:            qpack.Dynamic_Table,
	// Peer has acknowledged this many of our inserts (decoder-stream ICI).
	qpack_enc_known_received:   u64,
	// True after we sent Set Dynamic Table Capacity on the encoder stream.
	qpack_enc_capacity_sent:    bool,
	// Unacked field-section RICs by request/response stream id (for Section Ack).
	qpack_enc_section_ric:      map[u64]u64,

	poller: Http3_Stream_Poller,
	xs:     map[u64]^Exchange, // bidi streams
	unis:   map[u64]^Uni_In,   // inbound peer uni streams

	// Per-exchange buffered body cap (0 = unbounded; servers should set
	// it — bodies are assembled fully in memory before delivery).
	max_body_bytes: int,
}

// Bring up the connection: open control + QPACK encoder/decoder uni streams,
// write their stream-type prefixes, and send SETTINGS first on the control
// stream (RFC 9114 §6.2.1). The QUIC handshake must already be Connected.
// Default `settings` is DEFAULT_SETTINGS (QPACK max table capacity 4096).
// Pass an explicit Settings{qpack_max_table_capacity=0,...} for static-only.
h3_conn_init :: proc(
	h: ^Http3_Connection, conn: ^quic.Conn, is_server: bool,
	settings := DEFAULT_SETTINGS, allocator := context.allocator,
) -> Http3_Error {
	h.conn = conn
	h.is_server = is_server
	h.allocator = allocator
	h.local_settings = settings
	poller_init(&h.poller, allocator)
	h.xs.allocator = allocator
	h.unis.allocator = allocator

	qpack.dyn_init(&h.qpack_dec_table, int(settings.qpack_max_table_capacity), allocator)
	h.qpack_known_received = 0
	// Encoder max_capacity is filled in when peer SETTINGS arrive.
	qpack.dyn_init(&h.qpack_enc_table, 0, allocator)
	h.qpack_enc_known_received = 0
	h.qpack_enc_capacity_sent = false
	h.qpack_enc_section_ric.allocator = allocator

	ok: Http3_Stream_Error
	if h.control, ok = stream_open(conn, .Uni); ok != .None do return .Stream_Open_Failed
	if h.qpack_enc, ok = stream_open(conn, .Uni); ok != .None do return .Stream_Open_Failed
	if h.qpack_dec, ok = stream_open(conn, .Uni); ok != .None do return .Stream_Open_Failed

	scratch: [dynamic]u8
	scratch.allocator = allocator
	defer delete(scratch)

	stream_type_write(&scratch, STREAM_TYPE_CONTROL)
	frame_write_settings(&scratch, settings)
	stream_write(conn, h.control, scratch[:])

	clear(&scratch)
	stream_type_write(&scratch, STREAM_TYPE_QPACK_ENCODER)
	// Capacity / inserts follow peer SETTINGS (see _qpack_maybe_set_enc_capacity).
	stream_write(conn, h.qpack_enc, scratch[:])

	clear(&scratch)
	stream_type_write(&scratch, STREAM_TYPE_QPACK_DECODER)
	stream_write(conn, h.qpack_dec, scratch[:])
	return .None
}

h3_conn_destroy :: proc(h: ^Http3_Connection) {
	for _, x in h.xs {
		qpack.headers_destroy(x.headers[:], h.allocator)
		delete(x.headers)
		delete(x.body)
		delete(x.rx)
		free(x, h.allocator)
	}
	delete(h.xs)
	for _, u in h.unis {
		delete(u.rx)
		free(u, h.allocator)
	}
	delete(h.unis)
	qpack.dyn_destroy(&h.qpack_dec_table)
	qpack.dyn_destroy(&h.qpack_enc_table)
	delete(h.qpack_enc_section_ric)
	poller_destroy(&h.poller)
}

// Pull readable data off the connection's streams and advance state: classify
// peer uni streams, parse peer SETTINGS, and decode request/response frames.
h3_conn_process :: proc(h: ^Http3_Connection) -> Http3_Error {
	events: [dynamic]Http3_Stream_Event
	events.allocator = context.allocator
	defer delete(events)
	poll(&h.poller, h.conn, &events)
	for ev in events {
		#partial switch e in ev {
		case Readable:
			_drain(h, e.stream) or_return
		case Finished:
			_drain(h, e.stream) or_return
		}
	}
	return .None
}

@(private)
_drain :: proc(h: ^Http3_Connection, s: Http3_Stream) -> Http3_Error {
	id := u64(s)
	// Skip our own unidirectional streams (send-only: control + QPACK enc/dec).
	// Bidi streams are always drained — we read responses on streams we
	// initiated and requests on streams the peer initiated.
	if (id & 0x2) != 0 {
		peer_bit: u64 = h.is_server ? 0 : 1
		if (id & 0x1) != peer_bit do return .None
	}

	chunk: [dynamic]u8
	chunk.allocator = context.allocator
	defer delete(chunk)
	tmp: [4096]u8
	eof := false
	for {
		n, e, werr := stream_read(h.conn, s, tmp[:])
		if werr != .None do return .Transport
		if n > 0 do append(&chunk, ..tmp[:n])
		if e {
			eof = true
			break
		}
		if n == 0 do break
	}

	if (id & 0x2) != 0 {
		return _drain_uni(h, id, chunk[:])
	}
	return _drain_bidi(h, id, chunk[:], eof)
}

@(private)
_drain_uni :: proc(h: ^Http3_Connection, id: u64, data: []u8) -> Http3_Error {
	u := h.unis[id]
	if u == nil {
		u = new(Uni_In, h.allocator)
		u.rx.allocator = h.allocator
		h.unis[id] = u
	}
	append(&u.rx, ..data)

	if !u.type_read {
		stype, n, ok := quic.varint_decode(u.rx[:])
		if !ok do return .None // need more bytes for the type varint
		u.type_read = true
		switch stype {
		case STREAM_TYPE_CONTROL:       u.role = .Control
		case STREAM_TYPE_QPACK_ENCODER: u.role = .Qpack_Encoder
		case STREAM_TYPE_QPACK_DECODER: u.role = .Qpack_Decoder
		case:                           u.role = .Unknown
		}
		remove_range(&u.rx, 0, n)
	}

	switch u.role {
	case .Control:
		for {
			hdr, payload, consumed, ferr := frame_decode(u.rx[:])
			if ferr == .Incomplete do break
			if ferr != .None do return .Frame
			if hdr.ftype == FRAME_SETTINGS {
				s, se := settings_decode(payload)
				if se != .None do return .Frame
				h.peer_settings = s
				h.peer_settings_received = true
				_qpack_maybe_set_enc_capacity(h) or_return
			}
			// GOAWAY and others ignored for now.
			remove_range(&u.rx, 0, consumed)
		}
	case .Qpack_Encoder:
		// Peer encoder stream → our decoder dynamic table (RFC 9204 §4.3).
		if h.local_settings.qpack_max_table_capacity == 0 {
			// We advertised capacity 0; peer must not send instructions.
			// Still drain the buffer so it doesn't grow unbounded.
			clear(&u.rx)
			return .None
		}
		n, qe := qpack.qpack_decode_encoder_stream(&h.qpack_dec_table, u.rx[:])
		if qe != .None do return .Qpack
		if n > 0 do remove_range(&u.rx, 0, n)
		// Acknowledge new inserts promptly so the peer can reference them
		// without needing blocked streams.
		_qpack_send_ici(h) or_return
	case .Qpack_Decoder:
		// Peer decoder instructions: ICI / section acks for *our* encoder inserts.
		_qpack_handle_decoder_stream(h, &u.rx) or_return
	case .Unknown:
		// Leave bytes buffered; unknown uni streams are ignored.
	}
	return .None
}

// Emit Insert Count Increment for inserts not yet acknowledged.
@(private)
_qpack_send_ici :: proc(h: ^Http3_Connection) -> Http3_Error {
	delta := h.qpack_dec_table.insert_count - h.qpack_known_received
	if delta == 0 do return .None
	buf: [dynamic]u8
	buf.allocator = context.temp_allocator
	defer delete(buf)
	qpack.qpack_encode_insert_count_increment(&buf, delta)
	if stream_write(h.conn, h.qpack_dec, buf[:]) != .None do return .Transport
	h.qpack_known_received = h.qpack_dec_table.insert_count
	return .None
}

// Emit Section Acknowledgment after decoding a field section with RIC > 0.
@(private)
_qpack_send_section_ack :: proc(h: ^Http3_Connection, stream_id: u64) -> Http3_Error {
	buf: [dynamic]u8
	buf.allocator = context.temp_allocator
	defer delete(buf)
	qpack.qpack_encode_section_ack(&buf, stream_id)
	if stream_write(h.conn, h.qpack_dec, buf[:]) != .None do return .Transport
	return .None
}

// After peer SETTINGS: open our encoder table to min(peer max, our default).
@(private)
_qpack_maybe_set_enc_capacity :: proc(h: ^Http3_Connection) -> Http3_Error {
	if h.qpack_enc_capacity_sent do return .None
	peer_cap := h.peer_settings.qpack_max_table_capacity
	if peer_cap == 0 do return .None
	// Cap at what we ourselves are willing to use (same default as decoder).
	cap := peer_cap
	if cap > DEFAULT_QPACK_MAX_TABLE_CAPACITY do cap = DEFAULT_QPACK_MAX_TABLE_CAPACITY
	h.qpack_enc_table.max_capacity = int(cap)
	if se := qpack.dyn_set_capacity(&h.qpack_enc_table, int(cap)); se != .None do return .Qpack
	buf: [dynamic]u8
	buf.allocator = context.temp_allocator
	defer delete(buf)
	qpack.qpack_encode_set_capacity(&buf, cap)
	if stream_write(h.conn, h.qpack_enc, buf[:]) != .None do return .Transport
	h.qpack_enc_capacity_sent = true
	return .None
}

// Apply peer decoder-stream instructions to our encoder known-received count.
@(private)
_qpack_handle_decoder_stream :: proc(h: ^Http3_Connection, rx: ^[dynamic]u8) -> Http3_Error {
	events: [dynamic]qpack.Decoder_Stream_Event
	events.allocator = context.temp_allocator
	defer delete(events)
	n, qe := qpack.qpack_decode_decoder_stream(rx[:], &events)
	if qe != .None do return .Qpack
	if n > 0 do remove_range(rx, 0, n)
	for ev in events {
		switch ev.kind {
		case .Insert_Count_Increment:
			h.qpack_enc_known_received += ev.increment
		case .Section_Ack:
			if ric, ok := h.qpack_enc_section_ric[ev.stream_id]; ok {
				delete_key(&h.qpack_enc_section_ric, ev.stream_id)
				if ric > h.qpack_enc_known_received {
					h.qpack_enc_known_received = ric
				}
			}
		case .Stream_Cancellation:
			delete_key(&h.qpack_enc_section_ric, ev.stream_id)
		}
	}
	return .None
}

@(private)
_drain_bidi :: proc(h: ^Http3_Connection, id: u64, data: []u8, eof: bool) -> Http3_Error {
	x := h.xs[id]
	if x == nil {
		x = new(Exchange, h.allocator)
		x.stream = Http3_Stream(id)
		x.rx.allocator = h.allocator
		x.headers.allocator = h.allocator
		x.body.allocator = h.allocator
		h.xs[id] = x
	}
	append(&x.rx, ..data)

	for {
		hdr, payload, consumed, ferr := frame_decode(x.rx[:])
		if ferr == .Incomplete do break
		if ferr != .None do return .Frame
		switch hdr.ftype {
		case FRAME_HEADERS:
			dt: ^qpack.Dynamic_Table = nil
			if h.local_settings.qpack_max_table_capacity > 0 {
				dt = &h.qpack_dec_table
			}
			hs, ric, qe := qpack.qpack_decode_field_section(payload, h.allocator, dt)
			if qe != .None {
				qpack.headers_destroy(hs[:], h.allocator)
				delete(hs)
				return .Qpack
			}
			for entry in hs do append(&x.headers, entry)
			delete(hs) // frees the array; the Header strings now belong to x.headers
			x.headers_done = true
			if ric > 0 {
				_qpack_send_section_ack(h, id) or_return
			}
		case FRAME_DATA:
			if h.max_body_bytes > 0 && len(x.body) + len(payload) > h.max_body_bytes do return .Frame
			append(&x.body, ..payload)
		}
		remove_range(&x.rx, 0, consumed)
	}
	if eof do x.finished = true
	return .None
}


// Open a bidi stream and send a request (HEADERS [+ DATA]), then FIN. Returns
// the stream token to correlate the response. `headers` should include the
// request pseudo-headers (:method, :scheme, :authority, :path).
h3_send_request :: proc(
	h: ^Http3_Connection, headers: []qpack.Header, body: []u8 = nil,
) -> (Http3_Stream, Http3_Error) {
	s, e := stream_open(h.conn, .Bidi)
	if e != .None do return s, .Stream_Open_Failed
	if werr := _write_headers(h, s, headers); werr != .None do return s, werr
	if werr := _write_data(h, s, body); werr != .None do return s, werr
	stream_close(h.conn, s)
	return s, .None
}

h3_response :: proc(
	h: ^Http3_Connection, s: Http3_Stream,
) -> (headers: []qpack.Header, body: []u8, done: bool) {
	x := h.xs[u64(s)]
	if x == nil || !x.finished do return nil, nil, false
	return x.headers[:], x.body[:], true
}


h3_next_request :: proc(
	h: ^Http3_Connection,
) -> (s: Http3_Stream, headers: []qpack.Header, body: []u8, ok: bool) {
	for id, x in h.xs {
		if x.finished && !x.delivered {
			x.delivered = true
			return Http3_Stream(id), x.headers[:], x.body[:], true
		}
	}
	return {}, nil, nil, false
}

// Graceful shutdown (RFC 9114 §5.2): tell the peer which requests we did (or
// will) process — a server passes the lowest UNHANDLED client-bidi stream id;
// requests at or above it can be retried elsewhere.
h3_send_goaway :: proc(h: ^Http3_Connection, id: u64) -> Http3_Error {
	frame: [dynamic]u8
	frame.allocator = context.temp_allocator
	defer delete(frame)
	frame_write_goaway(&frame, id)
	if stream_write(h.conn, h.control, frame[:]) != .None do return .Transport
	return .None
}

// Chunk large DATA frames so a peer can decode progressively and so a single
// STREAM packet never has to buffer an entire multi-megabyte TLV length.
H3_DATA_CHUNK :: 16 * 1024

// Send HEADERS only (no DATA, no FIN). Used when a host body pump will follow
// (static files). Pair with h3_send_data + h3_send_fin.
// `headers` should include the :status pseudo-header.
h3_send_response_headers :: proc(
	h: ^Http3_Connection, s: Http3_Stream, headers: []qpack.Header,
) -> Http3_Error {
	return _write_headers(h, s, headers)
}

// Append body as one or more DATA frames (no FIN). Safe to call repeatedly.
h3_send_data :: proc(h: ^Http3_Connection, s: Http3_Stream, body: []u8) -> Http3_Error {
	if len(body) == 0 do return .None
	return _write_data(h, s, body)
}

// Close the response send side (QUIC FIN). Idempotent at transport layer.
h3_send_fin :: proc(h: ^Http3_Connection, s: Http3_Stream) -> Http3_Error {
	if stream_close(h.conn, s) != .None do return .Transport
	return .None
}

// Send a response (HEADERS [+ DATA]) on the request's bidi stream, then FIN.
// `headers` should include the :status pseudo-header.
h3_send_response :: proc(
	h: ^Http3_Connection, s: Http3_Stream, headers: []qpack.Header, body: []u8 = nil,
) -> Http3_Error {
	if werr := _write_headers(h, s, headers); werr != .None do return werr
	if werr := _write_data(h, s, body); werr != .None do return werr
	return h3_send_fin(h, s)
}

@(private)
_write_headers :: proc(
	h: ^Http3_Connection, s: Http3_Stream, headers: []qpack.Header,
) -> Http3_Error {
	// Ensure encoder capacity is advertised if peer SETTINGS already landed.
	_qpack_maybe_set_enc_capacity(h) or_return

	enc_stream: [dynamic]u8
	enc_stream.allocator = context.allocator
	defer delete(enc_stream)

	opts: qpack.Qpack_Encode_Opts
	if h.qpack_enc_table.capacity > 0 {
		opts = qpack.Qpack_Encode_Opts {
			enc_dt         = &h.qpack_enc_table,
			enc_stream     = &enc_stream,
			known_received = h.qpack_enc_known_received,
			// Peers advertising blocked_streams = 0 must not see RIC ahead of
			// their table; only index known-received entries.
			allow_unacked  = h.peer_settings.qpack_blocked_streams > 0,
		}
	}

	block: [dynamic]u8
	block.allocator = context.allocator
	defer delete(block)
	ric := qpack.qpack_encode_field_section(&block, headers, true, opts)

	// Encoder-stream inserts / capacity first so the peer can process them
	// before (or with) the field section on the request stream.
	if len(enc_stream) > 0 {
		if stream_write(h.conn, h.qpack_enc, enc_stream[:]) != .None do return .Transport
	}

	// Track RIC for Section Acknowledgment → known_received.
	if ric > 0 {
		h.qpack_enc_section_ric[u64(s)] = ric
	}

	frame: [dynamic]u8
	frame.allocator = context.allocator
	defer delete(frame)
	frame_write_headers(&frame, block[:])
	if stream_write(h.conn, s, frame[:]) != .None do return .Transport
	return .None
}

@(private)
_write_data :: proc(h: ^Http3_Connection, s: Http3_Stream, body: []u8) -> Http3_Error {
	if len(body) == 0 do return .None
	frame: [dynamic]u8
	frame.allocator = context.allocator
	defer delete(frame)
	// Stream DATA in chunks (not one giant frame). Clears the old
	// "64 KiB body never finishes under cwnd + single Incomplete frame" stall.
	for off := 0; off < len(body); {
		n := min(H3_DATA_CHUNK, len(body) - off)
		clear(&frame)
		frame_write_data(&frame, body[off:off + n])
		if stream_write(h.conn, s, frame[:]) != .None do return .Transport
		off += n
	}
	return .None
}


// ///////////////////////////////////////////////////////////////
//                         Tests
// ///////////////////////////////////////////////////////////////


// Test cert + key copied from quic's loopback_test.odin (those live in quic's
// test-only files, so they aren't importable from package h3).
TEST_KEY_PEM := `-----BEGIN RSA PRIVATE KEY-----
MIIEowIBAAKCAQEAz105EYUbOdW5uJ8o/TqtxtOtKJL7AQdy5yiXoslosAsulaew
4JSJetVa6Fa6Bq5BK6fsphGD9bpGGeiBZFBt75JRjOrkj4DwlLGa0CPLTgG5hul4
Ufe9B7VG3J5P8OwUqIYmPzj8uTbNtkgFRcYumHR28h4GkYdG5Y04AV4vIjgKE47j
AgV5ACRHkcmGrTzF2HOes2wT73l4yLSkKR4GlIWu5cLRdI8PTUmjMFAh/GIh1ahd
+VqXz051V3jok0n1klVNjc6DnWuH3j/MSOg/52C3YfcUjCeIJGVfcqDnPTJKSNEF
yVTYCUjWy+B0B4fMz3MpU17dDWpvS5hfc4VrgQIDAQABAoIBAQCq+i208XBqdnwk
6y7r5Tcl6qErBE3sIk0upjypX7Ju/TlS8iqYckENQ+AqFGBcY8+ehF5O68BHm2hz
sk8F/H84+wc8zuzYGjPEFtEUb38RecCUqeqog0Gcmm6sN+ioOLAr6DifBojy2mox
sx6N0oPW9qigp/s4gTcGzTLxhcwNRHWuoWjQwq6y6qwt2PJXnllii5B5iIJhKAxE
EOmcVCmFbPavQ1Xr9F5jd5rRc1TYq28hXX8dZN2JhdVUbLlHzaiUfTnA/8yI4lyq
bEmqu29Oqe+CmDtB6jRnrLiIwyZxzXKuxXaO6NqgxqtaVjLcdISEgZMeHEftuOtf
C1xxodaVAoGBAOb1Y1SvUGx+VADSt1d30h3bBm1kU/1LhLKZOAQrnFMrEfyOfYbz
AZ4FJgXE6ZsB1BA7hC0eJDVHz8gTgDJQrOOO8WJWDGRe4TbZkCi5IizYg5UH/6az
I/WKlfdA4j1tftbQhycHL+9bGzdoRzrwIK489PG4oVAJJCaK2CVtx+l3AoGBAOXY
75sHOiMaIvDA7qlqFbaBkdi1NzH7bCgy8IntNfLxlOCmGjxeNZzKrkode3JWY9SI
Mo/nuWj8EZBEHj5omCapzOtkW/Nhnzc4C6U3BCspdrQ4mzbmzEGTdhqvxepa7U7K
iRcoD1iU7kINCEwg2PsB/BvCSrkn6lpIJlYXlJDHAoGAY7QjgXd9fJi8ou5Uf8oW
RxU6nRbmuz5Sttc2O3aoMa8yQJkyz4Mwe4s1cuAjCOutJKTM1r1gXC/4HyNsAEyb
llErG4ySJPJgv1EEzs+9VSbTBw9A6jIDoAiH3QmBoYsXapzy+4I6y1XFVhIKTgND
2HQwOfm+idKobIsb7GyMFNkCgYBIsixWZBrHL2UNsHfLrXngl2qBmA81B8hVjob1
mMkPZckopGB353Qdex1U464/o4M/nTQgv7GsuszzTBgktQAqeloNuVg7ygyJcnh8
cMIoxJx+s8ijvKutse4Q0rdOQCP+X6CsakcwRSp2SZjuOxVljmMmhHUNysocc+Vs
JVkf0QKBgHiCVLU60EoPketADvhRJTZGAtyCMSb3q57Nb0VIJwxdTB5KShwpul1k
LPA8Z7Y2i9+IEXcPT0r3M+hTwD7noyHXNlNuzwXot4B8PvbgKkMLyOpcwBjppJd7
ns4PifoQbhDFnZPSfnrpr+ZXSEzxtiyv7Ql69jznl/vB8b75hBL4
-----END RSA PRIVATE KEY-----`

TEST_CERT_PEM := `-----BEGIN CERTIFICATE-----
MIIDLDCCAhSgAwIBAgIIIXlwQVKrtaAwDQYJKoZIhvcNAQELBQAwIDEeMBwGA1UE
AxMVbWluaWNhIHJvb3QgY2EgMmJiOTlkMB4XDTIxMDIwMjE0NDYzNFoXDTIzMDMw
NDE0NDYzNFowFDESMBAGA1UEAxMJbG9jYWxob3N0MIIBIjANBgkqhkiG9w0BAQEF
AAOCAQ8AMIIBCgKCAQEAz105EYUbOdW5uJ8o/TqtxtOtKJL7AQdy5yiXoslosAsu
laew4JSJetVa6Fa6Bq5BK6fsphGD9bpGGeiBZFBt75JRjOrkj4DwlLGa0CPLTgG5
hul4Ufe9B7VG3J5P8OwUqIYmPzj8uTbNtkgFRcYumHR28h4GkYdG5Y04AV4vIjgK
E47jAgV5ACRHkcmGrTzF2HOes2wT73l4yLSkKR4GlIWu5cLRdI8PTUmjMFAh/GIh
1ahd+VqXz051V3jok0n1klVNjc6DnWuH3j/MSOg/52C3YfcUjCeIJGVfcqDnPTJK
SNEFyVTYCUjWy+B0B4fMz3MpU17dDWpvS5hfc4VrgQIDAQABo3YwdDAOBgNVHQ8B
Af8EBAMCBaAwHQYDVR0lBBYwFAYIKwYBBQUHAwEGCCsGAQUFBwMCMAwGA1UdEwEB
/wQCMAAwHwYDVR0jBBgwFoAULXa6lBiO7OLL5Z6XuF5uF5wR9PQwFAYDVR0RBA0w
C4IJbG9jYWxob3N0MA0GCSqGSIb3DQEBCwUAA4IBAQBOMkNXfzPEDU475zbiSi3v
JOhpZLyuoaYY62RzZc9VF8YRybJlWKUWdR3szAiUd1xCJe/beNX7b9lPg6wNadKq
DGTWFmVxSfpVMO9GQYBXLDcNaAUXzsDLC5sbAFST7jkAJELiRn6KtQYxZ2kEzo7G
QmzNMfNMc1KeL8Qr4nfEHZx642yscSWj9edGevvx4o48j5KXcVo9+pxQQFao9T2O
F5QxyGdov+uNATWoYl92Gj8ERi7ovHimU3H7HLIwNPqMJEaX4hH/E/Oz56314E9b
AXVFFIgCSluyrolaD6CWD9MqOex4YOfJR2bNxI7lFvuK4AwjyUJzT1U1HXib17mM
-----END CERTIFICATE-----`

@(private)
h3_tp :: proc() -> quic.Transport_Params {
	return quic.Transport_Params {
		max_idle_timeout                    = 30_000,
		max_udp_payload_size                = 1472,
		initial_max_data                    = 10 * 1024 * 1024,
		initial_max_stream_data_bidi_local  = 1 * 1024 * 1024,
		initial_max_stream_data_bidi_remote = 1 * 1024 * 1024,
		initial_max_stream_data_uni         = 1 * 1024 * 1024,
		initial_max_streams_bidi            = 16,
		initial_max_streams_uni             = 16,
		ack_delay_exponent                  = 3,
		max_ack_delay                       = 25,
		active_connection_id_limit          = 2,
		max_datagram_frame_size             = 65527,
		disable_active_migration            = true,
	}
}

// Stand up two connected quic.Conns via the in-memory handshake dance (mirrors
// quic's loopback tests).
@(private = "file")
loopback_connect :: proc() -> (client, server: ^quic.Conn) {
	alpn := [3]u8{2, 'h', '3'} // ALPN wire form of "h3"
	client, _ = quic.conn_new("localhost", alpn[:], h3_tp())
	quic.conn_disable_verify(client)
	server, _ = quic.conn_new_server(
		transmute([]u8)string(TEST_CERT_PEM),
		transmute([]u8)string(TEST_KEY_PEM),
		h3_tp(),
	)

	quic.conn_start_handshake(client)
	pkt: [2048]u8
	cn, _ := quic.conn_build_initial_packet(client, pkt[:])
	quic.conn_on_udp_recv(server, pkt[:cn])

	s_init: [2048]u8
	si, _ := quic.conn_build_initial_packet(server, s_init[:])
	s_hs: [2048]u8
	sh, _ := quic.conn_build_handshake_packet(server, s_hs[:])
	quic.conn_on_udp_recv(client, s_init[:si])
	quic.conn_on_udp_recv(client, s_hs[:sh])

	c_hs: [2048]u8
	ch, _ := quic.conn_build_handshake_packet(client, c_hs[:])
	quic.conn_on_udp_recv(server, c_hs[:ch])
	return
}

// Shuttle 1-RTT stream packets both directions until quiescent.
@(private = "file")
pump :: proc(a, b: ^quic.Conn) {
	buf: [2048]u8
	for _ in 0 ..< 64 {
		moved := false
		for {
			n, _, _ := quic.conn_build_stream_packet(a, buf[:])
			if n == 0 do break
			quic.conn_on_udp_recv(b, buf[:n])
			moved = true
		}
		for {
			n, _, _ := quic.conn_build_stream_packet(b, buf[:])
			if n == 0 do break
			quic.conn_on_udp_recv(a, buf[:n])
			moved = true
		}
		if !moved do break
	}
}

@(test)
test_h3_loopback_request_response :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	cc, sc := loopback_connect()
	defer quic.conn_free(cc)
	defer quic.conn_free(sc)
	testing.expect_value(t, cc.state, quic.Conn_State.Connected)
	testing.expect_value(t, sc.state, quic.Conn_State.Connected)

	client: Http3_Connection
	server: Http3_Connection
	testing.expect_value(t, h3_conn_init(&client, cc, false), Http3_Error.None)
	testing.expect_value(t, h3_conn_init(&server, sc, true), Http3_Error.None)
	defer h3_conn_destroy(&client)
	defer h3_conn_destroy(&server)

	pump(cc, sc)
	testing.expect_value(t, h3_conn_process(&client), Http3_Error.None)
	testing.expect_value(t, h3_conn_process(&server), Http3_Error.None)
	testing.expect(t, client.peer_settings_received, "client received server SETTINGS")
	testing.expect(t, server.peer_settings_received, "server received client SETTINGS")

	req := []qpack.Header {
		{name = ":method", value = "GET"},
		{name = ":scheme", value = "https"},
		{name = ":authority", value = "localhost"},
		{name = ":path", value = "/"},
		{name = "user-agent", value = "odin-http-h3"},
	}
	rs, rerr := h3_send_request(&client, req)
	testing.expect_value(t, rerr, Http3_Error.None)

	pump(cc, sc)
	testing.expect_value(t, h3_conn_process(&server), Http3_Error.None)

	req_stream, got_headers, _, ok := h3_next_request(&server)
	testing.expect(t, ok, "server received a request")
	method_ok, path_ok := false, false
	for hh in got_headers {
		if hh.name == ":method" && hh.value == "GET" do method_ok = true
		if hh.name == ":path" && hh.value == "/" do path_ok = true
	}
	testing.expect(t, method_ok, "decoded :method GET")
	testing.expect(t, path_ok, "decoded :path /")

	resp := []qpack.Header{{name = ":status", value = "200"}, {name = "content-type", value = "text/plain"}}
	serr := h3_send_response(&server, req_stream, resp, transmute([]u8)string("hello h3"))
	testing.expect_value(t, serr, Http3_Error.None)

	pump(cc, sc)
	testing.expect_value(t, h3_conn_process(&client), Http3_Error.None)

	r_headers, r_body, done := h3_response(&client, rs)
	testing.expect(t, done, "client received the response")
	status_ok := false
	for hh in r_headers do if hh.name == ":status" && hh.value == "200" do status_ok = true
	testing.expect(t, status_ok, "decoded :status 200")
	testing.expect_value(t, string(r_body), "hello h3")
}
