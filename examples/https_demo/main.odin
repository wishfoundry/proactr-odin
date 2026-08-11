// Manual HTTPS oneshot + SSE demo.
// Self-signed localhost cert.
//   odin build examples/https_demo -out:examples/https_demo/https_demo.bin -o:none
//   ./examples/https_demo/https_demo.bin
//   curl -k --http1.1 https://127.0.0.1:18443/
//   curl -kN --http1.1 -H 'Accept: text/event-stream' https://127.0.0.1:18443/sse
//   curl -k --http2 https://127.0.0.1:18443/   # eng unary H2 probe only
// Not a product example (E0 sample remains examples/empty_ok clear-H1).
package main

import "core:fmt"
import "core:log"
import "core:net"
import "core:os"
import "core:time"

import http "../../http"

// Demo pad for /sse (conn-allocated via sse_alloc).
Tick :: struct {
	n: int,
}

CERT :: `-----BEGIN CERTIFICATE-----
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

KEY :: `-----BEGIN PRIVATE KEY-----
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

main :: proc() {
	context.logger = log.create_console_logger(.Info)
	port := 18443
	if p := os.get_env_alloc("PORT", context.allocator); p != "" {
		// ignore parse for demo; default 18443
		delete(p)
	}

	b: http.Builder
	http.builder_init(&b)
	defer http.builder_destroy(&b)
	http.builder_get_fn(&b, "/", proc(req: ^http.Request, res: ^http.Response) {
		http.respond_plain(res, "OK")
	})
	http.builder_get_fn(&b, "/sse", proc(req: ^http.Request, res: ^http.Response) {
		_ = req
		pad := cast(^Tick)http.sse_alloc(res, size_of(Tick))
		http.sse_start(res, on_sse_ticks, {user = pad})
	})

	s: http.Server
	http.server_shutdown_on_interrupt(&s)
	opts := http.Default_Server_Opts
	opts.thread_count = 1
	opts.tls_cert_pem = transmute([]u8)string(CERT)
	opts.tls_key_pem = transmute([]u8)string(KEY)

	log.infof("proactr HTTPS demo on :%d (self-signed; curl -k --http1.1 [/ and /sse])", port)
	err, build_err := http.listen_builder(
		&s,
		&b,
		net.Endpoint{address = net.IP4_Address{127, 0, 0, 1}, port = port},
		opts,
	)
	if build_err.kind != .None {
		fmt.eprintf("route build: %s\n", http.builder_error_format(build_err))
		os.exit(1)
	}
	fmt.eprintf("server exited: %v\n", err)
	if err == .Unsupported {
		os.exit(2)
	}
}

on_sse_ticks :: proc(sess: ^http.Session, ev: http.Session_Event, user: rawptr) -> http.Effects {
	_ = sess
	st := (^Tick)(user)
	switch ev.kind {
	case .Start:
		return http.effects_of(
			http.effect_sse_event("hello", "ok"),
			http.effect_arm(200 * time.Millisecond),
		)
	case .Timer:
		st.n += 1
		if st.n >= 3 {
			return http.effects_of(http.effect_sse_data("bye"), http.effect_end())
		}
		return http.effects_of(
			http.effect_sse_data(fmt.tprintf("%d", st.n)),
			http.effect_arm(200 * time.Millisecond),
		)
	case .Client_Gone, .Idle_Timeout:
		return http.effects_of(http.effect_abort())
	case .External, .Writable:
		return {}
	}
	return {}
}
