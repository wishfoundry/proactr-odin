// Compile-time TCP TLS backend selection for default_provider().
// Host code calls through Provider; this flag only picks the default adapter.
package tls_server

// "dynlib" is the only supported default for PR5.
HTTP_TLS_BACKEND :: #config(HTTP_TLS_BACKEND, "dynlib")

HTTP_TLS_DYNLIB_PATH :: #config(HTTP_TLS_DYNLIB_PATH, "")
