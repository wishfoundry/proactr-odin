#+build darwin, freebsd, openbsd, netbsd
package http

// Host backend: kqueue.
// Darwin: native multi-kq reactor (io_reactor_kqueue + server_loop_reactor +
// tls_reactor_flush). Shared listen (no REUSEPORT) — multi-bind REUSEPORT +
// localhost pins all accepts to one worker.
// Other BSD: proactr kqueue façade + per-worker SO_REUSEPORT; workers use the
// portable host loop until a native reactor is ported.

import "core:c"
import "core:log"
import "core:net"
import "core:sys/posix"

import proactr "../proactr"

_SO_REUSEPORT :: c.int(0x0200)

// ---------------------------------------------------------------------------
// Listen helpers
// ---------------------------------------------------------------------------

@(private)
_kqueue_listen_tcp :: proc(
	endpoint: net.Endpoint,
	backlog: int,
	reuse_port: bool,
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

	if reuse_port {
		one: c.int = 1
		if posix.setsockopt(
			fd,
			posix.SOL_SOCKET,
			posix.Sock_Option(_SO_REUSEPORT),
			&one,
			size_of(one),
		) != .OK {
			log.debugf("setsockopt REUSEPORT: %v (continuing; WORKERS=1 if bind fails)", posix.errno())
		}
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
	if net.set_blocking(any_sock, false) != nil {
		log.errorf("set_blocking(false) failed")
		net.close(tsock)
		return {}, .Init_Failed
	}
	return tsock, .None
}

// host_listen_bind: Darwin shared listen at listen(); other BSD defer to attach.
@(private)
host_listen_bind :: proc(s: ^Server, endpoint: net.Endpoint) -> proactr.Error {
	when ODIN_OS == .Darwin {
		lfd, lerr := _kqueue_listen_tcp(endpoint, s.opts.listen_backlog, reuse_port = false)
		if lerr != .None {
			return lerr
		}
		s.tcp_sock = lfd
		log.infof(
			"host listen: shared fd (kqueue multi-kq accept) endpoint=%v backlog=%d",
			endpoint,
			s.opts.listen_backlog,
		)
		return .None
	} else {
		_ = s
		_ = endpoint
		return .None
	}
}

@(private)
host_worker_attach_listen :: proc(s: ^Server) -> bool {
	when ODIN_OS == .Darwin {
		if s.tcp_sock == {} {
			log.error("shared listen socket missing (call listen before serve)")
			return false
		}
		td.listen_fd = s.tcp_sock
		return true
	} else {
		lfd, lerr := _kqueue_listen_tcp(s.endpoint, s.opts.listen_backlog, reuse_port = true)
		if lerr != .None {
			log.errorf("listen REUSEPORT failed: %v", lerr)
			return false
		}
		td.listen_fd = lfd
		return true
	}
}

@(private)
server_close_listen_sockets :: proc(s: ^Server) {
	when ODIN_OS == .Darwin {
		if s.tcp_sock != {} {
			net.close(s.tcp_sock)
			s.tcp_sock = {}
		}
		if s.threads != nil {
			for &t in s.threads {
				t.listen_fd = {}
			}
		}
	} else {
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
}

// ---------------------------------------------------------------------------
// Close / interest / worker enter
// ---------------------------------------------------------------------------

@(private)
conn_reactor_io_in_flight :: proc(c: ^Connection) -> bool {
	when ODIN_OS == .Darwin {
		// Native reactor: product READ is level — never defer on read_armed alone.
		// Only oneshot fairness WRITE defers.
		if c.reactor_write_armed && !c.reactor_write_level {
			log.debugf("connection %i close deferred (oneshot WRITE armed)", c.socket)
			return true
		}
		return false
	} else {
		// proactr kqueue façade: oneshot-style recv interest.
		if c.tls_ct_recv_inflight || c.reactor_read_armed {
			log.debugf("connection %i close deferred (recv interest in flight)", c.socket)
			return true
		}
		return false
	}
}

@(private)
conn_close_finish :: proc(c: ^Connection) {
	when ODIN_OS == .Darwin {
		reactor_host_close(c)
	} else {
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
}

// Darwin native reactor takes the worker; other BSD continue portable host loop.
@(private)
host_worker_enter :: proc(s: ^Server) -> bool {
	when ODIN_OS == .Darwin {
		server_reactor_worker_loop(s)
		return true
	} else {
		_ = s
		return false
	}
}

@(private)
host_accept_is_unsupported_multishot :: proc(result: i32) -> bool {
	_ = result
	return false
}
