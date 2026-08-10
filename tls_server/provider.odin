// Provider — host-injected SSL surface (IOC).
// Vtable methods take self (^Provider) so adapters can use user_data (dynlib).
//
// Opaque handles only: no SSL* / SSL_CTX* types leave this package into public
// http API. Host (Tls_Pipe / cipher module) holds Ctx/Conn as distinct rawptrs.
//
// Product I/O path (Plan A mem-BIO law):
//   setup_mem_bios → bio_write_net (inbound CT) / bio_read_net + bio_pending_out
//   (outbound CT) + accept/read/write on plaintext side.
// set_fd is an optional fallback for blocking/simple demos; not the product path.
package tls_server

import "core:c"

Ctx :: distinct rawptr
Conn :: distinct rawptr
Method :: distinct rawptr

// C calling convention so OpenSSL can invoke the ALPN select callback.
Alpn_Select_Cb :: #type proc "c" (
	ssl:     rawptr,
	out:     ^[^]u8,
	out_len: ^u8,
	in_data: [^]u8,
	in_len:  c.uint,
	arg:     rawptr,
) -> c.int

Provider :: struct {
	name: string,

	server_method:          proc(self: ^Provider) -> Method,
	ctx_new:                proc(self: ^Provider, method: Method) -> Ctx,
	ctx_free:               proc(self: ^Provider, ctx: Ctx),
	ctx_load_pem:           proc(self: ^Provider, ctx: Ctx, cert_pem, key_pem: []u8) -> bool,
	ctx_set_alpn_select_cb: proc(self: ^Provider, ctx: Ctx, cb: Alpn_Select_Cb, arg: rawptr),

	conn_new:  proc(self: ^Provider, ctx: Ctx) -> Conn,
	conn_free: proc(self: ^Provider, ssl: Conn),

	// Fallback: SSL_set_fd. Product path is mem-BIO (setup_mem_bios); prefer that.
	set_fd: proc(self: ^Provider, ssl: Conn, fd: c.int) -> c.int,

	// Optional: SSL_set_mode (nil = unsupported). Bits match OpenSSL SSL_MODE_*.
	set_mode: proc(self: ^Provider, ssl: Conn, mode: u32) -> u32,

	// Memory-BIO path (product). After setup_mem_bios, do not set_fd;
	// feed ciphertext with bio_write_net, drain with bio_read_net / bio_pending_out.
	setup_mem_bios:   proc(self: ^Provider, ssl: Conn) -> bool,
	bio_write_net:    proc(self: ^Provider, ssl: Conn, data: rawptr, n: c.int) -> c.int,
	bio_read_net:     proc(self: ^Provider, ssl: Conn, buf: rawptr, n: c.int) -> c.int,
	bio_pending_out:  proc(self: ^Provider, ssl: Conn) -> c.int,
	// Optional zero-copy wBIO view (mem-BIO BIO_get_mem_data). out_ptr → internal buf;
	// returns len. Valid only until bio_reset_out or further SSL/BIO ops.
	// nil procs = unsupported (callers fall back to bio_read_net).
	bio_peek_out:     proc(self: ^Provider, ssl: Conn, out_ptr: ^rawptr) -> c.int,
	bio_reset_out:    proc(self: ^Provider, ssl: Conn) -> c.int,
	// Hot-path: SSL_get_wbio once; then bio_*_out_bio(wbio) avoids get_wbio each drain.
	// nil = unsupported (callers keep using ssl-based bio_pending_out / peek / reset).
	get_wbio:            proc(self: ^Provider, ssl: Conn) -> rawptr,
	bio_pending_out_bio: proc(self: ^Provider, wbio: rawptr) -> c.int,
	bio_peek_out_bio:    proc(self: ^Provider, wbio: rawptr, out_ptr: ^rawptr) -> c.int,
	bio_reset_out_bio:   proc(self: ^Provider, wbio: rawptr) -> c.int,
	set_accept_state:    proc(self: ^Provider, ssl: Conn),

	accept:             proc(self: ^Provider, ssl: Conn) -> c.int,
	read:               proc(self: ^Provider, ssl: Conn, buf: rawptr, n: c.int) -> c.int,
	write:              proc(self: ^Provider, ssl: Conn, buf: rawptr, n: c.int) -> c.int,
	get_error:          proc(self: ^Provider, ssl: Conn, ret: c.int) -> c.int,
	shutdown:           proc(self: ^Provider, ssl: Conn) -> c.int,
	get0_alpn_selected: proc(self: ^Provider, ssl: Conn, out_data: ^[^]u8, out_len: ^c.uint),

	// SSL_get_error codes (adapter fills OpenSSL-compatible values).
	ERROR_NONE:        c.int,
	ERROR_SSL:         c.int,
	ERROR_WANT_READ:   c.int,
	ERROR_WANT_WRITE:  c.int,
	ERROR_SYSCALL:     c.int,
	ERROR_ZERO_RETURN: c.int,
	TLSEXT_ERR_OK:     c.int,
	TLSEXT_ERR_NOACK:  c.int,

	user_data: rawptr,
	destroy:   proc(self: ^Provider),
}

g_default: ^Provider

// Owned by default_provider() dynlib path; destroyed only if process exits
// without set_default_provider override (adapters own cleanup via destroy).
g_dynlib_owned: ^Provider

set_default_provider :: proc(p: ^Provider) {
	g_default = p
}

// Default for convenience APIs. Selected at compile time via HTTP_TLS_BACKEND
// (see config.odin). Override at runtime with set_default_provider or pass an
// explicit ^Provider into host init.
//
// PR5: only "dynlib". Returns nil if system libssl cannot be loaded — callers
// must handle that (tests skip; product host reports config error).
default_provider :: proc() -> ^Provider {
	if g_default != nil do return g_default

	backend := HTTP_TLS_BACKEND
	switch backend {
	case "dynlib":
		p, err := provider_openssl_dynlib_load(HTTP_TLS_DYNLIB_PATH)
		if err != .None || p == nil {
			return nil
		}
		g_dynlib_owned = p
		g_default = p
	case:
		// Unknown backend string — try dynlib as sole PR5 adapter.
		p, err := provider_openssl_dynlib_load(HTTP_TLS_DYNLIB_PATH)
		if err != .None || p == nil {
			return nil
		}
		g_dynlib_owned = p
		g_default = p
	}
	return g_default
}

// ---------------------------------------------------------------------------
// Thin wrappers (nil-safe)
// ---------------------------------------------------------------------------

ctx_new :: proc(p: ^Provider) -> Ctx {
	if p == nil || p.ctx_new == nil || p.server_method == nil do return nil
	return p.ctx_new(p, p.server_method(p))
}

ctx_free :: proc(p: ^Provider, ctx: Ctx) {
	if p != nil && ctx != nil && p.ctx_free != nil do p.ctx_free(p, ctx)
}

ctx_load_pem :: proc(p: ^Provider, ctx: Ctx, cert_pem, key_pem: []u8) -> bool {
	if p == nil || ctx == nil || p.ctx_load_pem == nil do return false
	return p.ctx_load_pem(p, ctx, cert_pem, key_pem)
}

ctx_set_alpn_select_cb :: proc(p: ^Provider, ctx: Ctx, cb: Alpn_Select_Cb, arg: rawptr) {
	if p != nil && ctx != nil && p.ctx_set_alpn_select_cb != nil {
		p.ctx_set_alpn_select_cb(p, ctx, cb, arg)
	}
}

conn_new :: proc(p: ^Provider, ctx: Ctx) -> Conn {
	if p == nil || ctx == nil || p.conn_new == nil do return nil
	return p.conn_new(p, ctx)
}

conn_free :: proc(p: ^Provider, ssl: Conn) {
	if p != nil && ssl != nil && p.conn_free != nil do p.conn_free(p, ssl)
}

// Fallback FD path — not the product mem-BIO path.
set_fd :: proc(p: ^Provider, ssl: Conn, fd: c.int) -> c.int {
	if p == nil || ssl == nil || p.set_fd == nil do return 0
	return p.set_fd(p, ssl, fd)
}

// SSL_MODE bits (OpenSSL). Optional via set_mode.
SSL_MODE_ENABLE_PARTIAL_WRITE       :: u32(0x00000001)
SSL_MODE_ACCEPT_MOVING_WRITE_BUFFER :: u32(0x00000002)

set_mode :: proc(p: ^Provider, ssl: Conn, mode: u32) -> u32 {
	if p == nil || ssl == nil || p.set_mode == nil do return 0
	return p.set_mode(p, ssl, mode)
}

// Install paired memory BIOs for app-owned ciphertext I/O (proactr / io_uring).
// SSL takes ownership of the BIOs. Returns false if provider lacks mem-BIO support.
setup_mem_bios :: proc(p: ^Provider, ssl: Conn) -> bool {
	if p == nil || ssl == nil || p.setup_mem_bios == nil do return false
	return p.setup_mem_bios(p, ssl)
}

// Write inbound network ciphertext into the SSL read BIO.
bio_write_net :: proc(p: ^Provider, ssl: Conn, data: []u8) -> int {
	if p == nil || ssl == nil || p.bio_write_net == nil || len(data) == 0 do return 0
	return int(p.bio_write_net(p, ssl, raw_data(data), c.int(len(data))))
}

// Read outbound network ciphertext from the SSL write BIO into buf.
bio_read_net :: proc(p: ^Provider, ssl: Conn, buf: []u8) -> int {
	if p == nil || ssl == nil || p.bio_read_net == nil || len(buf) == 0 do return 0
	return int(p.bio_read_net(p, ssl, raw_data(buf), c.int(len(buf))))
}

// Bytes of ciphertext waiting to be sent on the wire.
bio_pending_out :: proc(p: ^Provider, ssl: Conn) -> int {
	if p == nil || ssl == nil || p.bio_pending_out == nil do return 0
	return int(p.bio_pending_out(p, ssl))
}

// Zero-copy view of outbound CT in the mem-BIO wBIO (OpenSSL BIO_get_mem_data).
// Empty if unsupported or no data. Do not free; invalid after bio_reset_out / SSL_write.
bio_peek_out :: proc(p: ^Provider, ssl: Conn) -> []u8 {
	if p == nil || ssl == nil || p.bio_peek_out == nil {
		return nil
	}
	data: rawptr
	n := p.bio_peek_out(p, ssl, &data)
	if n <= 0 || data == nil {
		return nil
	}
	return ([^]u8)(data)[:int(n)]
}

// Discard all data in the wBIO (BIO_reset). Call after send or after residual stash copy.
bio_reset_out :: proc(p: ^Provider, ssl: Conn) -> bool {
	if p == nil || ssl == nil || p.bio_reset_out == nil {
		return false
	}
	return p.bio_reset_out(p, ssl) == 1
}

// SSL write-BIO pointer (opaque). Cache once after setup_mem_bios for hot drain.
// nil if provider lacks get_wbio or mem-BIO not set up.
get_wbio :: proc(p: ^Provider, ssl: Conn) -> rawptr {
	if p == nil || ssl == nil || p.get_wbio == nil {
		return nil
	}
	return p.get_wbio(p, ssl)
}

// Direct wBIO ops — no SSL_get_wbio. Hot path when host caches wbio on Connection.
bio_pending_out_bio :: proc(p: ^Provider, wbio: rawptr) -> int {
	if p == nil || wbio == nil || p.bio_pending_out_bio == nil {
		return 0
	}
	return int(p.bio_pending_out_bio(p, wbio))
}

bio_peek_out_bio :: proc(p: ^Provider, wbio: rawptr) -> []u8 {
	if p == nil || wbio == nil || p.bio_peek_out_bio == nil {
		return nil
	}
	data: rawptr
	n := p.bio_peek_out_bio(p, wbio, &data)
	if n <= 0 || data == nil {
		return nil
	}
	return ([^]u8)(data)[:int(n)]
}

bio_reset_out_bio :: proc(p: ^Provider, wbio: rawptr) -> bool {
	if p == nil || wbio == nil || p.bio_reset_out_bio == nil {
		return false
	}
	return p.bio_reset_out_bio(p, wbio) == 1
}

// True when peek+reset are wired (Darwin reactor CT drain prefers this).
// Direct-bio path (bio_*_out_bio) is preferred when host has a cached wbio.
bio_peek_supported :: proc(p: ^Provider) -> bool {
	if p == nil {
		return false
	}
	if p.bio_peek_out_bio != nil && p.bio_reset_out_bio != nil {
		return true
	}
	return p.bio_peek_out != nil && p.bio_reset_out != nil
}

set_accept_state :: proc(p: ^Provider, ssl: Conn) {
	if p != nil && ssl != nil && p.set_accept_state != nil do p.set_accept_state(p, ssl)
}

accept :: proc(p: ^Provider, ssl: Conn) -> c.int {
	if p == nil || ssl == nil || p.accept == nil do return 0
	return p.accept(p, ssl)
}

read :: proc(p: ^Provider, ssl: Conn, buf: rawptr, n: c.int) -> c.int {
	if p == nil || ssl == nil || p.read == nil do return 0
	return p.read(p, ssl, buf, n)
}

write :: proc(p: ^Provider, ssl: Conn, buf: rawptr, n: c.int) -> c.int {
	if p == nil || ssl == nil || p.write == nil do return 0
	return p.write(p, ssl, buf, n)
}

get_error :: proc(p: ^Provider, ssl: Conn, ret: c.int) -> c.int {
	if p == nil || ssl == nil || p.get_error == nil do return 0
	return p.get_error(p, ssl, ret)
}

shutdown :: proc(p: ^Provider, ssl: Conn) -> c.int {
	if p == nil || ssl == nil || p.shutdown == nil do return 0
	return p.shutdown(p, ssl)
}

get0_alpn_selected :: proc(p: ^Provider, ssl: Conn, out_data: ^[^]u8, out_len: ^c.uint) {
	if p != nil && ssl != nil && p.get0_alpn_selected != nil {
		p.get0_alpn_selected(p, ssl, out_data, out_len)
	}
}

provider_destroy :: proc(p: ^Provider) {
	if p == nil do return
	if p.destroy != nil do p.destroy(p)
}

// ---------------------------------------------------------------------------
// ALPN select — wire format of in_data: repeated (1-byte length + protocol bytes).
// Product host: alpn_select_h2_or_http11 (prefer h2, fallback http/1.1).
// alpn_select_http11 kept for H1-only tests.
// ---------------------------------------------------------------------------

ALPN_H2     :: "h2"
ALPN_HTTP11 :: "http/1.1"

// Scan client ALPN list for want. On match, out points at the static want bytes.
// contextless: called from OpenSSL C ALPN select callbacks (no Odin context).
@(private)
_alpn_match :: proc "contextless" (in_data: [^]u8, in_len: c.uint, want: string) -> (ok: bool, ptr: [^]u8, plen: u8) {
	w := transmute([]u8)want
	i: c.uint = 0
	for i < in_len {
		n := c.uint(in_data[i])
		i += 1
		if i + n > in_len do break
		if n == c.uint(len(w)) {
			match := true
			for j in 0 ..< n {
				if in_data[i + j] != w[j] {
					match = false
					break
				}
			}
			if match {
				return true, raw_data(w), u8(n)
			}
		}
		i += n
	}
	return false, nil, 0
}

// Use with ctx_set_alpn_select_cb(p, ctx, alpn_select_http11, nil).
// Returns TLSEXT_ERR_OK (0) when http/1.1 is offered; TLSEXT_ERR_NOACK (3) otherwise.
// H1-only — tests and callers that must not negotiate h2.
alpn_select_http11 :: proc "c" (
	ssl:     rawptr,
	out:     ^[^]u8,
	out_len: ^u8,
	in_data: [^]u8,
	in_len:  c.uint,
	arg:     rawptr,
) -> c.int {
	_ = ssl
	_ = arg
	ok, ptr, plen := _alpn_match(in_data, in_len, ALPN_HTTP11)
	if ok {
		out^ = ptr
		out_len^ = plen
		return 0 // SSL_TLSEXT_ERR_OK
	}
	return 3 // SSL_TLSEXT_ERR_NOACK
}

// Prefer h2 if the client offers it; else http/1.1; else NOACK.
// Engineering ALPN for dual-stack TLS — does not imply product HTTP/2 framing.
alpn_select_h2_or_http11 :: proc "c" (
	ssl:     rawptr,
	out:     ^[^]u8,
	out_len: ^u8,
	in_data: [^]u8,
	in_len:  c.uint,
	arg:     rawptr,
) -> c.int {
	_ = ssl
	_ = arg
	if ok, ptr, plen := _alpn_match(in_data, in_len, ALPN_H2); ok {
		out^ = ptr
		out_len^ = plen
		return 0 // SSL_TLSEXT_ERR_OK
	}
	if ok, ptr, plen := _alpn_match(in_data, in_len, ALPN_HTTP11); ok {
		out^ = ptr
		out_len^ = plen
		return 0 // SSL_TLSEXT_ERR_OK
	}
	return 3 // SSL_TLSEXT_ERR_NOACK
}

// True if the negotiated ALPN protocol is "h2" (post-handshake).
alpn_is_h2 :: proc(p: ^Provider, ssl: Conn) -> bool {
	if p == nil || ssl == nil || p.get0_alpn_selected == nil do return false
	data: [^]u8
	n:    c.uint
	get0_alpn_selected(p, ssl, &data, &n)
	if data == nil || n == 0 do return false
	return string(data[:n]) == ALPN_H2
}
