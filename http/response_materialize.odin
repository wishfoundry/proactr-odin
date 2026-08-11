package http

// Response body materialize helpers: cmds → resp_buf Write_Slice payload.
// Called from response_send_got_body when writev/sendfile/ciphered-split do not apply.

import "core:bytes"
import "core:c"
import "core:log"
import "core:sys/posix"

// Materialize cmds into _buf as one Write_Slice payload (Phase 1–3 fallback).
// Not used when body_reserve / response_writer already wrote the heading into _buf.
// Hot path (TFB plaintext/size ladder): single Static/Bytes with known length —
// one exact buffer grow, heading into resp_buf, one body memcpy. Skips
// plan_body_materialize_only + buffer_write bookkeeping tax.
@(private)
_response_materialize_cmds :: proc(r: ^Response) {
	assert(!r._heading_written)
	assert(r._cmd_count > 0)

	cmds := r._cmds[:r._cmd_count]

	// Fast path: single Static/Bytes body, small/medium only.
	// Large bodies (e.g. 1MiB) keep the classic grow+buffer_write path — bastion
	// measured a s1m RPS regression with exact-size resize+copy under multi-worker load.
	MATERIALIZE_FAST_MAX :: 256 * 1024
	if r._cmd_count == 1 {
		c := cmds[0]
		if (c.kind == .Static || c.kind == .Bytes) && len(c.bytes) <= MATERIALIZE_FAST_MAX {
			body_len := len(c.bytes)
			t0_build: u64
			when HTTP_PHASE_STATS {
				t0_build = phase_now()
			}
			hscratch: [512]byte
			hlen := _response_format_heading(r, body_len, hscratch[:])
			assert(hlen > 0 && hlen <= len(hscratch))
			need := hlen + body_len
			if cap(r._buf.buf) < need {
				reserve(&r._buf.buf, need)
			}
			resize(&r._buf.buf, need)
			copy(r._buf.buf[0:hlen], hscratch[:hlen])
			r._heading_written = true
			if !_response_is_head(r._conn) && body_len > 0 {
				copy(r._buf.buf[hlen:][:body_len], c.bytes)
			} else if _response_is_head(r._conn) {
				resize(&r._buf.buf, hlen)
			}
			when HTTP_PHASE_STATS {
				bc := phase_now() - t0_build
				phase_add(0, 0, 0, 0, 0, bc, 0)
				path_metrics_note_materialize_cycles(bc)
			}
			return
		}
	}

	plan := plan_body_materialize_only(cmds)
	assert(plan.materialized && plan.op_count == 1 && plan.ops[0].kind == .Write_Slice)

	// Content-Length: sum of known lengths. Materialize requires known body size.
	// Validate *before* writing the heading so a bad File.length cannot emit a wrong CL
	// and then assert mid-materialize (or worse under -disable-assert).
	body_len: int
	assert(plan.total_body >= 0, "materialize requires known body length (set File.length)")
	// Prefer recompute from cmds so a planner bug cannot poison CL.
	body_len = 0
	for c in cmds {
		n, ok := cmd_known_length(c)
		assert(ok, "materialize requires known body length (set File.length)")
		assert(n >= 0)
		// Overflow guard: body must fit in int (buffer length).
		assert(i64(body_len) + n <= i64(max(int)))
		body_len += int(n)
	}
	assert(i64(body_len) == plan.total_body, "plan total_body mismatch vs cmd lengths")

	t0_build: u64
	when HTTP_PHASE_STATS {
		t0_build = phase_now()
	}

	_response_write_heading(r, body_len)

	// HEAD: headers + Content-Length only; do not copy/read body (RFC 9110 §9.3.2).
	// Close Owned File cmds immediately — no stream/materialize read will take ownership.
	if _response_is_head(r._conn) {
		_response_close_owned_file_cmds(cmds)
		when HTTP_PHASE_STATS {
			phase_add(0, 0, 0, 0, 0, phase_now() - t0_build, 0)
		}
		return
	}

	for c in cmds {
		switch c.kind {
		case .Static, .Bytes:
			bytes.buffer_write(&r._buf, c.bytes)
		case .File:
			_response_materialize_file(r, c)
		}
	}

	when HTTP_PHASE_STATS {
		bc := phase_now() - t0_build
		phase_add(0, 0, 0, 0, 0, bc, 0)
		path_metrics_note_materialize_cycles(bc)
	}
}

// Close File cmds marked Owned (after HEAD headers-only or failed arm before wire transfer).
@(private)
_response_close_owned_file_cmds :: proc(cmds: []Response_Cmd) {
	when ODIN_OS != .Windows {
		for c in cmds {
			if c.kind == .File && .Owned in c.flags && c.fd >= 0 {
				_ = posix.close(posix.FD(c.fd))
			}
		}
	}
}

// Public: abandon staged body cmds that own File fds without transferring to the wire.
// Clears the response cmd buffer. Used by middleware tests and callers that prepare then cancel.
response_close_owned_body_files :: proc(r: ^Response) {
	if r == nil || r._cmd_count == 0 {
		return
	}
	_response_close_owned_file_cmds(r._cmds[:r._cmd_count])
	r._cmd_count = 0
}

// Sync pread of a File cmd region into the response wire buffer (Phase 1 only).
// fd must remain open and the region readable until this returns (send copies into resp_buf).
// Owned fds are always closed before return (success, empty region, or error) so a failed
// Sendfile-wire → materialize fallback cannot leak static middleware fds.
@(private)
_response_materialize_file :: proc(r: ^Response, cmd: Response_Cmd) {
	assert(cmd.kind == .File)
	assert(cmd.length >= 0, "Phase 1 file materialize needs known length")
	// Guard against -disable-assert + length=-1 (int(-1) would grow absurdly / UB).
	if cmd.length < 0 {
		log.errorf("body_file materialize rejected unknown length (fd=%d)", cmd.fd)
		// Still close Owned so callers cannot leak on bad length.
		if .Owned in cmd.flags && cmd.fd >= 0 {
			when ODIN_OS != .Windows {
				_ = posix.close(posix.FD(cmd.fd))
			}
		}
		return
	}
	n := int(cmd.length)
	owned := .Owned in cmd.flags
	fd := cmd.fd
	// Close Owned once on every exit path (including assert failure under -disable-assert).
	defer {
		if owned && fd >= 0 {
			when ODIN_OS != .Windows {
				_ = posix.close(posix.FD(fd))
			}
		}
	}
	if n == 0 {
		return
	}
	// length that does not fit int (32-bit hosts / huge files): refuse.
	if i64(n) != cmd.length {
		log.errorf("body_file materialize length does not fit int: %d", cmd.length)
		assert(false, "file body length too large for materialize buffer")
		return
	}

	bytes.buffer_grow(&r._buf, n)
	dst := _dynamic_unwritten(r._buf.buf)
	assert(len(dst) >= n)

	when ODIN_OS == .Windows {
		// Host HTTP path is POSIX/Linux; Windows ring exists but this host is not wired.
		// Avoid referencing posix.pread (not available). Fail closed rather than wrong data.
		_ = dst
		log.errorf("body_file materialize: pread not available on Windows (fd=%d)", cmd.fd)
		assert(false, "body_file materialize unsupported on Windows in Phase 1")
		return
	} else {
		total := 0
		off := cmd.offset
		for total < n {
			got := posix.pread(
				posix.FD(cmd.fd),
				raw_data(dst[total:n]),
				c.size_t(n - total),
				posix.off_t(off),
			)
			if got < 0 {
				if posix.errno() == .EINTR {
					continue
				}
				log.errorf("body_file materialize pread failed: %v", posix.errno())
				assert(false, "file body pread failed during materialize")
				return
			}
			if got == 0 {
				assert(false, "file body short/EOF during materialize")
				return
			}
			total += int(got)
			off += i64(got)
		}
		_dynamic_add_len(&r._buf.buf, n)
	}
}
