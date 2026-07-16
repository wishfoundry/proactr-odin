// Package http: proactor-hosted HTTP/1.1 types and server (fork of laytan/odin-http).
//
// Upstream baseline remains under vendor/laytan/odin-http for reactor/nbio benches.
// This package drives I/O exclusively through package proactr — not core:nbio.
package http

import "core:net"

import proactr "../proactr"

// Server is the proactor HTTP host.
Server :: struct {
	ring:      proactr.Ring,
	handler:   Handler,
	endpoint:  net.Endpoint,
	// listen_fd set after bind/listen (Linux).
	listen_fd: i32,
	// closed signals graceful stop.
	closed:    bool,
}

Handler :: #type proc(req: ^Request, res: ^Response)

Request :: struct {
	method:  string,
	target:  string, // raw request-target
	path:    string,
	query:   string,
	version: string,
	headers: Headers,
	// body filled when fully read; streaming later.
	body:    []u8,
	// conn / scratch owned by host.
	_conn:   rawptr,
}

Response :: struct {
	status:  Status,
	headers: Headers,
	// body or sendfile path — v0: in-memory only.
	body:    []u8,
	_conn:   rawptr,
	_done:   bool,
}

Status :: enum u16 {
	OK                       = 200,
	Bad_Request              = 400,
	Not_Found                = 404,
	Method_Not_Allowed       = 405,
	Request_Entity_Too_Large = 413,
	Internal_Server_Error    = 500,
}

Headers :: map[string]string

// listen_and_serve binds endpoint and runs the proactor completion loop.
// Returns when the server is closed or a fatal ring error occurs.
listen_and_serve :: proc(
	s: ^Server,
	handler: Handler,
	endpoint: net.Endpoint,
	entries: u32 = proactr.DEFAULT_ENTRIES,
) -> proactr.Error {
	s.handler = handler
	s.endpoint = endpoint
	if err := proactr.ring_init(&s.ring, entries); err != .None {
		return err
	}
	defer proactr.ring_destroy(&s.ring)

	// TODO: socket/bind/listen → s.listen_fd; submit_accept; completion loop.
	// v0 returns Unsupported so callers know the host is not live yet.
	return .Unsupported
}

server_close :: proc(s: ^Server) {
	s.closed = true
}

respond_plain :: proc(res: ^Response, body: string, status: Status = .OK) {
	res.status = status
	res.body = transmute([]u8)body
	res._done = true
}

respond_status :: proc(res: ^Response, status: Status) {
	res.status = status
	res.body = nil
	res._done = true
}
