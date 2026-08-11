package http

Handler_Proc :: proc(handler: ^Handler, req: ^Request, res: ^Response)
Handle_Proc :: proc(req: ^Request, res: ^Response)

Handler :: struct {
	user_data: rawptr,
	next:      Maybe(^Handler),
	handle:    Handler_Proc,
}

// TODO: something like http.handler_with_body which gets the body before calling the handler.

handler :: proc(handle: Handle_Proc) -> Handler {
	h: Handler
	h.user_data = rawptr(handle)

	handle := proc(h: ^Handler, req: ^Request, res: ^Response) {
		p := (Handle_Proc)(h.user_data)
		p(req, res)
	}

	h.handle = handle
	return h
}

middleware_proc :: proc(next: Maybe(^Handler), handle: Handler_Proc) -> Handler {
	h: Handler
	h.next = next
	h.handle = handle
	return h
}

// Invoke h.next if present. No-op when next is nil (terminal layer without child).
handler_call_next :: proc(h: ^Handler, req: ^Request, res: ^Response) {
	if n, ok := h.next.?; ok && n != nil {
		n.handle(n, req, res)
	}
}

/*
Wrap a (req, res, next) function as a Handler. next is stored by pointer — caller
must keep it alive (e.g. chain nodes, static storage).

	inner := http.handler(app)
	outer := http.from_fn(proc(req: ^Request, res: ^Response, next: ^Handler) {
		// before
		next.handle(next, req, res)
		// after only if next responded synchronously
	}, &inner)

Prefer package middleware for stock layers and chain builders.
*/
from_fn :: proc(
	f: proc(req: ^Request, res: ^Response, next: ^Handler),
	next: ^Handler,
	allocator := context.allocator,
) -> Handler {
	assert(f != nil)
	assert(next != nil)
	state := new(From_Fn_State, allocator)
	state.f = f
	state.next = next
	h: Handler
	h.user_data = state
	h.next = next
	h.handle = proc(h: ^Handler, req: ^Request, res: ^Response) {
		st := (^From_Fn_State)(h.user_data)
		st.f(req, res, st.next)
	}
	return h
}

From_Fn_State :: struct {
	f:    proc(req: ^Request, res: ^Response, next: ^Handler),
	next: ^Handler,
}
