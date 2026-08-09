// Compile-time TCP TLS backend selection for default_provider().
// Host code calls through Provider; this flag only picks the default adapter.
//
//   -define:HTTP_TLS_BACKEND=dynlib      // load libssl via core:dynlib (default, PR5)
//   -define:HTTP_TLS_DYNLIB_PATH=...     // optional explicit libssl path
//
// PR5 ships dynlib-only. Static BoringSSL / OpenSSL .a adapters are out of scope
// for this package (no vendor .a in proactr for PR5).
//
// Product path is mem-BIO (setup_mem_bios): the host owns ciphertext on the wire;
// SSL only encrypt/decrypts. set_fd may exist as a fallback on the provider but
// is not the proactr product I/O path.
package tls_server

// "dynlib" is the only supported default for PR5.
HTTP_TLS_BACKEND :: #config(HTTP_TLS_BACKEND, "dynlib")

// When non-empty and BACKEND=dynlib, load this path only (no probe list).
HTTP_TLS_DYNLIB_PATH :: #config(HTTP_TLS_DYNLIB_PATH, "")
