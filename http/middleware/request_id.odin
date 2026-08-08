package middleware

// Request-ID middleware: propagate or generate X-Request-Id (configurable header).
// Sets the id on the response before calling next (readable via res.headers).
// Request headers are readonly — id is not written onto req.

import http ".."
import "base:runtime"
import "core:fmt"
import "core:math/rand"
import "core:sync"
import "core:time"

Request_Id_Opts :: struct {
	// Incoming/outgoing header name. Empty → "x-request-id".
	header: string,
	// When true, always generate a new id (ignore inbound).
	force_new: bool,
}

@(private)
Request_Id_State :: struct {
	opts:   Request_Id_Opts,
	next:   ^http.Handler,
	header: string,
}

@(private)
_rid_counter: u64

request_id :: proc(opts: Request_Id_Opts, next: ^http.Handler, allocator := context.allocator) -> http.Handler {
	assert(next != nil)
	st := new(Request_Id_State, allocator)
	st.opts = opts
	st.next = next
	st.header = opts.header if opts.header != "" else "x-request-id"
	h: http.Handler
	h.user_data = st
	h.next = next
	h.handle = _request_id_handle
	return h
}

request_id_layer :: proc(opts: Request_Id_Opts, allocator := context.allocator) -> Layer {
	p := new(Request_Id_Opts, allocator)
	p^ = opts
	return Layer{data = p, build = _request_id_layer_build}
}

@(private)
_request_id_layer_build :: proc(data: rawptr, next: ^http.Handler, allocator: runtime.Allocator) -> http.Handler {
	return request_id((^Request_Id_Opts)(data)^, next, allocator)
}

@(private)
_request_id_handle :: proc(h: ^http.Handler, req: ^http.Request, res: ^http.Response) {
	st := (^Request_Id_State)(h.user_data)
	hdr := st.header

	id: string
	if !st.opts.force_new {
		if v, ok := http.headers_get(req.headers, hdr); ok && len(v) > 0 && len(v) <= 128 {
			if _request_id_safe(v) {
				id = v
			}
		}
	}
	if id == "" {
		id = _request_id_generate()
	}

	// Clone into request allocator so the response header value stays valid through send.
	id_out := fmt.tprintf("%s", id)

	http.headers_set(&res.headers, hdr, id_out)
	call_next(st.next, req, res)
}

// Allow only unreserved token chars (no CR/LF/controls) to prevent header injection.
@(private)
_request_id_safe :: proc(s: string) -> bool {
	if len(s) == 0 || len(s) > 128 {
		return false
	}
	for i in 0 ..< len(s) {
		c := s[i]
		switch c {
		case 'A' ..= 'Z', 'a' ..= 'z', '0' ..= '9', '-', '_', '.', ':':
			continue
		case:
			return false
		}
	}
	return true
}

@(private)
_request_id_generate :: proc() -> string {
	n := sync.atomic_add(&_rid_counter, 1)
	t := u64(time.time_to_unix_nano(time.now()))
	x := t ~ (n << 17) ~ (n * 0x9E3779B97F4A7C15)
	x ~= rand.uint64()
	// tprintf → context.temp_allocator (request arena during handle).
	return fmt.tprintf("%016x", x)
}
