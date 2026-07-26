#+build !linux
#+build !darwin
#+build !freebsd
#+build !openbsd
#+build !netbsd
package http

import "core:net"

import proactr "../proactr"

// Remaining platforms (e.g. pure Windows host not yet wired for HTTP).
@(private)
host_listen_reuseport :: proc(
	endpoint: net.Endpoint,
	backlog: int = HOST_LISTEN_BACKLOG,
) -> (sock: net.TCP_Socket, err: proactr.Error) {
	_ = endpoint
	_ = backlog
	return {}, .Unsupported
}

@(private)
host_accept_is_unsupported_multishot :: proc(result: i32) -> bool {
	_ = result
	return false
}
