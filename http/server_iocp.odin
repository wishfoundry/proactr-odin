#+build windows
package http

// Host backend: proactr IOCP (Windows).
// Product I/O on the proactr ring (WSASend/WSARecv/AcceptEx → GQCS).
// HTTP multi-worker listen is not product-hard yet — hooks compile; attach may fail.

import "core:log"
import "core:net"

import proactr "../proactr"

// host_listen_bind: no process-wide bind yet (REUSEADDR/port story TBD).
@(private)
host_listen_bind :: proc(s: ^Server, endpoint: net.Endpoint) -> proactr.Error {
	_ = s
	_ = endpoint
	return .None
}

@(private)
host_worker_attach_listen :: proc(s: ^Server) -> bool {
	_ = s
	// Wire when Windows HTTP product path is productized (bind + IOCP associate).
	log.error("host_worker_attach_listen: IOCP HTTP listen not product-wired")
	return false
}

@(private)
server_close_listen_sockets :: proc(s: ^Server) {
	if s.threads != nil {
		for &t in s.threads {
			if t.listen_fd != {} {
				net.close(t.listen_fd)
				t.listen_fd = {}
			}
		}
	}
	if s.tcp_sock != {} {
		net.close(s.tcp_sock)
		s.tcp_sock = {}
	}
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

@(private)
host_worker_enter :: proc(s: ^Server) -> bool {
	_ = s
	return false // portable proactr host loop
}

@(private)
host_accept_is_unsupported_multishot :: proc(result: i32) -> bool {
	_ = result
	return false
}
