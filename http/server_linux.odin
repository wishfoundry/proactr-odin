#+build linux
package http

// Linux-only: SO_REUSEPORT listen via raw core:sys/linux (net.set_option lacks Reuse_Port).

import "core:log"
import "core:net"
import "core:sys/linux"

import proactr "../proactr"

// host_listen_reuseport creates a TCP listen socket with SO_REUSEADDR + SO_REUSEPORT.
// Mirrors core:net _listen_tcp but sets REUSEPORT via raw linux.setsockopt before bind.
@(private)
host_listen_reuseport :: proc(
	endpoint: net.Endpoint,
	backlog: int = HOST_LISTEN_BACKLOG,
) -> (sock: net.TCP_Socket, err: proactr.Error) {
	family: linux.Address_Family
	addr: linux.Sock_Addr_Any
	switch a in endpoint.address {
	case net.IP4_Address:
		family = .INET
		addr = {
			ipv4 = {
				sin_family = .INET,
				sin_port   = u16be(endpoint.port),
				sin_addr   = ([4]u8)(a),
			},
		}
	case net.IP6_Address:
		family = .INET6
		addr = {
			ipv6 = {
				sin6_family = .INET6,
				sin6_port   = u16be(endpoint.port),
				sin6_addr   = transmute([16]u8)a,
			},
		}
	case:
		return {}, .Init_Failed
	}

	fd, errno := linux.socket(family, .STREAM, {.CLOEXEC}, .TCP)
	if errno != .NONE {
		log.errorf("socket: %v", errno)
		return {}, .Init_Failed
	}

	one: b32 = true
	if errno = linux.setsockopt(fd, linux.SOL_SOCKET, linux.Socket_Option.REUSEADDR, &one); errno != .NONE {
		linux.close(fd)
		log.errorf("setsockopt REUSEADDR: %v", errno)
		return {}, .Init_Failed
	}
	// SO_REUSEPORT: required for multi-worker listen.
	if errno = linux.setsockopt(fd, linux.SOL_SOCKET, linux.Socket_Option.REUSEPORT, &one); errno != .NONE {
		linux.close(fd)
		log.errorf("setsockopt REUSEPORT: %v", errno)
		return {}, .Init_Failed
	}

	if errno = linux.bind(fd, &addr); errno != .NONE {
		linux.close(fd)
		log.errorf("bind: %v", errno)
		return {}, .Init_Failed
	}
	if errno = linux.listen(fd, i32(backlog)); errno != .NONE {
		linux.close(fd)
		log.errorf("listen: %v", errno)
		return {}, .Init_Failed
	}
	return net.TCP_Socket(fd), .None
}

// host_accept_is_unsupported_multishot is true when accept failed because multishot
// is not supported (-EINVAL / -EOPNOTSUPP). Host falls back to single-shot.
@(private)
host_accept_is_unsupported_multishot :: proc(result: i32) -> bool {
	// Numeric errno avoids coupling the host loop to linux.Errno on every path.
	EINVAL :: 22
	EOPNOTSUPP :: 95
	return result == -EINVAL || result == -EOPNOTSUPP
}
