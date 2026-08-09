// Wire executor: submit/complete send, WRITEV, and sendfile/chunked file regions.
// Separated from server.odin (ring loop, accept/recv/close, connection lifecycle).
package http

import "core:c"
import "core:log"
import "core:mem/virtual"
import "core:sync"
import "core:sys/posix"

import proactr "../proactr"

// In-flight wire op. Exactly one of these is outstanding per connection (or None).
// Replaces parallel kernel_writev_active / kernel_sendfile_active + pending_send emptiness.
// Stream = progressive multi-CQE mid-body send (D0); completion routes via host_on_wire .Stream.
Wire_Kind :: enum u8 {
	None,
	Send,
	Writev,
	Sendfile,
	Stream,
}

// First-arm mem-queue mechanism (counter bookkeeping for plan_wire_inc_*).
Wire_Mem_Mech :: enum u8 {
	None,
	Kernel_Writev,
	Multi_Send,
}

// Max slots = PLAN_MAX_BODY_CMDS + 1 (heading).
PLAN_MAX_EXEC_BUFS :: PLAN_MAX_BODY_CMDS + 1
// Scratch size for Phase 4 chunked file send (not full-file materialize).
// 256 KiB: fewer pread+send round-trips for 1 MiB TFB file (4 vs 16 at 64 KiB).
FILE_SEND_CHUNK :: 256 * 1024

// Nested wire bag on Connection: mem queue, ephemeral iovecs, file region, in-flight kind.
// Sole host owner of response-delivery state between arm and final clean_request_loop.
Wire_State :: struct {
	kind:                Wire_Kind,
	// Remaining bytes for current SEND (materialize / multi_send / file chunk).
	// Slices into resp_buf, exec_bufs[exec_i], or file_send_buf.
	pending_send:        []u8,
	// Multi-buffer mem queue (Phase 3). exec_n == 0 → single-buffer / inactive.
	// Sole host-owned mem queue; WRITEV packs iovecs from remaining slots each submit.
	exec_bufs:           [PLAN_MAX_EXEC_BUFS][]u8,
	exec_i:              int,
	exec_n:              int,
	// Ephemeral WRITEV pack target (from exec_bufs); not a second queue.
	iovecs:              [PLAN_MAX_EXEC_BUFS]proactr.Io_Vec,
	iov_count:           int,
	// Phase 4 file-region stream. fd < 0 → inactive.
	// remaining = bytes not yet delivered; kind == .Sendfile → sendfile(2) path.
	// By default the handler owns the fd for the full send lifetime (host does not close).
	// file_send_close=true (body_file owned / static middleware) → host closes on clear.
	file_send_fd:        i32,
	file_send_off:       i64,
	file_send_remaining: i64,
	file_send_close:     bool,
	file_send_buf:       []u8, // conn_allocator scratch; len==FILE_SEND_CHUNK when allocated
}

// True while a send / WRITEV / sendfile SQE (or soft completion) is outstanding.
// connection_close must defer when true — clearing iovecs or freeing conn under an
// in-flight gather/sendfile was the bastion silent-death failure mode.
@(private)
_conn_wire_in_flight :: proc(c: ^Connection) -> bool {
	return c.wire.kind != .None
}

// ---------------------------------------------------------------------------
// Shared fail / mem-queue helpers
// ---------------------------------------------------------------------------

// Log, full wire teardown (mem + file + kind), close connection.
@(private)
_wire_fail :: proc(conn: ^Connection, msg: string, args: ..any) {
	log.errorf(msg, ..args)
	// Always return Stream pool slabs (error CQEs never reach _host_on_wire_stream).
	_stream_pool_abandon(conn)
	_conn_clear_exec(conn)
	connection_close(conn)
}

// Clear mem queue only: exec_i/n, pending_send, iovecs, nil exec_bufs.
// Does NOT touch file_send_* or wire.kind.
//
// Ownership / who sets wire.kind = .None:
//   - submit paths set kind on successful arm (.Send / .Writev / .Sendfile)
//   - CQE handlers clear kind to .None before re-arm or finish
//   - _conn_clear_exec (full teardown) sets kind = .None after clearing mem
//   - _conn_clear_mem_queue intentionally leaves kind alone so post-CQE mem-done
//     paths can clear the queue while kind is already .None and file region remains
@(private)
_conn_clear_mem_queue :: proc(conn: ^Connection) {
	conn.wire.exec_i = 0
	conn.wire.exec_n = 0
	conn.wire.pending_send = nil
	conn.wire.iov_count = 0
	for i in 0 ..< len(conn.wire.exec_bufs) {
		conn.wire.exec_bufs[i] = nil
	}
}

// Mem queue fully delivered: clear mem (preserve file_send_*), then start file
// region or finish the response.
@(private)
_wire_mem_done :: proc(conn: ^Connection) {
	_conn_clear_mem_queue(conn)
	if conn.wire.file_send_remaining > 0 || conn.wire.file_send_fd >= 0 {
		_ = _conn_file_region_start_or_finish(conn)
		return
	}
	_conn_clear_file_send(conn)
	clean_request_loop(conn)
}

// ---------------------------------------------------------------------------
// Submit paths
// ---------------------------------------------------------------------------

// host_submit_send enqueues send of conn.wire.pending_send.
@(private)
host_submit_send :: proc(conn: ^Connection) -> proactr.Error {
	assert_has_td()
	if conn.state >= .Closing {
		return .Closed
	}
	if len(conn.wire.pending_send) == 0 {
		return .None
	}
	_, err := proactr.submit_send(
		&td.ring,
		i32(conn.socket),
		conn.wire.pending_send,
		conn,
		conn.fixed_idx,
	)
	if err == .None {
		conn.wire.kind = .Send
	}
	return err
}

// host_try_send_nb: nonblocking send of buf on conn.socket (no ring arm).
// Returns (bytes_sent, would_block, hard_error).
// Pure EAGAIN → (0, true, false). Full delivery → (len, false, false).
// EINTR retried; other errors → (0, false, true). Windows forces again (arm path).
@(private)
host_try_send_nb :: proc(conn: ^Connection, buf: []u8) -> (n: int, again: bool, hard: bool) {
	if conn == nil || len(buf) == 0 {
		return 0, false, false
	}
	when ODIN_OS == .Windows {
		return 0, true, false
	} else {
		for _ in 0 ..< 8 {
			sn := posix.send(posix.FD(conn.socket), raw_data(buf), c.size_t(len(buf)), {})
			if sn >= 0 {
				return int(sn), false, false
			}
			e := posix.errno()
			if e == .EAGAIN || e == .EWOULDBLOCK {
				return 0, true, false
			}
			if e == .EINTR {
				continue
			}
			return 0, false, true
		}
		// EINTR storm — arm via ring rather than hard-fail.
		return 0, true, false
	}
}

// Pack non-empty exec_bufs[exec_i..] into conn.wire.iovecs (ephemeral for WRITEV submit).
// Returns iov count (0 if nothing to send).
@(private)
_conn_pack_iovecs :: proc(conn: ^Connection) -> int {
	n := 0
	for i in conn.wire.exec_i ..< conn.wire.exec_n {
		b := conn.wire.exec_bufs[i]
		if len(b) == 0 {
			continue
		}
		if n >= PLAN_MAX_EXEC_BUFS {
			break
		}
		conn.wire.iovecs[n] = proactr.Io_Vec {
			base = raw_data(b),
			len  = uint(len(b)),
		}
		n += 1
	}
	conn.wire.iov_count = n
	return n
}

// Primary host mutator for mem-queue progress (WRITEV short writes and multi_send).
// Advances exec_bufs after `sent` bytes delivered from the remaining queue.
// Returns true if more non-empty buffers remain.
// CRITICAL: never leave a zero-length buffer at exec_i with remain=true — host_submit_send
// returns .None for empty slices without posting a CQE (connection would hang).
@(private)
_conn_advance_exec_bufs :: proc(conn: ^Connection, sent: int) -> bool {
	if sent <= 0 || conn.wire.exec_n <= 0 {
		return conn.wire.exec_i < conn.wire.exec_n
	}
	left := sent
	i := conn.wire.exec_i
	for i < conn.wire.exec_n && left > 0 {
		b := conn.wire.exec_bufs[i]
		if len(b) == 0 {
			i += 1
			continue
		}
		if left >= len(b) {
			left -= len(b)
			conn.wire.exec_bufs[i] = nil
			i += 1
		} else {
			conn.wire.exec_bufs[i] = b[left:]
			left = 0
		}
	}
	for i < conn.wire.exec_n && len(conn.wire.exec_bufs[i]) == 0 {
		i += 1
	}
	conn.wire.exec_i = i
	return i < conn.wire.exec_n
}

// Pack heading + body slices into conn.wire.exec_bufs; set exec_i/n; skip empties.
// Returns false if nothing to send or too many segments.
@(private)
_conn_arm_mem_queue :: proc(conn: ^Connection, heading: []u8, bodies: [][]u8) -> bool {
	n_slots := 0
	if len(heading) > 0 {
		n_slots += 1
	}
	for b in bodies {
		if len(b) > 0 {
			n_slots += 1
		}
	}
	if n_slots == 0 || n_slots > PLAN_MAX_EXEC_BUFS {
		return false
	}
	bi := 0
	if len(heading) > 0 {
		conn.wire.exec_bufs[bi] = heading
		bi += 1
	}
	for b in bodies {
		if len(b) == 0 {
			continue
		}
		conn.wire.exec_bufs[bi] = b
		bi += 1
	}
	for i in bi ..< len(conn.wire.exec_bufs) {
		conn.wire.exec_bufs[i] = nil
	}
	conn.wire.exec_n = bi
	conn.wire.exec_i = 0
	// Skip leading empty buffers (defensive; arm already skipped empty inputs).
	for conn.wire.exec_i < conn.wire.exec_n && len(conn.wire.exec_bufs[conn.wire.exec_i]) == 0 {
		conn.wire.exec_i += 1
	}
	return conn.wire.exec_i < conn.wire.exec_n
}

// Prefer WRITEV if plan_wire_prefer_kernel && n_iov >= 2; else multi_send.
// Returns which mechanism was armed (first-arm counters stay in the caller).
// ok=false → submit failed or empty queue (caller closes / finishes).
// Packs iovecs at most once on the WRITEV arm (no re-pack inside submit).
@(private)
_conn_submit_mem_queue :: proc(conn: ^Connection) -> (mech: Wire_Mem_Mech, ok: bool) {
	if conn.wire.exec_i >= conn.wire.exec_n {
		return .None, false
	}
	// Prefer kernel WRITEV when ≥2 segments (heading+body or multi-body).
	// Single-iov WRITEV is redundant with SEND and was implicated in opt-mode
	// instability under load; use multi_send/SEND for the single-buffer case.
	if plan_wire_prefer_kernel() {
		n_iov := _conn_pack_iovecs(conn)
		if n_iov >= 2 {
			if err := host_submit_writev(conn); err == .None {
				return .Kernel_Writev, true
			}
			conn.wire.kind = .None
			// Fall through to multi_send; iovecs left stale until next pack (unused).
		}
	}
	conn.wire.pending_send = conn.wire.exec_bufs[conn.wire.exec_i]
	if len(conn.wire.pending_send) == 0 {
		// Should be unreachable after arm skip; fail closed (no CQE hang).
		return .None, false
	}
	if err := host_submit_send(conn); err != .None {
		log.errorf("submit_send (mem queue) failed: %v", err)
		return .None, false
	}
	return .Multi_Send, true
}

// host_submit_writev enqueues IORING_OP_WRITEV from already-packed conn.wire.iovecs.
// Caller must call _conn_pack_iovecs first (pack once per arm / per short-write resubmit).
// On .Unsupported, caller falls back to multi_send.
// Uses FIXED_FILE when registered — safe only because connection_close defers while
// wire.kind == .Writev (iovecs/exec_bufs must stay live until CQE).
@(private)
host_submit_writev :: proc(conn: ^Connection) -> proactr.Error {
	assert_has_td()
	if conn.state >= .Closing {
		return .Closed
	}
	if conn.wire.iov_count <= 0 {
		return .Invalid_Op
	}
	_, err := proactr.submit_writev(
		&td.ring,
		i32(conn.socket),
		conn.wire.iovecs[:conn.wire.iov_count],
		conn,
		conn.fixed_idx,
	)
	if err == .None {
		conn.wire.kind = .Writev
	}
	return err
}

// host_submit_sendfile enqueues kernel/BSD sendfile for conn.wire.file_send_* region.
// Linux: sendfile + soft_cq/POLL. Darwin: sendfile + kqueue EVFILT_WRITE.
// On .Unsupported, caller falls back to chunked pread+send.
// connection_close defers while wire.kind == .Sendfile so user/conn stay valid for CQE.
@(private)
host_submit_sendfile :: proc(conn: ^Connection) -> proactr.Error {
	assert_has_td()
	if conn.state >= .Closing {
		return .Closed
	}
	if conn.wire.file_send_fd < 0 || conn.wire.file_send_remaining <= 0 {
		return .Invalid_Op
	}
	_, err := proactr.submit_sendfile(
		&td.ring,
		i32(conn.socket),
		conn.wire.file_send_fd,
		conn.wire.file_send_off,
		u64(conn.wire.file_send_remaining),
		conn,
		conn.fixed_idx,
	)
	if err == .None {
		conn.wire.kind = .Sendfile
	}
	return err
}

// Pure math: after pread of `got` bytes from a known remaining region.
// Returns false if got is invalid (0, negative, or > remaining).
@(private)
file_send_after_pread :: proc(off, remaining, got: i64) -> (new_off, new_remaining: i64, ok: bool) {
	if remaining <= 0 || got <= 0 || got > remaining {
		return off, remaining, false
	}
	return off + got, remaining - got, true
}

// Clear Phase 4 file-region cursor. Keeps file_send_buf allocation for reuse.
// Closes file_send_fd only when file_send_close was set (owned body_file).
@(private)
_conn_clear_file_send :: proc(conn: ^Connection) {
	if conn.wire.file_send_close && conn.wire.file_send_fd >= 0 {
		when ODIN_OS != .Windows {
			_ = posix.close(posix.FD(conn.wire.file_send_fd))
		}
	}
	conn.wire.file_send_fd = -1
	conn.wire.file_send_off = 0
	conn.wire.file_send_remaining = 0
	conn.wire.file_send_close = false
}

// After mem/heading complete: start kernel sendfile if preferred, else chunked pread.
// Increments plan_wire_sendfile or plan_wire_copy_into once when the file body is first armed.
// Returns true if a new SQE was submitted or clean finished; false if connection closed.
@(private)
_conn_file_region_start_or_finish :: proc(conn: ^Connection) -> bool {
	if conn.wire.file_send_remaining > 0 {
		// Opt-in kernel sendfile (PLAN_WIRE_SENDFILE=1); default chunked for stability.
		if plan_wire_prefer_sendfile() {
			if err := host_submit_sendfile(conn); err == .None {
				// First arm only: count terminal body mechanism when path is successfully armed.
				plan_wire_inc_sendfile()
				return true
			}
			conn.wire.kind = .None
		}
		// Chunked pread+send (default; real sendfile path available via env).
		// First arm only: do not re-inc when mid-stream chunked continues via continue_or_finish.
		plan_wire_inc_copy_into()
		return _conn_file_send_continue_or_finish(conn)
	}
	_conn_clear_file_send(conn)
	clean_request_loop(conn)
	return true
}

// Ensure conn.wire.file_send_buf has FILE_SEND_CHUNK capacity (conn_allocator, permanent).
@(private)
_conn_ensure_file_send_buf :: proc(conn: ^Connection) -> bool {
	if len(conn.wire.file_send_buf) >= FILE_SEND_CHUNK {
		return true
	}
	if conn.server == nil {
		return false
	}
	if conn.wire.file_send_buf != nil {
		delete(conn.wire.file_send_buf, conn.server.conn_allocator)
		conn.wire.file_send_buf = nil
	}
	conn.wire.file_send_buf = make([]u8, FILE_SEND_CHUNK, conn.server.conn_allocator)
	return len(conn.wire.file_send_buf) == FILE_SEND_CHUNK
}

// pread next file chunk into file_send_buf and set pending_send.
// On success: pending_send non-empty, off/remaining advanced (remaining = not-yet-pread).
// Short pread (0 < got < want) is progress — next fill continues at new off.
// got==0 with remaining>0 is unexpected EOF (declared length past file) → fail.
// On failure: state uncleared (caller closes connection).
@(private)
_conn_file_send_fill_chunk :: proc(conn: ^Connection) -> bool {
	if conn.wire.file_send_remaining <= 0 {
		return false
	}
	if !_conn_ensure_file_send_buf(conn) {
		log.errorf("file_send: scratch alloc failed fd=%v", conn.socket)
		return false
	}
	want := conn.wire.file_send_remaining
	if want > i64(FILE_SEND_CHUNK) {
		want = i64(FILE_SEND_CHUNK)
	}
	n := int(want)
	when ODIN_OS == .Windows {
		log.errorf("file_send: pread not available on Windows (fd=%d)", conn.wire.file_send_fd)
		return false
	} else {
		got: int
		for {
			g := posix.pread(
				posix.FD(conn.wire.file_send_fd),
				raw_data(conn.wire.file_send_buf),
				c.size_t(n),
				posix.off_t(conn.wire.file_send_off),
			)
			if g < 0 {
				if posix.errno() == .EINTR {
					continue
				}
				log.errorf("file_send pread failed fd=%v file=%d: %v", conn.socket, conn.wire.file_send_fd, posix.errno())
				return false
			}
			got = int(g)
			break
		}
		if got == 0 {
			// EOF before declared remaining — not a short-but-positive pread.
			log.errorf("file_send EOF fd=%v file=%d remaining=%d", conn.socket, conn.wire.file_send_fd, conn.wire.file_send_remaining)
			return false
		}
		new_off, new_rem, ok := file_send_after_pread(conn.wire.file_send_off, conn.wire.file_send_remaining, i64(got))
		if !ok {
			return false
		}
		conn.wire.file_send_off = new_off
		conn.wire.file_send_remaining = new_rem
		// remaining==0 after fill: this is the last pending chunk; file_send_fd stays set
		// until host_on_wire drains pending_send and calls _conn_clear_file_send.
		conn.wire.pending_send = conn.wire.file_send_buf[:got]
		return true
	}
}

// After a full buffer (header / mem / chunk) has been sent: either fill next file
// chunk, or finish the response. Returns true if a new send was submitted (or clean
// completed); false if connection was closed on error.
@(private)
_conn_file_send_continue_or_finish :: proc(conn: ^Connection) -> bool {
	if conn.wire.file_send_remaining > 0 {
		if !_conn_file_send_fill_chunk(conn) {
			_wire_fail(conn, "file_send fill failed fd=%v", conn.socket)
			return false
		}
		if len(conn.wire.pending_send) == 0 {
			_wire_fail(conn, "file_send empty pending after fill fd=%v", conn.socket)
			return false
		}
		if err := host_submit_send(conn); err != .None {
			_wire_fail(conn, "submit_send (file chunk) failed: %v", err)
			return false
		}
		return true
	}
	// File region fully loaded and prior chunk fully sent (or zero-length file).
	_conn_clear_exec(conn)
	clean_request_loop(conn)
	return true
}

// Full wire teardown: mem queue + kind + file cursor. Keeps file_send_buf for reuse.
@(private)
_conn_clear_exec :: proc(conn: ^Connection) {
	_conn_clear_mem_queue(conn)
	conn.wire.kind = .None
	_conn_clear_file_send(conn)
}

// True when pending_send is a view into file_send_buf (chunked file body in progress).
@(private)
_conn_pending_is_file_chunk :: proc(conn: ^Connection) -> bool {
	if len(conn.wire.file_send_buf) == 0 || len(conn.wire.pending_send) == 0 {
		return false
	}
	return raw_data(conn.wire.pending_send) == raw_data(conn.wire.file_send_buf)
}

// Unified wire completion: shared prologue then kind-specific advance.
@(private)
host_on_wire :: proc(conn: ^Connection, kind: Wire_Kind, result: i32) {
	context.temp_allocator = virtual.arena_allocator(&conn.temp_allocator)

	// Deferred close while a wire SQE was outstanding: account for this CQE first.
	// Mid multi-buffer / file stream: abort remaining queue (partial response on wire).
	if conn.close_on_io {
		if kind == .Stream || conn.slot.stream_send_slab != nil {
			_stream_pool_abandon(conn)
		}
		_conn_clear_exec(conn)
		conn.close_on_io = false
		if conn.state < .Closing {
			connection_close(conn)
		}
		return
	}

	if result < 0 {
		// Stream/session peer death: notify session before teardown when possible.
		if (kind == .Stream || conn.slot.stream_open) && conn.slot.session != nil {
			sync.atomic_add(&session_metrics_client_gone, 1)
			_session_drive(conn, Session_Event{kind = .Client_Gone})
		}
		_wire_fail(conn, "wire %v error fd=%v res=%d", kind, conn.socket, result)
		return
	}

	// Zero progress with work remaining: do not resubmit forever.
	switch kind {
	case .Send:
		if result == 0 && len(conn.wire.pending_send) > 0 {
			_wire_fail(conn, "send zero-length fd=%v pending=%d exec_n=%d", conn.socket, len(conn.wire.pending_send), conn.wire.exec_n)
			return
		}
		_host_on_wire_send(conn, int(result))
	case .Stream:
		if result == 0 && len(conn.wire.pending_send) > 0 {
			_wire_fail(conn, "stream send zero-length fd=%v pending=%d stream_sent=%d", conn.socket, len(conn.wire.pending_send), conn.slot.stream_sent)
			return
		}
		_host_on_wire_stream(conn, int(result))
	case .Writev:
		if result == 0 && conn.wire.exec_i < conn.wire.exec_n {
			_wire_fail(conn, "writev zero-length fd=%v exec_i=%d exec_n=%d", conn.socket, conn.wire.exec_i, conn.wire.exec_n)
			return
		}
		_host_on_wire_writev(conn, int(result))
	case .Sendfile:
		if result == 0 && conn.wire.file_send_remaining > 0 {
			_wire_fail(conn, "sendfile zero progress fd=%v file=%d remaining=%d", conn.socket, conn.wire.file_send_fd, conn.wire.file_send_remaining)
			return
		}
		_host_on_wire_sendfile(conn, i64(result))
	case .None:
		// Should not be dispatched.
		_ = result
	}
}

// Progressive Stream send CQE: partial advance within pool slab; on full arm delivered
// advance stream_sent, return slab, reflush or finish or arm PIN.
// pending_send always aliases stream_send_slab (never resp_buf).
@(private)
_host_on_wire_stream :: proc(conn: ^Connection, n: int) {
	conn.wire.kind = .None

	if n < 0 {
		_stream_pool_abandon(conn)
		_wire_fail(conn, "stream send error fd=%v n=%d", conn.socket, n)
		return
	}

	// Partial within current slab copy.
	if n < len(conn.wire.pending_send) {
		conn.wire.pending_send = conn.wire.pending_send[n:]
		if len(conn.wire.pending_send) == 0 {
			_stream_pool_abandon(conn)
			_wire_fail(conn, "stream partial emptied pending fd=%v", conn.socket)
			return
		}
		if err := host_submit_send(conn); err != .None {
			_stream_pool_abandon(conn)
			_wire_fail(conn, "submit_send (stream partial) failed: %v", err)
			return
		}
		conn.wire.kind = .Stream
		return
	}

	// Full arm delivered (stream_send_len is original copy size for this arm).
	delivered := conn.slot.stream_send_len
	if delivered <= 0 {
		delivered = len(conn.wire.pending_send)
	}
	conn.slot.stream_sent += delivered
	conn.wire.pending_send = nil
	_stream_pool_abandon(conn)

	// Compact when wire idle so long sessions reclaim RSS.
	_stream_compact_delivered(conn)

	if conn.slot.session != nil {
		_session_on_writable(conn)
	}

	more := len(conn.resp_buf) > conn.slot.stream_sent
	if more || conn.slot.stream_flush_pending || conn.slot.stream_ending {
		conn.slot.stream_flush_pending = false
		if more || conn.slot.stream_ending {
			_stream_try_submit(conn)
			return
		}
	}

	if conn.slot.stream_ending && conn.slot.stream_sent >= len(conn.resp_buf) {
		_stream_finish(conn)
		return
	}
	// Mid-session idle: hangup watch (clear PIN no-op; ciphered → CT recv).
	_session_arm_hangup_watch(conn)
}

@(private)
_stream_pool_abandon :: proc(conn: ^Connection) {
	if conn.slot.stream_send_slab != nil {
		stream_pool_put(conn.slot.stream_send_slab)
		conn.slot.stream_send_slab = nil
	}
	conn.slot.stream_send_len = 0
}

// Kernel WRITEV completion: advance exec_bufs on short write; then file region or finish.
@(private)
_host_on_wire_writev :: proc(conn: ^Connection, n: int) {
	// This CQE completes the prior WRITEV; clear until we re-arm.
	conn.wire.kind = .None

	remain := _conn_advance_exec_bufs(conn, n)
	if remain {
		// Re-pack after advance (one pack per resubmit; submit does not pack again).
		if _conn_pack_iovecs(conn) <= 0 {
			_wire_fail(conn, "writev resubmit empty iovecs fd=%v", conn.socket)
			return
		}
		if err := host_submit_writev(conn); err != .None {
			// Graceful degradation: multi_send from remaining exec_bufs (already advanced).
			// First-arm only: kernel_writev already counted at initial arm — do not re-inc multi_send.
			log.warnf("submit_writev (partial) failed: %v — falling back to multi_send", err)
			conn.wire.kind = .None
			conn.wire.iov_count = 0
			if conn.wire.exec_i >= conn.wire.exec_n || len(conn.wire.exec_bufs[conn.wire.exec_i]) == 0 {
				_wire_fail(conn, "writev→multi_send empty queue fd=%v", conn.socket)
				return
			}
			conn.wire.pending_send = conn.wire.exec_bufs[conn.wire.exec_i]
			if err2 := host_submit_send(conn); err2 != .None {
				_wire_fail(conn, "submit_send (writev→multi_send) failed: %v", err2)
				return
			}
		}
		return
	}

	_wire_mem_done(conn)
}

// Kernel sendfile completion: advance file cursor; resubmit remainder or finish.
@(private)
_host_on_wire_sendfile :: proc(conn: ^Connection, n_in: i64) {
	conn.wire.kind = .None

	n := n_in
	if n > conn.wire.file_send_remaining {
		n = conn.wire.file_send_remaining
	}
	conn.wire.file_send_off += n
	conn.wire.file_send_remaining -= n

	if conn.wire.file_send_remaining > 0 {
		if err := host_submit_sendfile(conn); err != .None {
			// First-arm only: sendfile already counted at region start; chunked continues same body.
			log.warnf("submit_sendfile (partial) failed: %v — falling back to chunked", err)
			conn.wire.kind = .None
			if !_conn_file_send_continue_or_finish(conn) {
				return
			}
		}
		return
	}

	// File region fully delivered.
	_conn_clear_exec(conn)
	clean_request_loop(conn)
}

// SEND completion: multi-buffer queue, single buffer, or file-chunk path.
// Mem queue progress uses the single mutator _conn_advance_exec_bufs (same as WRITEV).
@(private)
_host_on_wire_send :: proc(conn: ^Connection, n: int) {
	// This CQE completes the prior SEND; clear until we re-arm (partial or next buffer).
	conn.wire.kind = .None

	// Multi-buffer sequential queue (Phase 3 fallback / multi_send).
	// When the queue finishes and a file region remains, start sendfile or chunked stream.
	if conn.wire.exec_n > 0 {
		remain := _conn_advance_exec_bufs(conn, n)
		if !remain {
			_wire_mem_done(conn)
			return
		}
		// Defense: never arm a zero-length pending (no CQE → hang).
		conn.wire.pending_send = conn.wire.exec_bufs[conn.wire.exec_i]
		if len(conn.wire.pending_send) == 0 {
			_wire_fail(conn, "multi-op empty pending after advance fd=%v i=%d n=%d", conn.socket, conn.wire.exec_i, conn.wire.exec_n)
			return
		}
		if err := host_submit_send(conn); err != .None {
			_wire_fail(conn, "submit_send (multi-op) failed: %v", err)
			return
		}
		return
	}

	// Detect chunked file body before clearing pending (fill_chunk sets pending = file_send_buf[:got]).
	was_file_chunk := _conn_pending_is_file_chunk(conn)

	// Single-buffer or file-chunk path: partial send within current pending.
	if n < len(conn.wire.pending_send) {
		// Partial send — advance and resubmit. Buffer still owned until full send.
		// n==0 already closed above; n>0 here.
		conn.wire.pending_send = conn.wire.pending_send[n:]
		if len(conn.wire.pending_send) == 0 {
			// Should not happen (n < len implies remainder > 0); fail closed.
			_wire_fail(conn, "send partial emptied pending fd=%v", conn.socket)
			return
		}
		if err := host_submit_send(conn); err != .None {
			_wire_fail(conn, "submit_send (partial) failed: %v", err)
			return
		}
		return
	}

	// Current buffer fully sent.
	conn.wire.pending_send = nil

	// PR5 TLS: handshake CT or windowed response CT complete → continue seal/HS.
	if conn.tls_ssl != nil {
		if tls_host_on_send_complete(conn) {
			return
		}
	}

	// Phase 4: mid-chunked continue (no re-count); first file body entry via start_or_finish.
	if was_file_chunk {
		if conn.wire.file_send_remaining > 0 || conn.wire.file_send_fd >= 0 {
			_ = _conn_file_send_continue_or_finish(conn)
			return
		}
		_conn_clear_file_send(conn)
		clean_request_loop(conn)
		return
	}

	if conn.wire.file_send_remaining > 0 {
		// First transition into file body (heading/mem done): try kernel sendfile, else chunked.
		_ = _conn_file_region_start_or_finish(conn)
		return
	}
	if conn.wire.file_send_fd >= 0 {
		// Last file chunk fully delivered (remaining already 0 after last pread) — or empty file marker.
		_conn_clear_file_send(conn)
		clean_request_loop(conn)
		return
	}

	// Single-buffer path complete (materialize / body_reserve / HEAD).
	clean_request_loop(conn)
}
