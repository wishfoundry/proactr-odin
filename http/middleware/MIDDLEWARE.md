# Middleware

**Package:** `http/middleware` (import as `middleware`)  
**Host hooks:** `http.response_on_respond` / `http.response_on_complete`  
**Routing:** `http.Builder` + `listen_builder` (canonical product boot)  
**Chain:** `Chain`, `from_fn`, stock layers

## Model

```
Handler  →  may call next, respond, or submit proactr I/O
Runtime  →  only the proactor delivers completions (cb, user)
Request allocator → request-scoped state (reset after wire + clean)
on_respond / on_complete → host-fired; not a public resume API
```

There is **no** `http.resume`. Schedule work by submitting ops (or pool work that soft-completes into the ring). Put `req` / `res` / `next` in `user` if the completion must continue the chain.

## Quick start (Builder + stock layers)

Canonical product path: register routes on a `Builder`, attach middleware as `http.Layer`s, then `listen_builder`.

Stock `*_layer` constructors return `middleware.Layer`. Adapt with `to_http_layer` before `builder_use`:

```odin
import http "path/to/http"
import mw   "path/to/http/middleware"
import "core:net"

main :: proc() {
	b: http.Builder
	http.builder_init(&b)
	defer http.builder_destroy(&b)

	// Onion (outer-first): request_id → logger → security → cors → routes
	http.builder_use(&b,
		mw.to_http_layer(mw.request_id_layer({})),
		mw.to_http_layer(mw.logger_layer({})),
		mw.to_http_layer(mw.security_headers_layer({})),
		mw.to_http_layer(mw.cors_layer(mw.Cors_Default)),
	)

	http.builder_get_fn(&b, "/", proc(req: ^http.Request, res: ^http.Response) {
		http.respond_plain(res, "OK")
	})
	// Scoped MW under a group:
	// g := http.builder_group_begin(&b, "/api")
	// http.builder_use(g, mw.to_http_layer(mw.request_id_layer({})))
	// http.builder_get_fn(g, "/users", list_users)

	s: http.Server
	http.server_shutdown_on_interrupt(&s)
	err, build_err := http.listen_builder(&s, &b, net.Endpoint{port = 8080})
	if build_err.kind != .None {
		// format with http.builder_error_format(build_err)
		return
	}
	_ = err
}
```

Layer opts data is tracked on the expanded `Match_Table` and freed when the server tears down the table (under `listen_builder`).

### Chain-only (power / tests)

If you need a standalone onion without the Builder (e.g. unit tests):

```odin
terminal := http.handler(my_app)

c: mw.Chain
mw.chain_init(&c, terminal)
// Keep `c` alive for the entire server lifetime (next pointers are heap nodes inside c).
// defer mw.chain_destroy(&c) only after server shutdown.

mw.chain_wrap(&c, {
	mw.request_id_layer({}),
	mw.logger_layer({}),
	mw.security_headers_layer({}),
	mw.cors_layer(mw.Cors_Default),
})

s: http.Server
http.serve(&s, mw.chain_handler(&c))
// Prefer chain_root_ptr(&c) if you need a stable ^Handler for the process life.
```

Manual nesting (no Chain / no Builder):

```odin
app := http.handler(my_app)
// stable storage required for next pointers
nodes: [4]http.Handler
nodes[3] = app
nodes[2] = mw.security_headers({}, &nodes[3])
nodes[1] = mw.logger({}, &nodes[2])
nodes[0] = mw.request_id({}, &nodes[1])
// serve nodes[0]
```

## Stock middleware

| API | Role |
|-----|------|
| `logger` / `logger_layer` | Access log: method path status duration [rid=] via `on_respond` |
| `request_id` / `request_id_layer` | Echo or generate `X-Request-Id` on the response |
| `cors` / `cors_layer` | CORS + OPTIONS preflight; `Cors_Default` for public APIs |
| `security_headers` / `security_headers_layer` | nosniff, frame options, referrer-policy, optional HSTS/CSP |
| `static_*` | Elite static files (see `STATIC.md`) |
| `http.rate_limit` | IP rate limit (package `http`) |
| `from_fn` / `chain_use_fn` / `builder_use_fn` | Custom `(req, res, next)` layers |
| `to_http_layer` | Adapt `middleware.Layer` → `http.Layer` for `builder_use` |

## Hooks (package `http`)

```odin
// During middleware (before next or after scheduling):
http.response_on_respond(res, user, proc(req, res, user) {
    // Final status available; do not call respond again
})

http.response_on_complete(res, user, proc(req, res, user) {
    // Wire finished; request arena still live; about to reset
})
```

- **Max 4** of each per request (`RESPOND_HOOKS_MAX`) — fixed array, zero heap on register.
- **LIFO** fire order (onion: outer registers first, runs last on the way out).
- `user` should live in the **request allocator** (or static/server memory).

## Custom middleware

```odin
my_mw :: proc(next: ^http.Handler, allocator := context.allocator) -> http.Handler {
    return mw.from_fn(proc(req: ^http.Request, res: ^http.Response, next: ^http.Handler) {
        // before
        mw.call_next(next, req, res)
        // after only if next responded synchronously — prefer on_respond for status/duration
    }, next, allocator)
}
```

On a Builder without building a `Handler` yourself:

```odin
http.builder_use_fn(&b, proc(req: ^http.Request, res: ^http.Response, next: ^http.Handler) {
	// before
	next.handle(next, req, res)
})
```

Async gate (session load) — pattern only:

```odin
// submit I/O with user = Job{req, res, next, ...}
// completion handler (runtime-invoked):
//   if unauthorized { http.respond(res, .Unauthorized); return }
//   next.handle(next, req, res)
```

## Performance notes

- Builder expand: each layer is a **heap `Handler` node** on the frozen table; hot path is pointer calls only.
- Chain: same shape; setup allocates once per process.
- Logger: one arena object + hook slot; formats only when logging; fires at **final** status (`response_send_got_body`).
- Security/CORS: header sets with static or request-arena strings; CORS clones origin lists at construction.
- Hooks: fixed `[4]` arrays on `Response` — no dynamic grow.

## Design rules

1. Do not add a public `resume` — completions enter through proactr.
2. Do not write request headers (readonly after parse).
3. One `respond` per request; hooks must not re-enter `respond`.
4. Body intent transforms stay `response_body_middleware` / planner — not request chain callbacks.

## Tests

```bash
odin test http -o:none
odin test http/middleware -o:none
```
