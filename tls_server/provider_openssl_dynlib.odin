// Dynlib OpenSSL — load system libssl via core:dynlib (host may inject path).
// PR5: no static BoringSSL/OpenSSL .a. Mem-BIO is fully wired (product path).
package tls_server

import "core:c"
import "core:dynlib"

@(private)
Dynlib_State :: struct {
	lib:      dynlib.Library,
	owns_lib: bool,

	TLS_server_method:          proc "c" () -> rawptr,
	SSL_CTX_new:                proc "c" (method: rawptr) -> rawptr,
	SSL_CTX_free:               proc "c" (ctx: rawptr),
	SSL_new:                    proc "c" (ctx: rawptr) -> rawptr,
	SSL_free:                   proc "c" (ssl: rawptr),
	SSL_set_fd:                 proc "c" (ssl: rawptr, fd: c.int) -> c.int,
	SSL_set_bio:                proc "c" (ssl: rawptr, rbio: rawptr, wbio: rawptr),
	SSL_set_accept_state:       proc "c" (ssl: rawptr),
	SSL_get_rbio:               proc "c" (ssl: rawptr) -> rawptr,
	SSL_get_wbio:               proc "c" (ssl: rawptr) -> rawptr,
	SSL_accept:                 proc "c" (ssl: rawptr) -> c.int,
	SSL_read:                   proc "c" (ssl: rawptr, buf: rawptr, n: c.int) -> c.int,
	SSL_write:                  proc "c" (ssl: rawptr, buf: rawptr, n: c.int) -> c.int,
	SSL_get_error:              proc "c" (ssl: rawptr, ret: c.int) -> c.int,
	SSL_shutdown:               proc "c" (ssl: rawptr) -> c.int,
	SSL_get0_alpn_selected:     proc "c" (ssl: rawptr, out_data: ^[^]u8, out_len: ^c.uint),
	SSL_CTX_set_alpn_select_cb: proc "c" (ctx: rawptr, cb: rawptr, arg: rawptr),
	SSL_set_mode:               proc "c" (ssl: rawptr, mode: c.long) -> c.long,

	BIO_s_mem:       proc "c" () -> rawptr,
	BIO_new:         proc "c" (method: rawptr) -> rawptr,
	BIO_new_mem_buf: proc "c" (buf: rawptr, len: c.int) -> rawptr,
	BIO_free:        proc "c" (b: rawptr) -> c.int,
	BIO_write:        proc "c" (b: rawptr, data: rawptr, n: c.int) -> c.int,
	BIO_read:         proc "c" (b: rawptr, data: rawptr, n: c.int) -> c.int,
	BIO_ctrl_pending: proc "c" (b: rawptr) -> c.size_t,
	// BIO_ctrl: BIO_CTRL_RESET=1, BIO_CTRL_INFO=3 (BIO_get_mem_data).
	BIO_ctrl:         proc "c" (b: rawptr, cmd: c.int, larg: c.long, parg: rawptr) -> c.long,

	PEM_read_bio_X509:       proc "c" (bp, x, cb, u: rawptr) -> rawptr,
	PEM_read_bio_PrivateKey: proc "c" (bp, x, cb, u: rawptr) -> rawptr,
	SSL_CTX_use_certificate: proc "c" (ctx, x: rawptr) -> c.int,
	SSL_CTX_use_PrivateKey:  proc "c" (ctx, pkey: rawptr) -> c.int,
	X509_free:               proc "c" (x: rawptr),
	EVP_PKEY_free:           proc "c" (pkey: rawptr),
}

Provider_Dynlib_Error :: enum {
	None,
	Missing_Symbol,
	Nil_Library,
}

// Load OpenSSL from a path or platform default probe list and build a Provider.
// Owns the dynlib handle (destroy unloads it).
provider_openssl_dynlib_load :: proc(
	path: string = "",
	allocator := context.allocator,
) -> (p: ^Provider, err: Provider_Dynlib_Error) {
	candidates: [8]string
	n := 0
	if len(path) > 0 {
		candidates[0] = path
		n = 1
	} else {
		when ODIN_OS == .Linux {
			candidates[0] = "libssl.so.3"
			candidates[1] = "libssl.so.1.1"
			candidates[2] = "libssl.so"
			n = 3
		} else when ODIN_OS == .Darwin {
			// Prefer absolute Homebrew / MacPorts paths first.
			// Bare "libssl.dylib" resolves to Apple's system library which
			// intentionally aborts in __report_load when dlopened ("loading
			// libcrypto in an unsafe way"). Never probe bare libssl.dylib.
			candidates[0] = "/opt/homebrew/opt/openssl@3/lib/libssl.3.dylib"
			candidates[1] = "/opt/homebrew/opt/openssl/lib/libssl.dylib"
			candidates[2] = "/usr/local/opt/openssl@3/lib/libssl.3.dylib"
			candidates[3] = "/usr/local/opt/openssl/lib/libssl.dylib"
			candidates[4] = "/opt/local/lib/libssl.3.dylib"
			candidates[5] = "libssl.3.dylib" // rpath / DYLD_LIBRARY_PATH only
			n = 6
		} else when ODIN_OS == .Windows {
			candidates[0] = "libssl-3-x64.dll"
			candidates[1] = "libssl-3.dll"
			candidates[2] = "libssl.dll"
			n = 3
		} else {
			candidates[0] = "libssl.so"
			n = 1
		}
	}
	for i in 0 ..< n {
		lib, ok := dynlib.load_library(candidates[i])
		if !ok || lib == nil do continue
		p, err = provider_openssl_dynlib(lib, owns_lib = true, allocator = allocator)
		if err == .None do return p, .None
		dynlib.unload_library(lib)
	}
	return nil, .Nil_Library
}

provider_openssl_dynlib :: proc(
	lib: dynlib.Library,
	owns_lib := false,
	allocator := context.allocator,
) -> (p: ^Provider, err: Provider_Dynlib_Error) {
	if lib == nil do return nil, .Nil_Library

	st := new(Dynlib_State, allocator)
	st.lib = lib
	st.owns_lib = owns_lib
	if !_resolve_openssl_syms(st) {
		free(st, allocator)
		return nil, .Missing_Symbol
	}

	p = new(Provider, allocator)
	p.name = "openssl-dynlib"
	p.user_data = st
	p.destroy = _dynlib_provider_destroy
	// OpenSSL SSL_get_error constants.
	p.ERROR_NONE = 0
	p.ERROR_SSL = 1
	p.ERROR_WANT_READ = 2
	p.ERROR_WANT_WRITE = 3
	p.ERROR_SYSCALL = 5
	p.ERROR_ZERO_RETURN = 6
	p.TLSEXT_ERR_OK = 0
	p.TLSEXT_ERR_NOACK = 3

	p.server_method = proc(self: ^Provider) -> Method {
		s := (^Dynlib_State)(self.user_data)
		return Method(s.TLS_server_method())
	}
	p.ctx_new = proc(self: ^Provider, method: Method) -> Ctx {
		s := (^Dynlib_State)(self.user_data)
		return Ctx(s.SSL_CTX_new(rawptr(method)))
	}
	p.ctx_free = proc(self: ^Provider, ctx: Ctx) {
		s := (^Dynlib_State)(self.user_data)
		s.SSL_CTX_free(rawptr(ctx))
	}
	p.ctx_load_pem = proc(self: ^Provider, ctx: Ctx, cert_pem, key_pem: []u8) -> bool {
		s := (^Dynlib_State)(self.user_data)
		return _dynlib_ctx_load_pem(s, ctx, cert_pem, key_pem)
	}
	p.ctx_set_alpn_select_cb = proc(self: ^Provider, ctx: Ctx, cb: Alpn_Select_Cb, arg: rawptr) {
		s := (^Dynlib_State)(self.user_data)
		s.SSL_CTX_set_alpn_select_cb(rawptr(ctx), rawptr(cb), arg)
	}
	p.conn_new = proc(self: ^Provider, ctx: Ctx) -> Conn {
		s := (^Dynlib_State)(self.user_data)
		return Conn(s.SSL_new(rawptr(ctx)))
	}
	p.conn_free = proc(self: ^Provider, ssl: Conn) {
		s := (^Dynlib_State)(self.user_data)
		s.SSL_free(rawptr(ssl))
	}
	// Fallback FD path — product uses setup_mem_bios.
	p.set_fd = proc(self: ^Provider, ssl: Conn, fd: c.int) -> c.int {
		s := (^Dynlib_State)(self.user_data)
		return s.SSL_set_fd(rawptr(ssl), fd)
	}
	if st.SSL_set_mode != nil {
		p.set_mode = proc(self: ^Provider, ssl: Conn, mode: u32) -> u32 {
			s := (^Dynlib_State)(self.user_data)
			return u32(s.SSL_set_mode(rawptr(ssl), c.long(mode)))
		}
	}
	// Product mem-BIO path.
	p.setup_mem_bios = proc(self: ^Provider, ssl: Conn) -> bool {
		s := (^Dynlib_State)(self.user_data)
		rbio := s.BIO_new(s.BIO_s_mem())
		wbio := s.BIO_new(s.BIO_s_mem())
		if rbio == nil || wbio == nil {
			if rbio != nil do s.BIO_free(rbio)
			if wbio != nil do s.BIO_free(wbio)
			return false
		}
		// SSL takes ownership of both BIOs.
		s.SSL_set_bio(rawptr(ssl), rbio, wbio)
		s.SSL_set_accept_state(rawptr(ssl))
		return true
	}
	p.bio_write_net = proc(self: ^Provider, ssl: Conn, data: rawptr, n: c.int) -> c.int {
		s := (^Dynlib_State)(self.user_data)
		rbio := s.SSL_get_rbio(rawptr(ssl))
		if rbio == nil do return -1
		return s.BIO_write(rbio, data, n)
	}
	p.bio_read_net = proc(self: ^Provider, ssl: Conn, buf: rawptr, n: c.int) -> c.int {
		s := (^Dynlib_State)(self.user_data)
		wbio := s.SSL_get_wbio(rawptr(ssl))
		if wbio == nil do return -1
		return s.BIO_read(wbio, buf, n)
	}
	p.bio_pending_out = proc(self: ^Provider, ssl: Conn) -> c.int {
		s := (^Dynlib_State)(self.user_data)
		wbio := s.SSL_get_wbio(rawptr(ssl))
		if wbio == nil do return 0
		return c.int(s.BIO_ctrl_pending(wbio))
	}
	// Zero-copy wBIO view (drogon sendTLSData shape) when BIO_ctrl resolved.
	if st.BIO_ctrl != nil {
		p.bio_peek_out = proc(self: ^Provider, ssl: Conn, out_ptr: ^rawptr) -> c.int {
			s := (^Dynlib_State)(self.user_data)
			if s.BIO_ctrl == nil || out_ptr == nil {
				return 0
			}
			wbio := s.SSL_get_wbio(rawptr(ssl))
			if wbio == nil {
				return 0
			}
			out_ptr^ = nil
			// long BIO_ctrl(BIO *b, int cmd, long larg, void *parg) — BIO_CTRL_INFO=3
			n := s.BIO_ctrl(wbio, 3, 0, out_ptr)
			if n <= 0 || out_ptr^ == nil {
				return 0
			}
			return c.int(n)
		}
		// BIO_reset(wbio) via BIO_CTRL_RESET=1.
		p.bio_reset_out = proc(self: ^Provider, ssl: Conn) -> c.int {
			s := (^Dynlib_State)(self.user_data)
			if s.BIO_ctrl == nil {
				return 0
			}
			wbio := s.SSL_get_wbio(rawptr(ssl))
			if wbio == nil {
				return 0
			}
			// OpenSSL BIO_reset: mem BIO returns 1 on success.
			rc := s.BIO_ctrl(wbio, 1, 0, nil)
			return 1 if rc >= 0 else 0
		}
	}
	p.set_accept_state = proc(self: ^Provider, ssl: Conn) {
		s := (^Dynlib_State)(self.user_data)
		s.SSL_set_accept_state(rawptr(ssl))
	}
	p.accept = proc(self: ^Provider, ssl: Conn) -> c.int {
		s := (^Dynlib_State)(self.user_data)
		return s.SSL_accept(rawptr(ssl))
	}
	p.read = proc(self: ^Provider, ssl: Conn, buf: rawptr, n: c.int) -> c.int {
		s := (^Dynlib_State)(self.user_data)
		return s.SSL_read(rawptr(ssl), buf, n)
	}
	p.write = proc(self: ^Provider, ssl: Conn, buf: rawptr, n: c.int) -> c.int {
		s := (^Dynlib_State)(self.user_data)
		return s.SSL_write(rawptr(ssl), buf, n)
	}
	p.get_error = proc(self: ^Provider, ssl: Conn, ret: c.int) -> c.int {
		s := (^Dynlib_State)(self.user_data)
		return s.SSL_get_error(rawptr(ssl), ret)
	}
	p.shutdown = proc(self: ^Provider, ssl: Conn) -> c.int {
		s := (^Dynlib_State)(self.user_data)
		return s.SSL_shutdown(rawptr(ssl))
	}
	p.get0_alpn_selected = proc(self: ^Provider, ssl: Conn, out_data: ^[^]u8, out_len: ^c.uint) {
		s := (^Dynlib_State)(self.user_data)
		s.SSL_get0_alpn_selected(rawptr(ssl), out_data, out_len)
	}
	return p, .None
}

@(private)
_resolve_openssl_syms :: proc(st: ^Dynlib_State) -> bool {
	ok := true
	// Required SSL API.
	ok = ok && _dlsym_raw(st.lib, "TLS_server_method", transmute(^rawptr)&st.TLS_server_method)
	ok = ok && _dlsym_raw(st.lib, "SSL_CTX_new", transmute(^rawptr)&st.SSL_CTX_new)
	ok = ok && _dlsym_raw(st.lib, "SSL_CTX_free", transmute(^rawptr)&st.SSL_CTX_free)
	ok = ok && _dlsym_raw(st.lib, "SSL_new", transmute(^rawptr)&st.SSL_new)
	ok = ok && _dlsym_raw(st.lib, "SSL_free", transmute(^rawptr)&st.SSL_free)
	ok = ok && _dlsym_raw(st.lib, "SSL_set_fd", transmute(^rawptr)&st.SSL_set_fd)
	ok = ok && _dlsym_raw(st.lib, "SSL_set_bio", transmute(^rawptr)&st.SSL_set_bio)
	ok = ok && _dlsym_raw(st.lib, "SSL_set_accept_state", transmute(^rawptr)&st.SSL_set_accept_state)
	ok = ok && _dlsym_raw(st.lib, "SSL_get_rbio", transmute(^rawptr)&st.SSL_get_rbio)
	ok = ok && _dlsym_raw(st.lib, "SSL_get_wbio", transmute(^rawptr)&st.SSL_get_wbio)
	ok = ok && _dlsym_raw(st.lib, "SSL_accept", transmute(^rawptr)&st.SSL_accept)
	ok = ok && _dlsym_raw(st.lib, "SSL_read", transmute(^rawptr)&st.SSL_read)
	ok = ok && _dlsym_raw(st.lib, "SSL_write", transmute(^rawptr)&st.SSL_write)
	ok = ok && _dlsym_raw(st.lib, "SSL_get_error", transmute(^rawptr)&st.SSL_get_error)
	ok = ok && _dlsym_raw(st.lib, "SSL_shutdown", transmute(^rawptr)&st.SSL_shutdown)
	ok = ok && _dlsym_raw(st.lib, "SSL_get0_alpn_selected", transmute(^rawptr)&st.SSL_get0_alpn_selected)
	ok = ok && _dlsym_raw(st.lib, "SSL_CTX_set_alpn_select_cb", transmute(^rawptr)&st.SSL_CTX_set_alpn_select_cb)
	// Mem-BIO + PEM load (usually re-exported from libcrypto via libssl).
	ok = ok && _dlsym_raw(st.lib, "BIO_s_mem", transmute(^rawptr)&st.BIO_s_mem)
	ok = ok && _dlsym_raw(st.lib, "BIO_new", transmute(^rawptr)&st.BIO_new)
	ok = ok && _dlsym_raw(st.lib, "BIO_new_mem_buf", transmute(^rawptr)&st.BIO_new_mem_buf)
	ok = ok && _dlsym_raw(st.lib, "BIO_free", transmute(^rawptr)&st.BIO_free)
	ok = ok && _dlsym_raw(st.lib, "BIO_write", transmute(^rawptr)&st.BIO_write)
	ok = ok && _dlsym_raw(st.lib, "BIO_read", transmute(^rawptr)&st.BIO_read)
	ok = ok && _dlsym_raw(st.lib, "BIO_ctrl_pending", transmute(^rawptr)&st.BIO_ctrl_pending)
	// Optional for peek drain (fails open: bio_peek stays nil if missing).
	_ = _dlsym_raw(st.lib, "BIO_ctrl", transmute(^rawptr)&st.BIO_ctrl)
	ok = ok && _dlsym_raw(st.lib, "PEM_read_bio_X509", transmute(^rawptr)&st.PEM_read_bio_X509)
	ok = ok && _dlsym_raw(st.lib, "PEM_read_bio_PrivateKey", transmute(^rawptr)&st.PEM_read_bio_PrivateKey)
	ok = ok && _dlsym_raw(st.lib, "SSL_CTX_use_certificate", transmute(^rawptr)&st.SSL_CTX_use_certificate)
	ok = ok && _dlsym_raw(st.lib, "SSL_CTX_use_PrivateKey", transmute(^rawptr)&st.SSL_CTX_use_PrivateKey)
	ok = ok && _dlsym_raw(st.lib, "X509_free", transmute(^rawptr)&st.X509_free)
	ok = ok && _dlsym_raw(st.lib, "EVP_PKEY_free", transmute(^rawptr)&st.EVP_PKEY_free)
	// Optional.
	_ = _dlsym_raw(st.lib, "SSL_set_mode", transmute(^rawptr)&st.SSL_set_mode)
	return ok
}

@(private)
_dlsym_raw :: proc(lib: dynlib.Library, name: string, dest: ^rawptr) -> bool {
	ptr, found := dynlib.symbol_address(lib, name)
	if !found || ptr == nil do return false
	dest^ = ptr
	return true
}

@(private)
_dynlib_ctx_load_pem :: proc(st: ^Dynlib_State, ctx: Ctx, cert_pem, key_pem: []u8) -> bool {
	cbio := st.BIO_new_mem_buf(raw_data(cert_pem), c.int(len(cert_pem)))
	if cbio == nil do return false
	defer st.BIO_free(cbio)
	cert := st.PEM_read_bio_X509(cbio, nil, nil, nil)
	if cert == nil do return false
	defer st.X509_free(cert)
	if st.SSL_CTX_use_certificate(rawptr(ctx), cert) != 1 do return false

	kbio := st.BIO_new_mem_buf(raw_data(key_pem), c.int(len(key_pem)))
	if kbio == nil do return false
	defer st.BIO_free(kbio)
	key := st.PEM_read_bio_PrivateKey(kbio, nil, nil, nil)
	if key == nil do return false
	defer st.EVP_PKEY_free(key)
	return st.SSL_CTX_use_PrivateKey(rawptr(ctx), key) == 1
}

@(private)
_dynlib_provider_destroy :: proc(self: ^Provider) {
	if self == nil do return
	st := (^Dynlib_State)(self.user_data)
	if st != nil {
		if st.owns_lib && st.lib != nil {
			dynlib.unload_library(st.lib)
		}
		free(st)
	}
	free(self)
}
