# Phase 0–2: laytan/odin-http fork → proactr host

Working copy of the [laytan/odin-http](https://github.com/laytan/odin-http) protocol surface lives under `http/`. Upstream remains pristine in `vendor/laytan/odin-http` for reactor/nbio baselines.

## Copied from vendor (protocol surface)

| File | Role |
|------|------|
| `http.odin` | Request-line, version, method, date helpers, atomics |
| `request.odin` | `Request`, header validation |
| `response.odin` | `Response`, body buffers, heading write, send path |
| `responses.odin` | `respond_plain` / html / json / file helpers |
| `headers.odin` | Case-insensitive header map |
| `body.odin` | Content-Length + chunked body decode |
| `cookie.odin` | Cookie parse/write |
| `status.odin` | HTTP status enum + strings |
| `mimes.odin` | Extension → Content-Type |
| `handlers.odin` | `Handler`, middleware, rate limit |
| `routing.odin` | URL/query + Lua-pattern `Router` |
| `scanner.odin` | Callback scanner over connection buffers |
| `server.odin` | Server/Connection types + proactr host |

**Not copied:** `old_nbio/`, `openssl/`, `client/`, `allocator.odin` (`#+build ignore` upstream), examples/docs.

## Phase status

| Phase | Status | Notes |
|------:|--------|-------|
| 0 | Done | Protocol surface, no nbio; host stubs |
| 1 | Done | `proactr` ring (raw io_uring, no liburing) |
| 2 | **Done** | Linux `listen_and_serve` completion host |

## Phase 2 host (Linux)

- **`listen` / `serve` / `listen_and_serve`** — `net.listen_tcp` + one `proactr.Ring` per worker; non-Linux still returns `proactr.Error.Unsupported`.
- **Accept** — `submit_accept` → CQE → alloc `Connection` → re-arm accept → `conn_handle_reqs`.
- **Recv** — scanner path calls `host_submit_recv` into `scanner.buf[end:]`; CQE → `scanner_on_bytes`.
- **Send** — `response_send_got_body` builds the buffer, `host_submit_send`; partial sends resubmit; only after full send CQE does `clean_request_loop` free the request arena.
- **Close** — `submit_close` → free connection on CQE.
- **Keep-alive** — after full send, if not `Will_Close`, reset request and `submit_recv` again.
- **Workers** — `thread_count` (default 1); shared listen socket, one ring per thread. SO_REUSEPORT deferred.
- **Still sync:** `respond_file` uses `os.read_entire_file` (async open/read later).

## Guarantees

- No `import "core:nbio"` (or any nbio re-export) under `http/`.
- No liburing dependency in this package.
- `package http` is **not** fully self-contained: `server.odin` imports `../proactr` for the ring and errors.
- Consumers: `examples/empty_ok` imports `../../http`; peer microservers under `comparisons/*/proactr` import `../../../http`.
- `vendor/laytan/odin-http` is baseline-only — do not modify.

## Connection state machine (Phase 2)

```
Listening ──Accept CQE──► New ──conn_handle_reqs──► Active
                              ▲                       │
                              │                    handler
                              │                       │
                              │                  submit_send
                              │                       │
                         keep-alive              Send CQE(s)
                              │                       │
                              └────── Idle ◄──────────┤
                                                      │
                                                 Will_Close
                                                      │
                                                 submit_close
                                                      │
                                                   Closed
```

## Next

1. Bastion smoke: TFB plaintext + size ladder under load.
2. Optional SO_REUSEPORT multi-listen; measure worker scaling.
3. Optional: async file I/O for `respond_file` once open/read ops exist.
4. Multishot accept / fixed buffers if CQ pressure shows up.
