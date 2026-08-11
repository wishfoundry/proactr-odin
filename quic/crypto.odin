package quic

import "core:c"

// RFC 9001 §5.2 — Initial Salt for QUIC v1
INITIAL_SALT :: [20]u8{
	0x38, 0x76, 0x2c, 0xf7, 0xf5, 0x59, 0x34, 0xb3, 0x4d, 0x17,
	0x9a, 0xe6, 0xa4, 0xc8, 0x0c, 0xad, 0xcc, 0xbb, 0x7f, 0x0a,
}

AES_128_KEY_LEN :: 16
AES_256_KEY_LEN :: 32
CHACHA_KEY_LEN  :: 32
QUIC_IV_LEN     :: 12
QUIC_HP_MAX     :: 32
QUIC_TAG_LEN    :: 16

Aead_Kind :: enum u8 {
	Aes_128_Gcm = 0,
	Aes_256_Gcm,
	Chacha20_Poly1305,
}

// Long-lived packet keys + OpenSSL EVP_CIPHER_CTX handles.
Packet_Keys :: struct {
	key:     [32]u8,
	iv:      [QUIC_IV_LEN]u8,
	hp:      [QUIC_HP_MAX]u8,
	key_len: int,
	hp_len:  int,
	aead:    Aead_Kind,
	enc_ctx: rawptr, // EVP_CIPHER_CTX*
	dec_ctx: rawptr,
	hp_ctx:  rawptr,
}

Initial_Keys :: struct {
	client: Packet_Keys,
	server: Packet_Keys,
}

// --- HKDF: prefer one-shot HMAC (fast path); fall back to EVP_KDF ---

@(private)
_hmac :: proc(md: rawptr, key: []u8, data: []u8, out: []u8) -> bool {
	if g_os.HMAC == nil || md == nil || len(out) == 0 do return false
	out_len: c.uint = c.uint(len(out))
	r := g_os.HMAC(
		md,
		raw_data(key) if len(key) > 0 else nil,
		c.int(len(key)),
		raw_data(data),
		c.size_t(len(data)),
		raw_data(out),
		&out_len,
	)
	return r != nil && int(out_len) == len(out)
}

// HKDF-Extract(salt, IKM) = HMAC(salt, IKM) with empty salt → HashLen zeros.
hkdf_extract_sha256 :: proc(out32: []u8, salt: []u8, ikm: []u8) -> bool {
	if len(out32) < 32 || !os_ensure() do return false
	if g_os.HMAC != nil && g_os.EVP_sha256 != nil {
		md := g_os.EVP_sha256()
		s := salt
		zeros: [32]u8
		if len(s) == 0 do s = zeros[:]
		return _hmac(md, s, ikm, out32[:32])
	}
	return _hkdf_derive(out32[:32], EVP_KDF_HKDF_MODE_EXTRACT_ONLY, "SHA256", ikm, salt, true)
}

// HKDF-Expand(PRK, info, L) — RFC 5869 (single block when L <= HashLen).
hkdf_expand_sha256 :: proc(out: []u8, prk: []u8, info: []u8) -> bool {
	if !os_ensure() || len(out) == 0 do return false
	if g_os.HMAC != nil && g_os.EVP_sha256 != nil && len(out) <= 32 {
		md := g_os.EVP_sha256()
		// T(1) = HMAC(PRK, info || 0x01)
		msg: [128]u8
		if len(info) + 1 > len(msg) do return false
		copy(msg[:], info)
		msg[len(info)] = 1
		tmp: [32]u8
		if !_hmac(md, prk, msg[:len(info)+1], tmp[:]) do return false
		copy(out, tmp[:len(out)])
		return true
	}
	return _hkdf_derive(out, EVP_KDF_HKDF_MODE_EXPAND_ONLY, "SHA256", prk, info, false)
}

hkdf_expand_sha384 :: proc(out: []u8, prk: []u8, info: []u8) -> bool {
	if !os_ensure() || len(out) == 0 do return false
	if g_os.HMAC != nil && g_os.EVP_sha384 != nil && len(out) <= 48 {
		md := g_os.EVP_sha384()
		msg: [160]u8
		if len(info) + 1 > len(msg) do return false
		copy(msg[:], info)
		msg[len(info)] = 1
		tmp: [48]u8
		if !_hmac(md, prk, msg[:len(info)+1], tmp[:]) do return false
		copy(out, tmp[:len(out)])
		return true
	}
	return _hkdf_derive(out, EVP_KDF_HKDF_MODE_EXPAND_ONLY, "SHA384", prk, info, false)
}

@(private)
_hkdf_derive :: proc(out: []u8, mode: c.int, digest_name: cstring, key: []u8, salt_or_info: []u8, is_extract: bool) -> bool {
	if !os_ensure() || g_os.kdf_hkdf == nil do return false
	kctx := g_os.EVP_KDF_CTX_new(g_os.kdf_hkdf)
	if kctx == nil do return false
	defer g_os.EVP_KDF_CTX_free(kctx)

	mode_val := mode
	params: [5]OSSL_PARAM
	i := 0
	params[i] = ossl_param_int("mode", &mode_val); i += 1
	params[i] = ossl_param_utf8("digest", digest_name); i += 1
	params[i] = ossl_param_octet("key", raw_data(key), c.size_t(len(key))); i += 1
	if is_extract {
		params[i] = ossl_param_octet("salt", raw_data(salt_or_info), c.size_t(len(salt_or_info))); i += 1
	} else {
		params[i] = ossl_param_octet("info", raw_data(salt_or_info), c.size_t(len(salt_or_info))); i += 1
	}
	params[i] = ossl_param_end()

	return g_os.EVP_KDF_derive(kctx, raw_data(out), c.size_t(len(out)), &params[0]) > 0
}

// TLS 1.3 HKDF-Expand-Label
hkdf_expand_label :: proc(out: []u8, secret: []u8, label: string, sha384: bool) -> bool {
	info: [64]u8
	label_total_len := 6 + len(label)
	if label_total_len > 255 || len(out) == 0 do return false
	n := 0
	info[n] = u8(len(out) >> 8); n += 1
	info[n] = u8(len(out)); n += 1
	info[n] = u8(label_total_len); n += 1
	copy(info[n:], "tls13 "); n += 6
	copy(info[n:], label); n += len(label)
	info[n] = 0; n += 1
	if sha384 do return hkdf_expand_sha384(out, secret, info[:n])
	return hkdf_expand_sha256(out, secret, info[:n])
}

// --- CTX free / install ---

packet_keys_free_ctx :: proc(keys: ^Packet_Keys) {
	if keys == nil || !os_ensure() do return
	if keys.enc_ctx != nil {
		g_os.EVP_CIPHER_CTX_free(keys.enc_ctx)
		keys.enc_ctx = nil
	}
	if keys.dec_ctx != nil {
		g_os.EVP_CIPHER_CTX_free(keys.dec_ctx)
		keys.dec_ctx = nil
	}
	if keys.hp_ctx != nil {
		g_os.EVP_CIPHER_CTX_free(keys.hp_ctx)
		keys.hp_ctx = nil
	}
}

packet_keys_clear_crypto :: proc(keys: ^Packet_Keys) {
	if keys == nil do return
	packet_keys_free_ctx(keys)
	for i in 0 ..< len(keys.key) do keys.key[i] = 0
	for i in 0 ..< len(keys.iv) do keys.iv[i] = 0
	for i in 0 ..< len(keys.hp) do keys.hp[i] = 0
	keys.key_len = 0
	keys.hp_len = 0
}

@(private)
_aead_cipher :: proc(kind: Aead_Kind) -> rawptr {
	switch kind {
	case .Aes_128_Gcm: return g_os.cipher_aes_128_gcm
	case .Aes_256_Gcm: return g_os.cipher_aes_256_gcm
	case .Chacha20_Poly1305: return g_os.cipher_chacha_poly
	}
	return nil
}

@(private)
_hp_cipher :: proc(kind: Aead_Kind) -> rawptr {
	switch kind {
	case .Aes_128_Gcm: return g_os.cipher_aes_128_ecb
	case .Aes_256_Gcm: return g_os.cipher_aes_256_ecb
	case .Chacha20_Poly1305: return g_os.cipher_chacha20
	}
	return nil
}

packet_keys_install_ctx :: proc(keys: ^Packet_Keys) -> bool {
	if !os_ensure() do return false
	packet_keys_free_ctx(keys)
	acipher := _aead_cipher(keys.aead)
	hcipher := _hp_cipher(keys.aead)
	if acipher == nil || hcipher == nil do return false

	keys.enc_ctx = os_cipher_ctx_new()
	keys.dec_ctx = os_cipher_ctx_new()
	keys.hp_ctx = os_cipher_ctx_new()
	if keys.enc_ctx == nil || keys.dec_ctx == nil || keys.hp_ctx == nil {
		packet_keys_free_ctx(keys)
		return false
	}

	// Encrypt path: set cipher + IV len + key (IV per packet).
	if g_os.EVP_EncryptInit_ex(keys.enc_ctx, acipher, nil, nil, nil) != 1 do return false
	if g_os.EVP_CIPHER_CTX_ctrl(keys.enc_ctx, EVP_CTRL_AEAD_SET_IVLEN, QUIC_IV_LEN, nil) != 1 do return false
	if g_os.EVP_EncryptInit_ex(keys.enc_ctx, nil, nil, &keys.key[0], nil) != 1 do return false

	if g_os.EVP_DecryptInit_ex(keys.dec_ctx, acipher, nil, nil, nil) != 1 do return false
	if g_os.EVP_CIPHER_CTX_ctrl(keys.dec_ctx, EVP_CTRL_AEAD_SET_IVLEN, QUIC_IV_LEN, nil) != 1 do return false
	if g_os.EVP_DecryptInit_ex(keys.dec_ctx, nil, nil, &keys.key[0], nil) != 1 do return false

	// HP
	if keys.aead == .Chacha20_Poly1305 {
		// ChaCha20 key only; counter/nonce set per mask call.
		if g_os.EVP_EncryptInit_ex(keys.hp_ctx, hcipher, nil, &keys.hp[0], nil) != 1 do return false
	} else {
		if g_os.EVP_EncryptInit_ex(keys.hp_ctx, hcipher, nil, &keys.hp[0], nil) != 1 do return false
		g_os.EVP_CIPHER_CTX_set_padding(keys.hp_ctx, 0)
	}
	return true
}

derive_packet_keys :: proc(keys: ^Packet_Keys, secret: []u8, key_len: int, sha384: bool, kind: Aead_Kind) -> bool {
	if !os_ensure() do return false
	keys.aead = kind
	keys.key_len = key_len
	keys.hp_len = key_len
	if !hkdf_expand_label(keys.key[:key_len], secret, "quic key", sha384) do return false
	if !hkdf_expand_label(keys.iv[:], secret, "quic iv", sha384) do return false
	if !hkdf_expand_label(keys.hp[:keys.hp_len], secret, "quic hp", sha384) do return false
	// Lazy CTX install: free old; first seal/open/hp installs. Keeps yield_secret
	// (inside SSL_do_handshake) off the EVP_CIPHER_CTX_new critical path.
	packet_keys_free_ctx(keys)
	return true
}

// Ensure long-lived CTXs exist (first use after key install).
packet_keys_ensure_ctx :: proc(keys: ^Packet_Keys) -> bool {
	if keys == nil do return false
	if keys.enc_ctx != nil && keys.dec_ctx != nil && keys.hp_ctx != nil do return true
	if keys.key_len == 0 do return false
	return packet_keys_install_ctx(keys)
}

derive_initial_packet_keys :: proc(keys: ^Packet_Keys, secret: []u8) -> bool {
	// Initial keys are used immediately for the first flight — install CTXs now.
	if !derive_packet_keys(keys, secret, AES_128_KEY_LEN, false, .Aes_128_Gcm) do return false
	return packet_keys_ensure_ctx(keys)
}

derive_initial_keys :: proc(keys: ^Initial_Keys, dcid: []u8) -> bool {
	if !os_ensure() do return false
	initial_secret: [32]u8
	salt := INITIAL_SALT
	if !hkdf_extract_sha256(initial_secret[:], salt[:], dcid) do return false
	client_secret: [32]u8
	server_secret: [32]u8
	if !hkdf_expand_label(client_secret[:], initial_secret[:], "client in", false) do return false
	if !hkdf_expand_label(server_secret[:], initial_secret[:], "server in", false) do return false
	if !derive_initial_packet_keys(&keys.client, client_secret[:]) do return false
	if !derive_initial_packet_keys(&keys.server, server_secret[:]) do return false
	return true
}

// --- AEAD seal / open (long-lived CTX; zero heap) ---

aead_seal :: proc(keys: ^Packet_Keys, out: []u8, nonce: []u8, plaintext: []u8, aad: []u8) -> (n: int, ok: bool) {
	if keys == nil || !os_ensure() do return 0, false
	if !packet_keys_ensure_ctx(keys) do return 0, false
	if len(nonce) != QUIC_IV_LEN do return 0, false
	if len(out) < len(plaintext) + QUIC_TAG_LEN do return 0, false

	ctx := keys.enc_ctx
	if g_os.EVP_EncryptInit_ex(ctx, nil, nil, nil, raw_data(nonce)) != 1 do return 0, false

	outl: c.int
	if len(aad) > 0 {
		if g_os.EVP_EncryptUpdate(ctx, nil, &outl, raw_data(aad), c.int(len(aad))) != 1 do return 0, false
	}
	if g_os.EVP_EncryptUpdate(ctx, raw_data(out), &outl, raw_data(plaintext), c.int(len(plaintext))) != 1 do return 0, false
	written := int(outl)
	if g_os.EVP_EncryptFinal_ex(ctx, raw_data(out[written:]), &outl) != 1 do return 0, false
	written += int(outl)

	tag: [QUIC_TAG_LEN]u8
	if g_os.EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_AEAD_GET_TAG, QUIC_TAG_LEN, &tag[0]) != 1 do return 0, false
	copy(out[written:], tag[:])
	return written + QUIC_TAG_LEN, true
}

aead_open :: proc(keys: ^Packet_Keys, out: []u8, nonce: []u8, ciphertext: []u8, aad: []u8) -> (n: int, ok: bool) {
	if keys == nil || !os_ensure() do return 0, false
	if !packet_keys_ensure_ctx(keys) do return 0, false
	if len(nonce) != QUIC_IV_LEN do return 0, false
	if len(ciphertext) < QUIC_TAG_LEN do return 0, false
	pt_len := len(ciphertext) - QUIC_TAG_LEN
	if len(out) < pt_len do return 0, false

	ctx := keys.dec_ctx
	if g_os.EVP_DecryptInit_ex(ctx, nil, nil, nil, raw_data(nonce)) != 1 do return 0, false

	tag_ptr := raw_data(ciphertext[pt_len:])
	if g_os.EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_AEAD_SET_TAG, QUIC_TAG_LEN, tag_ptr) != 1 do return 0, false

	outl: c.int
	if len(aad) > 0 {
		if g_os.EVP_DecryptUpdate(ctx, nil, &outl, raw_data(aad), c.int(len(aad))) != 1 do return 0, false
	}
	if g_os.EVP_DecryptUpdate(ctx, raw_data(out), &outl, raw_data(ciphertext), c.int(pt_len)) != 1 do return 0, false
	written := int(outl)
	if g_os.EVP_DecryptFinal_ex(ctx, raw_data(out[written:]), &outl) != 1 do return 0, false
	return written + int(outl), true
}

// Header protection mask (5 bytes) into mask_out[0..5] (full 16 buffer OK).
hp_mask :: proc(keys: ^Packet_Keys, mask_out: []u8, sample16: []u8) -> bool {
	if keys == nil || !os_ensure() do return false
	if !packet_keys_ensure_ctx(keys) do return false
	if len(sample16) < 16 || len(mask_out) < 5 do return false

	if keys.aead == .Chacha20_Poly1305 {
		// counter = sample[0:4], nonce = sample[4:16]; encrypt 5 zero bytes.
		// EVP_chacha20: IV is 16 bytes = counter||nonce
		iv: [16]u8
		copy(iv[:], sample16[:16])
		if g_os.EVP_EncryptInit_ex(keys.hp_ctx, nil, nil, nil, &iv[0]) != 1 do return false
		zeros: [16]u8
		outl: c.int
		if g_os.EVP_EncryptUpdate(keys.hp_ctx, raw_data(mask_out), &outl, &zeros[0], 5) != 1 do return false
		return true
	}

	// AES-ECB: encrypt sample block
	outl: c.int
	block: [16]u8
	if g_os.EVP_EncryptUpdate(keys.hp_ctx, &block[0], &outl, raw_data(sample16), 16) != 1 do return false
	copy(mask_out, block[:5])
	return true
}

// One-shot AES-128-GCM for Retry tag (empty plaintext).
aead_seal_oneshot_aes128 :: proc(
	key: []u8,
	nonce: []u8,
	aad: []u8,
	out_tag: []u8,
) -> bool {
	if !os_ensure() || len(key) != 16 || len(nonce) != 12 || len(out_tag) < 16 do return false
	ctx := os_cipher_ctx_new()
	if ctx == nil do return false
	defer g_os.EVP_CIPHER_CTX_free(ctx)
	if g_os.EVP_EncryptInit_ex(ctx, g_os.cipher_aes_128_gcm, nil, nil, nil) != 1 do return false
	if g_os.EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_AEAD_SET_IVLEN, 12, nil) != 1 do return false
	if g_os.EVP_EncryptInit_ex(ctx, nil, nil, raw_data(key), raw_data(nonce)) != 1 do return false
	outl: c.int
	if len(aad) > 0 {
		if g_os.EVP_EncryptUpdate(ctx, nil, &outl, raw_data(aad), c.int(len(aad))) != 1 do return false
	}
	if g_os.EVP_EncryptFinal_ex(ctx, nil, &outl) != 1 do return false
	return g_os.EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_AEAD_GET_TAG, 16, raw_data(out_tag)) == 1
}

rand_bytes :: proc(buf: []u8) {
	if !os_ensure() || len(buf) == 0 do return
	_ = g_os.RAND_bytes(raw_data(buf), c.int(len(buf)))
}

// Suite map: id & 0xffff → params. ok=false on unknown (no silent fallback).
suite_params :: proc(suite_id: u16) -> (key_len: int, sha384: bool, kind: Aead_Kind, ok: bool) {
	switch suite_id {
	case 0x1301: return AES_128_KEY_LEN, false, .Aes_128_Gcm, true
	case 0x1302: return AES_256_KEY_LEN, true, .Aes_256_Gcm, true
	case 0x1303: return CHACHA_KEY_LEN, false, .Chacha20_Poly1305, true
	case: return 0, false, .Aes_128_Gcm, false
	}
}
