package middleware

// Baseline security headers (safe defaults, zero alloc on hot path — string literals).

import http ".."
import "base:runtime"
import "core:strings"

Security_Opts :: struct {
	// X-Content-Type-Options: nosniff (default on).
	disable_nosniff: bool,
	// X-Frame-Options. Empty → "DENY".
	frame_options:         string,
	disable_frame_options: bool,
	// Referrer-Policy. Empty → "strict-origin-when-cross-origin".
	referrer_policy:         string,
	disable_referrer_policy: bool,
	// Optional HSTS value e.g. "max-age=31536000; includeSubDomains". Empty → omit.
	hsts: string,
	// Optional Content-Security-Policy. Empty → omit.
	csp: string,
	// Set X-XSS-Protection: 0 (disable legacy auditor). Default on.
	disable_xss_protection_off: bool,
}

@(private)
Security_State :: struct {
	opts: Security_Opts,
	next: ^http.Handler,
}

security_headers :: proc(opts: Security_Opts, next: ^http.Handler, allocator := context.allocator) -> http.Handler {
	assert(next != nil)
	st := new(Security_State, allocator)
	st.opts = opts
	// Own non-literal strings for the handler lifetime.
	if opts.frame_options != "" {
		st.opts.frame_options = strings.clone(opts.frame_options, allocator)
	}
	if opts.referrer_policy != "" {
		st.opts.referrer_policy = strings.clone(opts.referrer_policy, allocator)
	}
	if opts.hsts != "" {
		st.opts.hsts = strings.clone(opts.hsts, allocator)
	}
	if opts.csp != "" {
		st.opts.csp = strings.clone(opts.csp, allocator)
	}
	st.next = next
	h: http.Handler
	h.user_data = st
	h.next = next
	h.handle = _security_handle
	return h
}

// Free owned security strings (Chain uses this via handle check when needed).
security_headers_destroy :: proc(h: ^http.Handler, allocator := context.allocator) {
	if h == nil || h.user_data == nil {
		return
	}
	st := (^Security_State)(h.user_data)
	if st.opts.frame_options != "" {
		delete(st.opts.frame_options, allocator)
	}
	if st.opts.referrer_policy != "" {
		delete(st.opts.referrer_policy, allocator)
	}
	if st.opts.hsts != "" {
		delete(st.opts.hsts, allocator)
	}
	if st.opts.csp != "" {
		delete(st.opts.csp, allocator)
	}
	free(st, allocator)
	h.user_data = nil
}

security_headers_layer :: proc(opts: Security_Opts, allocator := context.allocator) -> Layer {
	p := new(Security_Opts, allocator)
	p^ = opts
	return Layer{data = p, build = _security_layer_build}
}

@(private)
_security_layer_build :: proc(data: rawptr, next: ^http.Handler, allocator: runtime.Allocator) -> http.Handler {
	return security_headers((^Security_Opts)(data)^, next, allocator)
}

@(private)
_security_handle :: proc(h: ^http.Handler, req: ^http.Request, res: ^http.Response) {
	st := (^Security_State)(h.user_data)
	opts := st.opts
	_ = req

	if !opts.disable_nosniff {
		http.headers_set(&res.headers, "x-content-type-options", "nosniff")
	}
	if !opts.disable_frame_options {
		fo := opts.frame_options if opts.frame_options != "" else "DENY"
		http.headers_set(&res.headers, "x-frame-options", fo)
	}
	if !opts.disable_referrer_policy {
		rp := opts.referrer_policy if opts.referrer_policy != "" else "strict-origin-when-cross-origin"
		http.headers_set(&res.headers, "referrer-policy", rp)
	}
	if opts.hsts != "" {
		http.headers_set(&res.headers, "strict-transport-security", opts.hsts)
	}
	if opts.csp != "" {
		http.headers_set(&res.headers, "content-security-policy", opts.csp)
	}
	if !opts.disable_xss_protection_off {
		http.headers_set(&res.headers, "x-xss-protection", "0")
	}

	call_next(st.next, req, res)
}
