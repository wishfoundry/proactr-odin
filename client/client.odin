// client — multi-protocol HTTP client toolkit.
//
// Layers (see docs/LIBRARY.md):
//   CORE         H2_Session / H3_Session (sans-I/O), Dialer + request over io.Stream
//   ADAPTERS     tcp_dialer, tls_dialer, h3 dial (QUIC sleep-poll over H3_Session)
//   CONVENIENCE  get() one-shot
//
// Session negotiation (toolkit defaults; optional browser-ish Alt-Svc):
//   .Auto → TLS ALPN [h2, http/1.1] only (no surprise H3)
//   follow_alt_svc → try cached Alt-Svc h3 first, then ALPN fallback
//   Forced .Http1 / .Http2 → ALPN offer matches; mismatch → Unsupported_Version
//   Forced .Http3 → QUIC only
//   H1 keep-alive + H2 mux + H3 multi-stream on a reused Connection
package client

import "core:bytes"
import "core:fmt"
import "core:io"
import "core:mem"
import "core:net"
import "core:strconv"
import "core:strings"
import "core:time"
import gzip "core:compress/gzip"

import "../http2"
import "../qpack"

// Package defaults when Options.timeout / max_response_body / max_redirects are 0.
// timeout covers both dial and request I/O (h1/h2/h3). Non-zero Options.timeout
// replaces both defaults with that single budget.
DEFAULT_DIAL_TIMEOUT_MS    :: 10_000
DEFAULT_REQUEST_TIMEOUT_MS :: 30_000
DEFAULT_MAX_RESPONSE_BODY  :: 32 * 1024 * 1024 // 32 MiB
DEFAULT_MAX_REDIRECTS      :: 10
// Stable User-Agent when the request does not set one (not version-churny).
DEFAULT_USER_AGENT         :: "vapor-http/client"

// ---- Dialer: the pluggable transport seam ----------------------------------

// A Dialer produces a duplex byte stream to `target` and reports the version it
// negotiated (e.g. via ALPN). Swap it for TLS, a Unix socket, an SSH channel,
// or an in-memory pipe. h1/h2 ride the returned io.Stream; h3 is QUIC and is
// dialed separately (see `dial`).
//
// `data`+`procedure` mirror core:io.Stream — userdata travels with the proc,
// since Odin procs aren't closures.
Dial_Proc :: #type proc(
	data: rawptr, target: Target, allocator: mem.Allocator,
) -> (stream: io.Stream, negotiated: ProtocolVersion, err: Http_Error)

Dialer :: struct {
	data:      rawptr,
	procedure: Dial_Proc,
}

// The built-in plaintext-TCP dialer (the default when Options.dialer is unset).
tcp_dialer :: Dialer{procedure = _tcp_dial}

Options :: struct {
	// .Auto → TLS ALPN h2|h1 (toolkit default). .Http3 → QUIC only.
	// .Http1 / .Http2 force the ALPN offer and require that negotiation.
	version:  ProtocolVersion,
	dialer:   Dialer, // zero → scheme default (tcp / tls)
	// Wall-clock budget in ms for dial and for each request's I/O (h1/h2/h3).
	// 0 → DEFAULT_DIAL_TIMEOUT_MS (dial) and DEFAULT_REQUEST_TIMEOUT_MS (request).
	// Non-zero → that value for both dial and request.
	timeout:  int,
	// Max buffered response body bytes. 0 → DEFAULT_MAX_RESPONSE_BODY (32 MiB).
	// Exceeding returns Http_Error.Body_Too_Large.
	max_response_body: int,
	// Redirect following for get/request: 0 → DEFAULT_MAX_REDIRECTS (10);
	// negative → never follow; positive → follow at most that many hops.
	// 301/302/303/307/308; relative Location resolved against the previous URL.
	// Cross-origin re-dials; same-origin reuses keep-alive/mux when possible.
	// http↔https scheme changes are allowed (toolkit convenience).
	max_redirects: int,
	insecure: bool,   // skip TLS cert verify (self-signed test servers ONLY)
	// Opt-in: learn Alt-Svc + opportunistic H3 on .Auto (browser-ish).
	// Default false — explicit .Http3 or ALPN only, like Go clients.
	follow_alt_svc: bool,
	// Opt-in: on .Auto + https, try H3/QUIC first (same origin), fall back to
	// TCP+ALPN if QUIC fails. Independent of Alt-Svc cache (prefer_h3 = try now;
	// follow_alt_svc = try only when cache has a live h3 alt). Default false.
	prefer_h3: bool,
	// Opt-out: send connection: close and do not reuse H1 (default keep-alive).
	disable_h1_keep_alive: bool,
	// Accept-Encoding: gzip + transparent Content-Encoding gunzip.
	// nil (zero) → true (toolkit default). Set false to leave encoding alone;
	// set true to force on even when combining with other opts.
	accept_gzip: Maybe(bool),
	// Private Alt-Svc cache when following or learning; nil + follow → global.
	alt_svc_cache: ^Alt_Svc_Cache,
	// When true, GET uses the proactr completion path (thread-local ring):
	// clear H1, https H1/H2 (mem-BIO), and explicit .Http3. Default false keeps
	// legacy dial/request (H3 sleep-poll adapter).
	use_proactr_io: bool,
}

// ---- Public API ------------------------------------------------------------

get :: proc(url: string, opts := Options{}, allocator := context.allocator) -> (Response, Http_Error) {
	if http_worker_active {
		// INVALID_USE_DIAGNOSTIC
		return {}, .Invalid_Use
	}
	// Optional proactr path: clear H1 + https H1/H2 (mem-BIO) + H3 (explicit or prefer_h3).
	if opts.use_proactr_io {
		t, ok := parse_target(url)
		if !ok do return {}, .Invalid_Url
		if t.scheme == "http" && (opts.version == .Auto || opts.version == .Http1) {
			return get_proactr(url, opts, allocator)
		}
		if t.scheme == "https" &&
		   (opts.version == .Auto ||
			   opts.version == .Http1 ||
			   opts.version == .Http2 ||
			   opts.version == .Http3) {
			return get_proactr(url, opts, allocator)
		}
	}
	c, e := dial(url, opts, allocator)
	if e != .None do return {}, e
	defer close(c)
	req := Request{method = "GET", target = c.target}
	return request(c, &req, allocator)
}

// get_proactr is a one-shot GET over a private proactr ring (thread-local Client_Runtime).
// http → clear H1; https → TLS mem-BIO H1/H2, H3 when version==.Http3 or prefer_h3.
// No redirect following (v1) — max_redirects is ignored on this path.
get_proactr :: proc(url: string, opts := Options{}, allocator := context.allocator) -> (Response, Http_Error) {
	if http_worker_active {
		return {}, .Invalid_Use
	}
	t, ok := parse_target(url)
	if !ok do return {}, .Invalid_Url

	rt := runtime_thread_local()
	if rt == nil || !rt.inited {
		return {}, .Not_Configured
	}

	max_body := _resolve_max_body(opts.max_response_body)
	timeout_ms := _resolve_request_timeout_ms(opts.timeout)
	path := t.path if len(t.path) > 0 else "/"

	// Forced H3 — no TCP fallback.
	if opts.version == .Http3 {
		if t.scheme != "https" {
			return {}, .Unsupported_Version
		}
		return h3_request_blocking(
			rt,
			"GET",
			t.host,
			path,
			t.port,
			nil,
			max_body,
			opts.insecure,
			timeout_ms,
			allocator,
		)
	}

	// prefer_h3: try QUIC first on .Auto https. Fall through only if *start/dial*
	// fails — never after a live exchange (no double GET). Short dial probe budget.
	if _opts_prefer_h3_first(opts, t.scheme) {
		Wait :: struct {
			done: bool,
			res:  Response,
			err:  Http_Error,
		}
		wait: Wait
		probe := _prefer_h3_probe_ms(opts.timeout)
		job, herr := h3_request_start(
			rt,
			"GET",
			t.host,
			path,
			t.port,
			nil,
			max_body,
			opts.insecure,
			timeout_ms,
			rawptr(&wait),
			proc(user: rawptr, res: Response, err: Http_Error) {
				w := (^Wait)(user)
				w.res = res
				w.err = err
				w.done = true
			},
			allocator,
			probe, // dial_timeout_ms — short probe, not full request budget
		)
		if herr == .None {
			// H3 dial/start ok — complete this exchange; no TCP fallback.
			perr := runtime_pump_until(rt, &wait.done, timeout_ms)
			if !wait.done {
				if job.live && !job.done_fired {
					job_cancel(job, false)
				}
				if wait.err == .None {
					wait.err = perr if perr != .None else .Timeout
				}
			}
			_ = runtime_drain(rt, 32, 0)
			return wait.res, wait.err
		}
		// Start/dial failed — fall through to TCP TLS (H1/H2).
	}

	// Clear-FD hop (honors opts.dialer when it yields nonblocking clear TCP).
	if t.scheme != "http" && t.scheme != "https" {
		return {}, .Unsupported_Version
	}
	if t.scheme == "http" && opts.version != .Auto && opts.version != .Http1 {
		return {}, .Unsupported_Version
	}
	if t.scheme == "https" &&
	   opts.version != .Auto &&
	   opts.version != .Http1 &&
	   opts.version != .Http2 {
		return {}, .Unsupported_Version
	}

	hop, herr := hop_dial_clear_fd(t, opts, allocator)
	if herr != .None do return {}, herr
	fd := hop_take_fd(&hop)
	hop_close(&hop)
	if fd < 0 {
		return {}, .Connect_Failed
	}

	if t.scheme == "https" {
		return tls_request_blocking(
			rt,
			fd,
			"GET",
			t.host,
			path,
			t.port,
			nil,
			max_body,
			opts.insecure,
			opts.version,
			timeout_ms,
			allocator,
		)
	}
	return h1_clear_request_blocking(
		rt,
		fd,
		"GET",
		t.host,
		path,
		t.port,
		nil,
		max_body,
		timeout_ms,
		allocator,
	)
}

// True when Auto+https should attempt H3 before TCP (prefer_h3 opt-in).
@(private)
_opts_prefer_h3_first :: proc(opts: Options, scheme: string) -> bool {
	return opts.prefer_h3 && opts.version == .Auto && scheme == "https"
}

// Short dial probe budget for prefer_h3 (avoid full request timeout sleep-poll).
// Caps at dial default; respects opts.timeout when smaller.
PREFER_H3_PROBE_MS :: 1500

@(private)
_prefer_h3_probe_ms :: proc(timeout_ms: int) -> int {
	probe := PREFER_H3_PROBE_MS
	if timeout_ms > 0 && timeout_ms < probe {
		return timeout_ms
	}
	dial_def := DEFAULT_DIAL_TIMEOUT_MS
	if probe > dial_def {
		return dial_def
	}
	return probe
}

dial :: proc(url: string, opts := Options{}, allocator := context.allocator) -> (^Connection, Http_Error) {
	t, ok := parse_target(url)
	if !ok do return nil, .Invalid_Url

	c := new(Connection, allocator)
	c.target = t
	c.allocator = allocator
	c.timeout_ms = opts.timeout
	c.max_response_body = _resolve_max_body(opts.max_response_body)
	c.max_redirects = _resolve_max_redirects(opts.max_redirects)
	c.accept_gzip = _resolve_accept_gzip(opts.accept_gzip)
	c.insecure = opts.insecure
	c.dialer = opts.dialer
	c.prefer_version = opts.version
	c.follow_alt_svc = opts.follow_alt_svc
	c.prefer_h3 = opts.prefer_h3
	c.h1_alive = true
	c.h1_keep_alive = !opts.disable_h1_keep_alive
	c.h1_rx.allocator = allocator

	// Cache: attach when following, or when caller supplies a private store to learn into.
	cache: ^Alt_Svc_Cache
	if opts.follow_alt_svc || opts.alt_svc_cache != nil {
		cache = opts.alt_svc_cache if opts.alt_svc_cache != nil else alt_svc_global()
	}
	c.alt_svc = cache

	return _conn_open(c, t, opts)
}

// Open transport for `t` into an allocated Connection shell (initial dial).
// On failure the Connection is freed.
@(private)
_conn_open :: proc(c: ^Connection, t: Target, opts: Options) -> (^Connection, Http_Error) {
	if e := _conn_bind_transport(c, t, opts); e != .None {
		_conn_free_unopened(c)
		return nil, e
	}
	return c, .None
}

// Close current transport (if any) and dial `t` with the same Options knobs
// stored on `c`. Does not free `c` — used for cross-origin redirect hops.
@(private)
_conn_redial :: proc(c: ^Connection, t: Target) -> Http_Error {
	_conn_close_transport(c)
	opts := Options {
		version               = c.prefer_version,
		dialer                = c.dialer,
		timeout               = c.timeout_ms,
		max_response_body     = c.max_response_body,
		max_redirects         = c.max_redirects, // already resolved; re-store same
		insecure              = c.insecure,
		follow_alt_svc        = c.follow_alt_svc,
		prefer_h3             = c.prefer_h3,
		disable_h1_keep_alive = !c.h1_keep_alive,
		accept_gzip           = c.accept_gzip,
		alt_svc_cache         = c.alt_svc,
	}
	// max_redirects / max_body / accept_gzip on Connection are already resolved;
	// Options re-resolution would clobber them — save and restore after bind.
	saved_redirects := c.max_redirects
	saved_max_body := c.max_response_body
	saved_gzip := c.accept_gzip
	e := _conn_bind_transport(c, t, opts)
	c.max_redirects = saved_redirects
	c.max_response_body = saved_max_body
	c.accept_gzip = saved_gzip
	return e
}

// Tear down transport + h2/h1 session state without freeing Connection.
@(private)
_conn_close_transport :: proc(c: ^Connection) {
	if c.h2_started {
		http2.conn_destroy(&c.h2)
		c.h2_started = false
		c.h2 = {}
	}
	// Prefer hop_close when hop owns stream/fd; avoid double-close of same sock.
	if c.hop.owns_stream || c.hop.owns_fd || c.hop.owns_quic {
		hop_close(&c.hop)
		c.transport = {}
	} else {
		switch p in c.transport {
		case io.Stream:    io.close(p)
		case ^Http3_State: _h3_close(p)
		}
		c.transport = {}
		// Clear non-owning hop shell.
		c.hop = {}
		c.hop.fd = -1
	}
	clear(&c.h1_rx)
	c.h1_alive = false
}

// Dial/bind transport onto `c` for target `t`. On failure transport is unset;
// caller decides whether to free `c`.
@(private)
_conn_bind_transport :: proc(c: ^Connection, t: Target, opts: Options) -> Http_Error {
	cache := c.alt_svc
	t := t

	// Forced H3 — no TCP fallback.
	if opts.version == .Http3 {
		st, e := _h3_dial(t.host, t.port, t.scheme, opts.insecure, opts.timeout, c.allocator)
		if e != .None do return e
		c.version = .Http3
		c.transport = st
		c.target = t
		c.h1_alive = true
		return .None
	}

	// prefer_h3: try same-origin H3 first (short dial probe), then TCP+ALPN.
	// On probe fail, skip Alt-Svc H3 this bind (avoid double QUIC).
	prefer_h3_failed := false
	if _opts_prefer_h3_first(opts, t.scheme) {
		probe := _prefer_h3_probe_ms(opts.timeout)
		st, e := _h3_dial(t.host, t.port, t.scheme, opts.insecure, probe, c.allocator)
		if e == .None {
			c.version = .Http3
			c.transport = st
			c.target = t
			c.h1_alive = true
			return .None
		}
		prefer_h3_failed = true
	}

	// Opt-in Alt-Svc: opportunistic H3 from cache, then TCP+ALPN on failure.
	// Skipped when prefer_h3 already failed same-origin QUIC this bind.
	if !prefer_h3_failed &&
	   opts.version == .Auto &&
	   opts.follow_alt_svc &&
	   t.scheme == "https" &&
	   cache != nil {
		if ent, hit := alt_svc_cache_lookup(cache, t.scheme, t.host, t.port); hit {
			host := ent.host if len(ent.host) > 0 else t.host
			st, e := _h3_dial(host, ent.port, t.scheme, opts.insecure, opts.timeout, c.allocator)
			if e == .None {
				alt_svc_cache_mark_ok(cache, t.scheme, t.host, t.port)
				c.version = .Http3
				c.transport = st
				c.target = t
				c.h1_alive = true
				return .None
			}
			// QUIC failed — suppress this alt for a while, fall through to TCP+ALPN.
			alt_svc_cache_mark_broken(cache, t.scheme, t.host, t.port)
		}
	}

	// h1/h2 over a byte stream; ALPN offer matches the caller's version hint.
	c.target = t
	c.target.version = opts.version
	c.target.dial_timeout_ms = _resolve_dial_timeout_ms(opts.timeout)
	t.version = opts.version
	t.dial_timeout_ms = c.target.dial_timeout_ms

	// Close previous hop if rebinding (redirect).
	if c.hop.owns_stream || c.hop.owns_fd {
		hop_close(&c.hop)
	}

	hop, herr := hop_dial_stream(t, opts, c.allocator)
	if herr != .None do return herr

	_try_set_stream_sock_timeout(hop.stream, _resolve_request_timeout(opts.timeout))

	c.version = hop.meta.negotiated
	c.transport = hop.stream
	// Connection retains hop (owns stream close via hop or transport — hop owns_stream).
	c.hop = hop
	c.h1_alive = true
	clear(&c.h1_rx)
	return .None
}

@(private)
_conn_free_unopened :: proc(c: ^Connection) {
	delete(c.h1_rx)
	free(c, c.allocator)
}

// Send `req` on `c`, following redirects per Connection.max_redirects
// (from Options at dial). Intermediate 3xx bodies are discarded; the final
// response (success or last unfollowed 3xx) is returned to the caller.
request :: proc(c: ^Connection, req: ^Request, allocator := context.allocator) -> (Response, Http_Error) {
	if http_worker_active {
		return {}, .Invalid_Use
	}
	// Fill missing target fields from the connection without clobbering path.
	if len(req.method) == 0 do req.method = "GET"
	if len(req.target.host) == 0 do req.target.host = c.target.host
	if len(req.target.scheme) == 0 do req.target.scheme = c.target.scheme
	if req.target.port == 0 do req.target.port = c.target.port
	if len(req.target.path) == 0 do req.target.path = c.target.path

	// Working copy so method/body/headers can change across hops without
	// permanently mutating the caller's Request (headers may be re-sliced).
	cur := req^
	hops := 0

	for {
		res, err := _request_once(c, &cur, allocator)
		if err != .None do return res, err

		// Negative max_redirects → never follow; 0 remaining budget → stop.
		if c.max_redirects < 0 || hops >= c.max_redirects {
			return res, .None
		}
		if !_is_redirect_status(res.status) {
			return res, .None
		}

		loc, has_loc := _headers_get_ci(res.headers[:], "location")
		if !has_loc || len(loc) == 0 {
			return res, .None
		}

		next, rok := _resolve_redirect_target(cur.target, loc)
		if !rok {
			response_destroy(&res, allocator)
			return {}, .Invalid_Url
		}

		method, drop_body := _redirect_method_and_body(res.status, cur.method)
		response_destroy(&res, allocator)

		cur.method = method
		if drop_body {
			cur.body = nil
			cur.headers = _headers_without_body_metadata(cur.headers[:], context.temp_allocator)
		}
		cur.target = next

		// Same origin + healthy transport → reuse; otherwise re-dial.
		need_redial := !_same_origin(c.target, next)
		if !need_redial {
			#partial switch c.version {
			case .Http1, .Auto:
				if !c.h1_alive do need_redial = true
			}
			// Update path (and full target) for Host/:authority on reuse.
			c.target = next
			c.target.version = c.prefer_version
			c.target.dial_timeout_ms = _resolve_dial_timeout_ms(c.timeout_ms)
		}
		if need_redial {
			if e := _conn_redial(c, next); e != .None {
				return {}, e
			}
		}

		hops += 1
	}
}

// One exchange, no redirect following.
@(private)
_request_once :: proc(c: ^Connection, req: ^Request, allocator: mem.Allocator) -> (Response, Http_Error) {
	res: Response
	err: Http_Error
	switch p in c.transport {
	case io.Stream:
		switch c.version {
		case .Http1, .Auto:
			res, err = _h1_do(c, p, req, allocator)
		case .Http2:
			res, err = _h2_do(c, p, req, allocator)
		case .Http3:
			return {}, .Unsupported_Version
		}
	case ^Http3_State:
		res, err = _h3_do(p, req, allocator, c.timeout_ms, c.max_response_body)
	case:
		return {}, .Unsupported_Version
	}
	if err == .None {
		_learn_alt_svc(c, &res)
		if c.accept_gzip {
			if gerr := _maybe_gunzip_response(&res, allocator); gerr != .None {
				response_destroy(&res, allocator)
				return {}, gerr
			}
		}
	}
	return res, err
}

@(private)
_learn_alt_svc :: proc(c: ^Connection, res: ^Response) {
	if c.alt_svc == nil do return
	scheme := c.target.scheme
	if len(scheme) == 0 do scheme = "https"
	alt_svc_learn_from_headers(
		c.alt_svc, scheme, c.target.host, c.target.port, res.headers[:], c.allocator,
	)
}

close :: proc(c: ^Connection) {
	if c == nil do return
	if c.h2_started do http2.conn_destroy(&c.h2)
	if c.hop.owns_stream || c.hop.owns_fd || c.hop.owns_quic {
		hop_close(&c.hop)
		c.transport = {}
	} else {
		switch p in c.transport {
		case io.Stream:     io.close(p)
		case ^Http3_State:  _h3_close(p)
		}
		c.transport = {}
		c.hop = {}
		c.hop.fd = -1
	}
	delete(c.h1_rx)
	free(c, c.allocator)
}

response_destroy :: proc(r: ^Response, allocator := context.allocator) {
	for h in r.headers {
		delete(h.name, allocator)
		delete(h.value, allocator)
	}
	delete(r.headers)
	delete(r.body)
}

// ---- HTTP/1.1 driver (keep-alive over ANY io.Stream) -----------------------

@(private)
_h1_do :: proc(
	c: ^Connection, stream: io.Stream, req: ^Request, allocator: mem.Allocator,
) -> (Response, Http_Error) {
	if !c.h1_alive do return {}, .Closed

	deadline := _request_deadline(c.timeout_ms)
	_try_set_stream_sock_timeout(stream, _resolve_request_timeout(c.timeout_ms))

	b: strings.Builder
	strings.builder_init(&b, context.temp_allocator)

	fmt.sbprintf(&b, "%s %s HTTP/1.1\r\n", req.method, req.target.path)
	fmt.sbprintf(&b, "host: %s\r\n", format_authority(req.target.scheme, req.target.host, req.target.port))
	if c.h1_keep_alive {
		strings.write_string(&b, "connection: keep-alive\r\n")
	} else {
		strings.write_string(&b, "connection: close\r\n")
	}
	if !_headers_has_ci(req.headers[:], "user-agent") {
		fmt.sbprintf(&b, "user-agent: %s\r\n", DEFAULT_USER_AGENT)
	}
	if c.accept_gzip && !_headers_has_ci(req.headers[:], "accept-encoding") {
		strings.write_string(&b, "accept-encoding: gzip\r\n")
	}
	for h in req.headers {
		fmt.sbprintf(&b, "%s: %s\r\n", h.name, h.value)
	}
	if len(req.body) > 0 {
		fmt.sbprintf(&b, "content-length: %d\r\n", len(req.body))
	}
	strings.write_string(&b, "\r\n")

	w := io.to_writer(stream)
	if _, e := io.write_string(w, strings.to_string(b)); e != .None {
		c.h1_alive = false
		return {}, .Closed
	}
	if len(req.body) > 0 {
		if _, e := io.write(w, req.body); e != .None {
			c.h1_alive = false
			return {}, .Closed
		}
	}

	return _h1_read_response(c, stream, allocator, deadline)
}

// Read one framed response into `c.h1_rx`, leave any pipelined remainder.
@(private)
_h1_read_response :: proc(
	c: ^Connection, stream: io.Stream, allocator: mem.Allocator, deadline: time.Time,
) -> (Response, Http_Error) {
	r := io.to_reader(stream)
	tmp: [4096]u8
	max_body := c.max_response_body

	// Need headers first.
	for {
		if _deadline_exceeded(deadline) {
			c.h1_alive = false
			return {}, .Timeout
		}
		if sep := _find_header_end(c.h1_rx[:]); sep >= 0 do break
		n, e := io.read(r, tmp[:])
		if n > 0 do append(&c.h1_rx, ..tmp[:n])
		if e != .None {
			if len(c.h1_rx) == 0 || _find_header_end(c.h1_rx[:]) < 0 {
				c.h1_alive = false
				return {}, .Closed if e == .EOF else .Protocol
			}
			break
		}
		if len(c.h1_rx) > 1024 * 1024 {
			c.h1_alive = false
			return {}, .Protocol
		}
	}

	sep := _find_header_end(c.h1_rx[:])
	if sep < 0 {
		c.h1_alive = false
		return {}, .Protocol
	}

	head := string(c.h1_rx[:sep])
	body_start := sep + 4

	// Parse status + headers.
	res: Response
	res.version = .Http1
	res.body.allocator = allocator
	res.headers.allocator = allocator

	lines := strings.split(head, "\r\n", context.temp_allocator)
	if len(lines) == 0 {
		c.h1_alive = false
		return {}, .Protocol
	}
	sp := strings.index_byte(lines[0], ' ')
	if sp < 0 {
		c.h1_alive = false
		return {}, .Protocol
	}
	rest := lines[0][sp + 1:]
	code_end := strings.index_byte(rest, ' ')
	code_str := rest if code_end < 0 else rest[:code_end]
	code, cok := strconv.parse_int(code_str)
	if !cok {
		c.h1_alive = false
		return {}, .Protocol
	}
	res.status = Status(code)

	content_length := -1 // -1 = not set; -2 = chunked
	peer_close := false
	for line in lines[1:] {
		ci := strings.index_byte(line, ':')
		if ci < 0 do continue
		name := strings.trim_space(line[:ci])
		val := strings.trim_space(line[ci + 1:])
		append(&res.headers, Header{name = strings.clone(name, allocator), value = strings.clone(val, allocator), name_owned = true, value_owned = true})
		nl := strings.to_lower(name, context.temp_allocator)
		vl := strings.to_lower(val, context.temp_allocator)
		if nl == "content-length" {
			if n, ok := strconv.parse_int(val); ok do content_length = n
		} else if nl == "transfer-encoding" && strings.contains(vl, "chunked") {
			content_length = -2
		} else if nl == "connection" && strings.contains(vl, "close") {
			peer_close = true
		}
	}

	// Body framing.
	switch content_length {
	case -2:
		// Chunked: need full chunk stream ending in 0\r\n\r\n
		n_consumed, cerr := _h1_decode_chunked(c, stream, body_start, &res.body, deadline, max_body)
		if cerr != .None {
			response_destroy(&res, allocator)
			c.h1_alive = false
			return {}, cerr
		}
		_h1_consume(c, n_consumed)
	case -1:
		// No CL and not chunked: read until EOF (connection closes).
		for {
			if _deadline_exceeded(deadline) {
				response_destroy(&res, allocator)
				c.h1_alive = false
				return {}, .Timeout
			}
			n, e := io.read(r, tmp[:])
			if n > 0 do append(&c.h1_rx, ..tmp[:n])
			if body_start < len(c.h1_rx) && len(c.h1_rx) - body_start > max_body {
				response_destroy(&res, allocator)
				c.h1_alive = false
				return {}, .Body_Too_Large
			}
			if e != .None do break
		}
		if body_start < len(c.h1_rx) {
			append(&res.body, ..c.h1_rx[body_start:])
		}
		if len(res.body) > max_body {
			response_destroy(&res, allocator)
			c.h1_alive = false
			return {}, .Body_Too_Large
		}
		clear(&c.h1_rx)
		c.h1_alive = false
	case:
		if content_length > max_body {
			response_destroy(&res, allocator)
			c.h1_alive = false
			return {}, .Body_Too_Large
		}
		need := body_start + content_length
		for len(c.h1_rx) < need {
			if _deadline_exceeded(deadline) {
				response_destroy(&res, allocator)
				c.h1_alive = false
				return {}, .Timeout
			}
			n, e := io.read(r, tmp[:])
			if n > 0 do append(&c.h1_rx, ..tmp[:n])
			if e != .None {
				if len(c.h1_rx) < need {
					response_destroy(&res, allocator)
					c.h1_alive = false
					return {}, .Closed
				}
				break
			}
		}
		append(&res.body, ..c.h1_rx[body_start:need])
		_h1_consume(c, need)
	}

	if peer_close || !c.h1_keep_alive {
		c.h1_alive = false
	}
	return res, .None
}

@(private)
_find_header_end :: proc(buf: []u8) -> int {
	s := string(buf)
	return strings.index(s, "\r\n\r\n")
}

@(private)
_h1_consume :: proc(c: ^Connection, n: int) {
	if n <= 0 do return
	if n >= len(c.h1_rx) {
		clear(&c.h1_rx)
		return
	}
	copy(c.h1_rx[:], c.h1_rx[n:])
	resize(&c.h1_rx, len(c.h1_rx) - n)
}

// Decode chunked body starting at body_start in c.h1_rx; may read more from stream.
// Appends decoded bytes to `out`. Returns bytes consumed from start of h1_rx.
@(private)
_h1_decode_chunked :: proc(
	c: ^Connection, stream: io.Stream, body_start: int, out: ^[dynamic]u8,
	deadline: time.Time, max_body: int,
) -> (consumed: int, err: Http_Error) {
	r := io.to_reader(stream)
	tmp: [4096]u8
	pos := body_start

	for {
		if _deadline_exceeded(deadline) do return 0, .Timeout
		// Ensure we can see a chunk-size line.
		for {
			if _deadline_exceeded(deadline) do return 0, .Timeout
			line_end := _find_crlf(c.h1_rx[pos:])
			if line_end >= 0 do break
			n, e := io.read(r, tmp[:])
			if n > 0 do append(&c.h1_rx, ..tmp[:n])
			if e != .None do return 0, .Protocol
		}
		line_end := _find_crlf(c.h1_rx[pos:])
		if line_end < 0 do return 0, .Protocol
		size_line := string(c.h1_rx[pos:pos + line_end])
		// Ignore chunk extensions.
		if semi := strings.index_byte(size_line, ';'); semi >= 0 {
			size_line = size_line[:semi]
		}
		size_line = strings.trim_space(size_line)
		sz, sok := strconv.parse_int(size_line, 16)
		if !sok || sz < 0 do return 0, .Protocol
		pos += line_end + 2
		if sz == 0 {
			// Trailer section ends with CRLF (possibly empty trailers).
			for {
				if _deadline_exceeded(deadline) do return 0, .Timeout
				if te := _find_crlf(c.h1_rx[pos:]); te >= 0 {
					if te == 0 {
						pos += 2
						return pos, .None
					}
					pos += te + 2
					continue
				}
				n, e := io.read(r, tmp[:])
				if n > 0 do append(&c.h1_rx, ..tmp[:n])
				if e != .None {
					return pos, .None // tolerate EOF after last chunk
				}
			}
		}
		if len(out) + sz > max_body do return 0, .Body_Too_Large
		need := pos + sz + 2
		for len(c.h1_rx) < need {
			if _deadline_exceeded(deadline) do return 0, .Timeout
			n, e := io.read(r, tmp[:])
			if n > 0 do append(&c.h1_rx, ..tmp[:n])
			if e != .None && len(c.h1_rx) < need do return 0, .Protocol
		}
		append(out, ..c.h1_rx[pos:pos + sz])
		pos += sz + 2
	}
}

@(private)
_find_crlf :: proc(buf: []u8) -> int {
	s := string(buf)
	return strings.index(s, "\r\n")
}

// ---- HTTP/2 driver (persistent sans-IO mux over ANY io.Stream) --------------

@(private)
_h2_do :: proc(c: ^Connection, stream: io.Stream, req: ^Request, allocator: mem.Allocator) -> (Response, Http_Error) {
	h2 := &c.h2
	deadline := _request_deadline(c.timeout_ms)
	_try_set_stream_sock_timeout(stream, _resolve_request_timeout(c.timeout_ms))
	max_body := c.max_response_body

	out: [dynamic]u8
	out.allocator = context.temp_allocator
	if !c.h2_started {
		// Once per CONNECTION: preface + SETTINGS. Subsequent requests
		// multiplex on stream ids 1, 3, 5, ...
		http2.conn_init(h2, false)
		c.h2_started = true
		http2.conn_send_preface(h2, &out)
	}

	hdrs: [dynamic]Header
	hdrs.allocator = context.temp_allocator
	scheme := req.target.scheme if len(req.target.scheme) > 0 else "https"
	append(&hdrs, Header{name = ":method", value = req.method})
	append(&hdrs, Header{name = ":scheme", value = scheme})
	append(&hdrs, Header{name = ":authority", value = format_authority(req.target.scheme, req.target.host, req.target.port)})
	append(&hdrs, Header{name = ":path", value = req.target.path})
	if !_headers_has_ci(req.headers[:], "user-agent") {
		append(&hdrs, Header{name = "user-agent", value = DEFAULT_USER_AGENT})
	}
	if c.accept_gzip && !_headers_has_ci(req.headers[:], "accept-encoding") {
		append(&hdrs, Header{name = "accept-encoding", value = "gzip"})
	}
	for h in req.headers do append(&hdrs, Header{name = h.name, value = h.value})

	sid := http2.conn_send_request(h2, &out, hdrs[:], req.body)

	w := io.to_writer(stream)
	if _, e := io.write(w, out[:]); e != .None do return {}, .Closed

	r := io.to_reader(stream)
	tmp: [4096]u8
	for {
		if _deadline_exceeded(deadline) do return {}, .Timeout
		n, e := io.read(r, tmp[:])
		if n > 0 {
			reply: [dynamic]u8
			reply.allocator = context.temp_allocator
			if http2.conn_feed(h2, tmp[:n], &reply) != .None do return {}, .Protocol
			// Response first: if this chunk completed it, we're done — don't
			// fail on the reply write (ACKs/WINDOW_UPDATEs) when the server
			// answered-and-closed in one breath.
			if rh2, rb, done := http2.conn_response(h2, sid); done {
				rh := rh2
				if len(reply) > 0 do io.write(w, reply[:]) // best-effort
				if len(rb) > max_body do return {}, .Body_Too_Large
				return _headers_to_response(rh, rb, .Http2, allocator), .None
			}
			// Mid-stream body growth: reject early when the stream buffer exceeds max.
			if s, ok := h2.streams[sid]; ok && len(s.body) > max_body {
				return {}, .Body_Too_Large
			}
			if len(reply) > 0 {
				if _, we := io.write(w, reply[:]); we != .None do return {}, .Closed
			}
		}
		if rh2, rb, done := http2.conn_response(h2, sid); done {
			rh := rh2
			if len(rb) > max_body do return {}, .Body_Too_Large
			return _headers_to_response(rh, rb, .Http2, allocator), .None
		}
		if _, failed := http2.conn_stream_failed(h2, sid); failed {
			return {}, .Closed // peer reset the stream or GOAWAY'd past it
		}
		if e != .None do break
	}
	return {}, .Protocol
}

// Map a (Header list, body) — shared by h2/h3 — into a Response, pulling
// :status out of the pseudo-headers.
@(private)
_headers_to_response :: proc(
	headers: []Header, body: []u8, version: ProtocolVersion, allocator: mem.Allocator,
) -> Response {
	context.allocator = allocator

	res: Response
	res.version = version
	for h in headers {
		if h.name == ":status" {
			code, _ := strconv.parse_int(h.value)
			res.status = Status(code)
		} else {
			append(&res.headers, Header{name = strings.clone(h.name, allocator), value = strings.clone(h.value, allocator), name_owned = true, value_owned = true})
		}
	}
	append(&res.body, ..body)
	return res
}

// ---- Default headers / redirects / timeouts --------------------------------

@(private)
_resolve_max_redirects :: proc(opt: int) -> int {
	// 0 → package default; negative → never follow (-1); positive → that many hops.
	if opt == 0 do return DEFAULT_MAX_REDIRECTS
	if opt < 0 do return -1
	return opt
}

// Host / :authority for request headers (RFC 9110 / 3986).
// - default ports omitted (http:80, https:443; also ws/wss)
// - non-default ports included as host:port
// - IPv6 literals bracketed when not already (`[::1]:8080`)
// Uses context.temp_allocator for any formatted result.
format_authority :: proc(scheme, host: string, port: int) -> string {
	host_part := _host_for_authority(host)
	if _is_default_port(scheme, port) {
		return host_part
	}
	return fmt.tprintf("%s:%d", host_part, port)
}

// Dial endpoint always includes an explicit port (QUIC/TCP connect strings).
// IPv6 hosts are bracketed: `[::1]:443`.
format_dial_endpoint :: proc(host: string, port: int) -> string {
	p := port
	if p == 0 do p = 443
	return fmt.tprintf("%s:%d", _host_for_authority(host), p)
}

@(private)
_host_for_authority :: proc(host: string) -> string {
	if len(host) == 0 do return host
	if host[0] == '[' do return host // already bracketed
	// Unbracketed IPv6 contains ':' (hostnames / IPv4 do not in the host field).
	if strings.contains(host, ":") {
		return fmt.tprintf("[%s]", host)
	}
	return host
}

@(private)
_is_default_port :: proc(scheme: string, port: int) -> bool {
	if port == 0 do return true
	switch scheme {
	case "https", "wss":
		return port == 443
	case "http", "ws":
		return port == 80
	case "":
		// No scheme: treat classic defaults as omitable.
		return port == 80 || port == 443
	}
	return false
}

@(private)
_resolve_accept_gzip :: proc(v: Maybe(bool)) -> bool {
	if b, ok := v.?; ok do return b
	return true // toolkit default
}

// Gunzip a fully-buffered body when Content-Encoding is gzip (not identity).
// Corrupt streams → Protocol. Other encodings left untouched.
@(private)
_maybe_gunzip_response :: proc(res: ^Response, allocator: mem.Allocator) -> Http_Error {
	enc, ok := _headers_get_ci(res.headers[:], "content-encoding")
	if !ok do return .None

	// First coding token (ignore subsequent list members / q-values).
	first := strings.trim_space(enc)
	if i := strings.index_byte(first, ','); i >= 0 {
		first = strings.trim_space(first[:i])
	}
	if i := strings.index_byte(first, ';'); i >= 0 {
		first = strings.trim_space(first[:i])
	}
	fl := strings.to_lower(first, context.temp_allocator)
	if fl == "" || fl == "identity" do return .None
	if fl != "gzip" && fl != "x-gzip" do return .None

	buf: bytes.Buffer
	if gzip.load(res.body[:], &buf) != nil {
		bytes.buffer_destroy(&buf)
		return .Protocol
	}
	plain := bytes.buffer_to_bytes(&buf)

	delete(res.body)
	res.body = make([dynamic]u8, len(plain), allocator)
	copy(res.body[:], plain)
	bytes.buffer_destroy(&buf)

	// Length/encoding no longer describe the decoded body.
	_headers_remove_ci(&res.headers, "content-encoding", allocator)
	_headers_remove_ci(&res.headers, "content-length", allocator)
	return .None
}

@(private)
_headers_remove_ci :: proc(headers: ^OrderedHeaders, name: string, allocator: mem.Allocator) {
	dst := 0
	for i in 0 ..< len(headers) {
		if strings.equal_fold(headers[i].name, name) {
			delete(headers[i].name, allocator)
			delete(headers[i].value, allocator)
			continue
		}
		if dst != i do headers[dst] = headers[i]
		dst += 1
	}
	resize(headers, dst)
}

@(private)
_headers_has_ci :: proc(headers: []Header, name: string) -> bool {
	_, ok := _headers_get_ci(headers, name)
	return ok
}

@(private)
_headers_get_ci :: proc(headers: []Header, name: string) -> (string, bool) {
	for h in headers {
		if strings.equal_fold(h.name, name) do return h.value, true
	}
	return "", false
}

// Drop body-describing headers when a redirect converts the method to GET.
@(private)
_headers_without_body_metadata :: proc(
	headers: []Header, allocator: mem.Allocator,
) -> OrderedHeaders {
	out: OrderedHeaders
	out.allocator = allocator
	for h in headers {
		nl := strings.to_lower(h.name, context.temp_allocator)
		switch nl {
		case "content-length", "content-type", "content-encoding", "transfer-encoding":
			continue
		}
		append(&out, h)
	}
	return out
}

@(private)
_is_redirect_status :: proc(s: Status) -> bool {
	#partial switch s {
	case .Moved_Permanently, .Found, .See_Other, .Temporary_Redirect, .Permanent_Redirect:
		return true
	}
	return false
}

// 303 → GET + drop body. 301/302 with POST (or other non-GET/HEAD) → GET + drop
// body (curl/browser-ish; matches Go CheckRedirect spirit). 307/308 keep method+body.
@(private)
_redirect_method_and_body :: proc(status: Status, method: string) -> (string, bool) {
	upper := strings.to_upper(method, context.temp_allocator)
	#partial switch status {
	case .See_Other: // 303
		return "GET", true
	case .Moved_Permanently, .Found: // 301, 302
		if upper == "GET" || upper == "HEAD" {
			return upper, false
		}
		return "GET", true
	case .Temporary_Redirect, .Permanent_Redirect: // 307, 308
		return method, false
	}
	return method, false
}

@(private)
_same_origin :: proc(a, b: Target) -> bool {
	as := a.scheme if len(a.scheme) > 0 else "http"
	bs := b.scheme if len(b.scheme) > 0 else "http"
	ap := a.port if a.port != 0 else (443 if as == "https" else 80)
	bp := b.port if b.port != 0 else (443 if bs == "https" else 80)
	return as == bs && a.host == b.host && ap == bp
}

// Resolve Location against the previous request target (absolute, scheme-relative,
// absolute-path, or relative path).
@(private)
_resolve_redirect_target :: proc(base: Target, location: string) -> (Target, bool) {
	loc := strings.trim_space(location)
	if len(loc) == 0 do return {}, false

	// Absolute URI.
	if strings.contains(loc, "://") {
		return parse_target(loc)
	}
	// Scheme-relative: //host/path
	if strings.has_prefix(loc, "//") {
		return parse_target(fmt.tprintf("%s:%s", base.scheme if len(base.scheme) > 0 else "http", loc))
	}

	t := base
	if strings.has_prefix(loc, "/") {
		// Absolute-path reference (may include ?query).
		t.path = loc
		return t, true
	}

	// Relative path: resolve against the directory of the current path.
	dir := base.path
	if len(dir) == 0 do dir = "/"
	if i := strings.last_index_byte(dir, '/'); i >= 0 {
		dir = dir[:i + 1]
	} else {
		dir = "/"
	}
	t.path = strings.concatenate({dir, loc}, context.temp_allocator)
	return t, true
}

// ---- Timeouts / body limits ------------------------------------------------

@(private)
_resolve_dial_timeout_ms :: proc(timeout_ms: int) -> int {
	if timeout_ms > 0 do return timeout_ms
	return DEFAULT_DIAL_TIMEOUT_MS
}

@(private)
_resolve_request_timeout_ms :: proc(timeout_ms: int) -> int {
	if timeout_ms > 0 do return timeout_ms
	return DEFAULT_REQUEST_TIMEOUT_MS
}

@(private)
_resolve_request_timeout :: proc(timeout_ms: int) -> time.Duration {
	return time.Duration(_resolve_request_timeout_ms(timeout_ms)) * time.Millisecond
}

@(private)
_resolve_max_body :: proc(max: int) -> int {
	if max > 0 do return max
	return DEFAULT_MAX_RESPONSE_BODY
}

@(private)
_request_deadline :: proc(timeout_ms: int) -> time.Time {
	return time.time_add(time.now(), _resolve_request_timeout(timeout_ms))
}

@(private)
_deadline_exceeded :: proc(deadline: time.Time) -> bool {
	return time.diff(time.now(), deadline) <= 0
}

// Best-effort: set SO_RCVTIMEO/SNDTIMEO when the stream is our TCP or TLS wrapper.
// Custom Dialers / mock streams have no accessible fd — wall-clock checks cover them.
@(private)
_try_set_stream_sock_timeout :: proc(stream: io.Stream, timeout: time.Duration) {
	if timeout <= 0 do return
	if stream.procedure == _tcp_stream_proc {
		sock := net.TCP_Socket(uintptr(stream.data))
		_ = net.set_option(sock, .Receive_Timeout, timeout)
		_ = net.set_option(sock, .Send_Timeout, timeout)
		return
	}
	if stream.procedure == _tls_stream_proc {
		st := (^Tls_State)(stream.data)
		_ = net.set_option(st.sock, .Receive_Timeout, timeout)
		_ = net.set_option(st.sock, .Send_Timeout, timeout)
	}
}

// Apply dial/request socket timeouts to a raw TCP socket (tls/tcp dialers).
@(private)
_set_sock_timeouts :: proc(sock: net.TCP_Socket, timeout: time.Duration) {
	if timeout <= 0 do return
	_ = net.set_option(sock, .Receive_Timeout, timeout)
	_ = net.set_option(sock, .Send_Timeout, timeout)
}

// ---- Built-in TCP dialer + transport adapters ------------------------------

// The default Dial_Proc for http targets: plaintext TCP, exposed as an
// io.Stream. (https defaults to tls_dialer — see tls.odin.)
@(private)
_tcp_dial :: proc(
	data: rawptr, target: Target, allocator: mem.Allocator,
) -> (io.Stream, ProtocolVersion, Http_Error) {
	ep4, ep6, rerr := net.resolve(target.host)
	if rerr != nil do return {}, .Http1, .Resolve_Failed
	ep := ep4 if ep4.address != nil else ep6
	ep.port = target.port

	sock, derr := net.dial_tcp(ep)
	if derr != nil do return {}, .Http1, .Connect_Failed
	// Best-effort I/O deadlines (connect itself is OS-bounded; see tls for handshake).
	dial_to := time.Duration(_resolve_dial_timeout_ms(target.dial_timeout_ms)) * time.Millisecond
	_set_sock_timeouts(sock, dial_to)
	return tcp_stream(sock), .Http1, .None
}

// Wrap a TCP socket as a duplex io.Stream.
tcp_stream :: proc(sock: net.TCP_Socket) -> io.Stream {
	return io.Stream{data = rawptr(uintptr(sock)), procedure = _tcp_stream_proc}
}

@(private)
_tcp_stream_proc :: proc(
	stream_data: rawptr, mode: io.Stream_Mode, p: []byte, offset: i64, whence: io.Seek_From,
) -> (n: i64, err: io.Error) {
	sock := net.TCP_Socket(uintptr(stream_data))
	#partial switch mode {
	case .Query:
		return io.query_utility(io.Stream_Mode_Set{.Query, .Read, .Write, .Close})
	case .Read:
		got, rerr := net.recv_tcp(sock, p)
		if rerr != nil do return i64(got), .Unexpected_EOF
		if got == 0 do return 0, .EOF
		return i64(got), .None
	case .Write:
		sent, serr := net.send_tcp(sock, p)
		if serr != nil do return i64(sent), .Short_Write
		return i64(sent), .None
	case .Close:
		net.close(sock)
		return 0, .None
	}
	return 0, .Empty
}

// Parse scheme://host[:port]/path into a Target.
// Host is stored unbracketed (IPv6 as `::1`); use format_authority for Host/:authority.
// Bracketed IPv6 (`[::1]`, `[::1]:8080`) is required for IPv6 literals (RFC 3986).
@(private)
parse_target :: proc(url: string) -> (t: Target, ok: bool) {
	s := url
	if i := strings.index(s, "://"); i >= 0 {
		t.scheme = s[:i]
		s = s[i + 3:]
	} else {
		t.scheme = "http"
	}
	if i := strings.index_byte(s, '/'); i >= 0 {
		t.path = s[i:]
		s = s[:i]
	} else {
		t.path = "/"
	}

	default_port := 443 if t.scheme == "https" || t.scheme == "wss" else 80

	// Bracketed IPv6: [host] or [host]:port
	if len(s) > 0 && s[0] == '[' {
		end := strings.index_byte(s, ']')
		if end < 0 do return t, false
		t.host = s[1:end]
		rest := s[end + 1:]
		if len(rest) == 0 {
			t.port = default_port
			return t, true
		}
		if rest[0] != ':' do return t, false
		p, pok := strconv.parse_int(rest[1:])
		if !pok do return t, false
		t.port = p
		return t, true
	}

	// host:port — only one colon allowed in the host field (IPv6 must be bracketed).
	if i := strings.index_byte(s, ':'); i >= 0 {
		if strings.contains(s[i + 1:], ":") {
			// Multiple colons without brackets → not a valid authority for us.
			return t, false
		}
		t.host = s[:i]
		p, pok := strconv.parse_int(s[i + 1:])
		if !pok do return t, false
		t.port = p
	} else {
		t.host = s
		t.port = default_port
	}
	return t, true
}
