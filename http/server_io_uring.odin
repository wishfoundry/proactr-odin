#+build linux
package http

// Host backend: proactr io_uring (Linux).
// Per-worker SO_REUSEPORT listen; product I/O on the proactr ring.

import "core:log"
import "core:net"
import "core:sys/linux"

import proactr "../proactr"

// host_listen_bind: no process-wide listen; workers bind REUSEPORT at attach.
@(private)
host_listen_bind :: proc(s: ^Server, endpoint: net.Endpoint) -> proactr.Error {
	_ = s
	_ = endpoint
	return .None
}

@(private)
_io_uring_listen_reuseport :: proc(
	endpoint: net.Endpoint,
	backlog: int,
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

@(private)
host_worker_attach_listen :: proc(s: ^Server) -> bool {
	lfd, lerr := _io_uring_listen_reuseport(s.endpoint, s.opts.listen_backlog)
	if lerr != .None {
		log.errorf("listen REUSEPORT failed: %v", lerr)
		return false
	}
	td.listen_fd = lfd
	return true
}

@(private)
server_close_listen_sockets :: proc(s: ^Server) {
	if s.threads == nil {
		return
	}
	for &t in s.threads {
		if t.listen_fd != {} {
			net.close(t.listen_fd)
			t.listen_fd = {}
		}
	}
	s.tcp_sock = {}
}

@(private)
conn_reactor_io_in_flight :: proc(c: ^Connection) -> bool {
	if c.tls_ct_recv_inflight || c.reactor_read_armed {
		log.debugf("connection %i close deferred (recv interest in flight)", c.socket)
		return true
	}
	return false
}

@(private)
conn_close_finish :: proc(c: ^Connection) {
	_, err := proactr.submit_close(&td.ring, i32(c.socket), c, -1)
	if err != .None {
		log.errorf("submit_close failed: %v", err)
		net.close(c.socket)
		if c.fixed_idx >= 0 {
			_ = proactr.ring_file_clear(&td.ring, c.fixed_idx)
			c.fixed_idx = -1
		}
		connection_destroy(c)
		return
	}
	c.close_pending = true
}

// Returns true if this backend took over the worker thread (native loop).
@(private)
host_worker_enter :: proc(s: ^Server) -> bool {
	_ = s
	return false // portable proactr host loop in server.odin
}

@(private)
host_accept_is_unsupported_multishot :: proc(result: i32) -> bool {
	EINVAL :: 22
	EOPNOTSUPP :: 95
	return result == -EINVAL || result == -EOPNOTSUPP
}
