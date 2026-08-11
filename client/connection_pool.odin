// Idle connection pool — Go-like reuse for many short get/request calls.
// A single Connection already supports multi-request reuse without a pool:
// dial once, then call request() repeatedly (h1 keep-alive, h2 mux, h3 streams).
// Use a Connection_Pool when you issue many independent short gets and want idle
// connections reused across those calls for the same origin.
// Reuse is only offered when ALL of the following hold:
//   - Same origin (scheme + host + port)
//   - Connection still alive:
//       h1  → h1_alive
//       h2  → fail_code == 0 and peer has not sent GOAWAY
//       h3  → transport state + QUIC conn present
//   - Protocol matches Options.version:
//       forced .Http1 / .Http2 / .Http3 only reuse that negotiated version
//       .Auto accepts any idle protocol for the origin
// Thread safety: core:sync.Mutex guards the idle list only; dial and request
// I/O run outside the lock. Not a full browser connection manager — no
// per-host concurrency caps, no Happy Eyeballs, no cross-process sharing.
package client

import "core:mem"
import "core:sync"
import "core:time"


// Default idle slots kept per origin when Connection_Pool_Config.max_idle_per_host is 0.
DEFAULT_MAX_IDLE_PER_HOST :: 2

// Optional limits for connection_pool_init. Zero fields use package defaults / unlimited age.
Connection_Pool_Config :: struct {
	// Max idle Connections retained for one origin. 0 → DEFAULT_MAX_IDLE_PER_HOST.
	max_idle_per_host: int,
	// Drop idle Connections older than this when taking/putting. 0 → no age limit.
	max_idle_time: time.Duration,
}

@(private)
_Connection_Pool_Idle :: struct {
	conn:       ^Connection,
	origin:     string, // owned "scheme://host:port"
	idle_since: time.Time,
}

// Idle connection pool keyed by origin. Zero value is not usable — call connection_pool_init.
Connection_Pool :: struct {
	mu:                sync.Mutex,
	allocator:         mem.Allocator,
	max_idle_per_host: int,
	max_idle_time:     time.Duration,
	idle:              [dynamic]_Connection_Pool_Idle,
	inited:            bool,
}

// Initialize an empty pool. Safe to call connection_pool_destroy on a zero value after init.
connection_pool_init :: proc(
	p: ^Connection_Pool, cfg := Connection_Pool_Config{}, allocator := context.allocator,
) {
	p^ = {}
	p.allocator = allocator
	p.max_idle_per_host = cfg.max_idle_per_host if cfg.max_idle_per_host > 0 else DEFAULT_MAX_IDLE_PER_HOST
	p.max_idle_time = cfg.max_idle_time
	p.idle.allocator = allocator
	p.inited = true
}

// Close every idle connection and free pool storage. Does not touch Connections
// currently borrowed via connection_pool_dial (caller still owns those).
connection_pool_destroy :: proc(p: ^Connection_Pool) {
	if p == nil || !p.inited do return
	sync.mutex_lock(&p.mu)
	for e in p.idle {
		close(e.conn)
		delete(e.origin, p.allocator)
	}
	delete(p.idle)
	sync.mutex_unlock(&p.mu)
	p^ = {}
}

// Borrow a live idle connection for the URL's origin, or dial a new one.
// Caller must connection_pool_put or close the returned Connection.
connection_pool_dial :: proc(
	p: ^Connection_Pool, url: string, opts := Options{}, allocator := context.allocator,
) -> (^Connection, Http_Error) {
	t, ok := parse_target(url)
	if !ok do return nil, .Invalid_Url

	if p != nil && p.inited {
		if c := _connection_pool_take(p, t.scheme, t.host, t.port, opts.version); c != nil {
			// Refresh path so defaulted requests match this URL.
			c.target.path = t.path
			c.target.scheme = t.scheme
			c.target.host = t.host
			c.target.port = t.port
			return c, .None
		}
	}
	return dial(url, opts, allocator)
}

// Return a connection to the pool if still reusable; otherwise close it.
// Safe with c == nil. Never put the same connection twice.
connection_pool_put :: proc(p: ^Connection_Pool, c: ^Connection) {
	if c == nil do return
	if p == nil || !p.inited || !_conn_pool_reusable(c) {
		close(c)
		return
	}

	origin := origin_key(c.target.scheme, c.target.host, c.target.port, p.allocator)
	now := time.now()

	sync.mutex_lock(&p.mu)
	_connection_pool_evict_expired_unlocked(p, now)

	// Cap idle per origin: drop oldest for this origin if at limit.
	for _connection_pool_count_origin_unlocked(p, origin) >= p.max_idle_per_host {
		if !_connection_pool_drop_oldest_origin_unlocked(p, origin) {
			break
		}
	}
	if _connection_pool_count_origin_unlocked(p, origin) >= p.max_idle_per_host {
		sync.mutex_unlock(&p.mu)
		delete(origin, p.allocator)
		close(c)
		return
	}

	append(&p.idle, _Connection_Pool_Idle{conn = c, origin = origin, idle_since = now})
	sync.mutex_unlock(&p.mu)
}

// One-shot GET via the pool: dial-or-reuse, request, put back (or close on error).
// Prefer dial + request on one Connection when issuing many requests on purpose;
// this is the short-get path analogous to get().
connection_pool_get :: proc(
	p: ^Connection_Pool, url: string, opts := Options{}, allocator := context.allocator,
) -> (Response, Http_Error) {
	if http_worker_active {
		return {}, .Invalid_Use
	}
	c, e := connection_pool_dial(p, url, opts, allocator)
	if e != .None do return {}, e

	t, _ := parse_target(url)
	req := Request {
		method = "GET",
		target = t,
	}
	res, err := request(c, &req, allocator)
	if err != .None {
		close(c)
		return res, err
	}
	connection_pool_put(p, c)
	return res, .None
}

// Send `req` (method/headers/body) to `url` via the pool. Fills missing target
// fields from the URL. Puts the connection back on success; closes on error.
connection_pool_request :: proc(
	p: ^Connection_Pool, url: string, req: ^Request, opts := Options{}, allocator := context.allocator,
) -> (Response, Http_Error) {
	if http_worker_active {
		return {}, .Invalid_Use
	}
	c, e := connection_pool_dial(p, url, opts, allocator)
	if e != .None do return {}, e

	t, ok := parse_target(url)
	if !ok {
		close(c)
		return {}, .Invalid_Url
	}
	if len(req.target.scheme) == 0 do req.target.scheme = t.scheme
	if len(req.target.host) == 0 do req.target.host = t.host
	if req.target.port == 0 do req.target.port = t.port
	if len(req.target.path) == 0 do req.target.path = t.path

	res, err := request(c, req, allocator)
	if err != .None {
		close(c)
		return res, err
	}
	connection_pool_put(p, c)
	return res, .None
}

// ---- internals -------------------------------------------------------------

@(private)
_conn_pool_reusable :: proc(c: ^Connection) -> bool {
	if c == nil do return false
	return _conn_pool_alive(c)
}

@(private)
_conn_pool_alive :: proc(c: ^Connection) -> bool {
	switch c.version {
	case .Http1, .Auto:
		return c.h1_alive
	case .Http2:
		// Peer GOAWAY or a connection-level failure means no more streams.
		return c.h2.fail_code == 0 && !c.h2.goaway_received
	case .Http3:
		st, ok := c.transport.(^Http3_State)
		return ok && st != nil && st.session.conn != nil
	}
	return false
}

@(private)
_connection_pool_protocol_ok :: proc(wanted, have: ProtocolVersion) -> bool {
	if wanted == .Auto do return true
	return wanted == have
}

@(private)
_connection_pool_idle_expired :: proc(p: ^Connection_Pool, e: _Connection_Pool_Idle, now: time.Time) -> bool {
	if p.max_idle_time <= 0 do return false
	return time.diff(e.idle_since, now) >= p.max_idle_time
}

// Take LIFO idle entry matching origin + protocol; drop dead/expired along the way.
@(private)
_connection_pool_take :: proc(
	p: ^Connection_Pool, scheme, host: string, port: int, wanted: ProtocolVersion,
) -> ^Connection {
	key := origin_key(scheme, host, port, context.temp_allocator)
	now := time.now()

	sync.mutex_lock(&p.mu)
	defer sync.mutex_unlock(&p.mu)

	// Scan from the end (most recently put) for a match.
	for i := len(p.idle) - 1; i >= 0; i -= 1 {
		e := p.idle[i]
		if e.origin != key do continue

		// Remove this slot either way (reuse, dead, or expired).
		ordered_remove(&p.idle, i)
		origin_owned := e.origin

		if _connection_pool_idle_expired(p, e, now) || !_conn_pool_alive(e.conn) {
			delete(origin_owned, p.allocator)
			close(e.conn)
			continue
		}
		if !_connection_pool_protocol_ok(wanted, e.conn.version) {
			// Wrong protocol for this take — leave it available for a matching caller.
			append(&p.idle, _Connection_Pool_Idle{conn = e.conn, origin = origin_owned, idle_since = e.idle_since})
			continue
		}

		delete(origin_owned, p.allocator)
		return e.conn
	}
	return nil
}

@(private)
_connection_pool_count_origin_unlocked :: proc(p: ^Connection_Pool, origin: string) -> int {
	n := 0
	for e in p.idle {
		if e.origin == origin do n += 1
	}
	return n
}

// Drop the oldest idle entry for origin; returns false if none.
@(private)
_connection_pool_drop_oldest_origin_unlocked :: proc(p: ^Connection_Pool, origin: string) -> bool {
	for i in 0 ..< len(p.idle) {
		if p.idle[i].origin != origin do continue
		e := p.idle[i]
		ordered_remove(&p.idle, i)
		close(e.conn)
		delete(e.origin, p.allocator)
		return true
	}
	return false
}

@(private)
_connection_pool_evict_expired_unlocked :: proc(p: ^Connection_Pool, now: time.Time) {
	if p.max_idle_time <= 0 do return
	// Walk backward so ordered_remove is stable.
	for i := len(p.idle) - 1; i >= 0; i -= 1 {
		e := p.idle[i]
		if !_connection_pool_idle_expired(p, e, now) do continue
		ordered_remove(&p.idle, i)
		close(e.conn)
		delete(e.origin, p.allocator)
	}
}
