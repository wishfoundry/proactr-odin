# client

Multi-protocol HTTP client (H1 / H2 / H3) for proactr-odin.

- Headers: `qpack.Header` / package `httpfield`
- H2: package `http2`
- H3: `http3` + `quic` + `qpack`
- TCP TLS: `openssl_dynlib` (OpenSSL ≥3.5)
- Status codes: `http.Status`

## Surfaces

| Need | API |
|------|-----|
| One-shot CLI/test | `get` / `request` |
| In-handler (non-blocking) | `get_async` |
| Keep-alive / reuse | `dial` + `request`, or `connection_pool_*` |
| Headers then body (H1) | `exchange_start` → `wait_headers` → `read_body` |
| Custom clear TCP for async | `hop_dial_clear_fd` + `get_async_hop` |
| Prefer HTTP/3 | `Options.prefer_h3` or `version = .Http3` |

### Dialer seams

- **`hop_dial_stream`** — connection path; dialer may return a finished TLS stream + ALPN.
- **`hop_dial_clear_fd`** — proactr path; nonblocking clear TCP only (TLS is a job phase). TLS-complete streams are rejected.

Async/proactr completes with a full body in `on_done`. Exchange is H1 + Content-Length only (no chunked). H3 uses QUIC, not the stream dialer.

## Outbound from a handler

Blocking `get` / `request` return `.Invalid_Use` on server workers. Use `get_async`:

```odin
ctx := new(Proxy_Ctx, conn_allocator) // not request-temp
ctx.res = res
job, err := client.get_async(res, "http://127.0.0.1:9000/api", {}, ctx,
	proc(user: rawptr, up: client.Response, err: client.Http_Error) {
		ctx := (^Proxy_Ctx)(user)
		defer client.response_destroy(&up)
		if err == .Exchange_Gone {
			return
		}
		if err != .None {
			http.respond_status(ctx.res, .Bad_Gateway)
			return
		}
		http.respond_bytes(ctx.res, up.body[:])
	},
)
_ = job
_ = err
```

Worker `Client_Runtime` is installed via `http.Client_Bridge`. Inbound clean cancels bound jobs with `.Exchange_Gone`.

### Proactr path protocols

| Mode | Behavior |
|------|----------|
| `http` Auto/H1 | Clear HTTP/1.1 |
| `https` Auto/H1/H2 | TLS mem-BIO; ALPN picks H1 or H2 |
| `https` + `.Http3` | QUIC/H3 only |
| `prefer_h3` | Try H3 first, fall back to TCP+ALPN on dial failure |

Async does not follow redirects. `max_redirects` applies to blocking `get`/`request` only.
