package quic

import "core:c"
import "core:os"

// Receive path — parses inbound UDP datagrams, decrypts packets, feeds
// CRYPTO bytes into the OpenSSL pull FIFO, and drives the handshake forward.
// A single UDP datagram may contain multiple coalesced QUIC packets at
// different encryption levels (§12.2). For example, a server's first flight
// typically packs Initial + Handshake into one datagram. We walk the
// datagram, decrypting each packet in turn.

// Parsed long-header fields, plus offsets we need for HP removal + AEAD.
Long_Header :: struct {
	first_byte:     u8,
	long_type:      u8,
	version:        u32,
	dcid:           []u8,
	scid:           []u8,
	token:          []u8, // Initial only
	pn_offset:      int,  // byte index of packet number field
	length_end:     int,  // first byte after the "length" varint
	payload_length: int,  // value of the Length varint (pn_len + ct_len)
	total_packet_len: int, // pn_offset + payload_length (full packet span)
}

Recv_Error :: enum {
	None,
	Truncated,
	Bad_Header,
	Unsupported_Version,
	Decrypt_Failed,
	Keys_Unavailable,
	Bad_Frame,
	Bad_Crypto_Offset,
	Tls_Advance_Failed,
}

// Parse the long header of one packet starting at `buf[0]`. On success,
// populates `hdr` with offsets and lengths; the caller still needs to run
// header protection + AEAD to recover the packet number and payload.
parse_long_header :: proc(buf: []u8, hdr: ^Long_Header) -> Recv_Error {
	if len(buf) < 7 do return .Truncated

	hdr.first_byte = buf[0]
	// Long header + fixed bit.
	if (buf[0] & 0xc0) != 0xc0 do return .Bad_Header
	hdr.long_type = (buf[0] >> 4) & 0x03

	pos := 1

	// Version.
	if pos + 4 > len(buf) do return .Truncated
	hdr.version = u32(buf[pos]) << 24 | u32(buf[pos+1]) << 16 |
	              u32(buf[pos+2]) << 8 | u32(buf[pos+3])
	pos += 4
	if hdr.version != QUIC_VERSION_V1 do return .Unsupported_Version

	// DCID.
	if pos >= len(buf) do return .Truncated
	dcid_len := int(buf[pos]); pos += 1
	if dcid_len > 20 || pos + dcid_len > len(buf) do return .Truncated
	hdr.dcid = buf[pos : pos + dcid_len]
	pos += dcid_len

	// SCID.
	if pos >= len(buf) do return .Truncated
	scid_len := int(buf[pos]); pos += 1
	if scid_len > 20 || pos + scid_len > len(buf) do return .Truncated
	hdr.scid = buf[pos : pos + scid_len]
	pos += scid_len

	// Initial has Token Length + Token before the payload Length.
	if hdr.long_type == Long_Type_Initial {
		token_len, tn, tok := varint_decode(buf[pos:])
		if !tok do return .Truncated
		pos += tn
		if pos + int(token_len) > len(buf) do return .Truncated
		hdr.token = buf[pos : pos + int(token_len)]
		pos += int(token_len)
	}

	// Payload Length (varint). This is (pn_len + ciphertext_len).
	length_val, ln, lok := varint_decode(buf[pos:])
	if !lok do return .Truncated
	pos += ln

	hdr.pn_offset  = pos
	hdr.length_end = pos
	hdr.payload_length = int(length_val)
	hdr.total_packet_len = pos + int(length_val)

	if hdr.total_packet_len > len(buf) do return .Truncated
	return .None
}

// Decrypt one long-header packet starting at `buf[0]` using the given keys.
// Mutates `buf` in place: header protection is removed and the AEAD payload
// is decrypted over the ciphertext region. Returns the plaintext slice (a
// view into `buf`) and the packet number.
// On return, `consumed` holds the number of bytes this packet occupied in
// the UDP datagram so the caller can advance to the next coalesced packet.
decrypt_long_packet :: proc(
	buf:  []u8,
	keys: ^Packet_Keys,
) -> (plaintext: []u8, pn: u64, consumed: int, err: Recv_Error) {
	hdr: Long_Header
	if perr := parse_long_header(buf, &hdr); perr != .None do return nil, 0, 0, perr

	packet := buf[:hdr.total_packet_len]
	consumed = hdr.total_packet_len

	pn_len, ok_hp := remove_header_protection(packet, hdr.pn_offset, keys, true)
	if !ok_hp do return nil, 0, 0, .Decrypt_Failed
	if hdr.pn_offset + pn_len > len(packet) do return nil, 0, 0, .Truncated

	// Reconstruct packet number (truncated; a full impl would use the
	// largest-acked packet number to rebuild the high bits per RFC 9000 §A.3.
	// For our first-flight + response-flight use case, PNs are small enough
	// that truncation is an identity operation).
	truncated_pn: u64 = 0
	for i in 0..<pn_len {
		truncated_pn = (truncated_pn << 8) | u64(packet[hdr.pn_offset + i])
	}
	pn = truncated_pn

	header_len := hdr.pn_offset + pn_len
	ciphertext := packet[header_len:]

	nonce: [QUIC_IV_LEN]u8
	make_nonce(&nonce, keys.iv[:], pn)

	pt_len, open_ok := aead_open(keys, ciphertext, nonce[:], ciphertext, packet[:header_len])
	if !open_ok do return nil, 0, 0, .Decrypt_Failed

	return ciphertext[:pt_len], pn, consumed, .None
}

// --- Frame processing ---

// Process all frames inside a decrypted packet payload. Feeds CRYPTO data
// into the TLS FIFO and schedules ACKs for packets that contain
// ack-eliciting frames. CRYPTO is only appended during the frame loop;
// a single tls_drive runs after all frames (P-WOW-1).
process_frames :: proc(
	conn:   ^Conn,
	level:  Encryption_Level,
	payload: []u8,
) -> Recv_Error {
	pos := 0
	ack_eliciting := false
	fed_crypto := false

	for pos < len(payload) {
		frame, n, fe := frame_decode(payload[pos:])
		if fe != .None do return .Bad_Frame
		pos += n

		switch f in frame {
		case Padding_Frame:
			// Not ack-eliciting.

		case Ping_Frame:
			ack_eliciting = true

		case Ack_Frame:
			conn.stats.ack_frames_received += 1
			if level == .Application {
				loss_on_ack(conn, f)
			}

		case Crypto_Frame:
			ack_eliciting = true
			perr, fed := _handle_crypto_frame(conn, level, f)
			if perr != .None {
				return perr
			}
			if fed do fed_crypto = true

		case Connection_Close_Frame:
			conn.state = .Closing
			conn.peer_close_code = f.error_code
			conn.peer_close_is_app = f.is_app
			conn.peer_close_reason_len = copy(conn.peer_close_reason[:], f.reason)
			return .None

		case Datagram_Frame:
			conn.stats.datagram_frames_received += 1
			if level == .Application {
				_rx_datagram_push(conn, f.data)
			}
			ack_eliciting = true

		case Stream_Frame:
			conn.stats.stream_frames_received += 1
			conn.stats.stream_bytes_received += u64(len(f.data))
			if level == .Application {
				_handle_stream_frame(conn, f)
			}
			ack_eliciting = true

		case Max_Stream_Data_Frame:
			// Bump the local view of the peer's flow-control window.
			_handle_max_stream_data(conn, f)
			ack_eliciting = true

		case Max_Data_Frame:
			_handle_max_data(conn, f)
			ack_eliciting = true

		case Reset_Stream_Frame:
			// Peer aborted their send half of this stream (RFC 9000 §3.5).
			// Mark the rx half dead; pending fragments are now garbage.
			if s := conn_get_stream(conn, f.stream_id); s != nil {
				s.rx_aborted = true
				s.rx_closed  = true
				for frag in s.rx_fragments do delete(frag.data)
				clear(&s.rx_fragments)
				clear(&s.rx_delivered)
			}
			ack_eliciting = true

		case Stop_Sending_Frame:
			// Peer asked us to stop sending on this stream (§3.5). Drop
			// queued tx bytes and quiet the packet builder for this id.
			// We don't currently reciprocate with RESET_STREAM — the
			// peer's request is enough to silence us.
			if s := conn_get_stream(conn, f.stream_id); s != nil {
				s.tx_aborted = true
				clear(&s.tx_buffered)
				s.tx_sent_off = 0
				s.tx_acked_off = 0
			}
			ack_eliciting = true

		case Max_Streams_Frame:
			// Peer raised our stream-open cap. Bump the matching field so
			// conn_open_uni / open_bi don't keep refusing new opens.
			if f.is_uni {
				if f.max_count > conn.peer_tp.initial_max_streams_uni {
					conn.peer_tp.initial_max_streams_uni = f.max_count
				}
			} else {
				if f.max_count > conn.peer_tp.initial_max_streams_bidi {
					conn.peer_tp.initial_max_streams_bidi = f.max_count
				}
			}
			ack_eliciting = true

		case Handshake_Done_Frame:
			// Server confirms the handshake: our Finished arrived, so the
			// Handshake level retires — stop any PTO retransmission of it.
			conn.handshake_done_received = true
			_crypto_level_discard(&conn.handshake)

		case Unhandled_Frame:
			// Parse-and-ignore (DATA_BLOCKED, MAX_STREAMS, etc.).
			// Some are ack-eliciting per RFC 9000 §13.2 but it's safe to
			// treat them all as such.
			ack_eliciting = true
		}
	}

	// Coalesce: one TLS drive after all CRYPTO in this packet is in the FIFO.
	if fed_crypto {
		if !tls_drive(conn) {
			// tls_drive already queues CONNECTION_CLOSE on hard failure.
			return .Tls_Advance_Failed
		}
	}

	// Mark this packet's space as needing an ACK.
	if ack_eliciting {
		_mark_ack_elicited(conn, level)
	}
	return .None
}

// --- Stream frame handlers (real implementations live in conn_stream.odin) ---

@(private)
_handle_stream_frame :: proc(conn: ^Conn, frame: Stream_Frame) {
	// Lazy-create the stream entry on first inbound frame. RFC 9000 §2.1:
	// streams are implicitly created by the first frame referencing them.
	// Multi-stream mode relies on this so each priority's uni stream is
	// instantiated when the peer's first STREAM frame for it arrives.
	s := conn_get_or_open_stream(conn, frame.stream_id)
	pre := s.rx_next_offset
	stream_on_stream_frame(s, frame)
	delivered := s.rx_next_offset - pre
	if delivered == 0 do return

	// Connection-level flow control bookkeeping. RFC 9000 §4.1: the
	// receiver counts every byte that crossed into rx_delivered against
	// its advertised cap and bumps it via MAX_DATA before the peer would
	// otherwise stall.
	conn.rx_data_received += delivered
	if conn.rx_data_received > conn.rx_our_max_data / 2 {
		conn.rx_our_max_data = conn.rx_data_received + conn.local_tp.initial_max_data
		conn.rx_max_data_pending = true
	}
}

@(private)
_handle_max_stream_data :: proc(conn: ^Conn, frame: Max_Stream_Data_Frame) {
	s := conn_get_stream(conn, frame.stream_id)
	if s == nil do return
	if frame.max_data > s.tx_peer_max_data {
		s.tx_peer_max_data = frame.max_data
	}
}

@(private)
_handle_max_data :: proc(conn: ^Conn, frame: Max_Data_Frame) {
	if frame.max_data > conn.tx_peer_max_data {
		conn.tx_peer_max_data = frame.max_data
	}
}

// Handle a CRYPTO frame: update offset + append to FIFO only (no tls_drive).
// Returns fed=true when new bytes were appended for a later coalesced drive.
@(private)
_handle_crypto_frame :: proc(
	conn:  ^Conn,
	level: Encryption_Level,
	frame: Crypto_Frame,
) -> (err: Recv_Error, fed: bool) {
	lvl := _level_for(conn, level)
	if lvl == nil do return .Bad_Frame, false

	// Simplified: require in-order CRYPTO delivery. TLS 1.3 on loopback
	// will not reorder, and retransmitted CRYPTO from the peer will re-send
	// starting at lvl.rx_crypto_offset.
	if frame.offset < lvl.rx_crypto_offset {
		// Overlapping retransmit — skip the portion we already have.
		skip := int(lvl.rx_crypto_offset - frame.offset)
		if skip >= len(frame.data) do return .None, false
		data := frame.data[skip:]
		return _feed_crypto_only(conn, level, data)
	}
	if frame.offset > lvl.rx_crypto_offset {
		// Gap we can't fill yet. A full implementation would buffer and
		// reorder; we return an error so tests catch out-of-order arrival.
		return .Bad_Crypto_Offset, false
	}
	return _feed_crypto_only(conn, level, frame.data)
}

// Append CRYPTO bytes to the OpenSSL pull-model FIFO and advance the level
// offset. Caller is responsible for tls_drive (P-WOW-1 coalesce).
@(private)
_feed_crypto_only :: proc(
	conn:  ^Conn,
	level: Encryption_Level,
	data:  []u8,
) -> (err: Recv_Error, fed: bool) {
	lvl := _level_for(conn, level)
	if lvl == nil do return .Bad_Frame, false
	if len(data) == 0 do return .None, false

	if !crypto_fifo_append(&conn.tls_fifo, data) {
		return .Tls_Advance_Failed, false
	}
	lvl.rx_crypto_offset += u64(len(data))
	return .None, true
}

@(private)
_print_ssl_error :: proc() {
	if !os_ensure() do return
	buf: [256]u8
	for {
		e := g_os.ERR_get_error()
		if e == 0 do break
		g_os.ERR_error_string_n(e, &buf[0], 256)
		n := 0
		for n < 256 && buf[n] != 0 { n += 1 }
		os.write_string(os.stderr, "[quic] SSL error: ")
		os.write_string(os.stderr, string(buf[:n]))
		os.write_string(os.stderr, "\n")
	}
}

@(private)
_mark_ack_elicited :: proc(conn: ^Conn, level: Encryption_Level) {
	switch level {
	case .Initial:     conn.pn_initial.ack_elicited = true
	case .Handshake:   conn.pn_handshake.ack_elicited = true
	case .Application: conn.pn_one_rtt.ack_elicited = true
	case .Early_Data:  // 0-RTT off
	}
}

// --- Public receive entry point ---

// Process one UDP datagram. May contain multiple coalesced QUIC packets.
// Dispatches each packet to the appropriate decryption keys based on its
// long-header type.
conn_on_udp_recv :: proc(conn: ^Conn, datagram: []u8) -> Recv_Error {
	pos := 0
	for pos < len(datagram) {
		// Peek at first byte to decide parsing strategy.
		first := datagram[pos]
		if first & 0x80 == 0 {
			// Short header (1-RTT) — no length field, so it's always the last
			// packet in the datagram. If 1-RTT keys aren't up yet (servers
			// coalesce Initial+Handshake+1-RTT in the first flight), DROP it
			// rather than fail — the peer retransmits (§12.2).
			if !conn.one_rtt.have_rx_keys {
				conn.stats.packets_dropped += 1
				return .None
			}
			return _handle_short_header_packet(conn, datagram[pos:])
		}

		// Long header path.
		long_type := (first >> 4) & 0x03
		keys: ^Packet_Keys
		level: Encryption_Level
		switch long_type {
		case Long_Type_Initial:
			// Server without keys yet: peek at DCID and install them.
			if !conn.initial.have_rx_keys {
				peek: Long_Header
				if perr := parse_long_header(datagram[pos:], &peek); perr != .None {
					return perr
				}
				if !conn_server_install_dcid(conn, peek.dcid) {
					return .Keys_Unavailable
				}
			}
			// Client: on the first Server Initial, capture the server's
			// SCID and install it as our dst_cid. Subsequent packets to
			// the server must be addressed to this CID.
			if !conn.is_server {
				peek: Long_Header
				if perr := parse_long_header(datagram[pos:], &peek); perr == .None {
					if len(peek.scid) > 0 {
						copy(conn.dst_cid[:], peek.scid)
						conn.dst_cid_len = len(peek.scid)
					}
				}
			}
			keys = &conn.initial.rx_keys
			level = .Initial
		case Long_Type_Handshake:
			if !conn.handshake.have_rx_keys {
				// Keys not derived yet — skip just this packet and keep
				// walking the datagram (§12.2: drop, peer retransmits).
				hdr: Long_Header
				if parse_long_header(datagram[pos:], &hdr) != .None do return .None
				conn.stats.packets_dropped += 1
				pos += hdr.total_packet_len
				continue
			}
			keys = &conn.handshake.rx_keys
			level = .Handshake
		case Long_Type_Retry:
			// Retry has no Length field and is never coalesced — it IS the
			// rest of the datagram. parse_long_header doesn't apply, so check
			// the version (bytes 1..5) here before handing off.
			pkt := datagram[pos:]
			if len(pkt) >= 5 {
				version := u32(pkt[1]) << 24 | u32(pkt[2]) << 16 | u32(pkt[3]) << 8 | u32(pkt[4])
				if version == QUIC_VERSION_V1 {
					return _handle_retry_packet(conn, pkt)
				}
			}
			conn.stats.packets_dropped += 1
			return .None
		case:
			// 0-RTT not enabled (F10 — docs/VAPOR_PROGRAM.md §7a); drop rest of datagram.
			conn.stats.packets_dropped += 1
			return .None
		}

		plaintext, pn, consumed, derr := decrypt_long_packet(datagram[pos:], keys)
		if derr != .None {
			conn.stats.packets_decrypt_failed += 1
			// A packet we can't read is dropped, not a connection error
			// (§5.2) — stray/corrupt/wrong-epoch packets must not kill the
			// connection. Skip it if the header length parses; otherwise
			// drop the rest of the datagram.
			hdr: Long_Header
			if parse_long_header(datagram[pos:], &hdr) != .None do return .None
			pos += hdr.total_packet_len
			continue
		}
		conn.stats.packets_decrypted += 1
		_update_largest_rx_pn(conn, level, pn)

		if perr := process_frames(conn, level, plaintext); perr != .None do return perr

		pos += consumed
	}
	return .None
}

@(private)
_update_largest_rx_pn :: proc(conn: ^Conn, level: Encryption_Level, pn: u64) {
	space := _pn_space(conn, level)
	if space == nil do return
	if !space.has_rx || pn > space.largest_rx_pn {
		space.largest_rx_pn = pn
		space.has_rx = true
	}
	_pn_space_record_rx(space, pn)
}

@(private)
_pn_space :: proc(conn: ^Conn, level: Encryption_Level) -> ^Pn_Space {
	switch level {
	case .Initial:     return &conn.pn_initial
	case .Handshake:   return &conn.pn_handshake
	case .Application: return &conn.pn_one_rtt
	case .Early_Data:  return nil // 0-RTT off
	}
	return nil
}

@(private)
_handle_short_header_packet :: proc(conn: ^Conn, buf: []u8) -> Recv_Error {
	if !conn.one_rtt.have_rx_keys do return .Keys_Unavailable

	plaintext, pn, ok := decrypt_one_rtt(buf, conn.src_cid_len, &conn.one_rtt.rx_keys)
	if !ok {
		conn.stats.packets_decrypt_failed += 1
		return .Decrypt_Failed
	}
	conn.stats.packets_decrypted += 1

	_update_largest_rx_pn(conn, .Application, pn)
	return process_frames(conn, .Application, plaintext)
}

// --- Build Handshake-level packet ---
// Symmetric with conn_build_initial_packet but uses Handshake keys and
// omits the Token field. Used to send the client's Finished message.

conn_build_handshake_packet :: proc(conn: ^Conn, out: []u8) -> (n: int, err: Quic_Error) {
	// No keys yet = nothing to do (caller loops opportunistically), not an error.
	if !conn.handshake.have_tx_keys do return 0, .None
	send_ack := conn.pn_handshake.ack_elicited && conn.pn_handshake.has_rx
	send_close := conn.has_pending_close
	if len(conn.handshake.tx_crypto) == 0 && !send_ack && !send_close do return 0, .None

	// Plaintext: [ACK] + CRYPTO + [CONNECTION_CLOSE]. ACK-only is valid and
	// necessary — the server retransmits and stays amplification-limited
	// until its Handshake packets are acknowledged.
	plaintext: [2048]u8
	pos := 0

	if send_ack {
		w := encode_ack_from_space(plaintext[pos:], &conn.pn_handshake, 0)
		if w < 0 do return 0, .Encrypt_Failed
		pos += w
		conn.pn_handshake.ack_elicited = false
	}

	crypto_data := conn.handshake.tx_crypto[:]
	if len(crypto_data) > 0 {
		w := encode_crypto(plaintext[pos:], conn.handshake.tx_crypto_offset, crypto_data)
		if w < 0 do return 0, .Encrypt_Failed
		pos += w
		_crypto_level_record_flight(&conn.handshake, crypto_data)
		conn.handshake.tx_crypto_offset += u64(len(crypto_data))
	}

	if code, reason, ok_close := conn_take_pending_close(conn); ok_close {
		w := encode_connection_close(plaintext[pos:], code, 0, reason)
		if w < 0 do return 0, .Encrypt_Failed
		pos += w
	}

	pn := conn.pn_handshake.next_tx_pn
	conn.pn_handshake.next_tx_pn += 1

	packet_len, ok := encrypt_long_handshake(
		out,
		conn.dst_cid[:conn.dst_cid_len],
		conn.src_cid[:conn.src_cid_len],
		pn,
		4,
		plaintext[:pos],
		&conn.handshake.tx_keys,
	)
	if !ok do return 0, .Encrypt_Failed

	clear(&conn.handshake.tx_crypto)
	return packet_len, .None
}

// encrypt_long_handshake builds a Handshake-type long-header packet.
// Identical to encrypt_initial except:
//   - no Token field
//   - first-byte type bits are 0x20 (Handshake) instead of 0x00 (Initial)
encrypt_long_handshake :: proc(
	out:       []u8,
	dcid:      []u8,
	scid:      []u8,
	pn:        u64,
	pn_len:    int,
	plaintext: []u8,
	keys:      ^Packet_Keys,
) -> (packet_len: int, ok: bool) {
	pos := 0
	if len(out) < 1 do return 0, false
	out[pos] = build_long_first_byte(Long_Type_Handshake, pn_len)
	pos += 1

	if pos + 4 > len(out) do return 0, false
	out[pos]   = u8(QUIC_VERSION_V1 >> 24)
	out[pos+1] = u8(QUIC_VERSION_V1 >> 16)
	out[pos+2] = u8(QUIC_VERSION_V1 >> 8)
	out[pos+3] = u8(QUIC_VERSION_V1)
	pos += 4

	if pos + 1 + len(dcid) > len(out) do return 0, false
	out[pos] = u8(len(dcid)); pos += 1
	copy(out[pos:], dcid); pos += len(dcid)

	if pos + 1 + len(scid) > len(out) do return 0, false
	out[pos] = u8(len(scid)); pos += 1
	copy(out[pos:], scid); pos += len(scid)

	tag_len := 16
	length_val := u64(pn_len + len(plaintext) + tag_len)
	w := varint_encode_fixed_2byte(out[pos:], length_val)
	if w < 0 do return 0, false
	pos += w

	pn_offset := pos
	if pos + pn_len > len(out) do return 0, false
	for i in 0..<pn_len {
		out[pos + i] = u8(pn >> uint((pn_len - 1 - i) * 8))
	}
	pos += pn_len
	header_len := pos

	nonce: [QUIC_IV_LEN]u8
	make_nonce(&nonce, keys.iv[:], pn)

	ct_len, seal_ok := aead_seal(keys, out[pos:], nonce[:], plaintext, out[:header_len])
	if !seal_ok do return 0, false

	packet_len = pos + ct_len
	if !apply_header_protection(out[:packet_len], pn_offset, pn_len, keys, true) do return 0, false
	return packet_len, true
}
