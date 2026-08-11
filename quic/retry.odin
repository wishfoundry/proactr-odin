// Retry packets (RFC 9000 §17.2.5, RFC 9001 §5.8) — client side.
//
// A server under load answers the first Initial with a Retry: a new SCID plus
// an address-validation token, no crypto. The client must re-derive its
// Initial keys from the new SCID, include the token in every subsequent
// Initial, and re-send the ClientHello (re-queued from the PTO flight buffer).
// Honored at most once, and only before any server Initial arrives.
package quic

import "core:crypto"

// RFC 9001 §5.8 fixed key/nonce for the Retry integrity tag (QUIC v1).
@(private, rodata)
RETRY_KEY_V1 := [16]u8{
	0xbe, 0x0c, 0x69, 0x0b, 0x9f, 0x66, 0x57, 0x5a,
	0x1d, 0x76, 0x6b, 0x54, 0xe3, 0x68, 0xc8, 0x4e,
}
@(private, rodata)
RETRY_NONCE_V1 := [12]u8{0x46, 0x15, 0x99, 0xd3, 0x5d, 0x63, 0x2b, 0xf2, 0x23, 0x98, 0x25, 0xbb}

RETRY_TAG_LEN :: 16

// Compute the Retry Integrity Tag for `body` (the Retry packet without its
// final 16 bytes): AES-128-GCM over an empty plaintext with
// AAD = ODCID_len || ODCID || body. The seal's whole output is the tag.
@(private)
_compute_retry_tag :: proc(odcid: []u8, body: []u8) -> (tag: [RETRY_TAG_LEN]u8, ok: bool) {
	aad: [1 + 20 + 1500]u8
	if len(odcid) > 20 || 1 + len(odcid) + len(body) > len(aad) do return {}, false
	aad[0] = u8(len(odcid))
	copy(aad[1:], odcid)
	copy(aad[1 + len(odcid):], body)
	aad_len := 1 + len(odcid) + len(body)

	key := RETRY_KEY_V1
	nonce := RETRY_NONCE_V1
	if !aead_seal_oneshot_aes128(key[:], nonce[:], aad[:aad_len], tag[:]) {
		return {}, false
	}
	return tag, true
}

// Verify a full Retry packet's integrity tag against the ODCID we sent.
@(private)
_verify_retry_integrity :: proc(odcid: []u8, retry_packet: []u8) -> bool {
	if len(retry_packet) <= RETRY_TAG_LEN do return false
	body := retry_packet[:len(retry_packet) - RETRY_TAG_LEN]
	want := retry_packet[len(retry_packet) - RETRY_TAG_LEN:]
	got, ok := _compute_retry_tag(odcid, body)
	if !ok do return false
	return crypto.compare_constant_time(got[:], want) == 1
}

// Parse and apply a Retry packet. Returns .None both when applied and when
// the packet is ignored (dup/invalid/late) — Retry never kills a connection.
@(private)
_handle_retry_packet :: proc(conn: ^Conn, pkt: []u8) -> Recv_Error {
	// Only clients, only before any server Initial, only once (§17.2.5.2).
	if conn.is_server || conn.retry_received || conn.pn_initial.has_rx do return .None
	if len(pkt) < 7 + RETRY_TAG_LEN do return .None

	pos := 5 // first byte + version (already validated as v1 by the caller)
	dcid_len := int(pkt[pos]); pos += 1
	if dcid_len > 20 || pos + dcid_len > len(pkt) do return .None
	dcid := pkt[pos:pos + dcid_len]
	pos += dcid_len
	if pos >= len(pkt) do return .None
	scid_len := int(pkt[pos]); pos += 1
	if scid_len < 1 || scid_len > 20 || pos + scid_len > len(pkt) do return .None
	scid := pkt[pos:pos + scid_len]
	pos += scid_len
	if pos + RETRY_TAG_LEN >= len(pkt) do return .None // token must be non-empty
	token := pkt[pos:len(pkt) - RETRY_TAG_LEN]

	// Must be addressed to us, and the tag must verify against the DCID we
	// originally sent (which is still conn.dst_cid — no Initial arrived yet).
	if dcid_len != conn.src_cid_len || string(dcid) != string(conn.src_cid[:conn.src_cid_len]) do return .None
	if !_verify_retry_integrity(conn.dst_cid[:conn.dst_cid_len], pkt) do return .None

	// Apply: new DCID → re-derived Initial keys; token rides every
	// subsequent Initial; ClientHello re-queued from the flight buffer.
	// Drop previous Initial CTXs before re-deriving (they share with level keys).
	packet_keys_free_ctx(&conn.initial.rx_keys)
	packet_keys_free_ctx(&conn.initial.tx_keys)
	conn.initial_keys = {}
	conn.retry_received = true
	clear(&conn.retry_token)
	append(&conn.retry_token, ..token)

	copy(conn.dst_cid[:], scid)
	conn.dst_cid_len = scid_len
	if !derive_initial_keys(&conn.initial_keys, scid) do return .Bad_Header
	conn.initial.rx_keys = conn.initial_keys.server
	conn.initial.tx_keys = conn.initial_keys.client

	_crypto_level_requeue(&conn.initial)
	conn.initial.pto_count = 0
	return .None
}
