// Stock rate-limit layer (GCRA + bounded store). Engine lives in package http.
package middleware

import http ".."
import "base:runtime"

// Product path: multi-policy local rate limit. Zero opts → 100/s peer IP, 64k cap.
rate_limit_layer :: proc(opts: http.Rate_Limit_Opts, allocator := context.allocator) -> Layer {
	p := new(http.Rate_Limit_Opts, allocator)
	p^ = opts
	// Clone skip_paths / body / trusted so stack opts are safe after return.
	if len(opts.skip_paths) > 0 {
		p.skip_paths = make([]string, len(opts.skip_paths), allocator)
		for s, i in opts.skip_paths {
			// strings not imported — clone via http helpers? use raw clone
			p.skip_paths[i] = _clone_str(s, allocator)
		}
	}
	if opts.body != "" {
		p.body = _clone_str(opts.body, allocator)
	}
	if len(opts.client_ip.trusted) > 0 {
		p.client_ip.trusted = make([]http.Cidr, len(opts.client_ip.trusted), allocator)
		copy(p.client_ip.trusted, opts.client_ip.trusted)
	}
	if len(opts.policies) > 0 {
		p.policies = make([]http.Policy, len(opts.policies), allocator)
		copy(p.policies, opts.policies)
	}
	return Layer {
		data = p,
		build = _rate_limit_layer_build,
		free_data = _rate_limit_layer_free_data,
		free_built = _rate_limit_free_built,
	}
}

@(private)
_rate_limit_layer_build :: proc(data: rawptr, next: ^http.Handler, allocator: runtime.Allocator) -> http.Handler {
	opts := (^http.Rate_Limit_Opts)(data)
	return http.rate_limit(opts^, next, allocator)
}

@(private)
_rate_limit_free_built :: proc(h: ^http.Handler, allocator: runtime.Allocator) {
	http.rate_limit_destroy(h, allocator)
}

@(private)
_rate_limit_layer_free_data :: proc(data: rawptr, allocator: runtime.Allocator) {
	if data == nil {
		return
	}
	p := (^http.Rate_Limit_Opts)(data)
	for s in p.skip_paths {
		delete(s, allocator)
	}
	delete(p.skip_paths, allocator)
	if p.body != "" {
		delete(p.body, allocator)
	}
	delete(p.client_ip.trusted, allocator)
	delete(p.policies, allocator)
	free(p, allocator)
}

@(private)
_clone_str :: proc(s: string, allocator: runtime.Allocator) -> string {
	if s == "" {
		return ""
	}
	b := make([]u8, len(s), allocator)
	copy(b, transmute([]u8)s)
	return string(b)
}
