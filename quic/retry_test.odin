package quic

import "core:testing"

// RFC 9001 Appendix A.4 known-answer Retry packet:
//   ODCID 0x8394c8f03e515708, SCID 0xf067a5502a4262b5, token "token",
//   tag 04a265ba2eff4d829058fb3f0f2496ba.
@(test)
test_retry_integrity_rfc9001_a4 :: proc(t: ^testing.T) {
	odcid := []u8{0x83, 0x94, 0xc8, 0xf0, 0x3e, 0x51, 0x57, 0x08}
	packet := []u8{
		0xff, 0x00, 0x00, 0x00, 0x01, 0x00, 0x08,
		0xf0, 0x67, 0xa5, 0x50, 0x2a, 0x42, 0x62, 0xb5,
		0x74, 0x6f, 0x6b, 0x65, 0x6e, // "token"
		0x04, 0xa2, 0x65, 0xba, 0x2e, 0xff, 0x4d, 0x82,
		0x90, 0x58, 0xfb, 0x3f, 0x0f, 0x24, 0x96, 0xba,
	}
	testing.expect(t, _verify_retry_integrity(odcid, packet), "RFC 9001 §A.4 tag verifies")

	// Any flipped bit must fail.
	packet[16] ~= 1
	testing.expect(t, !_verify_retry_integrity(odcid, packet), "corrupted token rejected")
	packet[16] ~= 1
	testing.expect(t, !_verify_retry_integrity(odcid[:7], packet), "wrong ODCID rejected")
}

// A client that already sent its ClientHello applies a valid Retry: new
// dst_cid, token stored (and carried by the next Initial), CH re-queued.
// A second Retry is ignored.
@(test)
test_retry_applied_once :: proc(t: ^testing.T) {
	params := Transport_Params{initial_max_data = 1 << 20}
	alpn := [3]u8{2, 'h', '3'}
	conn, cerr := conn_new("example.com", alpn[:], params)
	testing.expect_value(t, cerr, Quic_Error.None)
	defer conn_free(conn)

	testing.expect_value(t, conn_start_handshake(conn), Quic_Error.None)
	pkt_buf: [2048]u8
	n, berr := conn_build_initial_packet(conn, pkt_buf[:])
	testing.expect_value(t, berr, Quic_Error.None)
	testing.expect(t, n > 0, "ClientHello Initial built")
	testing.expect(t, len(conn.initial.flight) > 0, "flight recorded for PTO/Retry")
	testing.expect_value(t, len(conn.initial.tx_crypto), 0)

	odcid: [20]u8
	odcid_len := conn.dst_cid_len
	copy(odcid[:], conn.dst_cid[:odcid_len])

	// Build a Retry: new SCID, token "tok", valid integrity tag.
	new_scid := []u8{1, 2, 3, 4, 5, 6, 7, 8}
	retry: [dynamic]u8
	defer delete(retry)
	append(&retry, 0xf0, 0x00, 0x00, 0x00, 0x01)        // first byte + version 1
	append(&retry, u8(conn.src_cid_len))                 // DCID = client's SCID
	append(&retry, ..conn.src_cid[:conn.src_cid_len])
	append(&retry, u8(len(new_scid)))
	append(&retry, ..new_scid)
	append(&retry, 't', 'o', 'k')
	tag, tok := _compute_retry_tag(odcid[:odcid_len], retry[:])
	testing.expect(t, tok, "tag computed")
	append(&retry, ..tag[:])

	testing.expect_value(t, conn_on_udp_recv(conn, retry[:]), Recv_Error.None)
	testing.expect(t, conn.retry_received, "retry applied")
	testing.expect_value(t, string(conn.retry_token[:]), "tok")
	testing.expect_value(t, string(conn.dst_cid[:conn.dst_cid_len]), string(new_scid))
	testing.expect(t, len(conn.initial.tx_crypto) > 0, "ClientHello re-queued")
	testing.expect_value(t, conn.initial.tx_crypto_offset, u64(0))

	// The next Initial carries the token.
	n2, berr2 := conn_build_initial_packet(conn, pkt_buf[:])
	testing.expect_value(t, berr2, Quic_Error.None)
	hdr: Long_Header
	testing.expect_value(t, parse_long_header(pkt_buf[:n2], &hdr), Recv_Error.None)
	testing.expect_value(t, string(hdr.token), "tok")

	// A second Retry (different SCID, valid tag against the CURRENT dcid) is ignored.
	clear(&retry)
	append(&retry, 0xf0, 0x00, 0x00, 0x00, 0x01)
	append(&retry, u8(conn.src_cid_len))
	append(&retry, ..conn.src_cid[:conn.src_cid_len])
	append(&retry, u8(4), 9, 9, 9, 9)
	append(&retry, 'x')
	tag2, _ := _compute_retry_tag(conn.dst_cid[:conn.dst_cid_len], retry[:])
	append(&retry, ..tag2[:])
	testing.expect_value(t, conn_on_udp_recv(conn, retry[:]), Recv_Error.None)
	testing.expect_value(t, string(conn.retry_token[:]), "tok") // unchanged
	testing.expect_value(t, string(conn.dst_cid[:conn.dst_cid_len]), string(new_scid))
}
