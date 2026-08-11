package client

import "core:fmt"
import "core:mem"
import "core:strconv"
import "core:strings" // header parse

import proactr "../proactr"

// Clear HTTP/1.1 one-shot over an already-connected TCP fd using proactr send/recv.
// Takes ownership of `fd` (closed by job transport free / cancel).
// v1 framing: status + headers; Content-Length body or read-until-close.
// Chunked transfer-encoding → Protocol error.
h1_clear_request_blocking :: proc(
	rt: ^Client_Runtime,
	fd: i32,
	method, host, path: string,
	port: int,
	body: []u8,
	max_body: int,
	timeout_ms: int,
	allocator: mem.Allocator,
) -> (Response, Http_Error) {
	if rt == nil || !rt.inited || rt.ring == nil {
		return {}, .Not_Configured
	}
	if fd < 0 {
		return {}, .Connect_Failed
	}

	Wait :: struct {
		done: bool,
		res:  Response,
		err:  Http_Error,
	}
	wait: Wait

	job := job_alloc(rt)
	job.fd = fd
	job.max_body = max_body if max_body > 0 else DEFAULT_MAX_RESPONSE_BODY
	// Result clones use caller allocator; wire buffers always runtime.allocator.
	job.allocator = allocator
	job.result.headers.allocator = allocator
	job.result.body.allocator = allocator
	job.user = rawptr(&wait)
	job.on_done = proc(user: rawptr, res: Response, err: Http_Error) {
		w := (^Wait)(user)
		w.res = res
		w.err = err
		w.done = true
	}

	// Build request directly into job.tx (recycled capacity).
	_job_build_h1_request(&job.tx, method, host, path, port, body)

	job.phase = .Sending
	job.tx_off = 0
	if e := _job_submit_send(job); e != .None {
		// Job not yet in flight — free manually.
		job.on_done = nil
		job_free_transport(job)
		job_free(rt, job)
		return {}, e
	}

	perr := runtime_pump_until(rt, &wait.done, timeout_ms)
	if !wait.done {
		// Timeout / pump error: cancel (sync on_done). Drain without quiet-wait tax.
		if job.live && !job.done_fired {
			job_cancel(job, false)
		}
		_ = runtime_drain(rt, 32, 0)
		if wait.err == .None {
			wait.err = perr if perr != .None else .Timeout
		}
	}
	return wait.res, wait.err
}

// Start clear H1 on `fd` without pumping (for get_async_runtime tests).
// Caller must pump `rt` until job completes. Takes ownership of fd.
h1_clear_request_start :: proc(
	rt: ^Client_Runtime,
	fd: i32,
	method, host, path: string,
	port: int,
	body: []u8,
	max_body: int,
	user: rawptr,
	on_done: proc(user: rawptr, res: Response, err: Http_Error),
	allocator: mem.Allocator,
) -> (^Client_Job, Http_Error) {
	if rt == nil || !rt.inited || rt.ring == nil {
		return nil, .Not_Configured
	}
	if fd < 0 {
		return nil, .Connect_Failed
	}

	job := job_alloc(rt)
	job.fd = fd
	job.max_body = max_body if max_body > 0 else DEFAULT_MAX_RESPONSE_BODY
	// Result clones use caller allocator; wire buffers always runtime.allocator.
	job.allocator = allocator
	job.result.headers.allocator = allocator
	job.result.body.allocator = allocator
	job.user = user
	job.on_done = on_done

	_job_build_h1_request(&job.tx, method, host, path, port, body)

	job.phase = .Sending
	job.tx_off = 0
	if e := _job_submit_send(job); e != .None {
		job.on_done = nil
		job_free_transport(job)
		job_free(rt, job)
		return nil, e
	}
	return job, .None
}

@(private)
_job_build_h1_request :: proc(
	tx: ^[dynamic]u8,
	method, host, path: string,
	port: int,
	body: []u8,
	scheme: string = "http",
) {
	clear(tx)
	req_path := path if len(path) > 0 else "/"
	auth := format_authority(scheme, host, port)
	// Single long-lived image in tx (no dual permanent buffers).
	reserve(tx, len(method) + len(req_path) + len(auth) + len(body) + 96)
	// Scratch line into temp, append into tx.
	line: [512]u8
	n := len(fmt.bprintf(line[:], "%s %s HTTP/1.1\r\n", method, req_path))
	append(tx, ..line[:n])
	n = len(fmt.bprintf(line[:], "host: %s\r\n", auth))
	append(tx, ..line[:n])
	append(tx, ..transmute([]u8)string("connection: close\r\n"))
	n = len(fmt.bprintf(line[:], "user-agent: %s\r\n", DEFAULT_USER_AGENT))
	append(tx, ..line[:n])
	if len(body) > 0 {
		n = len(fmt.bprintf(line[:], "content-length: %d\r\n", len(body)))
		append(tx, ..line[:n])
	}
	append(tx, ..transmute([]u8)string("\r\n"))
	if len(body) > 0 {
		append(tx, ..body)
	}
}

@(private)
_job_parse_headers :: proc(job: ^Client_Job) -> Http_Error {
	sep := job.header_sep
	if sep < 0 do return .Protocol
	head := string(job.rx[:sep])

	job.result.version = .Http1
	job.result.headers.allocator = job.allocator
	job.result.body.allocator = job.allocator

	lines := strings.split(head, "\r\n", context.temp_allocator)
	if len(lines) == 0 do return .Protocol

	sp := strings.index_byte(lines[0], ' ')
	if sp < 0 do return .Protocol
	rest := lines[0][sp + 1:]
	code_end := strings.index_byte(rest, ' ')
	code_str := rest if code_end < 0 else rest[:code_end]
	code, cok := strconv.parse_int(code_str)
	if !cok do return .Protocol
	job.result.status = Status(code)

	job.content_length = -1 // until close unless CL present
	for line in lines[1:] {
		ci := strings.index_byte(line, ':')
		if ci < 0 do continue
		name := strings.trim_space(line[:ci])
		val := strings.trim_space(line[ci + 1:])
		append(
			&job.result.headers,
			Header {
				name        = strings.clone(name, job.allocator),
				value       = strings.clone(val, job.allocator),
				name_owned  = true,
				value_owned = true,
			},
		)
		nl := strings.to_lower(name, context.temp_allocator)
		vl := strings.to_lower(val, context.temp_allocator)
		if nl == "content-length" {
			if n, ok := strconv.parse_int(val); ok {
				if n < 0 do return .Protocol
				if n > job.max_body do return .Body_Too_Large
				job.content_length = n
			}
		} else if nl == "transfer-encoding" && strings.contains(vl, "chunked") {
			// v1: not supported on clear proactr path
			return .Protocol
		}
	}
	return .None
}

@(private)
_job_materialize_body :: proc(job: ^Client_Job) -> Http_Error {
	if job.header_sep < 0 do return .Protocol
	body_start := job.header_sep + 4
	if body_start > len(job.rx) do return .Protocol
	body := job.rx[body_start:]
	if job.content_length >= 0 {
		if len(body) < job.content_length do return .Closed
		body = body[:job.content_length]
	}
	if len(body) > job.max_body do return .Body_Too_Large
	if len(body) > 0 {
		append(&job.result.body, ..body)
	}
	return .None
}
