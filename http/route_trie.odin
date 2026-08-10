package http

import "base:runtime"

import "core:strings"

// Segment trie (one edge per path segment; no path compression in v1).
// Product patterns only: static / {name} / {*name}.

Segment_Kind :: enum u8 {
	Static,
	Param,
	Catch_All,
}

Pattern_Seg :: struct {
	kind: Segment_Kind,
	text: string, // static text or param/catch-all name
}

Route_Leaf :: struct {
	handler: Handler, // outermost precomposed value; next ptrs on heap nodes
	pattern: string,  // interned template
}

// Frozen after expand. Static edges sorted for binary search.
Segment_Node :: struct {
	static_keys: []string,
	static_kids: []^Segment_Node,
	param:       ^Segment_Node, // at most one
	param_name:  string,        // interned
	catch_all:   ^Segment_Node, // at most one
	catch_name:  string,
	has_leaf:    bool,
	leaf:        Route_Leaf,
}

// Build-time mutable node; frozen into Segment_Node at expand end.
@(private)
_Build_Node :: struct {
	static_keys: [dynamic]string,
	static_kids: [dynamic]^_Build_Node,
	param:       ^_Build_Node,
	param_name:  string,
	catch_all:   ^_Build_Node,
	catch_name:  string,
	has_leaf:    bool,
	leaf:        Route_Leaf,
}

// Strip one trailing '/' except root. Subslice only — never clones.
normalize_trailing_slash :: proc(path: string) -> string {
	if len(path) > 1 && path[len(path) - 1] == '/' {
		return path[:len(path) - 1]
	}
	return path
}

// Segment-aware mount test. FORBIDDEN: raw has_prefix("/api") matching "/apiv2".
path_under_mount :: proc(path, prefix: string) -> bool {
	if prefix == "" || prefix == "/" {
		return true
	}
	if path == prefix {
		return true
	}
	if len(path) > len(prefix) &&
	   path[:len(prefix)] == prefix &&
	   path[len(prefix)] == '/' {
		return true
	}
	return false
}

// Join prefix + path into a normalized absolute pattern (no trailing slash except root).
join_route_path :: proc(prefix, path: string, allocator := context.allocator) -> string {
	p := prefix
	s := path
	if p == "" {
		p = "/"
	}
	if s == "" {
		s = "/"
	}
	if len(s) == 0 || s[0] != '/' {
		if p == "/" {
			return normalize_trailing_slash(strings.concatenate([]string{"/", s}, allocator))
		}
		return normalize_trailing_slash(strings.concatenate([]string{p, "/", s}, allocator))
	}
	if p == "/" {
		return normalize_trailing_slash(strings.clone(s, allocator))
	}
	if s == "/" {
		return normalize_trailing_slash(strings.clone(p, allocator))
	}
	return normalize_trailing_slash(strings.concatenate([]string{p, s}, allocator))
}

// Parse product pattern into segments. pattern must be absolute (leading '/').
// Caller owns returned segs slice (allocator).
parse_pattern :: proc(
	pattern: string,
	allocator := context.allocator,
) -> (
	segs: []Pattern_Seg,
	err: Builder_Error,
) {
	if pattern == "" {
		err.kind = .Empty_Path
		err.message = "empty path"
		return
	}
	p := normalize_trailing_slash(pattern)
	if len(p) == 0 || p[0] != '/' {
		err.kind = .Bad_Pattern
		err.pattern_a = pattern
		err.message = "path must start with /"
		return
	}
	if p == "/" {
		segs = make([]Pattern_Seg, 0, allocator)
		return
	}

	dyn := make([dynamic]Pattern_Seg, 0, 8, allocator)

	i := 1
	for i <= len(p) {
		j := i
		for j < len(p) && p[j] != '/' {
			j += 1
		}
		if j == i {
			delete(dyn)
			err.kind = .Bad_Pattern
			err.pattern_a = pattern
			err.message = "empty path segment"
			return
		}
		seg_text := p[i:j]
		ps: Pattern_Seg
		if len(seg_text) >= 2 && seg_text[0] == '{' && seg_text[len(seg_text) - 1] == '}' {
			inner := seg_text[1:len(seg_text) - 1]
			if len(inner) == 0 {
				delete(dyn)
				err.kind = .Bad_Pattern
				err.pattern_a = pattern
				err.message = "empty param name"
				return
			}
			if inner[0] == '*' {
				name := inner[1:]
				if len(name) == 0 {
					delete(dyn)
					err.kind = .Bad_Pattern
					err.pattern_a = pattern
					err.message = "empty catch-all name"
					return
				}
				ps.kind = .Catch_All
				ps.text = name
			} else {
				if strings.contains_rune(inner, ':') {
					delete(dyn)
					err.kind = .Bad_Pattern
					err.pattern_a = pattern
					err.message = "regex constraints not supported"
					return
				}
				ps.kind = .Param
				ps.text = inner
			}
		} else {
			ps.kind = .Static
			ps.text = seg_text
		}
		append(&dyn, ps)
		if j >= len(p) {
			break
		}
		i = j + 1
	}

	for idx in 0 ..< len(dyn) {
		s := dyn[idx]
		if s.kind == .Catch_All && idx != len(dyn) - 1 {
			delete(dyn)
			err.kind = .Catch_All_Not_Final
			err.pattern_a = pattern
			err.message = "catch-all must be final segment"
			return
		}
		if s.kind == .Param || s.kind == .Catch_All {
			for k in 0 ..< idx {
				if (dyn[k].kind == .Param || dyn[k].kind == .Catch_All) && dyn[k].text == s.text {
					delete(dyn)
					err.kind = .Duplicate_Param_Name
					err.pattern_a = pattern
					err.message = "duplicate param name in pattern"
					return
				}
			}
		}
	}

	segs = make([]Pattern_Seg, len(dyn), allocator)
	copy(segs, dyn[:])
	delete(dyn)
	return
}

@(private)
_build_node_new :: proc(allocator: runtime.Allocator) -> ^_Build_Node {
	n := new(_Build_Node, allocator)
	n.static_keys = make([dynamic]string, 0, 4, allocator)
	n.static_kids = make([dynamic]^_Build_Node, 0, 4, allocator)
	return n
}

@(private)
_build_find_static :: proc(node: ^_Build_Node, key: string) -> (idx: int, found: bool) {
	lo, hi := 0, len(node.static_keys)
	for lo < hi {
		mid := int(uint(lo + hi) >> 1)
		cmp := strings.compare(node.static_keys[mid], key)
		if cmp == 0 {
			return mid, true
		} else if cmp < 0 {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo, false
}

@(private)
_build_insert_static :: proc(node: ^_Build_Node, key: string, child: ^_Build_Node) {
	idx, found := _build_find_static(node, key)
	assert(!found)
	inject_at(&node.static_keys, idx, key)
	inject_at(&node.static_kids, idx, child)
}

@(private)
_build_insert :: proc(
	node: ^_Build_Node,
	segs: []Pattern_Seg,
	i: int,
	leaf: Route_Leaf,
	allocator: runtime.Allocator,
) -> Builder_Error {
	if i == len(segs) {
		if node.has_leaf {
			err: Builder_Error
			err.kind = .Conflict
			err.pattern_a = node.leaf.pattern
			err.pattern_b = leaf.pattern
			err.message = "duplicate route"
			return err
		}
		node.has_leaf = true
		node.leaf = leaf
		return {}
	}

	s := segs[i]
	switch s.kind {
	case .Static:
		idx, found := _build_find_static(node, s.text)
		child: ^_Build_Node
		if found {
			child = node.static_kids[idx]
		} else {
			child = _build_node_new(allocator)
			_build_insert_static(node, s.text, child)
		}
		return _build_insert(child, segs, i + 1, leaf, allocator)

	case .Param:
		if node.param != nil && node.param_name != s.text {
			err: Builder_Error
			err.kind = .Conflict
			err.pattern_a = node.param_name
			err.pattern_b = s.text
			err.node_path = leaf.pattern
			err.message = "dual param names at same node"
			return err
		}
		if node.param == nil {
			node.param = _build_node_new(allocator)
			node.param_name = s.text
		}
		return _build_insert(node.param, segs, i + 1, leaf, allocator)

	case .Catch_All:
		if i != len(segs) - 1 {
			err: Builder_Error
			err.kind = .Catch_All_Not_Final
			err.pattern_a = leaf.pattern
			err.message = "catch-all must be final"
			return err
		}
		if node.catch_all != nil && node.catch_name != s.text {
			err: Builder_Error
			err.kind = .Conflict
			err.pattern_a = node.catch_name
			err.pattern_b = s.text
			err.node_path = leaf.pattern
			err.message = "dual catch-all names at same node"
			return err
		}
		if node.catch_all == nil {
			node.catch_all = _build_node_new(allocator)
			node.catch_name = s.text
		}
		return _build_insert(node.catch_all, segs, i + 1, leaf, allocator)
	}
	return {}
}

// Free an unfrozen build tree (expand failure path).
@(private)
_build_node_destroy :: proc(bn: ^_Build_Node, allocator: runtime.Allocator) {
	if bn == nil {
		return
	}
	for kid in bn.static_kids {
		_build_node_destroy(kid, allocator)
	}
	_build_node_destroy(bn.param, allocator)
	_build_node_destroy(bn.catch_all, allocator)
	delete(bn.static_keys)
	delete(bn.static_kids)
	free(bn, allocator)
}

// Freeze build tree into Segment_Node tree; tracks nodes for destroy.
@(private)
_freeze_node :: proc(
	bn: ^_Build_Node,
	allocator: runtime.Allocator,
	nodes: ^[dynamic]^Segment_Node,
) -> ^Segment_Node {
	if bn == nil {
		return nil
	}
	n := new(Segment_Node, allocator)
	append(nodes, n)

	n.static_keys = make([]string, len(bn.static_keys), allocator)
	n.static_kids = make([]^Segment_Node, len(bn.static_kids), allocator)
	for i in 0 ..< len(bn.static_keys) {
		n.static_keys[i] = bn.static_keys[i]
		n.static_kids[i] = _freeze_node(bn.static_kids[i], allocator, nodes)
	}
	n.param_name = bn.param_name
	n.param = _freeze_node(bn.param, allocator, nodes)
	n.catch_name = bn.catch_name
	n.catch_all = _freeze_node(bn.catch_all, allocator, nodes)
	n.has_leaf = bn.has_leaf
	n.leaf = bn.leaf

	delete(bn.static_keys)
	delete(bn.static_kids)
	free(bn, allocator)
	return n
}

@(private)
_static_lookup :: proc(node: ^Segment_Node, key: string) -> ^Segment_Node {
	lo, hi := 0, len(node.static_keys)
	for lo < hi {
		mid := int(uint(lo + hi) >> 1)
		cmp := strings.compare(node.static_keys[mid], key)
		if cmp == 0 {
			return node.static_kids[mid]
		} else if cmp < 0 {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return nil
}

@(private)
_params_push :: proc(params: ^Path_Params, name, val: string) -> bool {
	if params.n >= MAX_PATH_PARAMS {
		return false
	}
	params.keys[params.n] = name
	params.vals[params.n] = val
	params.n += 1
	return true
}

// Walk path (already trailing-slash-normalized) against method trie.
// LAW MATCH-ALLOC: 0 heap/temp; params filled with path slices only.
segment_walk :: proc(
	root: ^Segment_Node,
	path: string,
	params: ^Path_Params,
) -> (
	leaf: Route_Leaf,
	ok: bool,
) {
	if root == nil {
		return {}, false
	}
	node := root

	if path == "/" || path == "" {
		if node.has_leaf {
			return node.leaf, true
		}
		if node.catch_all != nil {
			if !_params_push(params, node.catch_name, "") {
				return {}, false // overflow → miss, never truncated hit
			}
			if node.catch_all.has_leaf {
				return node.catch_all.leaf, true
			}
		}
		return {}, false
	}

	i := 1 // skip leading '/'
	plen := len(path)
	for i <= plen {
		j := i
		for j < plen && path[j] != '/' {
			j += 1
		}
		// Empty segment from '//' — miss (no collapse).
		if j == i {
			return {}, false
		}
		seg := path[i:j]
		more := j < plen

		// 1) static > 2) param > 3) catch-all
		if child := _static_lookup(node, seg); child != nil {
			node = child
			if !more {
				if node.has_leaf {
					return node.leaf, true
				}
				if node.catch_all != nil {
					if !_params_push(params, node.catch_name, "") {
						return {}, false
					}
					if node.catch_all.has_leaf {
						return node.catch_all.leaf, true
					}
				}
				return {}, false
			}
			i = j + 1
			continue
		}

		if node.param != nil {
			if !_params_push(params, node.param_name, seg) {
				return {}, false
			}
			node = node.param
			if !more {
				if node.has_leaf {
					return node.leaf, true
				}
				if node.catch_all != nil {
					if !_params_push(params, node.catch_name, "") {
						return {}, false
					}
					if node.catch_all.has_leaf {
						return node.catch_all.leaf, true
					}
				}
				return {}, false
			}
			i = j + 1
			continue
		}

		if node.catch_all != nil {
			rem := path[i:]
			if !_params_push(params, node.catch_name, rem) {
				return {}, false
			}
			if node.catch_all.has_leaf {
				return node.catch_all.leaf, true
			}
			return {}, false
		}

		return {}, false
	}

	return {}, false
}

@(private)
segment_walk_exists :: proc(root: ^Segment_Node, path: string) -> bool {
	probe: Path_Params
	_, ok := segment_walk(root, path, &probe)
	return ok
}
