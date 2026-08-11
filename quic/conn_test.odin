package quic

import "core:testing"
import "core:fmt"

// --- Phase 7a: connection setup + ClientHello Initial generation ---
// These tests exercise the full pipeline from conn_new() through Initial
// packet emission, without any network I/O. A successful test proves:
//   1. BoringSSL SSL_QUIC_METHOD callbacks wire up correctly.
//   2. TLS 1.3 ClientHello is produced and lands in conn.initial.tx_crypto.
//   3. Our CRYPTO frame + Initial packet + AEAD + HP pipeline encrypts it.
//   4. Decrypting the result (with the same keys) recovers the CRYPTO frame
//      and yields bytes that parse as a valid TLS 1.3 ClientHello handshake
//      message (outer type 0x01).

@(test)
test_conn_new_and_free :: proc(t: ^testing.T) {
	alpn := _alpn_wire("hq-29")
	defer delete(alpn)

	tp := _default_client_tp()
	conn, err := conn_new("localhost", alpn[:], tp)
	testing.expect_value(t, err, Quic_Error.None)
	testing.expect(t, conn != nil, "conn should be non-nil")
	testing.expect(t, conn.tls != nil, "BoringSSL SSL should be initialized")
	testing.expect(t, conn.tls_ctx != nil, "BoringSSL SSL_CTX should be initialized")
	testing.expect_value(t, conn.src_cid_len, 8)
	testing.expect_value(t, conn.dst_cid_len, 8)
	testing.expect(t, conn.initial.have_tx_keys, "Initial tx keys should be derived")
	testing.expect(t, conn.initial.have_rx_keys, "Initial rx keys should be derived")

	conn_free(conn)
}

@(test)
test_conn_start_handshake_generates_clienthello :: proc(t: ^testing.T) {
	alpn := _alpn_wire("hq-29")
	defer delete(alpn)

	tp := _default_client_tp()
	conn, err := conn_new("localhost", alpn[:], tp)
	testing.expect_value(t, err, Quic_Error.None)
	defer conn_free(conn)

	// Drive the handshake forward. BoringSSL should synchronously emit
	// ClientHello via add_handshake_data, then return SSL_ERROR_WANT_READ.
	hs_err := conn_start_handshake(conn)
	testing.expect_value(t, hs_err, Quic_Error.None)
	testing.expect_value(t, conn.state, Conn_State.Handshaking)

	// After the callback, tx_crypto should contain a TLS handshake message.
	// The first byte of a TLS 1.3 ClientHello (inside the CRYPTO frame) is
	// the Handshake message type: 0x01 (client_hello).
	testing.expect(t, len(conn.initial.tx_crypto) > 0,
		"BoringSSL should have emitted ClientHello CRYPTO data")
	testing.expect_value(t, conn.initial.tx_crypto[0], u8(0x01))

	// A ClientHello is typically 200-400 bytes — sanity check the range.
	testing.expect(t, len(conn.initial.tx_crypto) > 100,
		"ClientHello should be at least 100 bytes")
	testing.expect(t, len(conn.initial.tx_crypto) < 2048,
		"ClientHello should be under 2KB")
}

@(test)
test_conn_build_initial_packet_roundtrip :: proc(t: ^testing.T) {
	alpn := _alpn_wire("hq-29")
	defer delete(alpn)

	tp := _default_client_tp()
	conn, err := conn_new("localhost", alpn[:], tp)
	testing.expect_value(t, err, Quic_Error.None)
	defer conn_free(conn)

	_ = conn_start_handshake(conn)
	testing.expect(t, len(conn.initial.tx_crypto) > 0)

	// Save a copy of the ClientHello before conn_build_initial_packet clears it.
	expected_ch := make([]u8, len(conn.initial.tx_crypto))
	defer delete(expected_ch)
	copy(expected_ch, conn.initial.tx_crypto[:])

	// Build the Initial packet.
	packet: [2048]u8
	packet_len, build_err := conn_build_initial_packet(conn, packet[:])
	testing.expect_value(t, build_err, Quic_Error.None)
	testing.expect(t, packet_len >= INITIAL_PACKET_MIN,
		"Initial packet must be at least 1200 bytes (RFC 9000 §14.1)")

	// tx_crypto should be drained (frame is in flight).
	testing.expect_value(t, len(conn.initial.tx_crypto), 0)

	// Decrypt with the same keys. In a real connection the server would
	// derive these independently from the DCID; we reuse conn.initial.tx_keys.
	plaintext, pn, dec_ok := decrypt_initial(packet[:packet_len], &conn.initial.tx_keys)
	testing.expect(t, dec_ok, "Initial packet should decrypt successfully")
	testing.expect_value(t, pn, u64(0)) // first packet, pn=0

	// Parse the first frame — should be CRYPTO with our ClientHello bytes.
	frame, n, fe := frame_decode(plaintext)
	testing.expect_value(t, fe, Frame_Error.None)
	testing.expect(t, n > 0)

	crypto, is_crypto := frame.(Crypto_Frame)
	testing.expect(t, is_crypto, "first frame should be CRYPTO")
	testing.expect_value(t, crypto.offset, u64(0))
	testing.expect_value(t, len(crypto.data), len(expected_ch))
	testing.expect(t, slice_equal(crypto.data, expected_ch[:]),
		"CRYPTO frame content must match emitted ClientHello")

	// When ClientHello is smaller than the §14.1 pad target, the rest is
	// PADDING. OpenSSL CH + TPs can exceed 1200 B; then no pad is needed.
	if n < len(plaintext) {
		rest, nr, re := frame_decode(plaintext[n:])
		testing.expect_value(t, re, Frame_Error.None)
		padding, is_pad := rest.(Padding_Frame)
		testing.expect(t, is_pad, "trailing frame should be PADDING")
		testing.expect(t, padding.count > 0)
		_ = nr
	}
}

@(test)
test_conn_peer_transport_params_placeholder :: proc(t: ^testing.T) {
	// Phase 7a does not yet parse peer transport params (requires a real
	// server response). This placeholder asserts the peer_tp struct starts
	// empty — phase 7b will fill it in after handshake completion.
	alpn := _alpn_wire("hq-29")
	defer delete(alpn)

	tp := _default_client_tp()
	conn, _ := conn_new("localhost", alpn[:], tp)
	defer conn_free(conn)

	testing.expect_value(t, conn.peer_tp.max_datagram_frame_size, u64(0))
}

// --- Test helpers ---

// Build an ALPN wire-format byte string from a single protocol name.
// Wire format: [length byte][protocol bytes] per entry (RFC 7301 §3.1).
_alpn_wire :: proc(proto: string) -> []u8 {
	buf := make([]u8, 1 + len(proto))
	buf[0] = u8(len(proto))
	copy(buf[1:], proto)
	return buf
}

_default_client_tp :: proc() -> Transport_Params {
	return Transport_Params{
		max_idle_timeout           = 30_000,
		max_udp_payload_size       = 1472,
		initial_max_data           = 10 * 1024 * 1024,
		initial_max_streams_bidi   = 0,  // no streams — DATAGRAM only
		initial_max_streams_uni    = 0,
		ack_delay_exponent         = 3,
		max_ack_delay              = 25,
		active_connection_id_limit = 2,
		max_datagram_frame_size    = 65527, // RFC 9221 — required for DATAGRAMs
		disable_active_migration   = true,
	}
}

// Handshake-phase PTO bookkeeping: the flight buffer mirrors the sent crypto
// stream, requeue restores it (plus any unsent tail) at offset 0, and a
// rebuilt+resent packet does not double-record.
@(test)
test_crypto_level_flight_requeue :: proc(t: ^testing.T) {
	lvl: Crypto_Level
	defer delete(lvl.tx_crypto)
	defer delete(lvl.flight)

	// "Send" CH part 1: 10 bytes at offset 0.
	append(&lvl.tx_crypto, ..[]u8{0, 1, 2, 3, 4, 5, 6, 7, 8, 9})
	_crypto_level_record_flight(&lvl, lvl.tx_crypto[:])
	lvl.tx_crypto_offset += 10
	clear(&lvl.tx_crypto)
	testing.expect_value(t, len(lvl.flight), 10)

	// PTO fires with 5 unsent bytes pending at offset 10.
	append(&lvl.tx_crypto, ..[]u8{10, 11, 12, 13, 14})
	_crypto_level_requeue(&lvl)
	testing.expect_value(t, lvl.tx_crypto_offset, u64(0))
	testing.expect_value(t, len(lvl.tx_crypto), 15) // full stream from 0
	testing.expect_value(t, lvl.tx_crypto[10], u8(10))

	// Resend records only the new suffix — flight grows to 15, not 25.
	_crypto_level_record_flight(&lvl, lvl.tx_crypto[:])
	lvl.tx_crypto_offset += 15
	clear(&lvl.tx_crypto)
	testing.expect_value(t, len(lvl.flight), 15)
	testing.expect_value(t, lvl.flight[14], u8(14))

	// Confirmed delivered: discard clears retransmit state.
	_crypto_level_discard(&lvl)
	testing.expect_value(t, len(lvl.flight), 0)
}
