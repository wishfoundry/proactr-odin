// Unit smoke for tls_server OpenSSL dynlib provider.
//
// Run: odin test tls_server -o:none
//
// If system libssl cannot load, tests skip gracefully (do not fail the suite).
// When OpenSSL is present: ctx + PEM load + conn + mem-BIO smoke.
package tls_server

import "core:c"
import "core:testing"

// Minimal self-signed RSA cert+key for unit smoke (CN=localhost, 10y).
// Generated with openssl req -x509 -newkey rsa:2048 -nodes. Not for production.
TEST_CERT_PEM :: `-----BEGIN CERTIFICATE-----
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

TEST_KEY_PEM :: `-----BEGIN PRIVATE KEY-----
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
test_dynlib_load_or_skip :: proc(t: ^testing.T) {
	p, err := provider_openssl_dynlib_load()
	if err != .None || p == nil {
		// Graceful: dynlib missing is OK for CI without openssl.
		testing.expect(t, err == .Nil_Library || err == .Missing_Symbol)
		return
	}
	defer provider_destroy(p)
	testing.expect(t, p.name == "openssl-dynlib")
	testing.expect(t, p.setup_mem_bios != nil, "mem-BIO product path required")
	testing.expect(t, p.bio_write_net != nil)
	testing.expect(t, p.bio_read_net != nil)
	testing.expect(t, p.bio_pending_out != nil)
	testing.expect(t, p.set_fd != nil, "set_fd fallback may exist")
	// Error codes match OpenSSL.
	testing.expect_value(t, p.ERROR_NONE, c.int(0))
	testing.expect_value(t, p.ERROR_WANT_READ, c.int(2))
	testing.expect_value(t, p.ERROR_WANT_WRITE, c.int(3))
	testing.expect_value(t, p.ERROR_SSL, c.int(1))
	testing.expect_value(t, p.ERROR_SYSCALL, c.int(5))
	testing.expect_value(t, p.ERROR_ZERO_RETURN, c.int(6))
}

@(test)
test_ctx_load_pem_and_conn :: proc(t: ^testing.T) {
	p, err := provider_openssl_dynlib_load()
	if err != .None || p == nil {
		return // skip without openssl
	}
	defer provider_destroy(p)

	ctx := ctx_new(p)
	testing.expect(t, ctx != nil, "ctx_new")
	if ctx == nil do return
	defer ctx_free(p, ctx)

	cert := transmute([]u8)string(TEST_CERT_PEM)
	key := transmute([]u8)string(TEST_KEY_PEM)
	ok := ctx_load_pem(p, ctx, cert, key)
	testing.expect(t, ok, "ctx_load_pem self-signed PEM")

	ctx_set_alpn_select_cb(p, ctx, alpn_select_http11, nil)

	conn := conn_new(p, ctx)
	testing.expect(t, conn != nil, "conn_new")
	if conn == nil do return
	defer conn_free(p, conn)
}

@(test)
test_mem_bios_smoke :: proc(t: ^testing.T) {
	p, err := provider_openssl_dynlib_load()
	if err != .None || p == nil {
		return // skip without openssl
	}
	defer provider_destroy(p)

	ctx := ctx_new(p)
	if ctx == nil {
		testing.expect(t, false, "ctx_new")
		return
	}
	defer ctx_free(p, ctx)

	ok := ctx_load_pem(
		p,
		ctx,
		transmute([]u8)string(TEST_CERT_PEM),
		transmute([]u8)string(TEST_KEY_PEM),
	)
	testing.expect(t, ok, "ctx_load_pem")
	if !ok do return

	conn := conn_new(p, ctx)
	if conn == nil {
		testing.expect(t, false, "conn_new")
		return
	}
	defer conn_free(p, conn)

	// Product path: mem-BIO, no set_fd.
	mb := setup_mem_bios(p, conn)
	testing.expect(t, mb, "setup_mem_bios")
	if !mb do return

	// No client yet → accept should WANT_READ (needs ClientHello).
	ret := accept(p, conn)
	ge := get_error(p, conn, ret)
	testing.expect(
		t,
		ge == p.ERROR_WANT_READ || ge == p.ERROR_WANT_WRITE || ge == p.ERROR_SSL,
		"accept without peer yields WANT_* or SSL (not crash)",
	)

	// Outbound pending may be 0 before any write/handshake progress.
	_ = bio_pending_out(p, conn)

	// Empty write_net is a no-op (wrapper returns 0).
	n := bio_write_net(p, conn, nil)
	testing.expect_value(t, n, 0)
}

@(test)
test_alpn_select_http11_only :: proc(t: ^testing.T) {
	// Pure callback test — no libssl required.
	// Offer: h2 + http/1.1 → H1-only selector still picks http/1.1
	offer := []u8 {
		2, 'h', '2',
		8, 'h', 't', 't', 'p', '/', '1', '.', '1',
	}
	out: [^]u8
	out_len: u8
	rc := alpn_select_http11(nil, &out, &out_len, raw_data(offer), c.uint(len(offer)), nil)
	testing.expect_value(t, rc, c.int(0)) // OK
	testing.expect_value(t, out_len, u8(8))
	testing.expect(t, string(out[:out_len]) == "http/1.1")

	// Offer: h2 only → NOACK
	h2_only := []u8{2, 'h', '2'}
	rc2 := alpn_select_http11(nil, &out, &out_len, raw_data(h2_only), c.uint(len(h2_only)), nil)
	testing.expect_value(t, rc2, c.int(3)) // NOACK
}

@(test)
test_alpn_select_h2_or_http11 :: proc(t: ^testing.T) {
	// Pure callback test — no libssl required.
	out: [^]u8
	out_len: u8

	// Offer: h2 + http/1.1 → prefer h2
	both := []u8 {
		2, 'h', '2',
		8, 'h', 't', 't', 'p', '/', '1', '.', '1',
	}
	rc := alpn_select_h2_or_http11(nil, &out, &out_len, raw_data(both), c.uint(len(both)), nil)
	testing.expect_value(t, rc, c.int(0)) // OK
	testing.expect_value(t, out_len, u8(2))
	testing.expect(t, string(out[:out_len]) == "h2")

	// Offer: http/1.1 only → selects http/1.1
	h11_only := []u8 {
		8, 'h', 't', 't', 'p', '/', '1', '.', '1',
	}
	rc2 := alpn_select_h2_or_http11(nil, &out, &out_len, raw_data(h11_only), c.uint(len(h11_only)), nil)
	testing.expect_value(t, rc2, c.int(0)) // OK
	testing.expect_value(t, out_len, u8(8))
	testing.expect(t, string(out[:out_len]) == "http/1.1")

	// Offer: h3 only → NOACK
	h3_only := []u8{2, 'h', '3'}
	rc3 := alpn_select_h2_or_http11(nil, &out, &out_len, raw_data(h3_only), c.uint(len(h3_only)), nil)
	testing.expect_value(t, rc3, c.int(3)) // NOACK
}

@(test)
test_alpn_is_h2_nil_safe :: proc(t: ^testing.T) {
	// No provider / no conn → false (does not require libssl).
	testing.expect(t, !alpn_is_h2(nil, nil))
	testing.expect(t, !alpn_is_h2(nil, Conn(rawptr(uintptr(1)))))
}

@(test)
test_default_provider_dynlib :: proc(t: ^testing.T) {
	// Isolate from any prior default; free process-owned handle if present.
	if g_dynlib_owned != nil {
		provider_destroy(g_dynlib_owned)
		g_dynlib_owned = nil
	}
	set_default_provider(nil)

	p := default_provider()
	if p == nil {
		// No libssl — acceptable.
		return
	}
	testing.expect(t, p.name == "openssl-dynlib")
	testing.expect(t, p.setup_mem_bios != nil)

	// default_provider owns via g_dynlib_owned; release for the memory tracker.
	set_default_provider(nil)
	if g_dynlib_owned == p {
		provider_destroy(p)
		g_dynlib_owned = nil
	}
}

@(test)
test_config_default_backend :: proc(t: ^testing.T) {
	testing.expect_value(t, HTTP_TLS_BACKEND, "dynlib")
}
