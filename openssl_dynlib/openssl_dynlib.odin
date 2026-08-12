// Shared OpenSSL ≥3.5 dynlib loader for quic, client TCP TLS, and tls_server.
// No static BoringSSL.
package openssl_dynlib

import "core:c"
import "core:dynlib"
import "core:strings"
import "core:sync"

// Path overrides (first non-empty wins at load).
PROACTR_OPENSSL_DYNLIB_PATH :: #config(PROACTR_OPENSSL_DYNLIB_PATH, "")
OPENSSL_DYNLIB_PATH :: #config(OPENSSL_DYNLIB_PATH, "")
QUIC_OPENSSL_DYNLIB_PATH :: #config(QUIC_OPENSSL_DYNLIB_PATH, "")

// OpenSSL 3.5+ quic-tls dispatch function ids (core_dispatch.h) — not dlsym.
OSSL_FUNC_SSL_QUIC_TLS_CRYPTO_SEND          :: 2001
OSSL_FUNC_SSL_QUIC_TLS_CRYPTO_RECV_RCD      :: 2002
OSSL_FUNC_SSL_QUIC_TLS_CRYPTO_RELEASE_RCD   :: 2003
OSSL_FUNC_SSL_QUIC_TLS_YIELD_SECRET         :: 2004
OSSL_FUNC_SSL_QUIC_TLS_GOT_TRANSPORT_PARAMS :: 2005
OSSL_FUNC_SSL_QUIC_TLS_ALERT                :: 2006

OSSL_RECORD_PROTECTION_LEVEL_NONE        :: u32(0)
OSSL_RECORD_PROTECTION_LEVEL_EARLY       :: u32(1)
OSSL_RECORD_PROTECTION_LEVEL_HANDSHAKE   :: u32(2)
OSSL_RECORD_PROTECTION_LEVEL_APPLICATION :: u32(3)

TLS1_2_VERSION :: 0x0303
TLS1_3_VERSION :: 0x0304

SSL_VERIFY_NONE :: 0
SSL_VERIFY_PEER :: 1

SSL_ERROR_NONE       :: 0
SSL_ERROR_SSL        :: 1
SSL_ERROR_WANT_READ  :: 2
SSL_ERROR_WANT_WRITE :: 3
SSL_ERROR_SYSCALL    :: 5
SSL_ERROR_ZERO_RETURN :: 6

SSL_TLSEXT_ERR_OK    :: 0
SSL_TLSEXT_ERR_NOACK :: 3

EVP_CTRL_AEAD_SET_IVLEN :: 0x9
EVP_CTRL_AEAD_GET_TAG   :: 0x10
EVP_CTRL_AEAD_SET_TAG   :: 0x11

EVP_KDF_HKDF_MODE_EXTRACT_ONLY :: 1
EVP_KDF_HKDF_MODE_EXPAND_ONLY  :: 2

// SSL_ctrl commands (macros in OpenSSL headers — pin values).
SSL_CTRL_SET_TLSEXT_HOSTNAME   :: 55
SSL_CTRL_SET_MIN_PROTO_VERSION :: 123
SSL_CTRL_SET_MAX_PROTO_VERSION :: 124
SSL_CTRL_SET_GROUPS_LIST       :: 92
SSL_CTRL_SET_SESS_CACHE_MODE   :: 44
SSL_CTRL_SET_SIGALGS_LIST      :: 98
SSL_SESS_CACHE_OFF             :: 0
TLSEXT_NAMETYPE_host_name      :: 0

OSSL_PARAM_INTEGER      :: 1
OSSL_PARAM_UTF8_STRING  :: 4
OSSL_PARAM_OCTET_STRING :: 5

// OSSL_PARAM — 40 bytes on 64-bit (verified).
OSSL_PARAM :: struct {
	key:          cstring,
	data_type:    u32,
	data:         rawptr,
	data_size:    c.size_t,
	return_size:  c.size_t,
}

// OSSL_DISPATCH — 16 bytes on 64-bit.
OSSL_DISPATCH :: struct {
	function_id: c.int,
	function:    rawptr,
}

OPENSSL_VERSION_MIN_3_5 :: c.ulong(0x30500000)

Os_Error :: enum {
	None,
	Load_Failed,
	Missing_Symbol,
	Version_Too_Old,
}

// Global OpenSSL API (resolved once).
Os :: struct {
	libssl:    dynlib.Library,
	libcrypto: dynlib.Library,
	owns:      bool,
	// ssl_ready: dylib + SSL/TLS/BIO symbols. crypto_ready: AEAD/HKDF prefetch.
	ssl_ready:    bool,
	crypto_ready: bool,
	// ready == crypto_ready (full product); kept for quic callers.
	ready:     bool,

	OpenSSL_version_num: proc "c" () -> c.ulong,
	OpenSSL_version:     proc "c" (t: c.int) -> cstring,

	TLS_client_method: proc "c" () -> rawptr,
	TLS_server_method: proc "c" () -> rawptr,
	SSL_CTX_new:  proc "c" (method: rawptr) -> rawptr,
	SSL_CTX_free: proc "c" (ctx: rawptr),
	SSL_new:  proc "c" (ctx: rawptr) -> rawptr,
	SSL_free: proc "c" (ssl: rawptr),
	SSL_set_connect_state: proc "c" (ssl: rawptr),
	SSL_set_accept_state:  proc "c" (ssl: rawptr),
	SSL_set_fd:       proc "c" (ssl: rawptr, fd: c.int) -> c.int,
	SSL_connect:      proc "c" (ssl: rawptr) -> c.int,
	SSL_accept:       proc "c" (ssl: rawptr) -> c.int,
	SSL_do_handshake: proc "c" (ssl: rawptr) -> c.int,
	SSL_read:         proc "c" (ssl: rawptr, buf: rawptr, num: c.int) -> c.int,
	SSL_write:        proc "c" (ssl: rawptr, buf: rawptr, num: c.int) -> c.int,
	SSL_shutdown:     proc "c" (ssl: rawptr) -> c.int,
	SSL_get_error:    proc "c" (ssl: rawptr, ret: c.int) -> c.int,
	SSL_set_bio:      proc "c" (ssl: rawptr, rbio: rawptr, wbio: rawptr),
	SSL_get_rbio:     proc "c" (ssl: rawptr) -> rawptr,
	SSL_get_wbio:     proc "c" (ssl: rawptr) -> rawptr,
	SSL_set_mode:     proc "c" (ssl: rawptr, mode: c.long) -> c.long,

	SSL_set_quic_tls_cbs: proc "c" (ssl: rawptr, qtdis: [^]OSSL_DISPATCH, arg: rawptr) -> c.int,
	SSL_set_quic_tls_transport_params: proc "c" (
		ssl: rawptr, params: rawptr, params_len: c.size_t,
	) -> c.int,
	SSL_set_quic_tls_early_data_enabled: proc "c" (ssl: rawptr, enabled: c.int) -> c.int,

	SSL_set_alpn_protos: proc "c" (ssl: rawptr, protos: rawptr, protos_len: c.uint) -> c.int,
	SSL_CTX_set_alpn_select_cb: proc "c" (ctx: rawptr, cb: rawptr, arg: rawptr),
	SSL_get0_alpn_selected: proc "c" (ssl: rawptr, data: ^[^]u8, len: ^c.uint),

	// SSL_set_tlsext_host_name is a macro → SSL_ctrl(SSL_CTRL_SET_TLSEXT_HOSTNAME).
	SSL_ctrl:     proc "c" (ssl: rawptr, cmd: c.int, larg: c.long, parg: rawptr) -> c.long,
	SSL_CTX_ctrl: proc "c" (ctx: rawptr, cmd: c.int, larg: c.long, parg: rawptr) -> c.long,
	// TLS 1.3-only cipher suite string (e.g. "TLS_AES_128_GCM_SHA256").
	SSL_CTX_set_ciphersuites: proc "c" (ctx: rawptr, str: cstring) -> c.int,
	SSL_CTX_set_num_tickets:  proc "c" (ctx: rawptr, num: c.size_t) -> c.int,
	SSL_set1_host:            proc "c" (ssl: rawptr, hostname: cstring) -> c.int,
	SSL_set_verify:           proc "c" (ssl: rawptr, mode: c.int, cb: rawptr),
	SSL_CTX_set_verify:       proc "c" (ctx: rawptr, mode: c.int, cb: rawptr),
	SSL_CTX_load_verify_locations: proc "c" (ctx: rawptr, CAfile: cstring, CApath: cstring) -> c.int,

	// min/max proto version are macros over SSL_CTX_ctrl — see helpers below.

	SSL_get_current_cipher: proc "c" (ssl: rawptr) -> rawptr,
	SSL_CIPHER_get_id:      proc "c" (cipher: rawptr) -> c.uint,

	SSL_CTX_use_certificate: proc "c" (ctx: rawptr, x: rawptr) -> c.int,
	SSL_CTX_use_PrivateKey:  proc "c" (ctx: rawptr, pkey: rawptr) -> c.int,
	SSL_check_private_key:   proc "c" (ssl: rawptr) -> c.int,
	SSL_use_certificate_file: proc "c" (ssl: rawptr, file: cstring, type: c.int) -> c.int,
	SSL_use_PrivateKey_file:  proc "c" (ssl: rawptr, file: cstring, type: c.int) -> c.int,

	SSL_set_ex_data: proc "c" (ssl: rawptr, idx: c.int, data: rawptr) -> c.int,
	SSL_get_ex_data: proc "c" (ssl: rawptr, idx: c.int) -> rawptr,
	SSL_get_app_data: proc "c" (ssl: rawptr) -> rawptr, // often SSL_get_ex_data(ssl,0)
	SSL_set_app_data: proc "c" (ssl: rawptr, arg: rawptr) -> c.int,

	ERR_get_error:      proc "c" () -> c.ulong,
	ERR_error_string_n: proc "c" (e: c.ulong, buf: rawptr, len: c.size_t),

	BIO_s_mem:               proc "c" () -> rawptr,
	BIO_new:                 proc "c" (method: rawptr) -> rawptr,
	BIO_new_mem_buf:         proc "c" (buf: rawptr, len: c.int) -> rawptr,
	BIO_free:                proc "c" (a: rawptr) -> c.int,
	BIO_write:               proc "c" (b: rawptr, data: rawptr, n: c.int) -> c.int,
	BIO_read:                proc "c" (b: rawptr, data: rawptr, n: c.int) -> c.int,
	BIO_ctrl_pending:        proc "c" (b: rawptr) -> c.size_t,
	BIO_ctrl:                proc "c" (b: rawptr, cmd: c.int, larg: c.long, parg: rawptr) -> c.long,
	PEM_read_bio_X509:       proc "c" (bp, x, cb, u: rawptr) -> rawptr,
	PEM_read_bio_PrivateKey: proc "c" (bp, x, cb, u: rawptr) -> rawptr,
	X509_free:               proc "c" (x: rawptr),
	EVP_PKEY_free:           proc "c" (pkey: rawptr),

	EVP_CIPHER_CTX_new:   proc "c" () -> rawptr,
	EVP_CIPHER_CTX_free:  proc "c" (ctx: rawptr),
	EVP_EncryptInit_ex:   proc "c" (ctx, cipher, impl, key, iv: rawptr) -> c.int,
	EVP_EncryptUpdate:    proc "c" (ctx: rawptr, out: rawptr, outl: ^c.int, in_: rawptr, inl: c.int) -> c.int,
	EVP_EncryptFinal_ex:  proc "c" (ctx: rawptr, out: rawptr, outl: ^c.int) -> c.int,
	EVP_DecryptInit_ex:   proc "c" (ctx, cipher, impl, key, iv: rawptr) -> c.int,
	EVP_DecryptUpdate:    proc "c" (ctx: rawptr, out: rawptr, outl: ^c.int, in_: rawptr, inl: c.int) -> c.int,
	EVP_DecryptFinal_ex:  proc "c" (ctx: rawptr, out: rawptr, outl: ^c.int) -> c.int,
	EVP_CIPHER_CTX_ctrl:  proc "c" (ctx: rawptr, type: c.int, arg: c.int, ptr: rawptr) -> c.int,
	EVP_CIPHER_CTX_set_padding: proc "c" (ctx: rawptr, pad: c.int) -> c.int,

	EVP_CIPHER_fetch: proc "c" (ctx: rawptr, algorithm: cstring, properties: cstring) -> rawptr,
	EVP_CIPHER_free:  proc "c" (cipher: rawptr),
	EVP_MD_fetch:     proc "c" (ctx: rawptr, algorithm: cstring, properties: cstring) -> rawptr,
	EVP_MD_free:      proc "c" (md: rawptr),
	EVP_MD_get_size:  proc "c" (md: rawptr) -> c.int,
	EVP_MD_get0_name: proc "c" (md: rawptr) -> cstring,

	EVP_KDF_fetch:    proc "c" (libctx: rawptr, algorithm: cstring, properties: cstring) -> rawptr,
	EVP_KDF_free:     proc "c" (kdf: rawptr),
	EVP_KDF_CTX_new:  proc "c" (kdf: rawptr) -> rawptr,
	EVP_KDF_CTX_free: proc "c" (ctx: rawptr),
	EVP_KDF_derive:   proc "c" (ctx: rawptr, key: rawptr, keylen: c.size_t, params: [^]OSSL_PARAM) -> c.int,

	RAND_bytes: proc "c" (buf: rawptr, num: c.int) -> c.int,

	// Fast HKDF path (HMAC one-shot).
	HMAC:       proc "c" (evp_md: rawptr, key: rawptr, key_len: c.int, data: rawptr, data_len: c.size_t, md: rawptr, md_len: ^c.uint) -> rawptr,
	EVP_sha256: proc "c" () -> rawptr,
	EVP_sha384: proc "c" () -> rawptr,

	// Prefetched algorithm handles (set in os_init).
	cipher_aes_128_gcm:  rawptr,
	cipher_aes_256_gcm:  rawptr,
	cipher_chacha_poly:  rawptr,
	cipher_aes_128_ecb:  rawptr,
	cipher_aes_256_ecb:  rawptr,
	cipher_chacha20:     rawptr,
	md_sha256:           rawptr,
	md_sha384:           rawptr,
	kdf_hkdf:            rawptr,

	// Debug counters (hot path must not increment *_new after install).
	aead_ctx_new_count:   int,
	cipher_ctx_new_count: int,
}

g_os: Os
@(private) g_os_once: sync.Once
@(private) g_last_error: Os_Error
@(private) g_loaded_ssl_path: string // for crypto sibling dir; process-static literal or config

// Survives Once — distinguish Version_Too_Old vs Load_Failed for tests/logs.
last_error :: proc() -> Os_Error {
	return g_last_error
}

// Full product init (ssl + crypto). Used by quic.
os_init :: proc() -> Os_Error {
	_ = os_ensure_ssl()
	if !g_os.ssl_ready {
		return g_last_error if g_last_error != .None else .Load_Failed
	}
	_ = os_ensure_crypto()
	if !g_os.crypto_ready {
		return g_last_error if g_last_error != .None else .Missing_Symbol
	}
	return .None
}

// Full ready (ssl + crypto).
os_ensure :: proc() -> bool {
	return os_init() == .None && g_os.ready
}

// TCP client / tls_server: load SSL symbols only (no AEAD prefetch).
os_ensure_ssl :: proc() -> bool {
	sync.once_do(&g_os_once, proc() {
		g_last_error = _os_load_ssl_impl()
	})
	return g_os.ssl_ready
}

// Quic AEAD path. Requires ssl_ready.
os_ensure_crypto :: proc() -> bool {
	if !os_ensure_ssl() do return false
	if g_os.crypto_ready do return true
	err := _os_prefetch_crypto()
	if err != .None {
		g_last_error = err
		return false
	}
	return g_os.crypto_ready
}

@(private)
_config_ssl_path :: proc() -> string {
	if len(string(PROACTR_OPENSSL_DYNLIB_PATH)) > 0 do return string(PROACTR_OPENSSL_DYNLIB_PATH)
	if len(string(OPENSSL_DYNLIB_PATH)) > 0 do return string(OPENSSL_DYNLIB_PATH)
	if len(string(QUIC_OPENSSL_DYNLIB_PATH)) > 0 do return string(QUIC_OPENSSL_DYNLIB_PATH)
	return ""
}

@(private)
_os_load_ssl_impl :: proc() -> Os_Error {
	path := _config_ssl_path()
	candidates: [8]string
	n := 0
	if len(path) > 0 {
		candidates[0] = path
		n = 1
	} else {
		when ODIN_OS == .Darwin {
			candidates[0] = "/opt/homebrew/opt/openssl@3/lib/libssl.3.dylib"
			candidates[1] = "/opt/homebrew/opt/openssl/lib/libssl.dylib"
			candidates[2] = "/usr/local/opt/openssl@3/lib/libssl.3.dylib"
			candidates[3] = "/usr/local/opt/openssl/lib/libssl.dylib"
			candidates[4] = "/opt/local/lib/libssl.3.dylib"
			n = 5
		} else when ODIN_OS == .Linux {
			// Product bar ≥3.5 — do not probe libssl.so.1.1.
			candidates[0] = "libssl.so.3"
			candidates[1] = "libssl.so"
			n = 2
		} else {
			candidates[0] = "libssl-3-x64.dll"
			candidates[1] = "libssl-3.dll"
			n = 2
		}
	}

	libssl: dynlib.Library
	ok: bool
	loaded_path := ""
	for i in 0 ..< n {
		libssl, ok = dynlib.load_library(candidates[i])
		if ok && libssl != nil {
			loaded_path = candidates[i]
			break
		}
		libssl = nil
	}
	if libssl == nil do return .Load_Failed
	g_loaded_ssl_path = loaded_path

	libcrypto: dynlib.Library
	// Prefer libcrypto beside custom/configured libssl.
	if len(loaded_path) > 0 && (strings.contains(loaded_path, "/") || strings.contains(loaded_path, "\\")) {
		dir := _path_dir(loaded_path)
		when ODIN_OS == .Darwin {
			for name in ([?]string{"libcrypto.3.dylib", "libcrypto.dylib"}) {
				p := strings.concatenate({dir, "/", name}, context.temp_allocator)
				libcrypto, ok = dynlib.load_library(p)
				if ok && libcrypto != nil do break
				libcrypto = nil
			}
		} else when ODIN_OS == .Linux {
			for name in ([?]string{"libcrypto.so.3", "libcrypto.so"}) {
				p := strings.concatenate({dir, "/", name}, context.temp_allocator)
				libcrypto, ok = dynlib.load_library(p)
				if ok && libcrypto != nil do break
				libcrypto = nil
			}
		}
	}
	if libcrypto == nil {
		when ODIN_OS == .Darwin {
			crypto_paths := [?]string{
				"/opt/homebrew/opt/openssl@3/lib/libcrypto.3.dylib",
				"/opt/homebrew/opt/openssl/lib/libcrypto.dylib",
				"/usr/local/opt/openssl@3/lib/libcrypto.3.dylib",
				"/usr/local/opt/openssl/lib/libcrypto.dylib",
				"/opt/local/lib/libcrypto.3.dylib",
			}
			for p in crypto_paths {
				libcrypto, ok = dynlib.load_library(p)
				if ok && libcrypto != nil do break
				libcrypto = nil
			}
		} else when ODIN_OS == .Linux {
			libcrypto, ok = dynlib.load_library("libcrypto.so.3")
			if !ok do libcrypto, ok = dynlib.load_library("libcrypto.so")
		} else {
			libcrypto, ok = dynlib.load_library("libcrypto-3-x64.dll")
			if !ok do libcrypto, ok = dynlib.load_library("libcrypto-3.dll")
		}
	}
	if libcrypto == nil {
		libcrypto = libssl
	}

	g_os.libssl = libssl
	g_os.libcrypto = libcrypto
	g_os.owns = true

	if !_resolve_ssl_syms() {
		_os_unload()
		return .Missing_Symbol
	}

	v := g_os.OpenSSL_version_num()
	if v < OPENSSL_VERSION_MIN_3_5 {
		_os_unload()
		return .Version_Too_Old
	}

	if g_os.SSL_set_app_data == nil {
		g_os.SSL_set_app_data = proc "c" (ssl: rawptr, arg: rawptr) -> c.int {
			return g_os.SSL_set_ex_data(ssl, 0, arg)
		}
	}
	if g_os.SSL_get_app_data == nil {
		g_os.SSL_get_app_data = proc "c" (ssl: rawptr) -> rawptr {
			return g_os.SSL_get_ex_data(ssl, 0)
		}
	}

	g_os.ssl_ready = true
	return .None
}

@(private)
_os_prefetch_crypto :: proc() -> Os_Error {
	if !g_os.ssl_ready do return .Load_Failed
	if g_os.crypto_ready do return .None
	if !_resolve_crypto_syms() {
		return .Missing_Symbol
	}
	g_os.cipher_aes_128_gcm = g_os.EVP_CIPHER_fetch(nil, "AES-128-GCM", nil)
	g_os.cipher_aes_256_gcm = g_os.EVP_CIPHER_fetch(nil, "AES-256-GCM", nil)
	g_os.cipher_chacha_poly = g_os.EVP_CIPHER_fetch(nil, "ChaCha20-Poly1305", nil)
	g_os.cipher_aes_128_ecb = g_os.EVP_CIPHER_fetch(nil, "AES-128-ECB", nil)
	g_os.cipher_aes_256_ecb = g_os.EVP_CIPHER_fetch(nil, "AES-256-ECB", nil)
	g_os.cipher_chacha20 = g_os.EVP_CIPHER_fetch(nil, "ChaCha20", nil)
	g_os.md_sha256 = g_os.EVP_MD_fetch(nil, "SHA256", nil)
	g_os.md_sha384 = g_os.EVP_MD_fetch(nil, "SHA384", nil)
	g_os.kdf_hkdf = g_os.EVP_KDF_fetch(nil, "HKDF", nil)

	if g_os.cipher_aes_128_gcm == nil || g_os.cipher_aes_128_ecb == nil ||
	   g_os.md_sha256 == nil || g_os.kdf_hkdf == nil {
		return .Missing_Symbol
	}
	g_os.crypto_ready = true
	g_os.ready = true
	return .None
}

@(private)
_os_unload :: proc() {
	if g_os.EVP_CIPHER_free != nil {
		if g_os.cipher_aes_128_gcm != nil do g_os.EVP_CIPHER_free(g_os.cipher_aes_128_gcm)
		if g_os.cipher_aes_256_gcm != nil do g_os.EVP_CIPHER_free(g_os.cipher_aes_256_gcm)
		if g_os.cipher_chacha_poly != nil do g_os.EVP_CIPHER_free(g_os.cipher_chacha_poly)
		if g_os.cipher_aes_128_ecb != nil do g_os.EVP_CIPHER_free(g_os.cipher_aes_128_ecb)
		if g_os.cipher_aes_256_ecb != nil do g_os.EVP_CIPHER_free(g_os.cipher_aes_256_ecb)
		if g_os.cipher_chacha20 != nil do g_os.EVP_CIPHER_free(g_os.cipher_chacha20)
	}
	if g_os.EVP_MD_free != nil {
		if g_os.md_sha256 != nil do g_os.EVP_MD_free(g_os.md_sha256)
		if g_os.md_sha384 != nil do g_os.EVP_MD_free(g_os.md_sha384)
	}
	if g_os.EVP_KDF_free != nil && g_os.kdf_hkdf != nil {
		g_os.EVP_KDF_free(g_os.kdf_hkdf)
	}
	if g_os.owns {
		if g_os.libcrypto != nil && g_os.libcrypto != g_os.libssl {
			dynlib.unload_library(g_os.libcrypto)
		}
		if g_os.libssl != nil do dynlib.unload_library(g_os.libssl)
	}
	g_os = {}
}

@(private)
_sym :: proc(lib: dynlib.Library, name: cstring, out: rawptr) -> bool {
	p, found := dynlib.symbol_address(lib, string(name))
	if !found || p == nil do return false
	(cast(^rawptr)out)^ = p
	return true
}

@(private)
_sym_either :: proc(name: cstring, out: rawptr) -> bool {
	if _sym(g_os.libssl, name, out) do return true
	if g_os.libcrypto != g_os.libssl do return _sym(g_os.libcrypto, name, out)
	return false
}

// SSL/TLS/BIO symbols required for client, server, and quic handshake control.
@(private)
_resolve_ssl_syms :: proc() -> bool {
	ok := true
	ok = ok && _sym_either("OpenSSL_version_num", &g_os.OpenSSL_version_num)
	_ = _sym_either("OpenSSL_version", &g_os.OpenSSL_version)

	ok = ok && _sym(g_os.libssl, "TLS_client_method", &g_os.TLS_client_method)
	ok = ok && _sym(g_os.libssl, "TLS_server_method", &g_os.TLS_server_method)
	ok = ok && _sym(g_os.libssl, "SSL_CTX_new", &g_os.SSL_CTX_new)
	ok = ok && _sym(g_os.libssl, "SSL_CTX_free", &g_os.SSL_CTX_free)
	ok = ok && _sym(g_os.libssl, "SSL_new", &g_os.SSL_new)
	ok = ok && _sym(g_os.libssl, "SSL_free", &g_os.SSL_free)
	ok = ok && _sym(g_os.libssl, "SSL_set_connect_state", &g_os.SSL_set_connect_state)
	ok = ok && _sym(g_os.libssl, "SSL_set_accept_state", &g_os.SSL_set_accept_state)
	ok = ok && _sym(g_os.libssl, "SSL_set_fd", &g_os.SSL_set_fd)
	ok = ok && _sym(g_os.libssl, "SSL_connect", &g_os.SSL_connect)
	ok = ok && _sym(g_os.libssl, "SSL_accept", &g_os.SSL_accept)
	ok = ok && _sym(g_os.libssl, "SSL_do_handshake", &g_os.SSL_do_handshake)
	ok = ok && _sym(g_os.libssl, "SSL_read", &g_os.SSL_read)
	ok = ok && _sym(g_os.libssl, "SSL_write", &g_os.SSL_write)
	ok = ok && _sym(g_os.libssl, "SSL_shutdown", &g_os.SSL_shutdown)
	ok = ok && _sym(g_os.libssl, "SSL_get_error", &g_os.SSL_get_error)
	ok = ok && _sym(g_os.libssl, "SSL_set_bio", &g_os.SSL_set_bio)
	ok = ok && _sym(g_os.libssl, "SSL_get_rbio", &g_os.SSL_get_rbio)
	ok = ok && _sym(g_os.libssl, "SSL_get_wbio", &g_os.SSL_get_wbio)
	_ = _sym(g_os.libssl, "SSL_set_mode", &g_os.SSL_set_mode)

	ok = ok && _sym(g_os.libssl, "SSL_set_quic_tls_cbs", &g_os.SSL_set_quic_tls_cbs)
	ok = ok && _sym(g_os.libssl, "SSL_set_quic_tls_transport_params", &g_os.SSL_set_quic_tls_transport_params)
	ok = ok && _sym(g_os.libssl, "SSL_set_quic_tls_early_data_enabled", &g_os.SSL_set_quic_tls_early_data_enabled)

	ok = ok && _sym(g_os.libssl, "SSL_set_alpn_protos", &g_os.SSL_set_alpn_protos)
	ok = ok && _sym(g_os.libssl, "SSL_CTX_set_alpn_select_cb", &g_os.SSL_CTX_set_alpn_select_cb)
	ok = ok && _sym(g_os.libssl, "SSL_get0_alpn_selected", &g_os.SSL_get0_alpn_selected)

	ok = ok && _sym(g_os.libssl, "SSL_ctrl", &g_os.SSL_ctrl)
	ok = ok && _sym(g_os.libssl, "SSL_CTX_ctrl", &g_os.SSL_CTX_ctrl)
	_ = _sym(g_os.libssl, "SSL_CTX_set_ciphersuites", &g_os.SSL_CTX_set_ciphersuites)
	_ = _sym(g_os.libssl, "SSL_CTX_set_num_tickets", &g_os.SSL_CTX_set_num_tickets)
	// REQUIRED — hostname verification must not silently vanish.
	ok = ok && _sym(g_os.libssl, "SSL_set1_host", &g_os.SSL_set1_host)
	ok = ok && _sym(g_os.libssl, "SSL_set_verify", &g_os.SSL_set_verify)
	_ = _sym(g_os.libssl, "SSL_CTX_set_verify", &g_os.SSL_CTX_set_verify)
	ok = ok && _sym(g_os.libssl, "SSL_CTX_load_verify_locations", &g_os.SSL_CTX_load_verify_locations)

	ok = ok && _sym(g_os.libssl, "SSL_get_current_cipher", &g_os.SSL_get_current_cipher)
	ok = ok && _sym(g_os.libssl, "SSL_CIPHER_get_id", &g_os.SSL_CIPHER_get_id)

	ok = ok && _sym(g_os.libssl, "SSL_CTX_use_certificate", &g_os.SSL_CTX_use_certificate)
	ok = ok && _sym(g_os.libssl, "SSL_CTX_use_PrivateKey", &g_os.SSL_CTX_use_PrivateKey)
	_ = _sym(g_os.libssl, "SSL_check_private_key", &g_os.SSL_check_private_key)
	_ = _sym(g_os.libssl, "SSL_use_certificate_file", &g_os.SSL_use_certificate_file)
	_ = _sym(g_os.libssl, "SSL_use_PrivateKey_file", &g_os.SSL_use_PrivateKey_file)

	ok = ok && _sym(g_os.libssl, "SSL_set_ex_data", &g_os.SSL_set_ex_data)
	ok = ok && _sym(g_os.libssl, "SSL_get_ex_data", &g_os.SSL_get_ex_data)
	_ = _sym(g_os.libssl, "SSL_get_app_data", &g_os.SSL_get_app_data)
	_ = _sym(g_os.libssl, "SSL_set_app_data", &g_os.SSL_set_app_data)

	ok = ok && _sym_either("ERR_get_error", &g_os.ERR_get_error)
	ok = ok && _sym_either("ERR_error_string_n", &g_os.ERR_error_string_n)

	ok = ok && _sym_either("BIO_s_mem", &g_os.BIO_s_mem)
	ok = ok && _sym_either("BIO_new", &g_os.BIO_new)
	ok = ok && _sym_either("BIO_new_mem_buf", &g_os.BIO_new_mem_buf)
	ok = ok && _sym_either("BIO_free", &g_os.BIO_free)
	ok = ok && _sym_either("BIO_write", &g_os.BIO_write)
	ok = ok && _sym_either("BIO_read", &g_os.BIO_read)
	ok = ok && _sym_either("BIO_ctrl_pending", &g_os.BIO_ctrl_pending)
	ok = ok && _sym_either("BIO_ctrl", &g_os.BIO_ctrl)
	ok = ok && _sym_either("PEM_read_bio_X509", &g_os.PEM_read_bio_X509)
	ok = ok && _sym_either("PEM_read_bio_PrivateKey", &g_os.PEM_read_bio_PrivateKey)
	ok = ok && _sym_either("X509_free", &g_os.X509_free)
	ok = ok && _sym_either("EVP_PKEY_free", &g_os.EVP_PKEY_free)
	ok = ok && _sym_either("RAND_bytes", &g_os.RAND_bytes)
	return ok
}

// AEAD/HKDF symbols — only required for crypto_ready / quic.
@(private)
_resolve_crypto_syms :: proc() -> bool {
	ok := true
	ok = ok && _sym_either("EVP_CIPHER_CTX_new", &g_os.EVP_CIPHER_CTX_new)
	ok = ok && _sym_either("EVP_CIPHER_CTX_free", &g_os.EVP_CIPHER_CTX_free)
	ok = ok && _sym_either("EVP_EncryptInit_ex", &g_os.EVP_EncryptInit_ex)
	ok = ok && _sym_either("EVP_EncryptUpdate", &g_os.EVP_EncryptUpdate)
	ok = ok && _sym_either("EVP_EncryptFinal_ex", &g_os.EVP_EncryptFinal_ex)
	ok = ok && _sym_either("EVP_DecryptInit_ex", &g_os.EVP_DecryptInit_ex)
	ok = ok && _sym_either("EVP_DecryptUpdate", &g_os.EVP_DecryptUpdate)
	ok = ok && _sym_either("EVP_DecryptFinal_ex", &g_os.EVP_DecryptFinal_ex)
	ok = ok && _sym_either("EVP_CIPHER_CTX_ctrl", &g_os.EVP_CIPHER_CTX_ctrl)
	ok = ok && _sym_either("EVP_CIPHER_CTX_set_padding", &g_os.EVP_CIPHER_CTX_set_padding)
	ok = ok && _sym_either("EVP_CIPHER_fetch", &g_os.EVP_CIPHER_fetch)
	ok = ok && _sym_either("EVP_CIPHER_free", &g_os.EVP_CIPHER_free)
	ok = ok && _sym_either("EVP_MD_fetch", &g_os.EVP_MD_fetch)
	ok = ok && _sym_either("EVP_MD_free", &g_os.EVP_MD_free)
	ok = ok && _sym_either("EVP_MD_get_size", &g_os.EVP_MD_get_size)
	_ = _sym_either("EVP_MD_get0_name", &g_os.EVP_MD_get0_name)
	ok = ok && _sym_either("EVP_KDF_fetch", &g_os.EVP_KDF_fetch)
	ok = ok && _sym_either("EVP_KDF_free", &g_os.EVP_KDF_free)
	ok = ok && _sym_either("EVP_KDF_CTX_new", &g_os.EVP_KDF_CTX_new)
	ok = ok && _sym_either("EVP_KDF_CTX_free", &g_os.EVP_KDF_CTX_free)
	ok = ok && _sym_either("EVP_KDF_derive", &g_os.EVP_KDF_derive)
	_ = _sym_either("HMAC", &g_os.HMAC)
	_ = _sym_either("EVP_sha256", &g_os.EVP_sha256)
	_ = _sym_either("EVP_sha384", &g_os.EVP_sha384)
	return ok
}

@(private)
_path_dir :: proc(path: string) -> string {
	// Last slash — no allocation.
	i := len(path) - 1
	for i >= 0 {
		if path[i] == '/' || path[i] == '\\' {
			return path[:i]
		}
		i -= 1
	}
	return ""
}

// System CA bundle candidates (shared by client TCP CTX).
load_system_roots :: proc(ctx: rawptr) -> bool {
	if ctx == nil || g_os.SSL_CTX_load_verify_locations == nil do return false
	CANDIDATES :: [?]cstring{
		"/etc/ssl/cert.pem",
		"/etc/ssl/certs/ca-certificates.crt",
		"/etc/pki/tls/certs/ca-bundle.crt",
		"/etc/ssl/ca-bundle.pem",
	}
	for path in CANDIDATES {
		if g_os.SSL_CTX_load_verify_locations(ctx, path, nil) == 1 do return true
	}
	return false
}


ossl_param_int :: proc(key: cstring, val: ^c.int) -> OSSL_PARAM {
	return OSSL_PARAM{
		key = key,
		data_type = OSSL_PARAM_INTEGER,
		data = val,
		data_size = size_of(c.int),
		return_size = 0,
	}
}

ossl_param_utf8 :: proc(key: cstring, s: cstring) -> OSSL_PARAM {
	// data_size 0 means strlen for construct_utf8_string convention when using settable params
	n: c.size_t = 0
	if s != nil {
		p := cast([^]u8)s
		for p[n] != 0 do n += 1
	}
	return OSSL_PARAM{
		key = key,
		data_type = OSSL_PARAM_UTF8_STRING,
		data = rawptr(s),
		data_size = n,
		return_size = 0,
	}
}

ossl_param_octet :: proc(key: cstring, buf: rawptr, len: c.size_t) -> OSSL_PARAM {
	return OSSL_PARAM{
		key = key,
		data_type = OSSL_PARAM_OCTET_STRING,
		data = buf,
		data_size = len,
		return_size = 0,
	}
}

ossl_param_end :: proc() -> OSSL_PARAM {
	return OSSL_PARAM{}
}

// Track CTX_new for tests.
os_cipher_ctx_new :: proc() -> rawptr {
	g_os.cipher_ctx_new_count += 1
	g_os.aead_ctx_new_count += 1 // AEAD uses same factory
	return g_os.EVP_CIPHER_CTX_new()
}

// Macro replacements (OpenSSL exposes these only as SSL_CTX_ctrl / SSL_ctrl).
SSL_CTX_set_min_proto_version :: proc(ctx: rawptr, version: c.int) -> c.int {
	if g_os.SSL_CTX_ctrl == nil do return 0
	return c.int(g_os.SSL_CTX_ctrl(ctx, SSL_CTRL_SET_MIN_PROTO_VERSION, c.long(version), nil))
}

SSL_CTX_set_max_proto_version :: proc(ctx: rawptr, version: c.int) -> c.int {
	if g_os.SSL_CTX_ctrl == nil do return 0
	return c.int(g_os.SSL_CTX_ctrl(ctx, SSL_CTRL_SET_MAX_PROTO_VERSION, c.long(version), nil))
}

SSL_set_tlsext_host_name :: proc(ssl: rawptr, name: cstring) -> c.int {
	if g_os.SSL_ctrl == nil do return 0
	return c.int(g_os.SSL_ctrl(ssl, SSL_CTRL_SET_TLSEXT_HOSTNAME, TLSEXT_NAMETYPE_host_name, rawptr(name)))
}

// Lean TLS profile for QUIC: single group + single suite → smaller ClientHello
// and less negotiation work (HS wall). Safe defaults for our stack.
SSL_CTX_set_groups_list :: proc(ctx: rawptr, list: cstring) -> c.int {
	if g_os.SSL_CTX_ctrl == nil do return 0
	return c.int(g_os.SSL_CTX_ctrl(ctx, SSL_CTRL_SET_GROUPS_LIST, 0, rawptr(list)))
}

ssl_ctx_apply_lean_tls13 :: proc(ctx: rawptr) {
	if ctx == nil do return
	// X25519 only (or P-256 if unavailable — OpenSSL returns 0 on bad list).
	if SSL_CTX_set_groups_list(ctx, "X25519") != 1 {
		_ = SSL_CTX_set_groups_list(ctx, "P-256")
	}
	if g_os.SSL_CTX_set_ciphersuites != nil {
		_ = g_os.SSL_CTX_set_ciphersuites(ctx, "TLS_AES_128_GCM_SHA256")
	}
	// No session tickets / cache — less post-HS work (QUIC doesn't use TLS tickets here).
	_ = g_os.SSL_CTX_ctrl(ctx, SSL_CTRL_SET_SESS_CACHE_MODE, SSL_SESS_CACHE_OFF, nil)
	if g_os.SSL_CTX_set_num_tickets != nil {
		_ = g_os.SSL_CTX_set_num_tickets(ctx, 0)
	}
	// Prefer modern signatures only (shrink/skip weak algos).
	sigalgs: cstring = "ECDSA+SHA256:RSA-PSS+SHA256:ed25519"
	_ = g_os.SSL_CTX_ctrl(ctx, SSL_CTRL_SET_SIGALGS_LIST, 0, transmute(rawptr)sigalgs)
}
