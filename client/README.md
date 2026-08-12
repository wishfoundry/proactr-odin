# client

HTTP client (H1 / H2 / H3) for proactr-odin.

| Need | API |
|------|-----|
| CLI / tests | `get` / `request` |
| In-handler | `get_async` |
| Keep-alive | `dial` + `request`, or `connection_pool_*` |
| Headers then body (H1) | `exchange_*` |
| Clear TCP for async | `hop_dial_clear_fd` + `get_async_hop` |
| Prefer H3 | `Options.prefer_h3` or `version = .Http3` |

- **`hop_dial_stream`** — connection path (TLS stream OK)  
- **`hop_dial_clear_fd`** — proactr clear nonblocking TCP only  

On workers, blocking `get`/`request` return `.Invalid_Use`; use `get_async`.  
TLS: `openssl_dynlib` (OpenSSL ≥3.5). H3: `quic` + `http3` + `qpack`.
