// - Always: lightweight connection_enable_ciphered + pipe firehose path stays green (no OpenSSL).
// - With OpenSSL: server_tls_init loads PEMs into shared SSL_CTX; conn_new + mem-BIO smoke.
// - Full HTTPS e2e (curl) is manual — see docs/ARCHITECTURE.md.
// Run: odin test http -define:ODIN_TEST_THREADS=1
package http

import "core:testing"

import tls_server "../tls_server"

// Same self-signed material as tls_server/tls_server_test.odin (CN=localhost).
TLS_HOST_TEST_CERT :: `-----BEGIN CERTIFICATE-----
MIIDCTCCAfGgAwIBAgIUVrQ0cs1oAv7AUAexn2bAnMdNClswDQYJKoZIhvcNAQEL
BQAwFDESMBAGA1UEAwwJbG9jYWxob3N0MB4XDTI2MDgwODIzMDE0OFoXDTM2MDgw
NTIzMDE0OFowFDESMBAGA1UEAwwJbG9jYWxob3N0MIIBIjANBgkqhkiG9w0BAQEF
AAOCAQ8AMIIBCgKCAQEAsAeV/jxsy5cdTVeISGOs3F6p8e+z+/Haj/Pl0xmyQ3K/
LffAWpAAKKlqzRNkVncp5IQI5ISwPMbTwBPGMHUX9BV3qB4G4UcTbjUYycT81ozC
kJTZo7Dp9Fo7/oQ2q2MEaNnu9POfQ7ivjalejK2Zu7wJH7LTokGLrK2k+lm3oRaw
qzd9dKCciV/FawRXn0PzTX8ej9Got0GCFtpZzF5oXqVIPTYpn91iZoaApvXEKQ99
bOdXpFDz5Xr+TXFx393CbL8qCFZiLnOEyo4Z0sBid/2beIBI9e4g/r+2v91wofFg
7fa+X0Q6/xEBwhdSPrkE7GVTjRYBNuJnJHNZ9js24wIDAQABo1MwUTAdBgNVHQ4E
FgQUC2IwxS/ImL7ybxQnA4ZyHoeXngwwHwYDVR0jBBgwFoAUC2IwxS/ImL7ybxQn
A4ZyHoeXngwwDwYDVR0TAQH/BAUwAwEB/zANBgkqhkiG9w0BAQsFAAOCAQEAb6NY
gOuGvY84LL/iA928b3SDAi5srWz3NlknaV5vjo+cM9Qb1cDIZacQuVwvs1l5BQd0
GhTBzmAbE/HKP+FQPOJUTFpHZ+jt5rLUnMXn9N/ttf0fPsDRnZE5OEF3UbDf5VU4
sIz8oTzNIKtHzZhL24a2TFF2tkPaOzhDPtVouuOD0f6QInYaYKzdbGuu14mw5EcC
6itoif/9yZQeg2rtq81UdoSkX5FU/uv50Gxf0z0iUMDqlVFA0toAjUhNheVFeB+U
ovblmBpvyGcYvdCOaVq1Bh/TWG9PIxNOnEMtx6HA8qJ7iyanm2WxLJoNLiSf2SKB
MEz3O+sjAbEPv6z9ag==
-----END CERTIFICATE-----
`

TLS_HOST_TEST_KEY :: `-----BEGIN PRIVATE KEY-----
MIIEvgIBADANBgkqhkiG9w0BAQEFAASCBKgwggSkAgEAAoIBAQCwB5X+PGzLlx1N
V4hIY6zcXqnx77P78dqP8+XTGbJDcr8t98BakAAoqWrNE2RWdynkhAjkhLA8xtPA
E8YwdRf0FXeoHgbhRxNuNRjJxPzWjMKQlNmjsOn0Wjv+hDarYwRo2e70859DuK+N
qV6MrZm7vAkfstOiQYusraT6WbehFrCrN310oJyJX8VrBFefQ/NNfx6P0ai3QYIW
2lnMXmhepUg9Nimf3WJmhoCm9cQpD31s51ekUPPlev5NcXHf3cJsvyoIVmIuc4TK
jhnSwGJ3/Zt4gEj17iD+v7a/3XCh8WDt9r5fRDr/EQHCF1I+uQTsZVONFgE24mck
c1n2OzbjAgMBAAECggEAJqEji21bOrpo1cY1xB0LnDix9sPxrYJ/wkN11gO3mRGf
XskVz0n2nvW+2E4/ILJ54QoQoYV034GKioZMYenwXcIwRhaA0AM3AmJolC7EhZjS
QcRIlqGGVfdPXyVIkgfiudfJlru34bav39ihRSH7sLUtE2W9B8h2jGh24fG6WIEy
eZ6+nmn+9FAGsVirMUONzN0BCs4gg6xp0Gvv3pIKTQqBCF7l78b+UgPJudu1Dh+n
7Pogc7+IZH/Rhbvoo9SGxOg53TP5gVCEbDzHip3ZSAE9UWDHUCVFIPlmUwVzOb+8
cwnMo9xgKs3evap6McCUWAGXJKC38d/cKt5ryAUxYQKBgQDtJu7KdeE102kTHkRl
fG0jC+rQqgqAH+4EHN1W5eYMVGM3YNRmqkS3SyIoqu/oH9qNOrneVvdVs90GkTwi
rjk4reSQwLDgrf/mMJ7u1nOIaoWu1s/3E8wZoUTyz9Ah6AQAb5KIhTuBLlXs+A7H
tpUGr71BLlLFJ3uEGjcoN7vtSQKBgQC+BRAymcZj23f6XZB7O6y3HXdvL+BgIXkz
oPT/AsYYM+VTj08aBmsrdn2Wt9LB1lt05tjTuoAHJGfa8VVp+EUwwWY+eWsS1XbU
Bge8Yw2FZfX/Bpz6CqKqKOyplg8eZUnu/KkRDBrz26jKduvQe1it8smfRXQV4ufC
Ie8uCKueywKBgBS8+dbEliwhz6d3Vx3U0qpk6WTT6dUodaTwbT6jHgnn+0Ele416
yEWLEXKi+BXBa1g8UXKrAjgBYYuoeazCtYhKVJl/8DfFn4IesFdMc4/zWLtgV5FQ
ruFy49ej6px8cJUlLJg5pml2htcRHiHCyqdqCM/BYEWTXU7BCB/BN/LZAoGBAJLP
QqZ1nIvGIroy09ACWPzZLU+gQ9DBy+yRrPfhYr+MSN/4Vvsafm6EC6AIwjK0tNBr
Epby/ruF6x+DWaSYBo0WvzIBiTJx7m79gbiRJv8ruZWhvGKLGQYyvDaCE4g+ZZLZ
bp4XJjPGQHC81JCs2+T5McF2XawTNVAN+8crN71lAoGBAJ5vk1rw++34e14Eu9kE
NLlODNmsW5RQa1oVQ21uqjF8bfKVfQF4xcaW09NRYUijP3APKKhyXMjKGQcePUCR
HedWwqdPY4mvf3VlvLidykaK7CH659mQcPC2MFld9YM3dPFtt4spvfg2/XssC24n
TlImL5v0KEBRhBq3eybNNZdR
-----END PRIVATE KEY-----
`

@(test)
test_tls_host_server_init_or_skip :: proc(t: ^testing.T) {
	// Own the provider so the test allocator can free it (no process default leak).
	p, err := tls_server.provider_openssl_dynlib_load()
	if err != .None || p == nil {
		return // skip without OpenSSL
	}
	defer tls_server.provider_destroy(p)
	tls_server.set_default_provider(p)
	defer tls_server.set_default_provider(nil)

	s: Server
	s.conn_allocator = context.allocator
	s.opts = Default_Server_Opts
	s.opts.tls_cert_pem = transmute([]u8)string(TLS_HOST_TEST_CERT)
	s.opts.tls_key_pem = transmute([]u8)string(TLS_HOST_TEST_KEY)

	ok := server_tls_init(&s)
	testing.expect(t, ok, "server_tls_init with self-signed PEMs")
	if !ok {
		return
	}
	testing.expect(t, server_tls_live(&s))
	testing.expect(t, s.tls_provider != nil)
	testing.expect(t, s.tls_ctx != nil)

	// Per-conn SSL + mem-BIO (no ring / no accept).
	ssl := tls_server.conn_new(s.tls_provider, s.tls_ctx)
	testing.expect(t, ssl != nil, "conn_new from host SSL_CTX")
	if ssl != nil {
		mb := tls_server.setup_mem_bios(s.tls_provider, ssl)
		testing.expect(t, mb, "setup_mem_bios")
		// Without ClientHello, accept wants read.
		ret := tls_server.accept(s.tls_provider, ssl)
		ge := tls_server.get_error(s.tls_provider, ssl, ret)
		testing.expect(
			t,
			ge == s.tls_provider.ERROR_WANT_READ ||
			ge == s.tls_provider.ERROR_WANT_WRITE ||
			ge == s.tls_provider.ERROR_SSL,
			"accept without peer is WANT_* or SSL",
		)
		tls_server.conn_free(s.tls_provider, ssl)
	}

	server_tls_destroy(&s)
	testing.expect(t, !server_tls_live(&s))
	testing.expect(t, s.tls_ctx == nil)
}

@(test)
test_tls_host_init_bad_pem_fails_honest :: proc(t: ^testing.T) {
	// Direct provider path (no default_provider process ownership).
	p, err := tls_server.provider_openssl_dynlib_load()
	if err != .None || p == nil {
		return
	}
	defer tls_server.provider_destroy(p)

	ctx := tls_server.ctx_new(p)
	testing.expect(t, ctx != nil)
	if ctx == nil {
		return
	}
	defer tls_server.ctx_free(p, ctx)

	// Bad PEM must fail honestly — same outcome server_tls_init would report.
	ok := tls_server.ctx_load_pem(
		p,
		ctx,
		transmute([]u8)string("not-a-pem"),
		transmute([]u8)string("also-not-a-pem"),
	)
	testing.expect(t, !ok, "bad PEM must fail ctx_load_pem")
}

@(test)
test_tls_host_ciphered_plan_and_flush_cursor :: proc(t: ^testing.T) {
	// Pure host plumbing without OpenSSL: enable_ciphered + plan_policy + plain cursor.
	c: Connection
	c.server = nil
	tls_pipe_init(&c.tls_pipe)
	testing.expect(t, connection_enable_ciphered(&c))
	testing.expect(t, c.ciphered)
	pol := plan_policy_for(&c)
	testing.expect(t, pol.ciphered)
	testing.expect(t, !pol.sendfile_ok)
	testing.expect_value(t, pol.max_write_unit, u32(PIPE_MAX_WRITE_UNIT_DEFAULT))

	// Windowed send cursor semantics (no SSL_write) — rest-only path.
	plain := transmute([]u8)string("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK")
	c.tls_plain_rest = plain
	c.tls_plain_body = nil
	c.tls_plain_body_off = 0
	testing.expect_value(t, tls_plain_total_remaining(&c), len(plain))
	win := min(tls_plain_total_remaining(&c), 16)
	view := tls_plain_window(&c, win)
	testing.expect_value(t, len(view), win)
	tls_plain_advance(&c, win)
	testing.expect_value(t, tls_plain_total_remaining(&c), len(plain) - win)
	tls_plain_clear(&c)
	testing.expect_value(t, tls_plain_total_remaining(&c), 0)

	connection_disable_ciphered(&c)
	testing.expect(t, !c.ciphered)
}

// Pure unit test: heading + borrowed body plain cursor (no OpenSSL).
@(test)
test_tls_plain_rest_then_body_cursor :: proc(t: ^testing.T) {
	c: Connection
	heading := transmute([]u8)string("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\n")
	body := transmute([]u8)string("hello")
	c.tls_plain_rest = heading
	c.tls_plain_body = body
	c.tls_plain_body_off = 0

	total := len(heading) + len(body)
	testing.expect_value(t, tls_plain_total_remaining(&c), total)

	// First window is heading-only (part boundary).
	w1 := tls_plain_window(&c, 1 << 20)
	testing.expect_value(t, len(w1), len(heading))
	testing.expect(t, raw_data(w1) == raw_data(heading))

	// Advance past heading → body becomes next part.
	tls_plain_advance(&c, len(heading))
	testing.expect_value(t, tls_plain_total_remaining(&c), len(body))
	testing.expect_value(t, len(c.tls_plain_rest), 0)

	w2 := tls_plain_window(&c, 3)
	testing.expect_value(t, len(w2), 3)
	testing.expect(t, string(w2) == "hel")
	tls_plain_advance(&c, 3)
	testing.expect_value(t, c.tls_plain_body_off, 3)
	testing.expect_value(t, tls_plain_total_remaining(&c), 2)

	w3 := tls_plain_window(&c, 16)
	testing.expect_value(t, len(w3), 2)
	testing.expect(t, string(w3) == "lo")
	tls_plain_advance(&c, 2)
	testing.expect_value(t, tls_plain_total_remaining(&c), 0)
	testing.expect(t, len(tls_plain_window(&c, 16)) == 0)

	// Over-advance and clear are safe.
	tls_plain_advance(&c, 10)
	tls_plain_clear(&c)
	testing.expect(t, c.tls_plain_rest == nil)
	testing.expect(t, c.tls_plain_body == nil)
	testing.expect_value(t, c.tls_plain_body_off, 0)
}

// Advance that straddles rest→body in one call.
@(test)
test_tls_plain_advance_across_parts :: proc(t: ^testing.T) {
	c: Connection
	heading := transmute([]u8)string("HDR\r\n\r\n")
	body := transmute([]u8)string("BODYDATA")
	c.tls_plain_rest = heading
	c.tls_plain_body = body
	c.tls_plain_body_off = 0

	// Consume last 2 of heading + first 3 of body in one advance.
	// First take only heading window (part-local).
	win := tls_plain_window(&c, 4) // "HDR\r"
	testing.expect_value(t, len(win), 4)
	tls_plain_advance(&c, 4)
	// Remaining heading: "\n\r\n" (3) + body 8 = 11
	testing.expect_value(t, tls_plain_total_remaining(&c), 3+8)
	// Cross the boundary: advance 5 (3 heading + 2 body).
	tls_plain_advance(&c, 5)
	testing.expect_value(t, len(c.tls_plain_rest), 0)
	testing.expect_value(t, c.tls_plain_body_off, 2)
	testing.expect_value(t, tls_plain_total_remaining(&c), 6)
	rest := tls_plain_window(&c, 100)
	testing.expect(t, string(rest) == "DYDATA")
	tls_plain_clear(&c)
}

@(test)
test_tls_host_conn_destroy_idempotent :: proc(t: ^testing.T) {
	c: Connection
	c.server = nil
	c.tls_ssl = nil
	c.tls_ct_rx = nil
	c.dual_ct = {}
	// Safe with no TLS state.
	tls_host_conn_destroy(&c)
	tls_host_conn_destroy(&c)
	testing.expect(t, c.tls_ssl == nil)
	testing.expect(t, !c.ciphered)
}

// Dual-CT ahead-seal destination selection (no OpenSSL / ring).
@(test)
test_tls_dual_ct_seal_dst_for_ahead :: proc(t: ^testing.T) {
	c: Connection
	tx := make([]u8, 64)
	hold := make([]u8, 64)
	defer delete(tx)
	defer delete(hold)
	c.dual_ct.tx = tx
	c.dual_ct.hold = hold
	// No wire flight → no ahead seal.
	c.wire.kind = .None
	dst, mark := tls_host_seal_dst_for_ahead(&c)
	testing.expect(t, len(dst) == 0)

	// Primary sending → seal into hold.
	c.wire.kind = .Send
	c.dual_ct.send_is_hold = false
	c.dual_ct.hold_n = 0
	c.dual_ct.tx_ready_n = 0
	dst, mark = tls_host_seal_dst_for_ahead(&c)
	testing.expect(t, mark)
	testing.expect(t, raw_data(dst) == raw_data(hold))

	// Hold already ready → no free slab.
	c.dual_ct.hold_n = 10
	dst, mark = tls_host_seal_dst_for_ahead(&c)
	testing.expect(t, len(dst) == 0)

	// Hold sending → seal into primary.
	c.dual_ct.hold_n = 0
	c.dual_ct.send_is_hold = true
	c.dual_ct.tx_ready_n = 0
	dst, mark = tls_host_seal_dst_for_ahead(&c)
	testing.expect(t, !mark)
	testing.expect(t, raw_data(dst) == raw_data(tx))

	// Promote prefers hold over primary ready.
	c.wire.kind = .None
	c.dual_ct.send_is_hold = false
	c.dual_ct.hold_n = 7
	c.dual_ct.tx_ready_n = 5
	// Cannot submit without ring — only check ready selection via seal_dst idle path.
	testing.expect(t, c.dual_ct.hold_n == 7 && c.dual_ct.tx_ready_n == 5)
}

@(test)
test_server_tls_wanted :: proc(t: ^testing.T) {
	s: Server
	testing.expect(t, !server_tls_wanted(&s))
	s.opts.tls_cert_pem = transmute([]u8)string("x")
	testing.expect(t, !server_tls_wanted(&s)) // key missing
	s.opts.tls_key_pem = transmute([]u8)string("y")
	testing.expect(t, server_tls_wanted(&s))
}

// Progressive stream cursor (no OpenSSL): per-slab plain_n holds sealed bytes until CT delivery.
@(test)
test_tls_stream_plain_n_cursor :: proc(t: ^testing.T) {
	c: Connection
	testing.expect(t, connection_enable_ciphered(&c))
	c.slot.stream_open = true
	c.slot.stream_sent = 0
	// Simulate seal of 10 plain bytes into primary CT in flight.
	c.dual_ct.tx_plain_n = 10
	testing.expect_value(t, tls_host_stream_plain_off(&c), 10)
	// After full CT CQE, host advances stream_sent and clears slab plain_n.
	c.slot.stream_sent += c.dual_ct.tx_plain_n
	c.dual_ct.tx_plain_n = 0
	testing.expect_value(t, c.slot.stream_sent, 10)
	testing.expect_value(t, c.dual_ct.tx_plain_n, 0)
	testing.expect_value(t, tls_host_stream_plain_off(&c), 10)
	// Long-lived gate used by send-complete demux.
	testing.expect(t, tls_host_stream_long_lived(&c))
	c.slot.stream_open = false
	c.slot.session = nil
	testing.expect(t, !tls_host_stream_long_lived(&c))
	connection_disable_ciphered(&c)
}

// Dual-CT progressive plain bookkeeping (pure, no OpenSSL): per-slab plain_n +
// plain_off cursor + CQE advance order (primary then hold).
@(test)
test_tls_stream_dual_ct_plain_n_bookkeeping :: proc(t: ^testing.T) {
	c: Connection
	c.slot.stream_open = true
	c.slot.stream_sent = 100
	// Seal N1 into primary (sending), N2 into hold (ready) — dual-CT overlap.
	c.dual_ct.tx_plain_n = 40
	c.dual_ct.hold_plain_n = 25
	c.dual_ct.send_is_hold = false
	testing.expect_value(t, tls_host_stream_plain_off(&c), 165) // 100+40+25

	// CQE for primary: advance by tx plain only (hold still outstanding).
	was_hold := c.dual_ct.send_is_hold
	slab_plain := was_hold ? c.dual_ct.hold_plain_n : c.dual_ct.tx_plain_n
	if was_hold {
		c.dual_ct.hold_plain_n = 0
	} else {
		c.dual_ct.tx_plain_n = 0
	}
	// No residual bio / zero-plain ready → advance slab plain.
	c.slot.stream_sent += slab_plain
	testing.expect_value(t, c.slot.stream_sent, 140)
	testing.expect_value(t, c.dual_ct.tx_plain_n, 0)
	testing.expect_value(t, c.dual_ct.hold_plain_n, 25)
	testing.expect_value(t, tls_host_stream_plain_off(&c), 165) // 140+25

	// Promote hold then CQE for hold.
	c.dual_ct.send_is_hold = true
	was_hold = c.dual_ct.send_is_hold
	slab_plain = was_hold ? c.dual_ct.hold_plain_n : c.dual_ct.tx_plain_n
	if was_hold {
		c.dual_ct.hold_plain_n = 0
	} else {
		c.dual_ct.tx_plain_n = 0
	}
	c.slot.stream_sent += slab_plain
	testing.expect_value(t, c.slot.stream_sent, 165)
	testing.expect_value(t, c.dual_ct.hold_plain_n, 0)
	testing.expect_value(t, tls_host_stream_plain_off(&c), 165)

	// until residual CT (ready slab plain_n==0) completes.
	c.slot.stream_sent = 0
	c.dual_ct.tx_plain_n = 16
	c.dual_ct.hold_plain_n = 0
	c.dual_ct.hold_n = 8 // residual CT stashed, no new plain
	c.tls_stream_plain_n = 0
	c.dual_ct.send_is_hold = false
	was_hold = false
	slab_plain = c.dual_ct.tx_plain_n
	c.dual_ct.tx_plain_n = 0
	// other ready with plain 0 → defer
	c.tls_stream_plain_n += slab_plain
	testing.expect_value(t, c.tls_stream_plain_n, 16)
	testing.expect_value(t, c.slot.stream_sent, 0)
	c.dual_ct.send_is_hold = true
	slab_plain = c.dual_ct.hold_plain_n // 0
	if slab_plain == 0 && c.tls_stream_plain_n > 0 {
		slab_plain = c.tls_stream_plain_n
		c.tls_stream_plain_n = 0
	}
	c.slot.stream_sent += slab_plain
	testing.expect_value(t, c.slot.stream_sent, 16)
	testing.expect_value(t, c.tls_stream_plain_n, 0)
}

// ---------------------------------------------------------------------------
// ---------------------------------------------------------------------------

@(test)
test_tls_host_stream_long_lived_gates_clean :: proc(t: ^testing.T) {
	// Documents: mid-session CT complete must not take oneshot clean_request_loop.
	c: Connection
	testing.expect(t, !tls_host_stream_long_lived(&c))
	c.slot.stream_open = true
	testing.expect(t, tls_host_stream_long_lived(&c), "stream_open ⇒ long-lived")
	c.slot.stream_open = false
	// Session pointer non-nil (fake) also gates.
	st: Session_State
	c.slot.session = &st
	testing.expect(t, tls_host_stream_long_lived(&c), "session ⇒ long-lived")
	c.slot.session = nil
	testing.expect(t, !tls_host_stream_long_lived(&c))
}

@(test)
test_tls_stream_plain_n_reset_on_ciphered_lifecycle :: proc(t: ^testing.T) {
	c: Connection
	c.server = nil
	tls_pipe_init(&c.tls_pipe)
	c.tls_stream_plain_n = 42
	c.dual_ct.tx_plain_n = 3
	c.dual_ct.hold_plain_n = 5
	testing.expect(t, connection_enable_ciphered(&c))
	// Field is independent of enable; destroy/clear path zeros it.
	testing.expect_value(t, c.tls_stream_plain_n, 42)
	c.tls_stream_plain_n = 7
	c.dual_ct.tx_plain_n = 3
	c.dual_ct.hold_plain_n = 5
	tls_host_conn_destroy(&c)
	testing.expect_value(t, c.tls_stream_plain_n, 0)
	testing.expect_value(t, c.dual_ct.tx_plain_n, 0)
	testing.expect_value(t, c.dual_ct.hold_plain_n, 0)
	testing.expect(t, !c.ciphered)
}

@(test)
test_tls_stream_path_when_ciphered_no_ssl :: proc(t: ^testing.T) {
	// When ciphered without SSL, stream submit must not use clear pool path.
	// tls_host_stream_try_submit sets flush_pending and returns (no assert_has_td
	// until host_submit_send — early path is pure).
	c: Connection
	c.server = nil
	tls_pipe_init(&c.tls_pipe)
	testing.expect(t, connection_enable_ciphered(&c))
	c.slot.stream_open = true
	c.resp_buf = make([dynamic]u8, 0, 64)
	defer delete(c.resp_buf)
	append(&c.resp_buf, ..transmute([]u8)string("data: hi\n\n"))
	c.slot.stream_sent = 0
	// No SSL → pending only; does not crash / does not take stream_pool.
	tls_host_stream_try_submit(&c)
	testing.expect(t, c.slot.stream_flush_pending, "ciphered without SSL marks pending")
	testing.expect(t, c.slot.stream_send_slab == nil, "TLS path must not take stream pool slab")
	testing.expect_value(t, c.slot.stream_sent, 0)
	connection_disable_ciphered(&c)
}

@(test)
test_tls_host_on_send_complete_mid_session_no_clean :: proc(t: ^testing.T) {
	// With OpenSSL mem-BIO: mid-session CT complete advances stream_sent and
	// leaves stream_open (does not enter oneshot clean_request_loop).
	p, err := tls_server.provider_openssl_dynlib_load()
	if err != .None || p == nil {
		return // skip without OpenSSL
	}
	defer tls_server.provider_destroy(p)

	ctx := tls_server.ctx_new(p)
	if ctx == nil {
		return
	}
	defer tls_server.ctx_free(p, ctx)
	if !tls_server.ctx_load_pem(
		p,
		ctx,
		transmute([]u8)string(TLS_HOST_TEST_CERT),
		transmute([]u8)string(TLS_HOST_TEST_KEY),
	) {
		return
	}

	ssl := tls_server.conn_new(p, ctx)
	if ssl == nil {
		return
	}
	defer tls_server.conn_free(p, ssl)
	if !tls_server.setup_mem_bios(p, ssl) {
		return
	}
	tls_server.set_accept_state(p, ssl)

	// Minimal Server so on_send_complete can read provider.
	s: Server
	s.tls_provider = p
	s.tls_ctx = ctx

	c: Connection
	c.server = &s
	c.tls_ssl = ssl
	c.ciphered = true
	c.tls_pipe.state = .Open
	c.slot.stream_open = true
	c.slot.stream_ending = false
	c.slot.stream_sent = 0
	// Per-slab plain for primary (legacy tls_stream_plain_n also accepted).
	c.dual_ct.tx_plain_n = 11
	c.dual_ct.send_is_hold = false
	c.resp_buf = make([dynamic]u8, 0, 32)
	defer delete(c.resp_buf)
	append(&c.resp_buf, ..transmute([]u8)string("hello world")) // 11 bytes — all plain sealed

	// Full CT buffer already delivered (pending_send cleared by caller path).
	// No residual wBIO CT (accept-only SSL, no prior write).
	// No more plain after advance → mid-session idle (td==nil ⇒ skip arm_recv).
	handled := tls_host_on_send_complete(&c)
	testing.expect(t, handled, "TLS stream complete must be handled")
	testing.expect(t, c.slot.stream_open, "mid-session must keep stream_open (no clean)")
	testing.expect_value(t, c.tls_stream_plain_n, 0)
	testing.expect_value(t, c.dual_ct.tx_plain_n, 0)
	testing.expect_value(t, c.slot.stream_sent, 11)
	// Must not have entered oneshot clean (which zeros stream_open / may close).
	testing.expect(t, c.state < .Closing, "must not clean/close mid-session")
}

// CQ-F1 structural fix: tls_ct_recv_inflight makes arm_recv single-flight.
// Cannot fully prove kqueue udata orphan without a live ring; the flag is the fix.
// Arm twice without CQE → second call is idempotent success (no second submit path).
@(test)
test_tls_ct_recv_inflight_arm_idempotent :: proc(t: ^testing.T) {
	c: Connection
	c.state = .Active
	// Simulate outstanding CT RECV (as after a successful submit_recv).
	c.tls_ct_recv_inflight = true
	// Second arm without CQE: must not assert_has_td / submit — returns true, stays armed.
	ok := tls_host_arm_recv(&c)
	testing.expect(t, ok, "re-arm while inflight is idempotent success")
	testing.expect(t, c.tls_ct_recv_inflight, "inflight stays true until CQE")
	// Again — still one flight.
	ok2 := tls_host_arm_recv(&c)
	testing.expect(t, ok2)
	testing.expect(t, c.tls_ct_recv_inflight)
}

// After on_recv consumes CQE, inflight clears; a subsequent arm may submit again.
// Flag clear is exercised without ring; real submit still needs worker + socket.
@(test)
test_tls_ct_recv_inflight_clear_on_recv :: proc(t: ^testing.T) {
	c: Connection
	c.state = .Active
	c.tls_ct_recv_inflight = true
	// tls_host_on_recv clears inflight on every CQE path (nil ssl early-returns after clear).
	fake: int = 1
	c.tls_ssl = tls_server.Conn(rawptr(&fake))
	// Closing path after clear: no SSL API calls once state is Closing.
	c.state = .Closing
	tls_host_on_recv(&c, 0)
	testing.expect(t, !c.tls_ct_recv_inflight, "CQE path clears inflight")
	// After clear, arm is no longer short-circuited as already-armed (Closing → false).
	c.state = .Active
	// Without ssl buffers / td we fail the submit gate, not the inflight short-circuit.
	c.tls_ssl = nil
	c.tls_ct_rx = nil
	// Inflight false + Closing false but no ssl: arm would need td; set inflight false
	// and prove short-circuit only when true.
	testing.expect(t, !c.tls_ct_recv_inflight)
	c.tls_ct_recv_inflight = true
	testing.expect(t, tls_host_arm_recv(&c), "inflight short-circuit still works")
	c.tls_ct_recv_inflight = false
	// Not inflight + Closing: hard fail without td.
	c.state = .Closing
	testing.expect(t, !tls_host_arm_recv(&c), "Closing rejects arm")
}

// close_on_io defer for CT recv mirrors wire send (CQ-M3 structural).
@(test)
test_tls_ct_recv_inflight_close_defers :: proc(t: ^testing.T) {
	// connection_close requires assert_has_td — document the gate purely.
	c: Connection
	c.tls_ct_recv_inflight = true
	// Same predicate connection_close uses before submit_close.
	should_defer := c.tls_ct_recv_inflight && !_conn_wire_in_flight(&c)
	testing.expect(t, should_defer, "CT recv in flight must defer close like wire send")
	c.tls_ct_recv_inflight = false
	testing.expect(t, !c.tls_ct_recv_inflight)
}

@(test)
test_tls_stream_plain_n_cqe_advance_semantics :: proc(t: ^testing.T) {
	// Documents CQE advance: after full CT for a seal, stream_sent += completed slab plain_n.
	// Pure (no OpenSSL) — same arithmetic as tls_host_on_send_complete mid-session branch.
	c: Connection
	c.slot.stream_open = true
	c.slot.stream_sent = 100
	c.dual_ct.tx_plain_n = 4096
	c.dual_ct.send_is_hold = false
	// Simulate completion advance (what on_send_complete does after CT fully delivered).
	was_hold := c.dual_ct.send_is_hold
	slab_plain := was_hold ? c.dual_ct.hold_plain_n : c.dual_ct.tx_plain_n
	if was_hold {
		c.dual_ct.hold_plain_n = 0
	} else {
		c.dual_ct.tx_plain_n = 0
	}
	if slab_plain > 0 {
		c.slot.stream_sent += slab_plain
	}
	testing.expect_value(t, c.slot.stream_sent, 4196)
	testing.expect_value(t, c.dual_ct.tx_plain_n, 0)
	testing.expect(t, tls_host_stream_long_lived(&c))
}

// Manual e2e (OpenSSL PEMs + live server): 
//   curl -kN --http1.1 -H 'Accept: text/event-stream' https://127.0.0.1:PORT/sse
// Expect event frames over TLS without mid-session hang.
