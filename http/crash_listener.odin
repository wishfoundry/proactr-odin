// Minimal crash manager for the proactr HTTP host.
package http

import "core:c/libc"
import "core:log"
import "core:os"

// server_request_shutdown marks the server for graceful stop.
// Safe to call from a signal handler: only an atomic store (no closes, no locks).
// Workers notice on the next ring_wait timeout (Server_Opts.wait_timeout_ms) or CQE.
server_request_shutdown :: proc(s: ^Server) {
	if s == nil {
		return
	}
	atomic_store(&s.closing, true)
}

// server_shutdown requests stop and, from a normal thread context, closes
// listen sockets so outstanding accept ops complete. Prefer this outside signals.
// Order: set closing → close listen → workers drain → serve returns.
server_shutdown :: proc(s: ^Server) {
	if s == nil {
		return
	}
	server_request_shutdown(s)
	server_close_listen(s)
}

// Global target for SIGINT/SIGTERM. Only the atomic `closing` flag is touched
// from the handler; never call server_close_listen here (not async-signal-safe).
@(private)
crash_listener_server: ^Server

// POSIX SIGPIPE (not in core:c/libc constants). Value is portable on Linux/BSD/Darwin.
when ODIN_OS != .Windows {
	_SIGPIPE :: 13
}

// server_ignore_sigpipe discards SIGPIPE so broken-pipe writes return EPIPE
// instead of killing the process. Required for kernel sendfile(2) and any
// non-MSG_NOSIGNAL write path when clients disconnect mid-response.
// Safe to call multiple times; install once before serve.
server_ignore_sigpipe :: proc() {
	when ODIN_OS != .Windows {
		// SIG_IGN is rawptr(1); match crash-listener handler type (cdecl/i32).
		ign := transmute(proc "cdecl" (i32))libc.SIG_IGN
		_ = libc.signal(_SIGPIPE, ign)
	}
}

// server_shutdown_on_interrupt installs a minimal crash listener:
// SIGINT and SIGTERM → server_request_shutdown only.
// Also ignores SIGPIPE (see server_ignore_sigpipe).
// Workers reap on the cold path (close listen, drain conns).
server_shutdown_on_interrupt :: proc(s: ^Server) {
	crash_listener_server = s
	server_ignore_sigpipe()
	_ = libc.signal(libc.SIGINT, _crash_listener_on_signal)
	_ = libc.signal(libc.SIGTERM, _crash_listener_on_signal)
}

@(private)
_crash_listener_on_signal :: proc "cdecl" (_: i32) {
	// Async-signal-safe: atomic store only. No context=, no net.close, no log.
	s := crash_listener_server
	if s != nil {
		// Inline store: cannot call Odin procs that might not be signal-safe.
		// atomic_store uses sync.atomic_store which is fine for bool.
		s.closing.raw = true
	}
}

// server_fatal is for unrecoverable host invariants. Best-effort request
// shutdown, then exit so the OS reclaims FDs/rings; external supervisors restart.
server_fatal :: proc(msg: string, args: ..any) {
	log.errorf(msg, ..args)
	if crash_listener_server != nil {
		server_request_shutdown(crash_listener_server)
	}
	os.exit(1)
}

// server_reap_if_closing is the cold-path reaper entry for a worker loop.
// Idempotent: closes listen once (CAS), begins connection drain, returns whether
// the server is shutting down.
@(private)
server_reap_if_closing :: proc(s: ^Server) -> bool {
	if !atomic_load(&s.closing) {
		return false
	}
	// Close all worker listen fds from normal context (signal only set the flag).
	server_close_listen(s)
	_server_thread_begin_shutdown(s)
	// Multishot accept may not deliver a CQE promptly after close; do not block
	// worker exit on accept_pending once listen is gone.
	if atomic_load(&s.listen_closed) {
		td.accept_pending = false
		td.needs_accept_rearm = false
	}
	return true
}
