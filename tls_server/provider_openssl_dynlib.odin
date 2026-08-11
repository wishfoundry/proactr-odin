// Dynlib OpenSSL via shared package openssl_dynlib (single process-wide load).
// No static BoringSSL; no second dlopen of libssl.
package tls_server

import "core:c"

import od "../openssl_dynlib"

@(private)
Dynlib_State :: struct {
	// Marks provider built on shared Os (never unload libssl here).
	shared: bool,
}

Provider_Dynlib_Error :: enum {
	None,
	Missing_Symbol,
	Nil_Library,
	Load_Failed,
}

// Load OpenSSL via openssl_dynlib and build a Provider.
// path argument is ignored after first process load — use #config PROACTR_OPENSSL_DYNLIB_PATH.
// owns_lib is always false (openssl_dynlib owns the dylib).
provider_openssl_dynlib_load :: proc(
	path: string = "",
	allocator := context.allocator,
) -> (p: ^Provider, err: Provider_Dynlib_Error) {
	_ = path // path only via #config at openssl_dynlib first load
	if !od.os_ensure_ssl() {
		return nil, .Load_Failed
	}
	return provider_openssl_dynlib_from_shared(allocator)
}

// Build Provider from already-loaded openssl_dynlib.Os.
provider_openssl_dynlib_from_shared :: proc(
	allocator := context.allocator,
) -> (p: ^Provider, err: Provider_Dynlib_Error) {
	if !od.g_os.ssl_ready {
		return nil, .Load_Failed
	}
	// Sanity: required symbols for product mem-BIO path.
	if od.g_os.TLS_server_method == nil ||
	   od.g_os.SSL_CTX_new == nil ||
	   od.g_os.BIO_s_mem == nil ||
	   od.g_os.BIO_ctrl == nil {
		return nil, .Missing_Symbol
	}

	st := new(Dynlib_State, allocator)
	st.shared = true

	p = new(Provider, allocator)
	p.name = "openssl-dynlib"
	p.user_data = st
	p.destroy = _dynlib_provider_destroy
	p.ERROR_NONE = 0
	p.ERROR_SSL = 1
	p.ERROR_WANT_READ = 2
	p.ERROR_WANT_WRITE = 3
	p.ERROR_SYSCALL = 5
	p.ERROR_ZERO_RETURN = 6
	p.TLSEXT_ERR_OK = 0
	p.TLSEXT_ERR_NOACK = 3

	p.server_method = proc(self: ^Provider) -> Method {
		_ = self
		return Method(od.g_os.TLS_server_method())
	}
	p.ctx_new = proc(self: ^Provider, method: Method) -> Ctx {
		_ = self
		return Ctx(od.g_os.SSL_CTX_new(rawptr(method)))
	}
	p.ctx_free = proc(self: ^Provider, ctx: Ctx) {
		_ = self
		od.g_os.SSL_CTX_free(rawptr(ctx))
	}
	p.ctx_load_pem = proc(self: ^Provider, ctx: Ctx, cert_pem, key_pem: []u8) -> bool {
		_ = self
		return _dynlib_ctx_load_pem(ctx, cert_pem, key_pem)
	}
	p.ctx_set_alpn_select_cb = proc(self: ^Provider, ctx: Ctx, cb: Alpn_Select_Cb, arg: rawptr) {
		_ = self
		od.g_os.SSL_CTX_set_alpn_select_cb(rawptr(ctx), rawptr(cb), arg)
	}
	p.conn_new = proc(self: ^Provider, ctx: Ctx) -> Conn {
		_ = self
		return Conn(od.g_os.SSL_new(rawptr(ctx)))
	}
	p.conn_free = proc(self: ^Provider, ssl: Conn) {
		_ = self
		od.g_os.SSL_free(rawptr(ssl))
	}
	p.set_fd = proc(self: ^Provider, ssl: Conn, fd: c.int) -> c.int {
		_ = self
		return od.g_os.SSL_set_fd(rawptr(ssl), fd)
	}
	if od.g_os.SSL_set_mode != nil {
		p.set_mode = proc(self: ^Provider, ssl: Conn, mode: u32) -> u32 {
			_ = self
			return u32(od.g_os.SSL_set_mode(rawptr(ssl), c.long(mode)))
		}
	}
	p.setup_mem_bios = proc(self: ^Provider, ssl: Conn) -> bool {
		_ = self
		rbio := od.g_os.BIO_new(od.g_os.BIO_s_mem())
		wbio := od.g_os.BIO_new(od.g_os.BIO_s_mem())
		if rbio == nil || wbio == nil {
			if rbio != nil do od.g_os.BIO_free(rbio)
			if wbio != nil do od.g_os.BIO_free(wbio)
			return false
		}
		od.g_os.SSL_set_bio(rawptr(ssl), rbio, wbio)
		od.g_os.SSL_set_accept_state(rawptr(ssl))
		return true
	}
	p.bio_write_net = proc(self: ^Provider, ssl: Conn, data: rawptr, n: c.int) -> c.int {
		_ = self
		rbio := od.g_os.SSL_get_rbio(rawptr(ssl))
		if rbio == nil do return -1
		return od.g_os.BIO_write(rbio, data, n)
	}
	p.bio_read_net = proc(self: ^Provider, ssl: Conn, buf: rawptr, n: c.int) -> c.int {
		_ = self
		wbio := od.g_os.SSL_get_wbio(rawptr(ssl))
		if wbio == nil do return -1
		return od.g_os.BIO_read(wbio, buf, n)
	}
	p.bio_pending_out = proc(self: ^Provider, ssl: Conn) -> c.int {
		_ = self
		wbio := od.g_os.SSL_get_wbio(rawptr(ssl))
		if wbio == nil do return 0
		return c.int(od.g_os.BIO_ctrl_pending(wbio))
	}
	p.get_wbio = proc(self: ^Provider, ssl: Conn) -> rawptr {
		_ = self
		return od.g_os.SSL_get_wbio(rawptr(ssl))
	}
	p.bio_pending_out_bio = proc(self: ^Provider, wbio: rawptr) -> c.int {
		_ = self
		if wbio == nil do return 0
		return c.int(od.g_os.BIO_ctrl_pending(wbio))
	}
	if od.g_os.BIO_ctrl != nil {
		p.bio_peek_out = proc(self: ^Provider, ssl: Conn, out_ptr: ^rawptr) -> c.int {
			_ = self
			if out_ptr == nil do return 0
			wbio := od.g_os.SSL_get_wbio(rawptr(ssl))
			if wbio == nil do return 0
			out_ptr^ = nil
			n := od.g_os.BIO_ctrl(wbio, 3, 0, out_ptr)
			if n <= 0 || out_ptr^ == nil do return 0
			return c.int(n)
		}
		p.bio_reset_out = proc(self: ^Provider, ssl: Conn) -> c.int {
			_ = self
			wbio := od.g_os.SSL_get_wbio(rawptr(ssl))
			if wbio == nil do return 0
			rc := od.g_os.BIO_ctrl(wbio, 1, 0, nil)
			return 1 if rc >= 0 else 0
		}
		p.bio_peek_out_bio = proc(self: ^Provider, wbio: rawptr, out_ptr: ^rawptr) -> c.int {
			_ = self
			if wbio == nil || out_ptr == nil do return 0
			out_ptr^ = nil
			n := od.g_os.BIO_ctrl(wbio, 3, 0, out_ptr)
			if n <= 0 || out_ptr^ == nil do return 0
			return c.int(n)
		}
		p.bio_reset_out_bio = proc(self: ^Provider, wbio: rawptr) -> c.int {
			_ = self
			if wbio == nil do return 0
			rc := od.g_os.BIO_ctrl(wbio, 1, 0, nil)
			return 1 if rc >= 0 else 0
		}
	}
	p.set_accept_state = proc(self: ^Provider, ssl: Conn) {
		_ = self
		od.g_os.SSL_set_accept_state(rawptr(ssl))
	}
	p.accept = proc(self: ^Provider, ssl: Conn) -> c.int {
		_ = self
		return od.g_os.SSL_accept(rawptr(ssl))
	}
	p.read = proc(self: ^Provider, ssl: Conn, buf: rawptr, n: c.int) -> c.int {
		_ = self
		return od.g_os.SSL_read(rawptr(ssl), buf, n)
	}
	p.write = proc(self: ^Provider, ssl: Conn, buf: rawptr, n: c.int) -> c.int {
		_ = self
		return od.g_os.SSL_write(rawptr(ssl), buf, n)
	}
	p.get_error = proc(self: ^Provider, ssl: Conn, ret: c.int) -> c.int {
		_ = self
		return od.g_os.SSL_get_error(rawptr(ssl), ret)
	}
	p.shutdown = proc(self: ^Provider, ssl: Conn) -> c.int {
		_ = self
		return od.g_os.SSL_shutdown(rawptr(ssl))
	}
	p.get0_alpn_selected = proc(self: ^Provider, ssl: Conn, out_data: ^[^]u8, out_len: ^c.uint) {
		_ = self
		od.g_os.SSL_get0_alpn_selected(rawptr(ssl), out_data, out_len)
	}
	return p, .None
}

// Kept for API compatibility; ignores lib — always uses shared Os.
provider_openssl_dynlib :: proc(
	lib: rawptr,
	owns_lib := false,
	allocator := context.allocator,
) -> (p: ^Provider, err: Provider_Dynlib_Error) {
	_ = lib
	_ = owns_lib
	return provider_openssl_dynlib_from_shared(allocator)
}

@(private)
_dynlib_ctx_load_pem :: proc(ctx: Ctx, cert_pem, key_pem: []u8) -> bool {
	cbio := od.g_os.BIO_new_mem_buf(raw_data(cert_pem), c.int(len(cert_pem)))
	if cbio == nil do return false
	defer od.g_os.BIO_free(cbio)
	cert := od.g_os.PEM_read_bio_X509(cbio, nil, nil, nil)
	if cert == nil do return false
	defer od.g_os.X509_free(cert)
	if od.g_os.SSL_CTX_use_certificate(rawptr(ctx), cert) != 1 do return false

	kbio := od.g_os.BIO_new_mem_buf(raw_data(key_pem), c.int(len(key_pem)))
	if kbio == nil do return false
	defer od.g_os.BIO_free(kbio)
	key := od.g_os.PEM_read_bio_PrivateKey(kbio, nil, nil, nil)
	if key == nil do return false
	defer od.g_os.EVP_PKEY_free(key)
	return od.g_os.SSL_CTX_use_PrivateKey(rawptr(ctx), key) == 1
}

@(private)
_dynlib_provider_destroy :: proc(self: ^Provider) {
	if self == nil do return
	st := (^Dynlib_State)(self.user_data)
	if st != nil {
		// Never unload shared openssl_dynlib.
		free(st)
	}
	free(self)
}
