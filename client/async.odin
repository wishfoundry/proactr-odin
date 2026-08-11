package client

import "core:net"

import http "../http"

// get_async — handler-path entry. Binds the inbound exchange (Stream_Slot) from res.
// Requires worker Client_Runtime installed (server worker boot via client_bridge).
// user must NOT be request-temp arena (Option A — copy small ctx into job/runtime allocator).
//
// Dialer policy (proactr): Options.dialer must supply a *clear nonblocking TCP* hop
// (or nil → default clear TCP). Stream-TLS dialers are for dial/request only.
// H3 uses quic residual dial (not Dialer). No redirect following (v1).
get_async :: proc(
	res: ^http.Response,
	url: string,
	opts: Options = {},
	user: rawptr = nil,
	on_done: proc(user: rawptr, upstream: Response, err: Http_Error) = nil,
	allocator := context.allocator,
) -> (job: ^Client_Job, err: Http_Error) {
	rt := worker_runtime()
	if rt == nil || !rt.inited || !http_worker_active {
		return nil, .Not_Configured
	}
	if res == nil {
		return nil, .Not_Configured
	}
	slot := res._slot
	if slot == nil && res._conn != nil {
		slot = &res._conn.slot
	}
	if slot == nil {
		return nil, .Not_Configured
	}

	job, err = get_async_runtime(rt, url, opts, user, on_done, allocator)
	if err != .None {
		return nil, err
	}
	job_link_slot(job, slot)
	return job, .None
}

// get_async_runtime starts a GET on an explicit runtime (tests / CLI).
// Caller must pump `rt` until on_done fires.
get_async_runtime :: proc(
	rt: ^Client_Runtime,
	url: string,
	opts: Options = {},
	user: rawptr = nil,
	on_done: proc(user: rawptr, upstream: Response, err: Http_Error) = nil,
	allocator := context.allocator,
) -> (job: ^Client_Job, err: Http_Error) {
	if rt == nil || !rt.inited {
		return nil, .Not_Configured
	}
	t, ok := parse_target(url)
	if !ok do return nil, .Invalid_Url

	if t.scheme == "http" && opts.version == .Http2 {
		return nil, .Unsupported_Version
	}

	max_body := _resolve_max_body(opts.max_response_body)
	path := t.path if len(t.path) > 0 else "/"
	timeout_ms := opts.timeout

	if opts.version == .Http3 {
		if t.scheme != "https" {
			return nil, .Unsupported_Version
		}
		return h3_request_start(
			rt,
			"GET",
			t.host,
			path,
			t.port,
			nil,
			max_body,
			opts.insecure,
			timeout_ms,
			user,
			on_done,
			allocator,
		)
	}

	if _opts_prefer_h3_first(opts, t.scheme) {
		probe := _prefer_h3_probe_ms(opts.timeout)
		job, herr := h3_request_start(
			rt,
			"GET",
			t.host,
			path,
			t.port,
			nil,
			max_body,
			opts.insecure,
			timeout_ms,
			user,
			on_done,
			allocator,
			probe,
		)
		if herr == .None {
			return job, .None
		}
	}

	if t.scheme != "http" && t.scheme != "https" {
		return nil, .Unsupported_Version
	}
	if t.scheme == "http" && opts.version != .Auto && opts.version != .Http1 {
		return nil, .Unsupported_Version
	}
	if t.scheme == "https" &&
	   opts.version != .Auto &&
	   opts.version != .Http1 &&
	   opts.version != .Http2 {
		return nil, .Unsupported_Version
	}

	hop, herr := hop_dial_clear_fd(t, opts, allocator)
	if herr != .None do return nil, herr
	return get_async_hop(rt, nil, hop, "GET", path, max_body, opts, user, on_done, allocator)
}

// get_async_hop starts clear H1 or TLS mem-BIO on a pre-dialed clear-FD hop.
// Takes FD ownership via hop_take_fd. hop must be clear TCP (not TLS-complete stream).
// If inbound_res != nil, binds Stream_Slot (handler path); else no slot link.
get_async_hop :: proc(
	rt: ^Client_Runtime,
	inbound_res: ^http.Response,
	hop: Hop,
	method: string = "GET",
	path: string = "/",
	max_body: int = 0,
	opts: Options = {},
	user: rawptr = nil,
	on_done: proc(user: rawptr, upstream: Response, err: Http_Error) = nil,
	allocator := context.allocator,
) -> (job: ^Client_Job, err: Http_Error) {
	if rt == nil || !rt.inited {
		return nil, .Not_Configured
	}
	hop := hop
	if !hop.meta.nonblocking || hop.fd < 0 {
		// Allow take if fd set but flag wrong after dialer.
		if hop.fd < 0 {
			hop_close(&hop)
			return nil, .Not_Configured
		}
	}
	fd := hop_take_fd(&hop)
	// Drop any remaining hop resources (should not close fd).
	hop_close(&hop)
	if fd < 0 {
		return nil, .Connect_Failed
	}

	max_body := max_body if max_body > 0 else _resolve_max_body(opts.max_response_body)
	path := path if len(path) > 0 else "/"
	method := method if len(method) > 0 else "GET"
	host := hop.meta.host
	port := hop.meta.port
	if len(host) == 0 {
		net.close(net.TCP_Socket(fd))
		return nil, .Invalid_Url
	}

	scheme := hop.meta.scheme
	if len(scheme) == 0 {
		scheme = "https" if opts.version != .Http1 else "http"
	}

	if scheme == "https" || opts.version == .Http2 {
		job, err = tls_request_start(
			rt,
			fd,
			method,
			host,
			path,
			port,
			nil,
			max_body,
			opts.insecure,
			opts.version,
			user,
			on_done,
			allocator,
		)
	} else {
		job, err = h1_clear_request_start(
			rt,
			fd,
			method,
			host,
			path,
			port,
			nil,
			max_body,
			user,
			on_done,
			allocator,
		)
	}
	if err != .None {
		return nil, err
	}
	if inbound_res != nil {
		slot := inbound_res._slot
		if slot == nil && inbound_res._conn != nil {
			slot = &inbound_res._conn.slot
		}
		if slot != nil {
			job_link_slot(job, slot)
		}
	}
	return job, .None
}
