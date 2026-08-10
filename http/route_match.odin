package http

import "base:runtime"

import "core:strings"

// Match_Proc classifies only — may write Request_Ctx; never responds; never Path_Params.
Match_Proc :: proc(req: ^Request) -> bool

Custom_Entry :: struct {
	match:   Match_Proc, // author-supplied; full path; classifies only
	handler: Handler,
	prefix:  string, // interned mount/group gate; "" or "/" = none
}

CUSTOMS_WARN :: 8

Tracked_Layer_Data :: struct {
	data: rawptr,
	free: proc(data: rawptr, allocator: runtime.Allocator),
}

// Wrap Handler shells that need custom free of user_data (CORS/security deep free).
Tracked_Handler_Free :: struct {
	h:    ^Handler,
	free: proc(h: ^Handler, allocator: runtime.Allocator),
}

Match_Table :: struct {
	allocator:     runtime.Allocator,
	roots:         [Method]^Segment_Node, // sparse nils OK
	customs:       []Custom_Entry,        // frozen; len 0 → free miss path
	not_found:     Handler,
	method_na:     Handler,
	// ownership for destroy
	nodes:         [dynamic]^Segment_Node,
	handler_nodes: [dynamic]^Handler, // onion nodes; terminal user_data app-owned
	handler_frees: [dynamic]Tracked_Handler_Free, // free_built for wraps
	layer_data:    [dynamic]Tracked_Layer_Data,
	interned:      [dynamic]string,
	// build-time only (cleared after freeze)
	_build_roots:  [Method]^_Build_Node,
	_customs_dyn:  [dynamic]Custom_Entry,
}

// Default framework 404/405 (unary respond).
@(private)
_default_404_handle :: proc(h: ^Handler, req: ^Request, res: ^Response) {
	_ = h
	_ = req
	res.status = .Not_Found
	respond(res)
}

@(private)
_default_405_handle :: proc(h: ^Handler, req: ^Request, res: ^Response) {
	_ = h
	_ = req
	// Allow header is set by match_table_handler before call when known.
	res.status = .Method_Not_Allowed
	respond(res)
}

default_404_handler :: proc() -> Handler {
	return Handler{handle = _default_404_handle}
}

default_405_handler :: proc() -> Handler {
	return Handler{handle = _default_405_handle}
}

match_table_destroy :: proc(t: ^Match_Table) {
	if t == nil {
		return
	}
	context.allocator = t.allocator

	// Free layer data (same rules as middleware.Chain).
	// Dedupe by pointer: shared ancestor layers are tracked once per wrapped leaf.
	for i in 0 ..< len(t.layer_data) {
		td := t.layer_data[i]
		if td.data == nil {
			continue
		}
		// Skip if already freed under an earlier index.
		dup := false
		for j in 0 ..< i {
			if t.layer_data[j].data == td.data {
				dup = true
				break
			}
		}
		if dup {
			continue
		}
		if td.free != nil {
			td.free(td.data, t.allocator)
		} else {
			free(td.data, t.allocator)
		}
	}
	delete(t.layer_data)

	// Chain-parity wrap free: free_built first (CORS/security deep free), then bare free
	// for remaining wrap user_data (from_fn). Terminals (next unset) keep app user_data.
	for tf in t.handler_frees {
		if tf.h == nil || tf.free == nil {
			continue
		}
		tf.free(tf.h, t.allocator)
	}
	delete(t.handler_frees)

	for h in t.handler_nodes {
		if h == nil {
			continue
		}
		if h.user_data != nil {
			if _, ok := h.next.?; ok {
				free(h.user_data, t.allocator)
				h.user_data = nil
			}
		}
		free(h, t.allocator)
	}
	delete(t.handler_nodes)

	for n in t.nodes {
		if n == nil {
			continue
		}
		delete(n.static_keys, t.allocator)
		delete(n.static_kids, t.allocator)
		free(n, t.allocator)
	}
	delete(t.nodes)

	for s in t.interned {
		delete(s, t.allocator)
	}
	delete(t.interned)

	if t.customs != nil {
		delete(t.customs, t.allocator)
	}
	delete(t._customs_dyn)

	// Unfrozen build roots (expand failure before freeze).
	for m in Method {
		if t._build_roots[m] != nil {
			_build_node_destroy(t._build_roots[m], t.allocator)
			t._build_roots[m] = nil
		}
	}

	t^ = {}
}

// Handler that dispatches via Match_Table. t must outlive the server.
match_table_handler :: proc(t: ^Match_Table) -> Handler {
	h: Handler
	h.user_data = t
	h.handle = _match_table_handle
	return h
}

@(private)
_match_table_handle :: proc(handler: ^Handler, req: ^Request, res: ^Response) {
	table := (^Match_Table)(handler.user_data)
	rline := req.line.(Requestline)
	method := rline.method

	path := normalize_trailing_slash(req.url.path)
	// Match entry: clear params only — never ctx (outer middleware may have deposited).
	path_params_clear(&req.params)
	req.route_pattern = ""

	// 1) method trie
	root := table.roots[method]
	if leaf, ok := segment_walk(root, path, &req.params); ok {
		req.route_pattern = leaf.pattern
		rh := leaf.handler
		rh.handle(&rh, req, res)
		return
	}

	// 2) customs (before 405), prefix-gated
	for e in table.customs {
		if e.prefix != "" && e.prefix != "/" {
			if !path_under_mount(path, e.prefix) {
				continue
			}
		}
		if e.match != nil && e.match(req) {
			rh := e.handler
			rh.handle(&rh, req, res)
			return
		}
	}

	// 3) 405 if path exists under another method — single walk builds Allow.
	parts, n, has_other := _collect_allow_methods(table, path, method)
	if has_other {
		if n > 0 {
			allow := strings.join(parts[:n], ", ", context.temp_allocator)
			if allow != "" {
				headers_set(&res.headers, "allow", allow)
			}
		}
		rh := table.method_na
		rh.handle(&rh, req, res)
		return
	}

	// 4) 404
	rh := table.not_found
	rh.handle(&rh, req, res)
}

// One pass over methods: collect Allow tokens and whether any method other than
// `skip` matches path. Avoids separate exists + allow full walks.
@(private)
_collect_allow_methods :: proc(
	table: ^Match_Table,
	path: string,
	skip: Method,
) -> (
	parts: [len(Method)]string,
	n: int,
	has_other: bool,
) {
	for m in Method {
		if !segment_walk_exists(table.roots[m], path) {
			continue
		}
		parts[n] = method_string(m)
		n += 1
		if m != skip {
			has_other = true
		}
	}
	return
}

@(private)
_table_intern :: proc(t: ^Match_Table, s: string) -> string {
	c := strings.clone(s, t.allocator)
	append(&t.interned, c)
	return c
}
