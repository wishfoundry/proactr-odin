package http

import "base:runtime"

import "core:mem"
import "core:strings"
import "core:testing"

@(test)
test_static_vs_param_priority :: proc(t: ^testing.T) {
	b: Builder
	builder_init(&b)
	defer builder_destroy(&b)

	// Static must win over param at same segment.
	builder_get_fn(&b, "/users/new", proc(req: ^Request, res: ^Response) {
		_ = res
		req_ctx_set_string(req, "hit", "static")
	})
	builder_get_fn(&b, "/users/{id}", proc(req: ^Request, res: ^Response) {
		_ = res
		req_ctx_set_string(req, "hit", "param")
	})

	table, err := builder_expand(&b)
	testing.expect_value(t, err.kind, Builder_Error_Kind.None)
	defer match_table_destroy(&table)

	// Direct walk checks
	params: Path_Params
	leaf, ok := segment_walk(table.roots[.Get], "/users/new", &params)
	testing.expect(t, ok)
	testing.expect_value(t, leaf.pattern, "/users/new")
	testing.expect_value(t, params.n, 0)

	params.n = 0
	leaf, ok = segment_walk(table.roots[.Get], "/users/42", &params)
	testing.expect(t, ok)
	testing.expect_value(t, leaf.pattern, "/users/{id}")
	testing.expect_value(t, params.n, 1)
	testing.expect_value(t, params.keys[0], "id")
	testing.expect_value(t, params.vals[0], "42")
}

@(test)
test_catch_all_empty_remainder :: proc(t: ^testing.T) {
	b: Builder
	builder_init(&b)
	defer builder_destroy(&b)
	builder_get_fn(&b, "/files/{*path}", proc(req: ^Request, res: ^Response) {})

	table, err := builder_expand(&b)
	testing.expect_value(t, err.kind, Builder_Error_Kind.None)
	defer match_table_destroy(&table)

	params: Path_Params
	leaf, ok := segment_walk(table.roots[.Get], "/files", &params)
	testing.expect(t, ok)
	testing.expect_value(t, params.n, 1)
	testing.expect_value(t, params.keys[0], "path")
	testing.expect_value(t, params.vals[0], "")

	params.n = 0
	leaf, ok = segment_walk(table.roots[.Get], "/files/a/b", &params)
	testing.expect(t, ok)
	testing.expect_value(t, params.vals[0], "a/b")
	_ = leaf
}

@(test)
test_trailing_slash_normalize :: proc(t: ^testing.T) {
	testing.expect_value(t, normalize_trailing_slash("/"), "/")
	testing.expect_value(t, normalize_trailing_slash("/users"), "/users")
	testing.expect_value(t, normalize_trailing_slash("/users/"), "/users")
	testing.expect_value(t, normalize_trailing_slash("/a/b/"), "/a/b")

	b: Builder
	builder_init(&b)
	defer builder_destroy(&b)
	builder_get_fn(&b, "/users", proc(req: ^Request, res: ^Response) {})

	table, err := builder_expand(&b)
	testing.expect_value(t, err.kind, Builder_Error_Kind.None)
	defer match_table_destroy(&table)

	params: Path_Params
	_, ok := segment_walk(table.roots[.Get], normalize_trailing_slash("/users/"), &params)
	testing.expect(t, ok)

	// Registering both /users and /users/ → conflict after normalize
	b2: Builder
	builder_init(&b2)
	defer builder_destroy(&b2)
	builder_get_fn(&b2, "/users", proc(req: ^Request, res: ^Response) {})
	builder_get_fn(&b2, "/users/", proc(req: ^Request, res: ^Response) {})
	_, err2 := builder_expand(&b2)
	testing.expect_value(t, err2.kind, Builder_Error_Kind.Conflict)
}

@(test)
test_conflict_dual_param_names :: proc(t: ^testing.T) {
	b: Builder
	builder_init(&b)
	defer builder_destroy(&b)
	builder_get_fn(&b, "/users/{id}", proc(req: ^Request, res: ^Response) {})
	builder_get_fn(&b, "/users/{user_id}", proc(req: ^Request, res: ^Response) {})
	_, err := builder_expand(&b)
	testing.expect_value(t, err.kind, Builder_Error_Kind.Conflict)
}

@(test)
test_customs_before_405 :: proc(t: ^testing.T) {
	b: Builder
	builder_init(&b)
	defer builder_destroy(&b)

	// GET /hook exists
	builder_get_fn(&b, "/hook", proc(req: ^Request, res: ^Response) {
		_ = res
		req_ctx_set_string(req, "hit", "get")
	})
	// Custom claims any method on /hook
	builder_match(
		&b,
		proc(req: ^Request) -> bool {
			return normalize_trailing_slash(req.url.path) == "/hook"
		},
		handler(proc(req: ^Request, res: ^Response) {
			_ = res
			req_ctx_set_string(req, "hit", "custom")
		}),
	)

	table, err := builder_expand(&b)
	testing.expect_value(t, err.kind, Builder_Error_Kind.None)
	defer match_table_destroy(&table)

	// Simulate match order for POST /hook: method trie miss → custom hit
	req: Request
	req.url.path = "/hook"
	req.line = Requestline {
		method = .Post,
		target = "/hook",
	}
	path := normalize_trailing_slash(req.url.path)
	path_params_clear(&req.params)

	// method trie miss
	_, ok := segment_walk(table.roots[.Post], path, &req.params)
	testing.expect(t, !ok)

	// custom should match
	hit_custom := false
	for e in table.customs {
		if e.prefix != "" && e.prefix != "/" {
			if !path_under_mount(path, e.prefix) {
				continue
			}
		}
		if e.match != nil && e.match(&req) {
			hit_custom = true
			break
		}
	}
	testing.expect(t, hit_custom)

	// Path exists under GET → would be 405 if no custom
	testing.expect(t, segment_walk_exists(table.roots[.Get], path))
}

@(test)
test_path_under_mount_segment_aware :: proc(t: ^testing.T) {
	testing.expect(t, path_under_mount("/api", "/api"))
	testing.expect(t, path_under_mount("/api/users", "/api"))
	testing.expect(t, !path_under_mount("/apiv2", "/api"))
	testing.expect(t, !path_under_mount("/apiv2/x", "/api"))
	testing.expect(t, path_under_mount("/v1", "/v1"))
	testing.expect(t, !path_under_mount("/v1x", "/v1"))
	testing.expect(t, path_under_mount("/anything", ""))
	testing.expect(t, path_under_mount("/anything", "/"))
}

@(test)
test_match_alloc_path_slices :: proc(t: ^testing.T) {
	b: Builder
	builder_init(&b)
	defer builder_destroy(&b)
	builder_get_fn(&b, "/users/{id}/posts/{pid}", proc(req: ^Request, res: ^Response) {})

	table, err := builder_expand(&b)
	testing.expect_value(t, err.kind, Builder_Error_Kind.None)
	defer match_table_destroy(&table)

	// Path buffer we control — param vals must be slices into it.
	path_buf := "/users/abc/posts/99"
	params: Path_Params
	tracking: mem.Tracking_Allocator
	mem.tracking_allocator_init(&tracking, context.allocator)
	defer mem.tracking_allocator_destroy(&tracking)
	context.allocator = mem.tracking_allocator(&tracking)
	context.temp_allocator = mem.tracking_allocator(&tracking)

	before_allocs := len(tracking.allocation_map)
	leaf, ok := segment_walk(table.roots[.Get], path_buf, &params)
	after_allocs := len(tracking.allocation_map)
	testing.expect(t, ok)
	testing.expect_value(t, after_allocs, before_allocs) // 0 allocs in match core
	testing.expect_value(t, params.n, 2)
	testing.expect_value(t, params.vals[0], "abc")
	testing.expect_value(t, params.vals[1], "99")
	// Slices must point into path_buf (same underlying data)
	testing.expect(t, raw_data(params.vals[0]) == raw_data(path_buf[7:10]))
	_ = leaf
}

@(test)
test_param_helper :: proc(t: ^testing.T) {
	req: Request
	req.params.n = 1
	req.params.keys[0] = "id"
	req.params.vals[0] = "42"
	v, ok := param(&req, "id")
	testing.expect(t, ok)
	testing.expect_value(t, v, "42")
	_, ok2 := param(&req, "missing")
	testing.expect(t, !ok2)
}

@(test)
test_mount_custom_prefix_gate :: proc(t: ^testing.T) {
	root: Builder
	builder_init(&root)
	defer builder_destroy(&root)

	lib: Builder
	builder_init(&lib)
	defer builder_destroy(&lib)
	builder_match(
		&lib,
		proc(req: ^Request) -> bool {
			// Author does not re-check mount; gate is in match loop.
			_ = req
			return true
		},
		handler(proc(req: ^Request, res: ^Response) {}),
	)
	builder_mount(&root, "/api", &lib)

	table, err := builder_expand(&root)
	testing.expect_value(t, err.kind, Builder_Error_Kind.None)
	defer match_table_destroy(&table)

	testing.expect(t, len(table.customs) == 1)
	testing.expect_value(t, table.customs[0].prefix, "/api")

	// /api should pass gate; /apiv2 should not
	testing.expect(t, path_under_mount("/api/x", table.customs[0].prefix))
	testing.expect(t, !path_under_mount("/apiv2", table.customs[0].prefix))
}

@(test)
test_builder_get_fn_root :: proc(t: ^testing.T) {
	b: Builder
	builder_init(&b)
	defer builder_destroy(&b)
	builder_get_fn(&b, "/", proc(req: ^Request, res: ^Response) {})
	table, err := builder_expand(&b)
	testing.expect_value(t, err.kind, Builder_Error_Kind.None)
	defer match_table_destroy(&table)
	params: Path_Params
	_, ok := segment_walk(table.roots[.Get], "/", &params)
	testing.expect(t, ok)
}

// ---------------------------------------------------------------------------
// ---------------------------------------------------------------------------

// Status-only handlers for unit tests (default 404/405 call respond → need conn).
@(private)
_test_status_handle :: proc(h: ^Handler, req: ^Request, res: ^Response) {
	_ = req
	st := (^Status)(h.user_data)
	res.status = st^
}

// free_data probe: mark only (no free) so the test can still read the flag.
@(private)
_Expand_Fail_Track :: struct {
	freed: bool,
}

@(private)
_expand_fail_layer_build :: proc(data: rawptr, next: ^Handler, allocator: runtime.Allocator) -> Handler {
	_ = data
	return from_fn(
		proc(req: ^Request, res: ^Response, next: ^Handler) {
			req_ctx_set_string(req, "mw", "1")
			next.handle(next, req, res)
		},
		next,
		allocator,
	)
}

@(private)
_expand_fail_layer_free :: proc(data: rawptr, allocator: runtime.Allocator) {
	_ = allocator
	tr := (^_Expand_Fail_Track)(data)
	tr.freed = true
}

@(test)
test_expand_fail_keeps_builder_layer_data :: proc(t: ^testing.T) {
	// Expand failure must not free Builder-owned Layer.data.
	// After a failed expand, re-expand still sees live layer state (no UAF).
	b: Builder
	builder_init(&b)
	defer builder_destroy(&b)

	track := new(_Expand_Fail_Track)
	track.freed = false
	defer free(track)

	builder_use(
		&b,
		Layer{
			data = track,
			build = _expand_fail_layer_build,
			free_data = _expand_fail_layer_free,
		},
	)

	// First route wraps layers (tracks layer_data on table); second conflicts.
	builder_get_fn(&b, "/users/{id}", proc(req: ^Request, res: ^Response) {})
	builder_get_fn(&b, "/users/{user_id}", proc(req: ^Request, res: ^Response) {})

	_, err := builder_expand(&b)
	testing.expect_value(t, err.kind, Builder_Error_Kind.Conflict)
	testing.expect(t, !track.freed, "expand fail must not free Builder-owned Layer.data")

	// Builder still usable: re-expand walks the same layers without UAF.
	// (Still conflicts — but wrap reuses live Layer.data.)
	_, err2 := builder_expand(&b)
	testing.expect_value(t, err2.kind, Builder_Error_Kind.Conflict)
	testing.expect(t, !track.freed)
}

@(test)
test_builder_merge_preserves_scoped_layers :: proc(t: ^testing.T) {
	other: Builder
	builder_init(&other)
	defer builder_destroy(&other)

	builder_use_fn(&other, proc(req: ^Request, res: ^Response, next: ^Handler) {
		req_ctx_set_string(req, "mw", "yes")
		next.handle(next, req, res)
	})
	builder_get_fn(&other, "/x", proc(req: ^Request, res: ^Response) {
		_ = res
		req_ctx_set_string(req, "hit", "route")
	})

	root: Builder
	builder_init(&root)
	defer builder_destroy(&root)
	builder_merge(&root, &other)

	table, err := builder_expand(&root)
	testing.expect_value(t, err.kind, Builder_Error_Kind.None)
	defer match_table_destroy(&table)

	// other.use_fn Layer.data was copied by value onto the merge subtree; after
	// successful expand the table owns free of that data. other is destroyed later
	// and must not free the same pointer — builder_destroy skips Layer.data.
	// Clear other's layers so a mistaken free_data path cannot double-free.
	clear(&other.layers)

	req: Request
	res: Response
	headers_init(&res.headers)
	req.url.path = "/x"
	req.line = Requestline {
		method = .Get,
		target = "/x",
	}
	h := match_table_handler(&table)
	h.handle(&h, &req, &res)

	mw, mw_ok := req_ctx_get_string(&req, "mw")
	testing.expect(t, mw_ok)
	testing.expect_value(t, mw, "yes")
	hit, hit_ok := req_ctx_get_string(&req, "hit")
	testing.expect(t, hit_ok)
	testing.expect_value(t, hit, "route")
}

@(test)
test_match_table_handler_405_allow :: proc(t: ^testing.T) {
	b: Builder
	builder_init(&b)
	defer builder_destroy(&b)

	builder_get_fn(&b, "/x", proc(req: ^Request, res: ^Response) {
		_ = req
		res.status = .OK
	})
	// Avoid default 405 respond() which needs a live connection.
	st := new(Status)
	st^ = .Method_Not_Allowed
	defer free(st)
	builder_method_not_allowed(&b, Handler{user_data = st, handle = _test_status_handle})

	table, err := builder_expand(&b)
	testing.expect_value(t, err.kind, Builder_Error_Kind.None)
	defer match_table_destroy(&table)

	req: Request
	res: Response
	headers_init(&res.headers)
	req.url.path = "/x"
	req.line = Requestline {
		method = .Post,
		target = "/x",
	}
	h := match_table_handler(&table)
	h.handle(&h, &req, &res)

	testing.expect_value(t, res.status, Status.Method_Not_Allowed)
	allow, ok := headers_get(res.headers, "allow")
	testing.expect(t, ok)
	// Single-pass Allow includes GET for a GET-only path.
	testing.expect(t, strings.contains(allow, "GET"))
}

@(test)
test_match_table_handler_customs_before_405 :: proc(t: ^testing.T) {
	b: Builder
	builder_init(&b)
	defer builder_destroy(&b)

	builder_get_fn(&b, "/hook", proc(req: ^Request, res: ^Response) {
		_ = res
		req_ctx_set_string(req, "hit", "get")
	})
	builder_match(
		&b,
		proc(req: ^Request) -> bool {
			return normalize_trailing_slash(req.url.path) == "/hook"
		},
		handler(proc(req: ^Request, res: ^Response) {
			_ = res
			req_ctx_set_string(req, "hit", "custom")
		}),
	)
	st := new(Status)
	st^ = .Method_Not_Allowed
	defer free(st)
	builder_method_not_allowed(&b, Handler{user_data = st, handle = _test_status_handle})

	table, err := builder_expand(&b)
	testing.expect_value(t, err.kind, Builder_Error_Kind.None)
	defer match_table_destroy(&table)

	req: Request
	res: Response
	headers_init(&res.headers)
	req.url.path = "/hook"
	req.line = Requestline {
		method = .Post,
		target = "/hook",
	}
	h := match_table_handler(&table)
	h.handle(&h, &req, &res)

	// Custom wins before 405; status left unset by custom (no Method_Not_Allowed).
	testing.expect(t, res.status != .Method_Not_Allowed)
	hit, ok := req_ctx_get_string(&req, "hit")
	testing.expect(t, ok)
	testing.expect_value(t, hit, "custom")
}
