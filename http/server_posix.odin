#+build darwin, freebsd, openbsd, netbsd
package http

// POSIX host helpers for proactr/kqueue: REUSEPORT listen + nonblocking sockets.

import "core:c"
import "core:log"
import "core:net"
import "core:sys/posix"

import proactr "../proactr"

// SO_REUSEPORT (BSD/Darwin). Not in core:net Socket_Option for posix.
_SO_REUSEPORT :: c.int(0x0200)

@(private)
host_listen_reuseport :: proc(
	endpoint: net.Endpoint,
	backlog: int = HOST_LISTEN_BACKLOG,
) -> (sock: net.TCP_Socket, err: proactr.Error) {
	family := net.family_from_endpoint(endpoint)
	any_sock, cerr := net.create_socket(family, .TCP)
	if cerr != nil {
		log.errorf("create_socket: %v", cerr)
		return {}, .Init_Failed
	}
	tsock := any_sock.(net.TCP_Socket)
	fd := posix.FD(tsock)

	if net.set_option(any_sock, .Reuse_Address, true) != nil {
		log.errorf("set_option Reuse_Address failed")
		net.close(tsock)
		return {}, .Init_Failed
	}

	// Multi-worker: SO_REUSEPORT (best-effort).
	one: c.int = 1
	if posix.setsockopt(
		fd,
		posix.SOL_SOCKET,
		posix.Sock_Option(_SO_REUSEPORT),
		&one,
		size_of(one),
	) != .OK {
		log.debugf("setsockopt REUSEPORT: %v (continuing; use WORKERS=1 if bind fails)", posix.errno())
	}

	if berr := net.bind(any_sock, endpoint); berr != nil {
		log.errorf("bind: %v", berr)
		net.close(tsock)
		return {}, .Init_Failed
	}

	if posix.listen(fd, c.int(backlog)) != .OK {
		log.errorf("listen: %v", posix.errno())
		net.close(tsock)
		return {}, .Init_Failed
	}

	// kqueue proactor requires nonblocking descriptors.
	if net.set_blocking(any_sock, false) != nil {
		log.errorf("set_blocking(false) failed")
		net.close(tsock)
		return {}, .Init_Failed
	}

	return tsock, .None
}

@(private)
host_accept_is_unsupported_multishot :: proc(result: i32) -> bool {
	_ = result
	return false
}
