# package `quic` — QUIC transport (RFC 9000/9001)

Product QUIC stack: **OpenSSL 3.5+ dynlib** for TLS-in-QUIC (`SSL_set_quic_tls_cbs`) and packet AEAD/HP via long-lived `EVP_CIPHER_CTX`.

| Layer | Implementation |
|-------|----------------|
| TLS SM | System OpenSSL ≥ 3.5 quic-tls callbacks |
| Packet protect | AES-GCM / ChaCha20-Poly1305 (libcrypto) |
| Not used | BoringSSL, `OSSL_QUIC_*` full stack |

## Requirements

```bash
export LIBRARY_PATH="/opt/homebrew/opt/openssl@3/lib:$LIBRARY_PATH"
export DYLD_LIBRARY_PATH="/opt/homebrew/opt/openssl@3/lib:${DYLD_LIBRARY_PATH:-}"
```

Optional: `-define:QUIC_OPENSSL_DYNLIB_PATH=/path/to/libssl.3.dylib`

## Test

```bash
odin test quic
```

## Design / history

- Port plan: [`docs/design/quic-openssl-dynlib-port.md`](../docs/design/quic-openssl-dynlib-port.md)
- WOW iteration: [`docs/design/quic-openssl-wow-iteration.md`](../docs/design/quic-openssl-wow-iteration.md)
- Pre-cutover A/B: [`comparisons/quic-openssl/results/DECISION.md`](../comparisons/quic-openssl/results/DECISION.md)
