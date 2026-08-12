# quic

QUIC (RFC 9000/9001) with OpenSSL ≥3.5 dynlib (`SSL_set_quic_tls_cbs` + libcrypto AEAD).

```bash
export DYLD_LIBRARY_PATH="/opt/homebrew/opt/openssl@3/lib:${DYLD_LIBRARY_PATH:-}"
odin test quic
```

Optional: `-define:PROACTR_OPENSSL_DYNLIB_PATH=/path/to/libssl.3.dylib`
