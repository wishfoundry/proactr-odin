package middleware

import http ".."
import "core:testing"

@(test)
test_chain_wrap_execute_order :: proc(t: ^testing.T) {
	test_chain_order = make([dynamic]int, 0, 8)
	defer {
		delete(test_chain_order)
		test_chain_order = nil
	}

	terminal: http.Handler
	terminal.handle = proc(h: ^http.Handler, req: ^http.Request, res: ^http.Response) {
		_ = h
		_ = req
		append(&test_chain_order, 0)
		res.status = .OK
	}

	c: Chain
	chain_init(&c, terminal)
	defer chain_destroy(&c)

	// Push outer first via successive use_fn: first use = inner wrap, second = outer.
	// use_fn(A) → A → terminal
	// use_fn(B) → B → A → terminal
	// order: B, A, terminal = 2, 1, 0
	chain_use_fn(&c, proc(req: ^http.Request, res: ^http.Response, next: ^http.Handler) {
		append(&test_chain_order, 1)
		call_next(next, req, res)
	})
	chain_use_fn(&c, proc(req: ^http.Request, res: ^http.Response, next: ^http.Handler) {
		append(&test_chain_order, 2)
		call_next(next, req, res)
	})

	testing.expect_value(t, len(c.nodes), 3)

	req: http.Request
	res: http.Response
	http.headers_init(&res.headers)
	root := chain_root_ptr(&c)
	root.handle(root, &req, &res)

	testing.expect_value(t, len(test_chain_order), 3)
	testing.expect_value(t, test_chain_order[0], 2)
	testing.expect_value(t, test_chain_order[1], 1)
	testing.expect_value(t, test_chain_order[2], 0)
	testing.expect_value(t, res.status, http.Status.OK)
}

@(private)
test_chain_order: [dynamic]int

@(test)
test_chain_three_stock_layers_no_recurse :: proc(t: ^testing.T) {
	hits: int
	terminal: http.Handler
	terminal.user_data = &hits
	terminal.handle = proc(h: ^http.Handler, req: ^http.Request, res: ^http.Response) {
		p := cast(^int)h.user_data
		p^ += 1
		_ = req
		res.status = .No_Content
	}

	c: Chain
	chain_init(&c, terminal)
	defer chain_destroy(&c)

	// Auto-track layer data inside chain_use
	chain_wrap(&c, {
		security_headers_layer({}),
		request_id_layer({}),
		logger_layer({disabled = true}),
	})

	testing.expect_value(t, len(c.nodes), 4)

	req: http.Request
	http.headers_init(&req.headers)
	res: http.Response
	http.headers_init(&res.headers)
	// Logger on_respond needs res._conn for fire — skip actual logger; disabled.
	root := chain_root_ptr(&c)
	root.handle(root, &req, &res)

	testing.expect_value(t, hits, 1)
	// security headers applied
	v, ok := http.headers_get(res.headers, "x-content-type-options")
	testing.expect(t, ok)
	testing.expect_value(t, v, "nosniff")
	// request id set
	_, ok = http.headers_get(res.headers, "x-request-id")
	testing.expect(t, ok)
}

@(test)
test_cors_origin_any :: proc(t: ^testing.T) {
	opts := Cors_Default
	ok, v := _cors_origin_allowed(&opts, "https://evil.example")
	testing.expect(t, ok)
	testing.expect_value(t, v, "*")
}

@(test)
test_cors_origin_list :: proc(t: ^testing.T) {
	opts := Cors_Opts {
		allow_origins = {"https://app.example.com", "https://admin.example.com"},
	}
	ok, v := _cors_origin_allowed(&opts, "https://app.example.com")
	testing.expect(t, ok)
	testing.expect_value(t, v, "https://app.example.com")

	ok, v = _cors_origin_allowed(&opts, "https://other.example.com")
	testing.expect(t, !ok)
}

@(test)
test_cors_credentials_blocks_star_config :: proc(t: ^testing.T) {
	opts := Cors_Opts {
		allow_any_origin  = true,
		allow_credentials = true,
	}
	ok, _ := _cors_origin_allowed(&opts, "https://a.com")
	testing.expect(t, !ok)
}

@(test)
test_cors_preflight_detect :: proc(t: ^testing.T) {
	req: http.Request
	http.headers_init(&req.headers)
	req.line = http.Requestline {
		method = .Options,
		target = "/",
	}
	testing.expect(t, !_cors_is_preflight(&req))
	http.headers_set_unsafe(&req.headers, "access-control-request-method", "POST")
	testing.expect(t, _cors_is_preflight(&req))
}

@(test)
test_cors_vary_token_exact :: proc(t: ^testing.T) {
	testing.expect(t, _cors_vary_has_token("Origin, Accept", "Origin"))
	testing.expect(t, _cors_vary_has_token("Accept, Origin", "Origin"))
	testing.expect(t, !_cors_vary_has_token("X-Origin", "Origin"))
	testing.expect(t, _cors_vary_has_token("origin", "Origin")) // fold
}

@(test)
test_cors_deep_owns_origins :: proc(t: ^testing.T) {
	// Stack slice must not dangle after cors() returns.
	origins := []string{"https://a.example", "https://b.example"}
	inner: http.Handler
	inner.handle = proc(h: ^http.Handler, req: ^http.Request, res: ^http.Response) {
		_ = h
		_ = req
		_ = res
	}
	h := cors(Cors_Opts{allow_origins = origins}, &inner)
	// Mutate original slice content — owned clone must remain.
	// (can't mutate string data; rebuild empty caller slice conceptually)
	st := (^Cors_State)(h.user_data)
	testing.expect_value(t, len(st.opts.allow_origins), 2)
	testing.expect_value(t, st.opts.allow_origins[0], "https://a.example")
	cors_destroy(&h)
}

@(test)
test_from_fn_calls_next :: proc(t: ^testing.T) {
	called := false
	inner: http.Handler
	inner.user_data = &called
	inner.handle = proc(h: ^http.Handler, req: ^http.Request, res: ^http.Response) {
		p := cast(^bool)h.user_data
		p^ = true
		_ = req
		_ = res
	}

	outer := from_fn(
		proc(req: ^http.Request, res: ^http.Response, next: ^http.Handler) {
			call_next(next, req, res)
		},
		&inner,
	)
	defer free(outer.user_data)

	req: http.Request
	res: http.Response
	outer.handle(&outer, &req, &res)
	testing.expect(t, called)
}

@(test)
test_request_id_rejects_crlf :: proc(t: ^testing.T) {
	testing.expect(t, _request_id_safe("abc-123"))
	testing.expect(t, !_request_id_safe("evil\r\nSet-Cookie: x"))
	testing.expect(t, !_request_id_safe("has space"))
}

@(test)
test_security_defaults_strings :: proc(t: ^testing.T) {
	inner: http.Handler
	inner.handle = proc(h: ^http.Handler, req: ^http.Request, res: ^http.Response) {
		_ = h
		_ = req
		_ = res
	}
	h := security_headers({}, &inner)
	defer free(h.user_data)

	req: http.Request
	res: http.Response
	http.headers_init(&res.headers)
	h.handle(&h, &req, &res)
	v, ok := http.headers_get(res.headers, "x-content-type-options")
	testing.expect(t, ok)
	testing.expect_value(t, v, "nosniff")
	v, ok = http.headers_get(res.headers, "x-frame-options")
	testing.expect(t, ok)
	testing.expect_value(t, v, "DENY")
}

@(test)
test_logger_disabled_structure :: proc(t: ^testing.T) {
	inner: http.Handler
	inner.handle = proc(h: ^http.Handler, req: ^http.Request, res: ^http.Response) {
		_ = h
		_ = req
		res.status = .No_Content
	}
	h := logger({disabled = true}, &inner)
	defer free(h.user_data)
	testing.expect(t, h.handle != nil)
	testing.expect(t, h.next == &inner)
}

