package http

import "core:log"
import "core:net"
import "core:strings"

// Fixed-capacity path captures and request-scoped context bag.
// LAW MATCH-ALLOC: match core never heap/temps for these; only n is cleared.

MAX_PATH_PARAMS :: 16
MAX_CTX_ENTRIES :: 16

Path_Params :: struct {
	n:    int,
	keys: [MAX_PATH_PARAMS]string,
	vals: [MAX_PATH_PARAMS]string, // views into req.url.path (or normalized subslice)
}

Request_Ctx_Kind :: enum u8 {
	Ptr,
	String,
}

Request_Ctx_Entry :: struct {
	key:  string,
	kind: Request_Ctx_Kind,
	ptr:  rawptr, // .Ptr
	str:  string, // .String — points at request-arena clone
}

Request_Ctx :: struct {
	n:       int,
	entries: [MAX_CTX_ENTRIES]Request_Ctx_Entry,
}

// Named path capture. No allocation. #optional_ok for `v := param(req, "id") or_return` style.
param :: proc(req: ^Request, name: string) -> (string, bool) #optional_ok {
	if req == nil {
		return "", false
	}
	for i in 0 ..< req.params.n {
		if req.params.keys[i] == name {
			return req.params.vals[i], true
		}
	}
	return "", false
}

// Percent-decode a path param (allocates). Raw default is param().
param_decoded :: proc(
	req: ^Request,
	name: string,
	allocator := context.temp_allocator,
) -> (
	val: string,
	ok: bool,
) {
	raw, pok := param(req, name)
	if !pok {
		return "", false
	}
	return net.percent_decode(raw, allocator)
}

// Store a raw pointer in the request context bag. false on overflow (n == MAX).
req_ctx_set :: proc(req: ^Request, key: string, value: rawptr) -> bool {
	if req == nil {
		return false
	}
	// Upsert existing key.
	for i in 0 ..< req.ctx.n {
		if req.ctx.entries[i].key == key {
			req.ctx.entries[i].kind = .Ptr
			req.ctx.entries[i].ptr = value
			req.ctx.entries[i].str = ""
			return true
		}
	}
	if req.ctx.n >= MAX_CTX_ENTRIES {
		when ODIN_DEBUG {
			log.warn("req_ctx_set overflow: MAX_CTX_ENTRIES reached")
		}
		return false
	}
	e := &req.ctx.entries[req.ctx.n]
	e.key = key
	e.kind = .Ptr
	e.ptr = value
	e.str = ""
	req.ctx.n += 1
	return true
}

req_ctx_get :: proc(req: ^Request, key: string) -> (rawptr, bool) {
	if req == nil {
		return nil, false
	}
	for i in 0 ..< req.ctx.n {
		if req.ctx.entries[i].key == key && req.ctx.entries[i].kind == .Ptr {
			return req.ctx.entries[i].ptr, true
		}
	}
	return nil, false
}

// Clone value into allocator (exchange/request arena) and store as .String.
req_ctx_set_string :: proc(
	req: ^Request,
	key: string,
	value: string,
	allocator := context.temp_allocator,
) -> bool {
	if req == nil {
		return false
	}
	cloned := strings.clone(value, allocator)
	for i in 0 ..< req.ctx.n {
		if req.ctx.entries[i].key == key {
			req.ctx.entries[i].kind = .String
			req.ctx.entries[i].str = cloned
			req.ctx.entries[i].ptr = nil
			return true
		}
	}
	if req.ctx.n >= MAX_CTX_ENTRIES {
		when ODIN_DEBUG {
			log.warn("req_ctx_set_string overflow: MAX_CTX_ENTRIES reached")
		}
		return false
	}
	e := &req.ctx.entries[req.ctx.n]
	e.key = key
	e.kind = .String
	e.str = cloned
	e.ptr = nil
	req.ctx.n += 1
	return true
}

req_ctx_get_string :: proc(req: ^Request, key: string) -> (string, bool) {
	if req == nil {
		return "", false
	}
	for i in 0 ..< req.ctx.n {
		if req.ctx.entries[i].key == key && req.ctx.entries[i].kind == .String {
			return req.ctx.entries[i].str, true
		}
	}
	return "", false
}

// Host exchange boundary: n=0 only (do not memset keys).
req_ctx_reset :: proc(req: ^Request) {
	if req != nil {
		req.ctx.n = 0
	}
}

path_params_clear :: proc(params: ^Path_Params) {
	if params != nil {
		params.n = 0
	}
}
