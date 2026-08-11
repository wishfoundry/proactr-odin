package quic

import "core:c"

// RFC 9000 §17 — QUIC packet format
// RFC 9001 §5.3–5.4 — packet protection (AEAD + header protection)
// This file implements Initial packet encrypt/decrypt. Handshake and 1-RTT
// packets share the same machinery: only the first-byte type bits and (for
// short header) the header layout differ.
// Crypto uses long-lived EVP_CIPHER_CTX on Packet_Keys (aead_seal/open, hp_mask).

QUIC_VERSION_V1 :: u32(0x00000001)

// Long header packet types (§17.2, bits 2-3 of the first byte).
Long_Type_Initial   :: u8(0)
Long_Type_Zero_Rtt  :: u8(1)
Long_Type_Handshake :: u8(2)
Long_Type_Retry     :: u8(3)

// Minimum UDP datagram for a client Initial (§14.1) — we always pad to this.
INITIAL_PACKET_MIN :: 1200

// First-byte bit layout for long header packets we produce/consume:
//   bit 0 (MSB): 1  (long header)
//   bit 1:       1  (fixed bit)
//   bits 2-3:    long packet type
//   bits 4-5:    reserved (must be 0 when unprotected; HP may flip them)
//   bits 6-7:    pn_length - 1
// Initial + 4-byte PN:          0xc3 = 1100_0011
// Initial + 1-byte PN:          0xc0
// Handshake + 4-byte PN:        0xe3 = 1110_0011
build_long_first_byte :: proc(long_type: u8, pn_len: int) -> u8 {
	return 0xc0 | (long_type << 4) | u8(pn_len - 1)
}

// --- AEAD nonce construction (§5.3) ---
// The nonce for packet N is iv XOR padded_pn, where padded_pn is the 62-bit
// packet number zero-extended to the AEAD's nonce length (12 bytes) with the
// packet number occupying the least-significant bytes.
make_nonce :: proc(nonce: ^[QUIC_IV_LEN]u8, iv: []u8, pn: u64) {
	assert(len(iv) == QUIC_IV_LEN)
	copy(nonce[:], iv)
	// XOR pn (big-endian) into the last 8 bytes of the nonce.
	for i in 0..<8 {
		nonce[QUIC_IV_LEN - 1 - i] ~= u8(pn >> uint(i * 8))
	}
}

// --- Header protection (§5.4) ---
// For AES-based AEADs, the HP mask is AES-ECB(hp_key, sample)[0..5].
// `sample` is 16 bytes taken at offset pn_offset+4 in the already-AEAD-sealed
// packet (i.e. sample begins 4 bytes after the start of the packet number
// field, which puts it at pn_offset+4 regardless of pn length 1..4).

// One-shot AES-ECB block for unit tests (not the hot path — hot path uses hp_mask).
aes_ecb_block :: proc(out: ^[16]u8, key: []u8, input: []u8) -> bool {
	assert(len(input) == 16)
	if !os_ensure() do return false
	cipher: rawptr
	switch len(key) {
	case 16:
		cipher = g_os.cipher_aes_128_ecb
	case 32:
		cipher = g_os.cipher_aes_256_ecb
	case:
		return false
	}
	if cipher == nil do return false
	ctx := os_cipher_ctx_new()
	if ctx == nil do return false
	defer g_os.EVP_CIPHER_CTX_free(ctx)
	if g_os.EVP_EncryptInit_ex(ctx, cipher, nil, raw_data(key), nil) != 1 do return false
	g_os.EVP_CIPHER_CTX_set_padding(ctx, 0)
	out_len: c.int
	if g_os.EVP_EncryptUpdate(ctx, &out[0], &out_len, raw_data(input), 16) != 1 do return false
	return out_len == 16
}

// Apply header protection to a just-sealed packet (in place).
// `pn_offset` is the byte index of the first packet-number byte.
// `pn_len`    is 1..4.
// `keys`      provides the long-lived HP CTX for this encryption level.
// `is_long`   controls whether 4 or 5 bits of the first byte are masked.
apply_header_protection :: proc(
	packet:    []u8,
	pn_offset: int,
	pn_len:    int,
	keys:      ^Packet_Keys,
	is_long:   bool,
) -> bool {
	sample_offset := pn_offset + 4
	if sample_offset + 16 > len(packet) do return false
	sample := packet[sample_offset : sample_offset + 16]

	mask: [16]u8
	if !hp_mask(keys, mask[:], sample) do return false

	// Mask the reserved bits + pn_length in the first byte.
	if is_long {
		packet[0] ~= mask[0] & 0x0f
	} else {
		packet[0] ~= mask[0] & 0x1f
	}
	// Mask the packet number bytes.
	for i in 0..<pn_len {
		packet[pn_offset + i] ~= mask[1 + i]
	}
	return true
}

// Remove header protection (in place). Returns the recovered pn_length (1..4).
// After this call, buf[0] and buf[pn_offset..pn_offset+pn_len] hold plaintext
// bytes and the caller can parse the packet number.
remove_header_protection :: proc(
	packet:    []u8,
	pn_offset: int,
	keys:      ^Packet_Keys,
	is_long:   bool,
) -> (pn_len: int, ok: bool) {
	// We need 16 bytes of sample from pn_offset+4. HP is applied before we
	// know pn_len, so we assume the sample offset using the maximum pn_len.
	sample_offset := pn_offset + 4
	if sample_offset + 16 > len(packet) do return 0, false
	sample := packet[sample_offset : sample_offset + 16]

	mask: [16]u8
	if !hp_mask(keys, mask[:], sample) do return 0, false

	if is_long {
		packet[0] ~= mask[0] & 0x0f
	} else {
		packet[0] ~= mask[0] & 0x1f
	}
	pn_len = int(packet[0] & 0x03) + 1

	for i in 0..<pn_len {
		packet[pn_offset + i] ~= mask[1 + i]
	}
	return pn_len, true
}

// --- Initial packet encryption ---
// Produces the fully-protected wire bytes in `out`. Layout:
//   first_byte (1)
//   version (4)
//   dcid_len (1) + dcid
//   scid_len (1) + scid
//   token_len (varint) + token
//   length (varint: pn_len + payload_len + tag_len)
//   packet_number (pn_len bytes, big-endian)
//   AEAD-sealed payload (payload_len + tag_len bytes)
// The caller supplies a padded payload (Initial packets carrying CRYPTO must
// pad the UDP datagram to at least 1200 bytes per §14.1 — that padding goes
// in the plaintext as PADDING frames, not here).

encrypt_initial :: proc(
	out:        []u8,
	dcid:       []u8,
	scid:       []u8,
	token:      []u8,
	pn:         u64,
	pn_len:     int,
	plaintext:  []u8,
	keys:       ^Packet_Keys,
) -> (packet_len: int, ok: bool) {
	assert(pn_len >= 1 && pn_len <= 4)

	// --- Build unprotected header ---
	pos := 0
	if len(out) < 1 do return 0, false
	out[pos] = build_long_first_byte(Long_Type_Initial, pn_len)
	pos += 1

	// Version (big-endian).
	if pos + 4 > len(out) do return 0, false
	out[pos]   = u8(QUIC_VERSION_V1 >> 24)
	out[pos+1] = u8(QUIC_VERSION_V1 >> 16)
	out[pos+2] = u8(QUIC_VERSION_V1 >> 8)
	out[pos+3] = u8(QUIC_VERSION_V1)
	pos += 4

	// DCID.
	if len(dcid) > 20 || pos + 1 + len(dcid) > len(out) do return 0, false
	out[pos] = u8(len(dcid)); pos += 1
	copy(out[pos:], dcid); pos += len(dcid)

	// SCID.
	if len(scid) > 20 || pos + 1 + len(scid) > len(out) do return 0, false
	out[pos] = u8(len(scid)); pos += 1
	copy(out[pos:], scid); pos += len(scid)

	// Token (varint length prefix + bytes).
	w := varint_encode(out[pos:], u64(len(token)))
	if w < 0 do return 0, false
	pos += w
	if pos + len(token) > len(out) do return 0, false
	copy(out[pos:], token); pos += len(token)

	// Length = pn_len + ciphertext_len (plaintext_len + tag_len).
	tag_len := QUIC_TAG_LEN
	length_val := u64(pn_len + len(plaintext) + tag_len)
	// Length is always encoded as a 2-byte varint when >= 64, to keep header
	// math simple for header protection's sample offset. zenoh-rs peers are
	// fine with any valid varint length.
	w = varint_encode_fixed_2byte(out[pos:], length_val)
	if w < 0 do return 0, false
	pos += w

	// Packet number (big-endian, pn_len bytes).
	pn_offset := pos
	if pos + pn_len > len(out) do return 0, false
	for i in 0..<pn_len {
		out[pos + i] = u8(pn >> uint((pn_len - 1 - i) * 8))
	}
	pos += pn_len

	// Header (AAD) is out[0..pos] at this point.
	header_len := pos

	// --- AEAD seal the plaintext into out[pos..] ---
	nonce: [QUIC_IV_LEN]u8
	make_nonce(&nonce, keys.iv[:], pn)

	remaining := len(out) - pos
	if remaining < len(plaintext) + tag_len do return 0, false

	ct_len, seal_ok := aead_seal(keys, out[pos:], nonce[:], plaintext, out[:header_len])
	if !seal_ok do return 0, false

	packet_len = pos + ct_len

	// --- Apply header protection ---
	if !apply_header_protection(out[:packet_len], pn_offset, pn_len, keys, true) do return 0, false

	return packet_len, true
}

// Decrypt an Initial packet in place. Returns the plaintext slice (a view into
// `buf`) and the recovered packet number.
// On entry, `buf` holds the full protected packet as received. The header is
// parsed through the Length field; header protection is then removed to
// recover pn_length and the packet number, and the payload is decrypted.

decrypt_initial :: proc(
	buf:  []u8,
	keys: ^Packet_Keys,
) -> (plaintext: []u8, pn: u64, ok: bool) {
	// --- Parse fixed-offset header fields (up to packet number) ---
	if len(buf) < 7 do return nil, 0, false

	// Must be long header + fixed bit.
	if (buf[0] & 0xc0) != 0xc0 do return nil, 0, false

	pos := 1
	// Version — skip.
	pos += 4
	if pos >= len(buf) do return nil, 0, false

	// DCID.
	dcid_len := int(buf[pos]); pos += 1
	if dcid_len > 20 || pos + dcid_len >= len(buf) do return nil, 0, false
	pos += dcid_len

	// SCID.
	if pos >= len(buf) do return nil, 0, false
	scid_len := int(buf[pos]); pos += 1
	if scid_len > 20 || pos + scid_len >= len(buf) do return nil, 0, false
	pos += scid_len

	// For Initial packets only: Token length + Token.
	if (buf[0] & 0x30) >> 4 == Long_Type_Initial {
		token_len, tn, tok := varint_decode(buf[pos:])
		if !tok do return nil, 0, false
		pos += tn
		if pos + int(token_len) > len(buf) do return nil, 0, false
		pos += int(token_len)
	}

	// Length varint.
	_, ln, lok := varint_decode(buf[pos:])
	if !lok do return nil, 0, false
	pos += ln

	// At this point `pos` is the packet-number offset.
	pn_offset := pos

	// --- Remove header protection ---
	pn_len, ok_hp := remove_header_protection(buf, pn_offset, keys, true)
	if !ok_hp do return nil, 0, false
	if pn_offset + pn_len > len(buf) do return nil, 0, false

	// Read packet number (truncated form; caller may need to reconstruct).
	truncated_pn: u64 = 0
	for i in 0..<pn_len {
		truncated_pn = (truncated_pn << 8) | u64(buf[pn_offset + i])
	}
	// For the Initial packet case, we accept the truncated PN as-is. A full
	// implementation would reconstruct against largest_acked per §A.3.
	pn = truncated_pn

	header_len := pn_offset + pn_len
	ciphertext := buf[header_len:]

	// --- AEAD open ---
	nonce: [QUIC_IV_LEN]u8
	make_nonce(&nonce, keys.iv[:], pn)

	// Decrypt in place into the same slice.
	pt_len, open_ok := aead_open(keys, ciphertext, nonce[:], ciphertext, buf[:header_len])
	if !open_ok do return nil, 0, false

	return ciphertext[:pt_len], pn, true
}

// --- 1-RTT short header packets (RFC 9000 §17.3.1) ---
// Layout:
//   byte 0:  0 1 S R R K P P
//            ^ header form (0 = short)
//              ^ fixed bit
//                ^ spin bit (we use 0)
//                  ^^ reserved (must be 0 when unprotected)
//                     ^ key phase (we use 0 — no key update)
//                       ^^ pn_length - 1
//   DCID (no length field; receiver knows the length implicitly)
//   Packet number (pn_len bytes)
//   AEAD payload
// Header protection masks the low 5 bits of the first byte (reserved +
// key_phase + pn_length) and all packet-number bytes.

SHORT_FIRST_BYTE_BASE :: u8(0x40)

// Build a 1-RTT packet into `out`. Returns bytes written.
// `dcid` is the peer's CID (what we received from them at handshake).
// `pn`/`pn_len` are the packet number; `plaintext` is the serialized frames.
encrypt_one_rtt :: proc(
	out:       []u8,
	dcid:      []u8,
	pn:        u64,
	pn_len:    int,
	plaintext: []u8,
	keys:      ^Packet_Keys,
) -> (packet_len: int, ok: bool) {
	assert(pn_len >= 1 && pn_len <= 4)
	tag_len := QUIC_TAG_LEN
	needed := 1 + len(dcid) + pn_len + len(plaintext) + tag_len
	if len(out) < needed do return 0, false

	pos := 0
	out[pos] = SHORT_FIRST_BYTE_BASE | u8(pn_len - 1)
	pos += 1

	copy(out[pos:], dcid); pos += len(dcid)

	pn_offset := pos
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
	// is_long = false -> mask 5 bits of first byte (0x1f)
	if !apply_header_protection(out[:packet_len], pn_offset, pn_len, keys, false) do return 0, false
	return packet_len, true
}

// Decrypt a 1-RTT packet in place. `dcid_len` is the length of the DCID the
// receiver assigned to itself (typically conn.src_cid_len). Returns the
// plaintext slice (a view into `buf`) and the packet number.
decrypt_one_rtt :: proc(
	buf:      []u8,
	dcid_len: int,
	keys:     ^Packet_Keys,
) -> (plaintext: []u8, pn: u64, ok: bool) {
	if len(buf) < 1 + dcid_len + 4 + 16 do return nil, 0, false
	// Must be short header + fixed bit.
	if (buf[0] & 0xc0) != 0x40 do return nil, 0, false

	pn_offset := 1 + dcid_len
	pn_len, ok_hp := remove_header_protection(buf, pn_offset, keys, false)
	if !ok_hp do return nil, 0, false
	if pn_offset + pn_len > len(buf) do return nil, 0, false

	truncated_pn: u64 = 0
	for i in 0..<pn_len {
		truncated_pn = (truncated_pn << 8) | u64(buf[pn_offset + i])
	}
	pn = truncated_pn

	header_len := pn_offset + pn_len
	ciphertext := buf[header_len:]

	nonce: [QUIC_IV_LEN]u8
	make_nonce(&nonce, keys.iv[:], pn)

	pt_len, open_ok := aead_open(keys, ciphertext, nonce[:], ciphertext, buf[:header_len])
	if !open_ok do return nil, 0, false

	return ciphertext[:pt_len], pn, true
}

// --- Helper: fixed 2-byte varint encoding ---
// RFC 9000 §16 allows non-minimal encodings. We use a fixed 2-byte encoding
// for the packet Length field because the header protection sample offset
// must be stable regardless of the length's numeric value. A 2-byte varint
// can carry values 0..16383, which covers any Initial packet we produce.
varint_encode_fixed_2byte :: proc(buf: []u8, v: u64) -> int {
	if v >= (1 << 14) do return -1
	if len(buf) < 2 do return -1
	buf[0] = 0x40 | u8(v >> 8)
	buf[1] = u8(v)
	return 2
}
