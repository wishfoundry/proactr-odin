package http

import "core:strings"

// Minimal router: exact-path GET/POST table. Lua-pattern routes can land later
// (laytan parity) once the host is live.

Method :: enum {
	Get,
	Post,
	Put,
	Delete,
	Head,
	Options,
	Patch,
}

Route :: struct {
	method:  Method,
	path:    string,
	handler: Handler,
}

Router :: struct {
	routes: [dynamic]Route,
}

// Scaffold: single active router for router_handler dispatch (no closures in Odin).
// Multi-server hosts should use a Handler that carries user_data later.
@(private)
_active_router: ^Router

router_init :: proc(r: ^Router, allocator := context.allocator) {
	r.routes = make([dynamic]Route, allocator)
}

router_destroy :: proc(r: ^Router) {
	delete(r.routes)
}

route_get :: proc(r: ^Router, path: string, h: Handler) {
	append(&r.routes, Route{method = .Get, path = path, handler = h})
}

route_post :: proc(r: ^Router, path: string, h: Handler) {
	append(&r.routes, Route{method = .Post, path = path, handler = h})
}

router_handler :: proc(r: ^Router) -> Handler {
	_active_router = r
	return _router_dispatch
}

@(private)
_router_dispatch :: proc(req: ^Request, res: ^Response) {
	r := _active_router
	if r == nil {
		respond_status(res, .Internal_Server_Error)
		return
	}
	m := method_from_string(req.method)
	for route in r.routes {
		if route.method == m && route.path == req.path {
			route.handler(req, res)
			return
		}
	}
	for route in r.routes {
		if route.method == m && paths_equal(route.path, req.path) {
			route.handler(req, res)
			return
		}
	}
	respond_status(res, .Not_Found)
}

@(private)
method_from_string :: proc(s: string) -> Method {
	switch strings.to_upper(s, context.temp_allocator) {
	case "GET":
		return .Get
	case "POST":
		return .Post
	case "PUT":
		return .Put
	case "DELETE":
		return .Delete
	case "HEAD":
		return .Head
	case "OPTIONS":
		return .Options
	case "PATCH":
		return .Patch
	}
	return .Get
}

@(private)
paths_equal :: proc(a, b: string) -> bool {
	if a == b {
		return true
	}
	if len(a) + 1 == len(b) && b[len(b) - 1] == '/' && a == b[:len(a)] {
		return true
	}
	if len(b) + 1 == len(a) && a[len(a) - 1] == '/' && b == a[:len(b)] {
		return true
	}
	return false
}
