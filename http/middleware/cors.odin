package middleware

// CORS middleware (browser cross-origin). Handles OPTIONS preflight short-circuit.

import http ".."
import "base:runtime"
import "core:fmt"
import "core:strings"

Cors_Opts :: struct {
	// Allowed origins (exact match). Ignored when allow_any_origin is true.
	allow_origins: []string,
	// Access-Control-Allow-Origin: * (incompatible with allow_credentials).
	allow_any_origin: bool,
	// Empty → default method list.
	allow_methods: string,
	// Empty → default header list.
	allow_headers: string,
	expose_headers: string,
	// Access-Control-Max-Age seconds; 0 → omit.
	max_age_secs: int,
	// Access-Control-Allow-Credentials: true. Incompatible with allow_any_origin.
	allow_credentials: bool,
}

// Sensible public-API defaults (any origin, no credentials).
Cors_Default :: Cors_Opts {
	allow_any_origin = true,
	allow_methods    = "GET, HEAD, POST, PUT, PATCH, DELETE, OPTIONS",
	allow_headers    = "Accept, Content-Type, Authorization, X-Request-Id",
	max_age_secs     = 600,
}

@(private)
Cors_State :: struct {
	opts: Cors_Opts,
	next: ^http.Handler,
}

cors :: proc(opts: Cors_Opts, next: ^http.Handler, allocator := context.allocator) -> http.Handler {
	assert(next != nil)
	if opts.allow_credentials {
		assert(!opts.allow_any_origin, "CORS: allow_credentials incompatible with allow_any_origin")
	}
	st := new(Cors_State, allocator)
	st.opts = opts
	// Deep-own allow_origins so stack/temp caller slices cannot dangle.
	if len(opts.allow_origins) > 0 {
		owned := make([]string, len(opts.allow_origins), allocator)
		for o, i in opts.allow_origins {
			owned[i] = strings.clone(o, allocator)
		}
		st.opts.allow_origins = owned
	} else {
		st.opts.allow_origins = nil
	}
	// Clone non-empty option strings that may be non-static.
	if opts.allow_methods != "" {
		st.opts.allow_methods = strings.clone(opts.allow_methods, allocator)
	}
	if opts.allow_headers != "" {
		st.opts.allow_headers = strings.clone(opts.allow_headers, allocator)
	}
	if opts.expose_headers != "" {
		st.opts.expose_headers = strings.clone(opts.expose_headers, allocator)
	}
	st.next = next
	h: http.Handler
	h.user_data = st
	h.next = next
	h.handle = _cors_handle
	return h
}

// Free deep-owned cors opts (call if not using Chain destroy for this handler).
cors_destroy :: proc(h: ^http.Handler, allocator := context.allocator) {
	if h == nil || h.user_data == nil {
		return
	}
	st := (^Cors_State)(h.user_data)
	for o in st.opts.allow_origins {
		delete(o, allocator)
	}
	delete(st.opts.allow_origins, allocator)
	// Non-empty method/header/expose strings were strings.clone'd in cors().
	if st.opts.allow_methods != "" {
		delete(st.opts.allow_methods, allocator)
	}
	if st.opts.allow_headers != "" {
		delete(st.opts.allow_headers, allocator)
	}
	if st.opts.expose_headers != "" {
		delete(st.opts.expose_headers, allocator)
	}
	free(st, allocator)
	h.user_data = nil
}

// Deep-clones origins and string fields at layer creation so stack slices need not
// outlive chain_use (cors() also clones into Cors_State for the handler lifetime).
cors_layer :: proc(opts: Cors_Opts, allocator := context.allocator) -> Layer {
	p := new(Cors_Opts, allocator)
	p^ = opts
	if len(opts.allow_origins) > 0 {
		owned := make([]string, len(opts.allow_origins), allocator)
		for o, i in opts.allow_origins {
			owned[i] = strings.clone(o, allocator)
		}
		p.allow_origins = owned
	}
	if opts.allow_methods != "" {
		p.allow_methods = strings.clone(opts.allow_methods, allocator)
	}
	if opts.allow_headers != "" {
		p.allow_headers = strings.clone(opts.allow_headers, allocator)
	}
	if opts.expose_headers != "" {
		p.expose_headers = strings.clone(opts.expose_headers, allocator)
	}
	return Layer {
		data = p,
		build = _cors_layer_build,
		free_data = cors_layer_data_destroy,
		free_built = _cors_free_built,
	}
}

// free_built for Match_Table / Builder destroy — deep free Cors_State on wrap Handler.
@(private)
_cors_free_built :: proc(h: ^http.Handler, allocator: runtime.Allocator) {
	cors_destroy(h, allocator)
}

@(private)
_cors_layer_build :: proc(data: rawptr, next: ^http.Handler, allocator: runtime.Allocator) -> http.Handler {
	// cors() deep-clones again into Cors_State; layer shell freed in chain_destroy.
	return cors((^Cors_Opts)(data)^, next, allocator)
}

// Free a cors_layer data blob (origins + strings). chain_destroy only free()s the shell —
// call this before free if destroying a layer outside Chain (Chain free is shallow on layer_data).
cors_layer_data_destroy :: proc(data: rawptr, allocator := context.allocator) {
	if data == nil {
		return
	}
	p := (^Cors_Opts)(data)
	for o in p.allow_origins {
		delete(o, allocator)
	}
	delete(p.allow_origins, allocator)
	if p.allow_methods != "" {
		delete(p.allow_methods, allocator)
	}
	if p.allow_headers != "" {
		delete(p.allow_headers, allocator)
	}
	if p.expose_headers != "" {
		delete(p.expose_headers, allocator)
	}
	free(p, allocator)
}

@(private)
_cors_handle :: proc(h: ^http.Handler, req: ^http.Request, res: ^http.Response) {
	st := (^Cors_State)(h.user_data)
	opts := &st.opts

	origin, has_origin := http.headers_get(req.headers, "origin")
	if !has_origin || origin == "" {
		call_next(st.next, req, res)
		return
	}

	allowed, allow_value := _cors_origin_allowed(opts, origin)
	if !allowed {
		if _cors_is_preflight(req) {
			res.status = .Forbidden
			http.respond(res)
			return
		}
		call_next(st.next, req, res)
		return
	}

	// allow_value is "*" or the request Origin string (lives in request headers / static).
	http.headers_set(&res.headers, "access-control-allow-origin", allow_value)
	if opts.allow_credentials {
		http.headers_set(&res.headers, "access-control-allow-credentials", "true")
	}
	if allow_value != "*" {
		_cors_append_vary(&res.headers, "Origin")
	}

	if _cors_is_preflight(req) {
		methods := opts.allow_methods if opts.allow_methods != "" else Cors_Default.allow_methods
		headers := opts.allow_headers if opts.allow_headers != "" else Cors_Default.allow_headers
		http.headers_set(&res.headers, "access-control-allow-methods", methods)
		http.headers_set(&res.headers, "access-control-allow-headers", headers)
		if opts.max_age_secs > 0 {
			age := fmt.tprintf("%d", opts.max_age_secs)
			http.headers_set(&res.headers, "access-control-max-age", age)
		}
		// Preflight cache safety: vary on the request fields that select the response.
		_cors_append_vary(&res.headers, "Origin")
		_cors_append_vary(&res.headers, "Access-Control-Request-Method")
		_cors_append_vary(&res.headers, "Access-Control-Request-Headers")
		res.status = .No_Content
		http.respond(res)
		return
	}

	if opts.expose_headers != "" {
		http.headers_set(&res.headers, "access-control-expose-headers", opts.expose_headers)
	}

	call_next(st.next, req, res)
}

@(private)
_cors_is_preflight :: proc(req: ^http.Request) -> bool {
	line, ok := req.line.?
	if !ok || line.method != .Options {
		return false
	}
	_, has := http.headers_get(req.headers, "access-control-request-method")
	return has
}

@(private)
_cors_origin_allowed :: proc(opts: ^Cors_Opts, origin: string) -> (ok: bool, value: string) {
	if opts.allow_any_origin {
		if opts.allow_credentials {
			return false, ""
		}
		return true, "*"
	}
	for o in opts.allow_origins {
		if o == origin {
			return true, origin
		}
	}
	return false, ""
}

@(private)
_cors_append_vary :: proc(h: ^http.Headers, token: string) {
	if v, ok := http.headers_get(h^, "vary"); ok {
		if _cors_vary_has_token(v, token) {
			return
		}
		joined := strings.concatenate({v, ", ", token}, context.temp_allocator)
		http.headers_set(h, "vary", joined)
		return
	}
	http.headers_set(h, "vary", token)
}

// Exact comma-separated token match (case-insensitive), not substring.
@(private)
_cors_vary_has_token :: proc(vary: string, token: string) -> bool {
	rest := vary
	for len(rest) > 0 {
		part: string
		if i := strings.index_byte(rest, ','); i >= 0 {
			part = strings.trim_space(rest[:i])
			rest = rest[i + 1:]
		} else {
			part = strings.trim_space(rest)
			rest = ""
		}
		if strings.equal_fold(part, token) {
			return true
		}
	}
	return false
}
