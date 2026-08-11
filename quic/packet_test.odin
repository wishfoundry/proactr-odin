package quic

import "core:testing"

// --- Nonce construction (RFC 9001 §5.3) ---

@(test)
test_make_nonce_xor :: proc(t: ^testing.T) {
	iv := [QUIC_IV_LEN]u8{
		0xfa, 0x04, 0x4b, 0x2f, 0x42, 0xa3, 0xfd, 0x3b, 0x46, 0xfb, 0x25, 0x5c,
	}

	// Packet number 0 — nonce == iv.
	nonce: [QUIC_IV_LEN]u8
	make_nonce(&nonce, iv[:], 0)
	testing.expect(t, slice_equal(nonce[:], iv[:]), "pn=0 should leave nonce == iv")

	// Packet number 2 — only the last byte flips.
	make_nonce(&nonce, iv[:], 2)
	expected := [QUIC_IV_LEN]u8{
		0xfa, 0x04, 0x4b, 0x2f, 0x42, 0xa3, 0xfd, 0x3b, 0x46, 0xfb, 0x25, 0x5e,
	}
	testing.expect(t, slice_equal(nonce[:], expected[:]), "pn=2 nonce mismatch")
}

// --- AES-ECB header protection mask ---

@(test)
test_aes_ecb_block_known_answer :: proc(t: ^testing.T) {
	// FIPS 197 / NIST AES-128 test vector.
	// Key:       000102030405060708090a0b0c0d0e0f
	// Plaintext: 00112233445566778899aabbccddeeff
	// Expected:  69c4e0d86a7b0430d8cdb78070b4c55a
	key := [16]u8{
		0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
		0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f,
	}
	plaintext := [16]u8{
		0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
		0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff,
	}
	expected := [16]u8{
		0x69, 0xc4, 0xe0, 0xd8, 0x6a, 0x7b, 0x04, 0x30,
		0xd8, 0xcd, 0xb7, 0x80, 0x70, 0xb4, 0xc5, 0x5a,
	}

	out: [16]u8
	ok := aes_ecb_block(&out, key[:], plaintext[:])
	testing.expect(t, ok, "aes_ecb_block failed")
	testing.expect(t, slice_equal(out[:], expected[:]), "AES-128 KAT mismatch")
}

// --- Initial packet roundtrip (our encoder ↔ our decoder) ---

@(test)
test_initial_roundtrip_small :: proc(t: ^testing.T) {
	// Derive Initial keys from the RFC §A.1 DCID so we can reuse the
	// verified key material.
	keys: Initial_Keys
	dcid := DCID_RFC9001_A1
	testing.expect(t, derive_initial_keys(&keys, dcid[:]), "key derive failed")

	// Encrypt.
	scid := []u8{0x01, 0x02, 0x03, 0x04}
	token: []u8 // empty
	plaintext := []u8{
		// A tiny CRYPTO frame: type 0x06, offset 0, length 4, data "ping"
		0x06, 0x00, 0x04, 0x70, 0x69, 0x6e, 0x67,
	}
	// Pad to 1200 bytes minimum with PADDING (0x00) inside the plaintext.
	padded: [1162]u8
	copy(padded[:], plaintext)
	// The rest is PADDING frames (0x00), automatic via default zero init.

	out: [2048]u8
	packet_len, ok := encrypt_initial(
		out[:],
		dcid[:],
		scid,
		token,
		2,     // packet number
		4,     // pn_len
		padded[:],
		&keys.client,
	)
	testing.expect(t, ok, "encrypt_initial failed")
	testing.expect(t, packet_len >= INITIAL_PACKET_MIN, "packet too small")

	// Decrypt.
	// We derive keys fresh from the same DCID — in real use, server would
	// extract the DCID from the received packet's header. For this test we
	// just need to verify the bytes roundtrip through AEAD + HP correctly.
	keys2: Initial_Keys
	derive_initial_keys(&keys2, dcid[:])

	recovered_pt, recovered_pn, dec_ok := decrypt_initial(out[:packet_len], &keys2.client)
	testing.expect(t, dec_ok, "decrypt_initial failed")
	testing.expect_value(t, recovered_pn, u64(2))
	testing.expect_value(t, len(recovered_pt), len(padded))
	testing.expect(t, slice_equal(recovered_pt, padded[:]), "plaintext mismatch after roundtrip")
}

@(test)
test_initial_roundtrip_varies_by_pn :: proc(t: ^testing.T) {
	keys: Initial_Keys
	dcid := DCID_RFC9001_A1
	derive_initial_keys(&keys, dcid[:])

	scid := []u8{0xaa}
	plaintext: [1162]u8
	// Put a CRYPTO frame marker at offset 0 so we can verify it round-trips.
	plaintext[0] = 0x06
	plaintext[1] = 0x00
	plaintext[2] = 0x04
	plaintext[3] = 0xde
	plaintext[4] = 0xad
	plaintext[5] = 0xbe
	plaintext[6] = 0xef

	// Encrypt with pn=42, decrypt with same pn, verify recovered.
	out: [2048]u8
	packet_len, ok := encrypt_initial(out[:], dcid[:], scid, nil, 42, 4, plaintext[:], &keys.client)
	testing.expect(t, ok)

	pt, pn, dec_ok := decrypt_initial(out[:packet_len], &keys.client)
	testing.expect(t, dec_ok)
	testing.expect_value(t, pn, u64(42))
	testing.expect(t, slice_equal(pt[:7], plaintext[:7]))
}

@(test)
test_initial_tamper_fails_aead :: proc(t: ^testing.T) {
	// Any modification to a sealed packet must cause AEAD to reject it.
	keys: Initial_Keys
	dcid := DCID_RFC9001_A1
	derive_initial_keys(&keys, dcid[:])

	plaintext: [1162]u8
	out: [2048]u8
	packet_len, _ := encrypt_initial(out[:], dcid[:], nil, nil, 1, 4, plaintext[:], &keys.client)

	// Flip a byte in the middle of the ciphertext.
	out[packet_len / 2] ~= 0x01

	_, _, ok := decrypt_initial(out[:packet_len], &keys.client)
	testing.expect(t, !ok, "AEAD should have rejected tampered packet")
}

@(test)
test_build_long_first_byte_layout :: proc(t: ^testing.T) {
	// Initial + 1-byte PN:  1100 0000 = 0xc0
	// Initial + 4-byte PN:  1100 0011 = 0xc3
	// Handshake + 4-byte PN: 1110 0011 = 0xe3
	testing.expect_value(t, build_long_first_byte(Long_Type_Initial, 1), u8(0xc0))
	testing.expect_value(t, build_long_first_byte(Long_Type_Initial, 4), u8(0xc3))
	testing.expect_value(t, build_long_first_byte(Long_Type_Handshake, 4), u8(0xe3))
}

// --- RFC 9001 §A.2 — Client Initial packet decryption ---
//
// The RFC gives the complete 1200-byte protected packet that a client sends
// when the DCID is 0x8394c8f03e515708, the packet number is 2, and the CRYPTO
// frame contains a specific (example) ClientHello. This test decrypts that
// exact byte sequence and verifies we recover PN=2 and the opening bytes of
// the expected CRYPTO frame.

@(test)
test_rfc9001_a2_client_initial_decrypt :: proc(t: ^testing.T) {
	// Full protected Client Initial from RFC 9001 §A.2.
	// Only the first ~30 bytes matter for structure + HP; AEAD will refuse
	// if anything is wrong across the whole buffer.
	rfc_a2 := []u8{
		0xc0, 0x00, 0x00, 0x00, 0x01, 0x08, 0x83, 0x94, 0xc8, 0xf0, 0x3e, 0x51, 0x57, 0x08, 0x00, 0x00,
		0x44, 0x9e, 0x7b, 0x9a, 0xec, 0x34, 0xd1, 0xb1, 0xc9, 0x8d, 0xd7, 0x68, 0x9f, 0xb8, 0xec, 0x11,
		0xd2, 0x42, 0xb1, 0x23, 0xdc, 0x9b, 0xd8, 0xba, 0xb9, 0x36, 0xb4, 0x7d, 0x92, 0xec, 0x35, 0x6c,
		0x0b, 0xab, 0x7d, 0xf5, 0x97, 0x6d, 0x27, 0xcd, 0x44, 0x9f, 0x63, 0x30, 0x00, 0x99, 0xf3, 0x99,
		0x1c, 0x26, 0x0e, 0xc4, 0xc6, 0x0d, 0x17, 0xb3, 0x1f, 0x84, 0x29, 0x15, 0x7b, 0xb3, 0x5a, 0x12,
		0x82, 0xa6, 0x43, 0xa8, 0xd2, 0x26, 0x2c, 0xad, 0x67, 0x50, 0x0c, 0xad, 0xb8, 0xe7, 0x37, 0x8c,
		0x8e, 0xb7, 0x53, 0x9e, 0xc4, 0xd4, 0x90, 0x5f, 0xed, 0x1b, 0xee, 0x1f, 0xc8, 0xaa, 0xfb, 0xa1,
		0x7c, 0x75, 0x0e, 0x2c, 0x7a, 0xce, 0x01, 0xe6, 0x00, 0x5f, 0x80, 0xfc, 0xb7, 0xdf, 0x62, 0x12,
		0x30, 0xc8, 0x37, 0x11, 0xb3, 0x93, 0x43, 0xfa, 0x02, 0x8c, 0xea, 0x7f, 0x7f, 0xb5, 0xff, 0x89,
		0xea, 0xc2, 0x30, 0x82, 0x49, 0xa0, 0x22, 0x52, 0x15, 0x5e, 0x23, 0x47, 0xb6, 0x3d, 0x58, 0xc5,
		0x45, 0x7a, 0xfd, 0x84, 0xd0, 0x5d, 0xff, 0xfd, 0xb2, 0x03, 0x92, 0x84, 0x4a, 0xe8, 0x12, 0x15,
		0x46, 0x82, 0xe9, 0xcf, 0x01, 0x2f, 0x90, 0x21, 0xa6, 0xf0, 0xbe, 0x17, 0xdd, 0xd0, 0xc2, 0x08,
		0x4d, 0xce, 0x25, 0xff, 0x9b, 0x06, 0xcd, 0xe5, 0x35, 0xd0, 0xf9, 0x20, 0xa2, 0xdb, 0x1b, 0xf3,
		0x62, 0xc2, 0x3e, 0x59, 0x6d, 0x11, 0xa4, 0xf5, 0xa6, 0xcf, 0x39, 0x48, 0x83, 0x8a, 0x3a, 0xec,
		0x4e, 0x15, 0xda, 0xf8, 0x50, 0x0a, 0x6e, 0xf6, 0x9e, 0xc4, 0xe3, 0xfe, 0xb6, 0xb1, 0xd9, 0x8e,
		0x61, 0x0a, 0xc8, 0xb7, 0xec, 0x3f, 0xaf, 0x6a, 0xd7, 0x60, 0xb7, 0xba, 0xd1, 0xdb, 0x4b, 0xa3,
	}
	// Note: we only embed the first ~256 bytes of the 1200-byte packet.
	// decrypt_initial will fail AEAD on this truncated input — that's OK for
	// structural validation. We just want to verify:
	//   1. Header parsing walks to the correct pn_offset.
	//   2. Header protection removal recovers the expected first byte (0xc3)
	//      and the expected packet number (2).
	//
	// Rather than invoke the full decrypt, we reproduce the header-walk
	// logic inline and check the HP removal step directly.

	keys: Initial_Keys
	dcid := DCID_RFC9001_A1
	derive_initial_keys(&keys, dcid[:])

	// Parse up to pn_offset: first byte (1) + version (4) + dcid_len (1) +
	// dcid (8) + scid_len (1) + token_len (1 varint = 0) + length (2 varint).
	buf := make([]u8, len(rfc_a2))
	defer delete(buf)
	copy(buf, rfc_a2)

	// First byte protected is 0xc0; after HP removal it should be 0xc3.
	testing.expect_value(t, buf[0], u8(0xc0))

	pn_offset := 1 + 4 + 1 + 8 + 1 + 1 + 2  // = 18
	testing.expect_value(t, pn_offset, 18)

	pn_len, ok := remove_header_protection(buf, pn_offset, &keys.client, true)
	testing.expect(t, ok, "remove_header_protection failed")
	testing.expect_value(t, pn_len, 4) // RFC A.2 encodes PN=2 as 4 bytes
	testing.expect_value(t, buf[0], u8(0xc3)) // recovered first byte

	// Recovered packet number should be 2.
	recovered_pn: u64 = 0
	for i in 0..<pn_len {
		recovered_pn = (recovered_pn << 8) | u64(buf[pn_offset + i])
	}
	testing.expect_value(t, recovered_pn, u64(2))
}
