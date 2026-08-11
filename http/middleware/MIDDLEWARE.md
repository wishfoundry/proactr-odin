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
| `rate_limit_layer` / `http.rate_limit` | GCRA multi-policy local rate limit (bounded store; see below) |
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

## Rate limit (stock)

**Engine:** package `http` (`Store`, `store_allow`, keys, `rate_limit`).  
**Layer:** `middleware.rate_limit_layer`.

- **Algorithm:** GCRA per key; multi-policy with `store_key(policy_index, user_key)` isolation.
- **Default** `rate_limit_layer({})`: 100/s **peer IP**, capacity 65 536, `Evict_Cold`.
- **Memory-safe under key spray** (hard cap). Not a global spray ceiling alone — compose
  `key_global` + `key_peer_ip` (or `key_client_ip` behind a trusted LB).
- **Per-process only** (each replica has its own budget). No Redis/cluster backend.
- **X-Forwarded-For:** ignored unless `key_client_ip` + non-empty `client_ip.trusted` CIDRs.
- **429** + `Retry-After` + `X-RateLimit-Limit|Remaining|Reset`. Pure `store_allow` has no HTTP.
- **Destroy:** layer `free_built` frees owned store; host `opts.store` is never destroyed by the layer.

```odin
// Zero-value
http.builder_use(&b, mw.to_http_layer(mw.rate_limit_layer({})))

// Production-ish: global + per-IP
http.builder_use(&b, mw.to_http_layer(mw.rate_limit_layer({
	policies = {
		{ name = "global", limit = 50_000, period = time.Second, key_fn = http.key_global },
		{ name = "ip", limit = 100, period = time.Second, key_fn = http.key_peer_ip },
	},
	skip_paths = { "/healthz" },
	capacity = 100_000,
})))
```

Immediate twin (tests / custom handlers):

```odin
var store: http.Store
http.store_init(&store, 10_000)
defer http.store_destroy(&store)
g := http.gcra_from_limit_period(50, time.Second, 50) or_else panic()
d := http.store_allow(&store, http.store_key(0, key), 1, g, now_ns)
if !d.allowed {
	http.rate_limit_write_deny(res, d, time.now(), "")
	http.respond(res)
}
```

## Live latency / RPS quantiles (optional)

Package **`quantile/`** (import as `quantile`) is host-agnostic helpers for app middleware
and handlers. Not wired into the core path metrics; use when you want your own
p50/p75/p90/p99 estimates.

- **Streaming (O(1) per sample, fixed 4-field set):** `quantile.Set` + `set_observe` /
  `set_observe_i64` — Frugal-2 estimates for p50, p75, p90, p99. Single-writer.
- **RPS stream (separate Set):** `rate_from_counts` or `Rate_Window` + `rate_window_tick`
  over a 1 s (or other) window; feed rate samples into their own `Set`, never mix with latency.
- **Offline (true order stats):** `percentile`, `quartiles`, `set_percentiles` for tests/benches.

```odin
import quantile "path/to/quantile"

// e.g. process-global or per-worker (single-writer)
lat: quantile.Set
rps: quantile.Rate_Window

// on_respond / handler complete:
quantile.set_observe_i64(&lat, i64(duration_ns))

// on a timer tick with total completed-request counter:
quantile.rate_window_tick(&rps, total_reqs, 1.0)

snap := quantile.set_snapshot(lat)
// snap.p50, snap.p75, snap.p90, snap.p99  — estimates, not loadgen truth
```

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
