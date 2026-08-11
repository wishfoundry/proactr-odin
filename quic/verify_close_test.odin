package quic

import "core:testing"

// Q-WOW quality tests: hard verify reject, CONNECTION_CLOSE 0x1c drain,
// pure AEAD zero ctx_new after install.

// C11 / Q-WOW-1: with verification ON (default), an untrusted/expired peer
// cert must not leave the client Connected — expect Closing + close.
@(test)
test_verify_on_rejects_untrusted :: proc(t: ^testing.T) {
	alpn := _alpn_wire("hq-29")
	defer delete(alpn)

	client, c_err := conn_new("localhost", alpn[:], _default_client_tp())
	testing.expect_value(t, c_err, Quic_Error.None)
	defer conn_free(client)
	// Deliberately NOT calling conn_disable_verify — expired minica cert.

	server, s_err := conn_new_server(
		transmute([]u8)string(TEST_CERT_PEM),
		transmute([]u8)string(TEST_KEY_PEM),
		_default_client_tp(),
	)
	testing.expect_value(t, s_err, Quic_Error.None)
	defer conn_free(server)

	// ClientHello.
	testing.expect_value(t, conn_start_handshake(client), Quic_Error.None)
	c_init: [2048]u8
	cn, berr := conn_build_initial_packet(client, c_init[:])
	testing.expect_value(t, berr, Quic_Error.None)
	testing.expect(t, cn > 0)

	// Server processes CH and emits SH + cert chain.
	_ = conn_on_udp_recv(server, c_init[:cn])
	s_init: [2048]u8
	si_n, _ := conn_build_initial_packet(server, s_init[:])
	s_hs: [4096]u8
	sh_n, _ := conn_build_handshake_packet(server, s_hs[:])

	// Deliver server flight to client. Cert verify should fail closed.
	if si_n > 0 {
		_ = conn_on_udp_recv(client, s_init[:si_n])
	}
	if sh_n > 0 {
		_ = conn_on_udp_recv(client, s_hs[:sh_n])
	}

	testing.expect(t, client.state != .Connected, "untrusted cert must not reach Connected")
	testing.expect(t, client.state == .Closing || client.has_pending_close,
		"client should be Closing with a CONNECTION_CLOSE queued")
	// Transport close codes for TLS alerts are 0x100 + alert (RFC 9000 §20.1).
	if client.has_pending_close {
		testing.expect(t, client.pending_close_code >= 0x100,
			"pending close should be a TLS-alert transport error")
	}
}

// C12 / Q-WOW-2: queue_connection_close + Initial build drains a 0x1c frame.
@(test)
test_queue_connection_close_drains_0x1c :: proc(t: ^testing.T) {
	alpn := _alpn_wire("hq-29")
	defer delete(alpn)

	conn, err := conn_new("localhost", alpn[:], _default_client_tp())
	testing.expect_value(t, err, Quic_Error.None)
	defer conn_free(conn)
	conn_disable_verify(conn)

	// Path A: take clears the queue and exposes the code/reason.
	conn_queue_connection_close(conn, 0x0a, "bye")
	testing.expect(t, conn.has_pending_close)
	testing.expect_value(t, conn.state, Conn_State.Closing)

	code, reason, ok := conn_take_pending_close(conn)
	testing.expect(t, ok)
	testing.expect_value(t, code, u64(0x0a))
	testing.expect(t, string(reason) == "bye")
	testing.expect(t, !conn.has_pending_close)

	// Path B: re-queue and drain through Initial packet build into 0x1c.
	conn_queue_connection_close(conn, 0x1c, "drain")
	pkt: [1500]u8
	n, berr := conn_build_initial_packet(conn, pkt[:])
	testing.expect_value(t, berr, Quic_Error.None)
	testing.expect(t, n > 0, "Initial with CONNECTION_CLOSE should build")
	testing.expect(t, !conn.has_pending_close, "close should be consumed by build")

	// decrypt_initial mutates the packet buffer in place.
	plaintext, _, dec_ok := decrypt_initial(pkt[:n], &conn.initial.tx_keys)
	testing.expect(t, dec_ok, "decrypt Initial carrying CONNECTION_CLOSE")

	found_close := false
	pos := 0
	for pos < len(plaintext) {
		frame, fn, fe := frame_decode(plaintext[pos:])
		if fe != .None do break
		pos += fn
		if cc, is_cc := frame.(Connection_Close_Frame); is_cc {
			testing.expect(t, !cc.is_app, "transport close is 0x1c not 0x1d")
			testing.expect_value(t, cc.error_code, u64(0x1c))
			found_close = true
			break
		}
	}
	testing.expect(t, found_close, "payload must contain CONNECTION_CLOSE 0x1c")
}

// Q-WOW-4: after keys are installed, pure AEAD seal must not allocate new CTXs.
@(test)
test_pure_aead_no_ctx_new_after_install :: proc(t: ^testing.T) {
	keys: Initial_Keys
	dcid := DCID_RFC9001_A1
	testing.expect(t, derive_initial_keys(&keys, dcid[:]), "derive_initial_keys")
	defer {
		packet_keys_clear_crypto(&keys.client)
		packet_keys_clear_crypto(&keys.server)
	}

	// Global counters race under parallel tests — assert long-lived path by
	// identity: seal/open 100× with the same CTX pointers and successful AEAD.
	enc0 := keys.client.enc_ctx
	dec0 := keys.client.dec_ctx
	testing.expect(t, enc0 != nil && dec0 != nil)

	pt: [100]u8
	for i in 0 ..< len(pt) do pt[i] = u8(i)
	aad: [16]u8
	nonce: [12]u8
	out: [128]u8
	pt2: [100]u8
	for i in 0 ..< 12 do nonce[i] = u8(i + 1)

	for _ in 0 ..< 100 {
		n, sok := aead_seal(&keys.client, out[:], nonce[:], pt[:], aad[:])
		testing.expect(t, sok)
		testing.expect(t, n == len(pt) + QUIC_TAG_LEN)
		m, ook := aead_open(&keys.client, pt2[:], nonce[:], out[:n], aad[:])
		testing.expect(t, ook && m == len(pt))
		// Same CTX pointers — install-only (C13).
		testing.expect(t, keys.client.enc_ctx == enc0)
		testing.expect(t, keys.client.dec_ctx == dec0)
		nonce[11] += 1
	}
}
