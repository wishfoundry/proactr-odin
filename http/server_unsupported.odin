#+build !linux
#+build !darwin
#+build !freebsd
#+build !openbsd
#+build !netbsd
#+build !windows
package http

// No proactr completion backend for this OS (see proactr ring_backend_name).

import "core:log"
import "core:net"

import proactr "../proactr"

@(private)
host_listen_bind :: proc(s: ^Server, endpoint: net.Endpoint) -> proactr.Error {
	_ = s
	_ = endpoint
	return .Unsupported
}

@(private)
host_worker_attach_listen :: proc(s: ^Server) -> bool {
	_ = s
	log.error("host_worker_attach_listen: no I/O backend for this OS")
	return false
}

@(private)
server_close_listen_sockets :: proc(s: ^Server) {
	s.tcp_sock = {}
}

@(private)
conn_reactor_io_in_flight :: proc(c: ^Connection) -> bool {
	_ = c
	return false
}

@(private)
conn_close_finish :: proc(c: ^Connection) {
	net.close(c.socket)
	if c.fixed_idx >= 0 && td != nil {
		_ = proactr.ring_file_clear(&td.ring, c.fixed_idx)
		c.fixed_idx = -1
	}
	connection_destroy(c)
}

@(private)
host_worker_enter :: proc(s: ^Server) -> bool {
	_ = s
	return false
}

@(private)
host_accept_is_unsupported_multishot :: proc(result: i32) -> bool {
	_ = result
	return false
}
