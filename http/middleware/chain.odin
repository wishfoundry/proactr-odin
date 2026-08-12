package middleware

// Handler chain builder and from_fn ergonomics.
// Model (proactor-aligned):
//   - Middleware is a Handler that may call next, respond, or submit I/O.
//   - Continuations are (callback, user) delivered by the proactr runtime — not a
//     public http.resume API.
//   - Request-scoped state uses the request allocator (conn temp arena).
//   - After-behavior uses http.response_on_respond / on_complete (host-fired).
// Chain nodes are individually heap-allocated so ^Handler next pointers never
// move (unlike inject_at into a [dynamic]Handler array).

import http ".."
import "base:runtime"

// from_fn / call_next

// Build a Handler from (req, res, next). Allocates with allocator.
// next must outlive the returned Handler (Chain nodes or static storage).
from_fn :: proc(
	f: proc(req: ^http.Request, res: ^http.Response, next: ^http.Handler),
	next: ^http.Handler,
	allocator := context.allocator,
) -> http.Handler {
	return http.from_fn(f, next, allocator)
}

// Call next.handle if next != nil.
call_next :: proc(next: ^http.Handler, req: ^http.Request, res: ^http.Response) {
	if next != nil {
		next.handle(next, req, res)
	}
}

// Layer — data + build proc (no closures; Odin-friendly)

// Setup-time layer: build(data, next) → wrapping Handler.
// data is optional heap opts; chain_use auto-tracks non-nil data for free.
// free_data: optional deep free (CORS owned strings); nil → free(data) only.
// Builders take http.Layer — use to_http_layer to adapt.
Layer :: struct {
	data:       rawptr,
	build:      proc(data: rawptr, next: ^http.Handler, allocator: runtime.Allocator) -> http.Handler,
	free_data:  proc(data: rawptr, allocator: runtime.Allocator),
	free_built: proc(h: ^http.Handler, allocator: runtime.Allocator), // deep free Handler.user_data
}

// Adapt middleware.Layer → http.Layer for Builder APIs (same layout).
to_http_layer :: proc(l: Layer) -> http.Layer {
	return http.Layer {
		data = l.data,
		build = l.build,
		free_data = l.free_data,
		free_built = l.free_built,
	}
}

@(private)
Tracked_Data :: struct {
	data: rawptr,
	free: proc(data: rawptr, allocator: runtime.Allocator),
}

// Chain — onion stack with heap-stable Handler nodes

@(private)
Tracked_Handler_Free :: struct {
	h:    ^http.Handler,
	free: proc(h: ^http.Handler, allocator: runtime.Allocator),
}

// Owns heap Handler nodes. root is outermost (server entry).
// nodes[0] is always the terminal; later entries are outer layers.
Chain :: struct {
	allocator:     runtime.Allocator,
	root:          ^http.Handler, // outermost; nil if empty
	nodes:         [dynamic]^http.Handler,
	layer_data:    [dynamic]Tracked_Data,
	handler_frees: [dynamic]Tracked_Handler_Free, // free_built (rate_limit/cors/security deep free)
}

// Initialize with the terminal (innermost) handler. Call chain_use to wrap outward.
chain_init :: proc(c: ^Chain, terminal: http.Handler, allocator := context.allocator) {
	c.allocator = allocator
	c.nodes = make([dynamic]^http.Handler, 0, 8, allocator)
	c.layer_data = make([dynamic]Tracked_Data, 0, 8, allocator)
	c.handler_frees = make([dynamic]Tracked_Handler_Free, 0, 8, allocator)
	node := new(http.Handler, allocator)
	node^ = terminal
	append(&c.nodes, node)
	c.root = node
}

chain_destroy :: proc(c: ^Chain) {
	// free_built first (rate_limit store, CORS/security deep free). Must nil user_data.
	for tf in c.handler_frees {
		if tf.h == nil || tf.free == nil {
			continue
		}
		tf.free(tf.h, c.allocator)
	}
	delete(c.handler_frees)

	// Free remaining wrap user_data (logger/from_fn). Terminal app data untouched.
	for i in 1 ..< len(c.nodes) {
		h := c.nodes[i]
		if h == nil || h.user_data == nil {
			continue
		}
		// Legacy special-cases if free_built was not registered.
		if h.handle == _cors_handle {
			cors_destroy(h, c.allocator)
			continue
		}
		if h.handle == _security_handle {
			security_headers_destroy(h, c.allocator)
			continue
		}
		free(h.user_data, c.allocator)
		h.user_data = nil
	}
	for td in c.layer_data {
		if td.data == nil {
			continue
		}
		if td.free != nil {
			td.free(td.data, c.allocator)
		} else {
			free(td.data, c.allocator)
		}
	}
	for h in c.nodes {
		if h != nil {
			free(h, c.allocator)
		}
	}
	delete(c.layer_data)
	delete(c.nodes)
	c^ = {}
}

// Root handler value for Server / listen (outermost). next pointers stay on heap.
// Keep Chain alive for the server lifetime (do not chain_destroy while serving).
chain_handler :: proc(c: ^Chain) -> http.Handler {
	assert(c.root != nil)
	return c.root^
}

// Pointer to outermost heap node (stable until destroy).
chain_root_ptr :: proc(c: ^Chain) -> ^http.Handler {
	assert(c.root != nil)
	return c.root
}

// Wrap with a Layer. New outermost. next is always a heap-stable ^Handler.
chain_use :: proc(c: ^Chain, layer: Layer) {
	assert(c.root != nil)
	assert(layer.build != nil)
	if layer.data != nil {
		append(&c.layer_data, Tracked_Data{data = layer.data, free = layer.free_data})
	}
	built := layer.build(layer.data, c.root, c.allocator)
	node := new(http.Handler, c.allocator)
	node^ = built
	// Ensure Handler.next matches state.next for consistency.
	node.next = c.root
	if layer.free_built != nil {
		append(&c.handler_frees, Tracked_Handler_Free{h = node, free = layer.free_built})
	}
	append(&c.nodes, node)
	c.root = node
}

// Apply layers outer-first: layers[0] becomes the outermost handler.
chain_wrap :: proc(c: ^Chain, layers: []Layer) {
	for i := len(layers) - 1; i >= 0; i -= 1 {
		chain_use(c, layers[i])
	}
}

// Wrap with a custom (req, res, next) function. New outermost.
chain_use_fn :: proc(
	c: ^Chain,
	f: proc(req: ^http.Request, res: ^http.Response, next: ^http.Handler),
) {
	assert(c.root != nil)
	assert(f != nil)
	built := from_fn(f, c.root, c.allocator)
	node := new(http.Handler, c.allocator)
	node^ = built
	node.next = c.root
	append(&c.nodes, node)
	c.root = node
}
