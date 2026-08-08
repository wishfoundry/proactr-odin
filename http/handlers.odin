package http

import "core:net"
import "core:strconv"
import "core:sync"
import "core:time"

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

Rate_Limit_On_Limit :: struct {
	user_data: rawptr,
	on_limit:  proc(req: ^Request, res: ^Response, user_data: rawptr),
}

// Convenience method to create a Rate_Limit_On_Limit that writes the given message.
rate_limit_message :: proc(message: ^string) -> Rate_Limit_On_Limit {
	return Rate_Limit_On_Limit{user_data = message, on_limit = proc(_: ^Request, res: ^Response, user_data: rawptr) {
		message := (^string)(user_data)
		body_set(res, message^)
		respond(res)
	}}
}

Rate_Limit_Opts :: struct {
	window:   time.Duration,
	max:      int,

	// Optional handler to call when a request is being rate-limited, allows you to customize the response.
	on_limit: Maybe(Rate_Limit_On_Limit),
}

Rate_Limit_Data :: struct {
	opts:       ^Rate_Limit_Opts,
	next_sweep: time.Time,
	hits:       map[net.Address]int,
	mu:         sync.Mutex,
}

rate_limit_destroy :: proc(data: ^Rate_Limit_Data) {
	sync.guard(&data.mu)
	delete(data.hits)
}

// Basic rate limit based on IP address.
rate_limit :: proc(data: ^Rate_Limit_Data, next: ^Handler, opts: ^Rate_Limit_Opts, allocator := context.allocator) -> Handler {
	assert(next != nil)

	h: Handler
	h.next = next

	data.opts = opts
	data.hits = make(map[net.Address]int, 16, allocator)
	data.next_sweep = time.time_add(time.now(), opts.window)
	h.user_data = data

	h.handle = proc(h: ^Handler, req: ^Request, res: ^Response) {
		data := (^Rate_Limit_Data)(h.user_data)

		sync.lock(&data.mu)

		// PERF: if this is not performing, we could run a thread that sweeps on a regular basis.
		if time.since(data.next_sweep) > 0 {
			clear(&data.hits)
			data.next_sweep = time.time_add(time.now(), data.opts.window)
		}

		// Count this request; limit when count would exceed max (allows exactly max).
		// max <= 0 → every request is limited.
		hits := data.hits[req.client.address]
		if data.opts.max <= 0 || hits >= data.opts.max {
			sync.unlock(&data.mu)
			res.status = .Too_Many_Requests

			retry_dur := i64(time.diff(time.now(), data.next_sweep) / time.Second)
			if retry_dur < 0 {
				retry_dur = 0
			}
			buf := make([]byte, 32, context.temp_allocator)
			retry_str := strconv.write_int(buf, retry_dur, 10)
			headers_set_unsafe(&res.headers, "retry-after", retry_str)

			if on, ok := data.opts.on_limit.(Rate_Limit_On_Limit); ok {
				on.on_limit(req, res, on.user_data)
			} else {
				respond(res)
			}
			return
		}
		data.hits[req.client.address] = hits + 1
		sync.unlock(&data.mu)

		next := h.next.(^Handler)
		next.handle(next, req, res)
	}

	return h
}
