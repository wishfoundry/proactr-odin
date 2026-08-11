# client

Multi-protocol HTTP client (H1 / H2 / H3) for proactr-odin.

**Provenance:** vapor-http `client/`, adapted to proactr packages:
- Wire headers use `qpack.Header` (not server `http.Headers`)
- H2 engine: package `http2` (proactr)
- H3: packages `http3` + `quic` + `qpack`
- TCP TLS: package `openssl_dynlib` (same OpenSSL ≥3.5 dynlib as server/QUIC)
- Status codes: package `http` `Status` enum only

Not a product “server host” surface; App Contract remains for handlers.

## API tiers (pick the right surface)

```
┌─────────────────────────────────────────────────────────────────┐
│  Convenience (full body in one shot)                            │
│    get / request / get_proactr / get_async                      │
│    → Response { status, headers, body }                         │
├─────────────────────────────────────────────────────────────────┤
│  Headers-first H1 (streaming body pull)                         │
│    exchange_start → wait_headers → read_body / cancel / collect │
│    → lives on a Connection (legacy stream path)                 │
├─────────────────────────────────────────────────────────────────┤
│  Connection / pool                                              │
│    dial / request / connection_pool_*                           │
│    → hop_dial_stream under the hood (TLS-complete stream OK)    │
├─────────────────────────────────────────────────────────────────┤
│  Hop (dial result + meta + optional FD)                         │
│    hop_dial_stream   — Connection path (may be TLS + ALPN)      │
│    hop_dial_clear_fd — proactr path (nonblocking clear TCP only)│
│    hop_take_fd / hop_close                                      │
│    get_async_hop(rt, res?, hop, …) — inject pre-dialed clear FD │
└─────────────────────────────────────────────────────────────────┘
```

| Need | Use |
|------|-----|
| One-shot CLI/test fetch | `get` / `request` |
| In-handler outbound (non-blocking) | `get_async` |
| Custom clear-TCP dial then async | `hop_dial_clear_fd` + `get_async_hop` |
| Headers before body (H1 only) | `exchange_*` on a dialed `Connection` |
| Keep-alive / pool | `connection_pool_*` + `request` |
| Forced H3 / prefer_h3 | `Options.version = .Http3` or `prefer_h3` |

**Dialer seams (do not conflate):**

- **`hop_dial_stream`** — `Options.dialer` may return a finished TLS stream + negotiated ALPN (legacy Connection, mock streams, SSH/Iroh-shaped pipes).
- **`hop_dial_clear_fd`** — proactr jobs need a **nonblocking clear TCP fd**; TLS is a job phase (mem-BIO). Custom dialers that return TLS-complete streams are **rejected** (`.Unsupported_Version`).

**Residuals (honest):**

- Async / proactr still delivers **full body** in `on_done` (no headers-first job twin yet).
- `Exchange` v1 is **H1 + Content-Length** only (no chunked TE; no H2/H3 exchange).
- H3 is not Dialer/stream-shaped (QUIC residual path).

## Outbound from a handler (PR2)

Blocking `get` / `request` hard-fail with `.Invalid_Use` on server workers. Use `get_async`:

```odin
// user must NOT be request-temp (conn_allocator / static / job-copied).
ctx := new(Proxy_Ctx, conn_allocator)
ctx.res = res
job, err := client.get_async(res, "http://127.0.0.1:9000/api", {}, ctx,
	proc(user: rawptr, up: client.Response, err: client.Http_Error) {
		ctx := (^Proxy_Ctx)(user)
		defer client.response_destroy(&up)
		if err == .Exchange_Gone {
			return // inbound dying — do not respond
		}
		if err != .None {
			http.respond_status(ctx.res, .Bad_Gateway)
			return
		}
		http.respond_bytes(ctx.res, up.body[:])
	},
)
if err == .Not_Configured {
	// worker runtime missing (should not happen after server boot)
}
_ = job
```

Worker `Client_Runtime` is installed automatically on each host worker ring (`http.Client_Bridge`). Clean/destroy cancels bound jobs with `.Exchange_Gone`.

### Protocols on the proactr path (`use_proactr_io` / `get_async`)

| Mode | Behavior |
|------|----------|
| `http` Auto/H1 | Clear HTTP/1.1 |
| `https` Auto/H1/H2 | TLS mem-BIO; ALPN picks H1 or H2 |
| `https` + `.Http3` | QUIC/H3 only (no TCP fallback) |
| `https` + `.Auto` + `prefer_h3` | Try H3 first, fall back to TCP+ALPN on dial failure |
| `follow_alt_svc` | Opportunistic H3 when Alt-Svc cache has a live alt (legacy dial; proactr uses `prefer_h3` for same-origin try) |

Custom `Options.dialer` on this path must yield **clear nonblocking TCP** (see `hop_dial_clear_fd`). Injected hops: `get_async_hop`.

Async path does **not** follow redirects (`max_redirects` ignored). Blocking `get`/`request`/`connection_pool_*` on a server worker return `.Invalid_Use` (`INVALID_USE_DIAGNOSTIC`).
