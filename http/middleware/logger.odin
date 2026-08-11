package middleware

// Access-log middleware: method, path, status, duration.
// Hot path: one request-arena Logger_Req + one on_respond registration.
// No logging work when disabled; line built only in the host-fired hook.

import http ".."
import "base:runtime"
import "core:fmt"
import "core:log"
import "core:time"

Logger_Opts :: struct {
	// When true, middleware is a no-op (still calls next).
	disabled: bool,
	// Log level for the access line. Zero → .Info.
	level:    log.Level,
	// When true, treat zero level as .Debug instead of defaulting to .Info.
	level_set: bool,
	// When true, skip logging successful (2xx) responses.
	skip_2xx: bool,
	// When true, skip logging 3xx.
	skip_3xx: bool,
	// Optional custom sink; nil → core:log at opts.level.
	// Called on the I/O worker during respond (must not block long).
	write:      proc(line: string, user: rawptr),
	write_user: rawptr,
}

@(private)
Logger_State :: struct {
	opts: Logger_Opts,
	next: ^http.Handler,
}

@(private)
Logger_Req :: struct {
	t0:   time.Tick,
	opts: ^Logger_Opts,
}

// Access log middleware. Registers on_respond; duration = enter → respond.
logger :: proc(opts: Logger_Opts, next: ^http.Handler, allocator := context.allocator) -> http.Handler {
	assert(next != nil)
	st := new(Logger_State, allocator)
	st.opts = opts
	if !st.opts.level_set && st.opts.level == .Debug {
		// Zero-value Level is Debug; default access logs to Info unless level_set.
		st.opts.level = .Info
	}
	st.next = next
	h: http.Handler
	h.user_data = st
	h.next = next
	h.handle = _logger_handle
	return h
}

// Layer for chain_use / chain_wrap. Clones opts into allocator (chain_use auto-tracks data).
logger_layer :: proc(opts: Logger_Opts, allocator := context.allocator) -> Layer {
	p := new(Logger_Opts, allocator)
	p^ = opts
	return Layer{data = p, build = _logger_layer_build}
}

@(private)
_logger_layer_build :: proc(data: rawptr, next: ^http.Handler, allocator: runtime.Allocator) -> http.Handler {
	opts := (^Logger_Opts)(data)
	return logger(opts^, next, allocator)
}

@(private)
_logger_handle :: proc(h: ^http.Handler, req: ^http.Request, res: ^http.Response) {
	st := (^Logger_State)(h.user_data)
	if st.opts.disabled {
		call_next(st.next, req, res)
		return
	}

	// Request arena: valid through on_respond and until clean_request_loop.
	lr := new(Logger_Req, context.temp_allocator)
	lr.t0 = time.tick_now()
	lr.opts = &st.opts
	http.response_on_respond(res, lr, _logger_on_respond)

	call_next(st.next, req, res)
}

@(private)
_logger_on_respond :: proc(req: ^http.Request, res: ^http.Response, user: rawptr) {
	lr := (^Logger_Req)(user)
	opts := lr.opts
	code := int(res.status)

	if opts.skip_2xx && code >= 200 && code < 300 {
		return
	}
	if opts.skip_3xx && code >= 300 && code < 400 {
		return
	}

	dur := time.tick_since(lr.t0)
	ms := f64(time.duration_nanoseconds(dur)) / 1_000_000.0

	method := "?"
	path := "/"
	if line, ok := req.line.?; ok {
		method = http.method_string(line.method)
		if req.url.path != "" {
			path = req.url.path
		} else if t, is_str := line.target.(string); is_str {
			path = t
		}
	}

	rid := ""
	if v, ok := http.headers_get(res.headers, "x-request-id"); ok {
		rid = v
	}

	line: string
	if rid != "" {
		line = fmt.tprintf("%s %s %d %.2fms rid=%s", method, path, code, ms, rid)
	} else {
		line = fmt.tprintf("%s %s %d %.2fms", method, path, code, ms)
	}

	if opts.write != nil {
		opts.write(line, opts.write_user)
		return
	}
	log.logf(opts.level, "%s", line)
}
