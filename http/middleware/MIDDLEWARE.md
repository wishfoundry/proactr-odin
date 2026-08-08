# Middleware

**Package:** `http/middleware` (import as `middleware`)  
**Host hooks:** `http.response_on_respond` / `http.response_on_complete`  
**Chain:** `Chain`, `from_fn`, stock layers

## Model

```
Handler  →  may call next, respond, or submit proactr I/O
Runtime  →  only the proactor delivers completions (cb, user)
Request allocator → request-scoped state (reset after wire + clean)
on_respond / on_complete → host-fired; not a public resume API
```

There is **no** `http.resume`. Schedule work by submitting ops (or pool work that soft-completes into the ring). Put `req` / `res` / `next` in `user` if the completion must continue the chain.

## Quick start

```odin
import http "path/to/http"
import mw   "path/to/http/middleware"

// Terminal app
router: http.Router
http.router_init(&router)
// ... routes ...
terminal := http.router_handler(&router)

// Onion (outer-first): request_id → logger → security → cors → router
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
// Layer opts data is auto-tracked and freed in chain_destroy.

s: http.Server
http.serve(&s, mw.chain_handler(&c))
// Prefer chain_root_ptr(&c) if you need a stable ^Handler for the process life.
```

Manual nesting (no Chain):

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
| `from_fn` / `chain_use_fn` | Custom `(req, res, next)` layers |

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

Async gate (session load) — pattern only:

```odin
// submit I/O with user = Job{req, res, next, ...}
// completion handler (runtime-invoked):
//   if unauthorized { http.respond(res, .Unauthorized); return }
//   next.handle(next, req, res)
```

## Performance notes

- Chain: each layer is a **heap `Handler` node** (stable `^Handler`); no `inject_at` into a shifting array.
- Chain setup allocates once per process; hot path is pointer calls only.
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
