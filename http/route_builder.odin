package http

import "base:runtime"

import "core:fmt"
import "core:log"
import "core:net"
import "core:strings"

import proactr "../proactr"

// ---------------------------------------------------------------------------
// Layer (re-homed in package http; middleware adapts into this)
// ---------------------------------------------------------------------------

// Setup-time layer: build(data, next) → wrapping Handler.
// free_data: free Layer.data (opts shell); nil → free(data) only when tracked.
// free_built: free Handler.user_data produced by build (e.g. CORS Cors_State deep free).
//   nil → bare free(user_data) for wraps (from_fn / simple layers).
Layer :: struct {
	data:       rawptr,
	build:      proc(data: rawptr, next: ^Handler, allocator: runtime.Allocator) -> Handler,
	free_data:  proc(data: rawptr, allocator: runtime.Allocator),
	free_built: proc(h: ^Handler, allocator: runtime.Allocator),
}

// ---------------------------------------------------------------------------
// Builder_Error
// ---------------------------------------------------------------------------

Builder_Error_Kind :: enum {
	None,
	Conflict,
	Bad_Pattern,
	Catch_All_Not_Final,
	Duplicate_Param_Name,
	Empty_Path,
	Child_Status_Override,
	Customs_Warn, // reserved; not a hard error
}

Builder_Error :: struct {
	kind:      Builder_Error_Kind,
	method:    Method,
	pattern_a: string,
	pattern_b: string,
	node_path: string,
	message:   string,
}

builder_error_format :: proc(e: Builder_Error, allocator := context.allocator) -> string {
	if e.kind == .None {
		return "ok"
	}
	switch e.kind {
	case .Conflict:
		return fmt.aprintf(
			"conflict: %s %s vs %s %s at %s (%s)",
			method_string(e.method),
			e.pattern_a,
			method_string(e.method),
			e.pattern_b,
			e.node_path,
			e.message,
			allocator = allocator,
		)
	case .Bad_Pattern:
		return fmt.aprintf("bad pattern: %s (%s)", e.pattern_a, e.message, allocator = allocator)
	case .Catch_All_Not_Final:
		return fmt.aprintf("catch-all not final: %s (%s)", e.pattern_a, e.message, allocator = allocator)
	case .Duplicate_Param_Name:
		return fmt.aprintf("duplicate param name: %s (%s)", e.pattern_a, e.message, allocator = allocator)
	case .Empty_Path:
		return fmt.aprintf("empty path (%s)", e.message, allocator = allocator)
	case .Child_Status_Override:
		return fmt.aprintf("child status override (%s)", e.message, allocator = allocator)
	case .Customs_Warn, .None:
		return fmt.aprintf("%v: %s", e.kind, e.message, allocator = allocator)
	}
	return fmt.aprintf("%v", e.kind, allocator = allocator)
}

// ---------------------------------------------------------------------------
// Builder tree
// ---------------------------------------------------------------------------

@(private)
_Builder_Route :: struct {
	methods: [dynamic]Method,
	path:    string, // as registered (relative to this node)
	handler: Handler,
}

@(private)
_Builder_Custom :: struct {
	match:   Match_Proc,
	handler: Handler,
}

@(private)
_Builder_Mount :: struct {
	prefix: string,
	child:  ^Builder,
	owned:  bool, // true for group_begin children (destroy with parent)
}

Builder :: struct {
	allocator: runtime.Allocator,
	prefix:    string, // group/mount prefix for this node (joined at expand)
	layers:    [dynamic]Layer,
	routes:    [dynamic]_Builder_Route,
	customs:   [dynamic]_Builder_Custom,
	children:  [dynamic]^Builder, // group_begin owned
	mounts:    [dynamic]_Builder_Mount,
	not_found: Maybe(Handler),
	method_na: Maybe(Handler),
	_is_root:  bool,
	_status_set: bool, // not_found or method_na was set on this node
}

builder_init :: proc(b: ^Builder, allocator := context.allocator) {
	b^ = {}
	b.allocator = allocator
	b.prefix = ""
	b.layers = make([dynamic]Layer, 0, 4, allocator)
	b.routes = make([dynamic]_Builder_Route, 0, 8, allocator)
	b.customs = make([dynamic]_Builder_Custom, 0, 2, allocator)
	b.children = make([dynamic]^Builder, 0, 2, allocator)
	b.mounts = make([dynamic]_Builder_Mount, 0, 2, allocator)
	b._is_root = true
}

builder_destroy :: proc(b: ^Builder) {
	if b == nil {
		return
	}
	context.allocator = b.allocator
	for &r in b.routes {
		delete(r.methods)
		delete(r.path)
	}
	delete(b.routes)
	delete(b.customs)
	delete(b.layers)
	for c in b.children {
		builder_destroy(c)
		free(c, b.allocator)
	}
	delete(b.children)
	for m in b.mounts {
		delete(m.prefix)
		if m.owned && m.child != nil {
			builder_destroy(m.child)
			free(m.child, b.allocator)
		}
		// borrowed mounts: caller destroys
	}
	delete(b.mounts)
	if b.prefix != "" {
		delete(b.prefix)
	}
	b^ = {}
}

builder_use :: proc(b: ^Builder, layers: ..Layer) {
	for l in layers {
		append(&b.layers, l)
	}
}

builder_use_fn :: proc(b: ^Builder, f: proc(req: ^Request, res: ^Response, next: ^Handler)) {
	// Encode as a Layer with no data; build uses from_fn.
	assert(f != nil)
	// Store f as data (function pointer as rawptr).
	st := new(_Use_Fn_Data, b.allocator)
	st.f = f
	append(
		&b.layers,
		Layer{
			data = st,
			build = _use_fn_layer_build,
			free_data = proc(data: rawptr, allocator: runtime.Allocator) {
				free(data, allocator)
			},
		},
	)
}

@(private)
_Use_Fn_Data :: struct {
	f: proc(req: ^Request, res: ^Response, next: ^Handler),
}

@(private)
_use_fn_layer_build :: proc(data: rawptr, next: ^Handler, allocator: runtime.Allocator) -> Handler {
	st := (^_Use_Fn_Data)(data)
	return from_fn(st.f, next, allocator)
}

// Primary Odin-native group: returns child builder owned by parent.
builder_group_begin :: proc(b: ^Builder, prefix: string) -> ^Builder {
	child := new(Builder, b.allocator)
	builder_init(child, b.allocator)
	child._is_root = false
	child.prefix = strings.clone(prefix, b.allocator)
	append(&b.children, child)
	return child
}

// Callback sugar (no captures).
builder_group :: proc(b: ^Builder, prefix: string, setup: proc(g: ^Builder)) {
	g := builder_group_begin(b, prefix)
	if setup != nil {
		setup(g)
	}
}

// Mount an external (or owned) builder under prefix. Borrowed by default.
builder_mount :: proc(b: ^Builder, prefix: string, child: ^Builder, owned := false) {
	assert(child != nil)
	append(
		&b.mounts,
		_Builder_Mount{
			prefix = strings.clone(prefix, b.allocator),
			child = child,
			owned = owned,
		},
	)
}

// Deep-copy other into b under a scoped subtree (DESIGN merge rules).
// other's layers/prefix wrap only the copied routes/customs/children/mounts —
// never dumped onto b's bare root. Does not import not_found / method_na.
builder_merge :: proc(b: ^Builder, other: ^Builder) {
	if other == nil {
		return
	}
	// Always place the copy under an owned group so other.layers stay scoped
	// over other.routes (even when other.prefix is empty).
	sub := builder_group_begin(b, other.prefix if other.prefix != "" else "")
	for l in other.layers {
		append(&sub.layers, l)
	}
	for r in other.routes {
		ms := make([dynamic]Method, 0, len(r.methods), b.allocator)
		for m in r.methods {
			append(&ms, m)
		}
		append(
			&sub.routes,
			_Builder_Route{
				methods = ms,
				path = strings.clone(r.path, b.allocator),
				handler = r.handler,
			},
		)
	}
	for c in other.customs {
		append(&sub.customs, c)
	}
	// Borrowed refs OK for v1 — caller keeps children/mount targets alive through expand.
	for c in other.children {
		builder_mount(sub, c.prefix, c, false)
	}
	for m in other.mounts {
		builder_mount(sub, m.prefix, m.child, false)
	}
	// Do NOT import not_found / method_na
}

builder_route :: proc(b: ^Builder, methods: []Method, path: string, h: Handler) {
	ms := make([dynamic]Method, 0, len(methods), b.allocator)
	for m in methods {
		append(&ms, m)
	}
	append(
		&b.routes,
		_Builder_Route{
			methods = ms,
			path = strings.clone(path, b.allocator),
			handler = h,
		},
	)
}

builder_get :: proc(b: ^Builder, path: string, h: Handler) {
	ms := [1]Method{.Get}
	builder_route(b, ms[:], path, h)
}

builder_post :: proc(b: ^Builder, path: string, h: Handler) {
	ms := [1]Method{.Post}
	builder_route(b, ms[:], path, h)
}

builder_put :: proc(b: ^Builder, path: string, h: Handler) {
	ms := [1]Method{.Put}
	builder_route(b, ms[:], path, h)
}

builder_patch :: proc(b: ^Builder, path: string, h: Handler) {
	ms := [1]Method{.Patch}
	builder_route(b, ms[:], path, h)
}

builder_delete :: proc(b: ^Builder, path: string, h: Handler) {
	ms := [1]Method{.Delete}
	builder_route(b, ms[:], path, h)
}

builder_head :: proc(b: ^Builder, path: string, h: Handler) {
	ms := [1]Method{.Head}
	builder_route(b, ms[:], path, h)
}

builder_options :: proc(b: ^Builder, path: string, h: Handler) {
	ms := [1]Method{.Options}
	builder_route(b, ms[:], path, h)
}

builder_get_fn :: proc(b: ^Builder, path: string, f: Handle_Proc) {
	builder_get(b, path, handler(f))
}

builder_post_fn :: proc(b: ^Builder, path: string, f: Handle_Proc) {
	builder_post(b, path, handler(f))
}

builder_put_fn :: proc(b: ^Builder, path: string, f: Handle_Proc) {
	builder_put(b, path, handler(f))
}

builder_patch_fn :: proc(b: ^Builder, path: string, f: Handle_Proc) {
	builder_patch(b, path, handler(f))
}

builder_delete_fn :: proc(b: ^Builder, path: string, f: Handle_Proc) {
	builder_delete(b, path, handler(f))
}

builder_match :: proc(b: ^Builder, m: Match_Proc, h: Handler) {
	append(&b.customs, _Builder_Custom{match = m, handler = h})
}

builder_not_found :: proc(b: ^Builder, h: Handler) {
	b.not_found = h
	b._status_set = true
}

builder_method_not_allowed :: proc(b: ^Builder, h: Handler) {
	b.method_na = h
	b._status_set = true
}

// ---------------------------------------------------------------------------
// Expand
// ---------------------------------------------------------------------------

builder_expand :: proc(b: ^Builder, allocator := context.allocator) -> (table: Match_Table, err: Builder_Error) {
	table.allocator = allocator
	table.nodes = make([dynamic]^Segment_Node, 0, 32, allocator)
	table.handler_nodes = make([dynamic]^Handler, 0, 32, allocator)
	table.handler_frees = make([dynamic]Tracked_Handler_Free, 0, 16, allocator)
	table.layer_data = make([dynamic]Tracked_Layer_Data, 0, 16, allocator)
	table.interned = make([dynamic]string, 0, 32, allocator)
	table._customs_dyn = make([dynamic]Custom_Entry, 0, 4, allocator)
	table.not_found = default_404_handler()
	table.method_na = default_405_handler()

	// Root-only status handlers.
	if nf, ok := b.not_found.?; ok {
		table.not_found = nf
	}
	if mn, ok := b.method_na.?; ok {
		table.method_na = mn
	}

	stack := make([dynamic]Layer, 0, 8, allocator)
	defer delete(stack)

	err = _expand_node(b, "/", stack[:], &table, true)
	if err.kind != .None {
		// Builder still owns Layer.data (builder_use / stock opts). Clear tracking
		// so match_table_destroy does not free them. Expand-private wrap shells,
		// From_Fn_State user_data, interned strings, and build roots still free.
		for &td in table.layer_data {
			td.data = nil
			td.free = nil
		}
		match_table_destroy(&table)
		table = {}
		return
	}

	// Freeze customs
	table.customs = make([]Custom_Entry, len(table._customs_dyn), allocator)
	copy(table.customs, table._customs_dyn[:])
	delete(table._customs_dyn)
	table._customs_dyn = {}

	if len(table.customs) > CUSTOMS_WARN {
		log.warnf("Match_Table has %d customs (warn threshold %d)", len(table.customs), CUSTOMS_WARN)
	}

	// Freeze build roots → Segment_Node
	for m in Method {
		if table._build_roots[m] != nil {
			table.roots[m] = _freeze_node(table._build_roots[m], allocator, &table.nodes)
			table._build_roots[m] = nil
		}
	}

	return
}

@(private)
_expand_node :: proc(
	node: ^Builder,
	prefix: string,
	stack_layers: []Layer,
	table: ^Match_Table,
	is_root: bool,
) -> Builder_Error {
	if node == nil {
		return {}
	}

	// Child status override is a build error.
	if !is_root && node._status_set {
		return Builder_Error {
			kind = .Child_Status_Override,
			message = "not_found/method_not_allowed only allowed on root Builder",
		}
	}

	// layers = concat(stack, node.layers)
	layers := make([dynamic]Layer, 0, len(stack_layers) + len(node.layers), table.allocator)
	defer delete(layers)
	for l in stack_layers {
		append(&layers, l)
	}
	for l in node.layers {
		append(&layers, l)
	}

	// 1) routes
	for r in node.routes {
		joined := join_route_path(prefix, r.path, table.allocator)
		// joined is temp for parse; intern a copy for leaf pattern
		pattern := normalize_trailing_slash(joined)
		// free joined if different storage — join always allocates
		// We'll intern pattern and free the join buffer after intern
		interned := _table_intern(table, pattern)
		delete(joined, table.allocator)

		segs, perr := parse_pattern(interned, table.allocator)
		if perr.kind != .None {
			return perr
		}
		// Intern segment texts for static edges / param names
		for &s in segs {
			s.text = _table_intern(table, s.text)
		}

		leaf_h := _wrap_layers(layers[:], r.handler, table)
		leaf := Route_Leaf {
			handler = leaf_h,
			pattern = interned,
		}

		for m in r.methods {
			if table._build_roots[m] == nil {
				table._build_roots[m] = _build_node_new(table.allocator)
			}
			ierr := _build_insert(table._build_roots[m], segs, 0, leaf, table.allocator)
			if ierr.kind != .None {
				ierr.method = m
				if ierr.pattern_a == "" {
					ierr.pattern_a = interned
				}
				if ierr.pattern_b == "" {
					ierr.pattern_b = interned
				}
				delete(segs, table.allocator)
				return ierr
			}
		}
		delete(segs, table.allocator)
	}

	// 2) customs
	gate := ""
	if prefix != "/" && prefix != "" {
		gate = _table_intern(table, normalize_trailing_slash(prefix))
	}
	for c in node.customs {
		leaf_h := _wrap_layers(layers[:], c.handler, table)
		append(
			&table._customs_dyn,
			Custom_Entry{
				match = c.match,
				handler = leaf_h,
				prefix = gate,
			},
		)
	}

	// 3) children (group_begin)
	for child in node.children {
		child_prefix := join_route_path(prefix, child.prefix, table.allocator)
		err := _expand_node(child, child_prefix, layers[:], table, false)
		delete(child_prefix, table.allocator)
		if err.kind != .None {
			return err
		}
	}

	// 4) mounts
	for m in node.mounts {
		mount_prefix := join_route_path(prefix, m.prefix, table.allocator)
		err := _expand_node(m.child, mount_prefix, layers[:], table, false)
		delete(mount_prefix, table.allocator)
		if err.kind != .None {
			return err
		}
	}

	return {}
}

// layers[0] outermost — reverse apply like chain_wrap.
@(private)
_wrap_layers :: proc(layers: []Layer, terminal: Handler, table: ^Match_Table) -> Handler {
	if len(layers) == 0 {
		return terminal
	}
	// Heap-stable terminal node.
	cur := new(Handler, table.allocator)
	cur^ = terminal
	append(&table.handler_nodes, cur)

	// Apply reverse: last layer builds first (innermost wrap).
	for i := len(layers) - 1; i >= 0; i -= 1 {
		layer := layers[i]
		assert(layer.build != nil)
		if layer.data != nil {
			append(&table.layer_data, Tracked_Layer_Data{data = layer.data, free = layer.free_data})
		}
		built := layer.build(layer.data, cur, table.allocator)
		node := new(Handler, table.allocator)
		node^ = built
		node.next = cur
		append(&table.handler_nodes, node)
		// free_built: deep free of Handler.user_data (CORS/security); else bare free on destroy.
		if layer.free_built != nil {
			append(&table.handler_frees, Tracked_Handler_Free{h = node, free = layer.free_built})
		}
		cur = node
	}
	return cur^
}

// ---------------------------------------------------------------------------
// listen_builder — canonical product boot
// ---------------------------------------------------------------------------

// Returns two values always.
// On expand failure: no listen, err == .None, build_err.kind != .None.
// On listen failure after successful expand: build_err.kind == .None, err is host error.
// On clean return from serve: both .None.
listen_builder :: proc(
	s: ^Server,
	b: ^Builder,
	endpoint: net.Endpoint = Default_Endpoint,
	opts: Server_Opts = Default_Server_Opts,
) -> (
	err: proactr.Error,
	build_err: Builder_Error,
) {
	table, berr := builder_expand(b, context.allocator)
	if berr.kind != .None {
		return .None, berr
	}

	// Server owns table for process life.
	s.match_table = table
	s.match_table_owned = true

	err = listen_and_serve(s, match_table_handler(&s.match_table), endpoint, opts)
	// Cover listen failure (or serve early return) before serve teardown clears owned.
	// On normal serve exit, destroy already ran and match_table_owned is false.
	if s.match_table_owned {
		match_table_destroy(&s.match_table)
		s.match_table_owned = false
	}
	return err, Builder_Error{kind = .None}
}
