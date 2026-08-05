package http

/*
Response command buffer + transport planner (experiment).

Phase 1–2: handlers emit Response_Cmd via body_* helpers; optional body middleware
rewrites cmds; default wire path is plan_body_materialize_only → one Write_Slice.

Phase 3 wire: when Server_Opts.plan_optimize or Handler_Profile.prefer_gather,
response_send runs plan_body; pure Writev prefers Linux IORING_OP_WRITEV
(plan_wire_kernel_writev_total), falling back to multi-buffer sequential send
(plan_wire_multi_send_total) on Unsupported / PLAN_WIRE_MODE=fallback.

Phase 4 wire: plan Write_Slice/Writev + Sendfile prefers Linux sendfile(2)
(plan_wire_sendfile_total), falling back to chunked pread + sequential send
(plan_wire_copy_into_total). Copy_Into plans and plan_optimize off still
full-materialize File into resp_buf.

Phase 5: SSE / long-lived streams use Response_Stream (begin/write/flush/end),
NOT Response_Cmd / plan_body. plan_wire_* does not count stream bodies.

PLAN_WIRE_MODE env (Linux): "kernel" (default) | "fallback" — force multi_send/copy_into.

See docs/RESPONSE_COMMAND_PLANNER.md.

Intent (handlers / middleware)  →  Response_Cmd[]
Policy (this file)              →  Plan_Result / Exec_Op[]
Mechanism (executor / proactr)  →  writev / sendfile / multi-send / file-region stream
Stream (Phase 5)                →  Response_Stream (chunked TE; separate lifetime)
*/

import "core:os"
import "core:sync"

// Wire-path mechanism counters (Phase 3–4). Atomic; safe across workers.
// Harness /metrics can load these to prove real wire paths vs materialize.
// Stream responses use stream_responses_total (Phase 5), not these plan_wire_*.
//
// multi_send      = sequential multi-buffer submit_send (fallback when no kernel writev)
// kernel_writev   = IORING_OP_WRITEV gather (Linux)
// copy_into       = chunked pread+send (fallback when no kernel sendfile)
// sendfile        = real sendfile(2) file→socket (Linux)
plan_wire_multi_send_total:     u64
plan_wire_kernel_writev_total:  u64
plan_wire_materialize_total:    u64
plan_wire_sendfile_total:       u64
plan_wire_copy_into_total:      u64
// Phase 5: response_begin_stream → stream_end completed (not a plan_body path).
stream_responses_total:         u64

// PLAN_WIRE_MODE: lazy once. Linux default prefer kernel; non-Linux always false.
@(private)
_plan_wire_mode_inited: bool
@(private)
_plan_wire_prefer_kernel: bool

// plan_wire_prefer_kernel: try IORING_OP_WRITEV for multi-segment gather.
// Override with PLAN_WIRE_MODE=fallback to force multi_send.
// PLAN_WIRE_MODE=kernel (default on Linux). Non-Linux always false.
plan_wire_prefer_kernel :: proc() -> bool {
	if !_plan_wire_mode_inited {
		_plan_wire_mode_inited = true
		when ODIN_OS == .Linux {
			_plan_wire_prefer_kernel = true
		} else {
			_plan_wire_prefer_kernel = false
		}
		if v, ok := os.lookup_env("PLAN_WIRE_MODE", context.allocator); ok {
			defer delete(v, context.allocator)
			switch v {
			case "fallback", "multi_send", "copy_into", "0", "false":
				_plan_wire_prefer_kernel = false
			case "kernel", "1", "true":
				when ODIN_OS == .Linux {
					_plan_wire_prefer_kernel = true
				}
			}
		}
	}
	return _plan_wire_prefer_kernel
}

// Kernel sendfile(2) is opt-in: PLAN_WIRE_SENDFILE=1|true|on.
// Default off — soft_post + POLL path was unstable under high concurrency on bastion
// (process death after file load). Code path exists for fidelity; chunked is default.
@(private)
_plan_wire_sendfile_inited: bool
@(private)
_plan_wire_prefer_sendfile: bool

plan_wire_prefer_sendfile :: proc() -> bool {
	if !_plan_wire_sendfile_inited {
		_plan_wire_sendfile_inited = true
		_plan_wire_prefer_sendfile = false
		when ODIN_OS == .Linux {
			if v, ok := os.lookup_env("PLAN_WIRE_SENDFILE", context.allocator); ok {
				defer delete(v, context.allocator)
				switch v {
				case "1", "true", "on", "kernel":
					_plan_wire_prefer_sendfile = true
				}
			}
		}
	}
	return _plan_wire_prefer_sendfile && plan_wire_prefer_kernel()
}

// Deprecated alias name — multi_send only (not kernel writev). Prefer plan_wire_load.
plan_wire_writev_total :: proc() -> u64 {
	return sync.atomic_load(&plan_wire_multi_send_total)
}

plan_wire_inc_writev :: #force_inline proc() {
	// Name kept for call sites; increments multi_send (honest mechanism).
	sync.atomic_add(&plan_wire_multi_send_total, u64(1))
}

plan_wire_inc_multi_send :: plan_wire_inc_writev

plan_wire_inc_kernel_writev :: #force_inline proc() {
	sync.atomic_add(&plan_wire_kernel_writev_total, u64(1))
}

plan_wire_inc_materialize :: #force_inline proc() {
	sync.atomic_add(&plan_wire_materialize_total, u64(1))
}

// Only call when real kernel sendfile/splice path armed (not chunked pread).
plan_wire_inc_sendfile :: #force_inline proc() {
	sync.atomic_add(&plan_wire_sendfile_total, u64(1))
}

plan_wire_inc_copy_into :: #force_inline proc() {
	sync.atomic_add(&plan_wire_copy_into_total, u64(1))
}

stream_inc_responses :: #force_inline proc() {
	sync.atomic_add(&stream_responses_total, u64(1))
}

plan_wire_load :: proc() -> (multi_send: u64, materialize: u64) {
	return sync.atomic_load(&plan_wire_multi_send_total), sync.atomic_load(&plan_wire_materialize_total)
}

plan_wire_load_kernel_writev :: proc() -> u64 {
	return sync.atomic_load(&plan_wire_kernel_writev_total)
}

plan_wire_load_file :: proc() -> (sendfile: u64, copy_into: u64) {
	return sync.atomic_load(&plan_wire_sendfile_total), sync.atomic_load(&plan_wire_copy_into_total)
}

stream_responses_load :: proc() -> u64 {
	return sync.atomic_load(&stream_responses_total)
}

// ---------------------------------------------------------------------------
// Intent: body commands (POD)
// ---------------------------------------------------------------------------

// Semantic capabilities. Orthogonal to transport (writev/sendfile/etc).
Body_Flag :: enum u8 {
	Borrowed, // valid until response send completes
	Owned, // free after send (arena or heap)
	Known_Length,
	Seekable,
	Replayable, // can re-read (static, owned bytes, file)
}

Body_Flags :: bit_set[Body_Flag; u8]

// Body intent only. Status/headers stay on Response for now (open question §9.1).
Response_Cmd_Kind :: enum u8 {
	Static, // borrowed immutable bytes
	Bytes, // owned or temporary bytes (see flags)
	File, // fd region
}

// Flat POD: kind selects which fields are meaningful. Cache-friendly, switch-friendly.
Response_Cmd :: struct {
	kind:   Response_Cmd_Kind,
	flags:  Body_Flags,
	// Static / Bytes
	bytes:  []u8,
	// File
	fd:     i32,
	offset: i64,
	length: i64, // File: byte count; -1 = unknown / rest of file
}

// ---------------------------------------------------------------------------
// Constraints (not syscalls)
// ---------------------------------------------------------------------------

// Snapshot of machine / connection limits that drive planner policy.
// Handlers may read this; they must not execute transport ops from it.
Plan_Context :: struct {
	max_iovecs:            u16, // gather budget (incl. heading slot)
	zero_copy_send:        bool,
	sendfile_ok:           bool, // plain TCP, OS support
	fixed_files:           bool, // registered fd table (Linux)
	tls:                   bool, // forces copy / no sendfile gather
	output_ring_free:      u32, // free staging bytes (0 = unknown / unused)
	sqe_budget:            u16, // remaining SQEs this batch (0 = ignore)
	preferred_copy_budget: u32, // materialize if total body ≤ this
}

// Conservative defaults for pure tests and early wiring.
// Live fill from conn/backend: plan_context(res) in response.odin.
PLAN_DEFAULT_MAX_IOVECS :: u16(1024)
PLAN_DEFAULT_COPY_BUDGET :: u32(4096)

plan_context_default :: proc() -> Plan_Context {
	return Plan_Context {
		max_iovecs            = PLAN_DEFAULT_MAX_IOVECS,
		zero_copy_send        = false,
		sendfile_ok           = false,
		fixed_files           = false,
		tls                   = false,
		output_ring_free      = 0,
		sqe_budget            = 0,
		preferred_copy_budget = PLAN_DEFAULT_COPY_BUDGET,
	}
}

// Handler-side bias over Plan_Context (POD).
// Zero value: no materialize/gather bias (server copy_budget / max_iovecs stand);
// prefer_sendfile is always opt-in (zero → sendfile_ok forced false even if platform allows).
// Applied by plan_context / plan_context_apply_profile (same rules as comparisons/plan plan_ctx_for).
Handler_Profile :: struct {
	prefer_materialize: bool, // force huge copy budget → plan_body materializes memory bodies
	prefer_gather:      bool, // use copy_budget for size gate (0 → disable size-based copy preference)
	prefer_sendfile:    bool, // AND with platform/server sendfile_ok (cannot enable when base is false)
	copy_budget:        u32,  // with prefer_gather: preferred_copy_budget (0 disables size gate)
}

// Apply Handler_Profile bias onto a base Plan_Context (filled from server/conn).
// Order matches comparisons/plan/server: prefer_gather first, prefer_materialize wins if both set.
// sendfile_ok becomes base.sendfile_ok && profile.prefer_sendfile (opt-in; never promotes false→true).
plan_context_apply_profile :: proc(base: Plan_Context, profile: Handler_Profile) -> Plan_Context {
	ctx := base
	if profile.prefer_gather {
		ctx.preferred_copy_budget = profile.copy_budget
	}
	if profile.prefer_materialize {
		ctx.preferred_copy_budget = max(u32)
	}
	ctx.sendfile_ok = base.sendfile_ok && profile.prefer_sendfile
	return ctx
}

// Body middleware: rewrite intent cmds before plan/materialize.
//
// Contract (lifetime-safe):
//   - Rewrite in place into the storage behind `cmds` (compact / expand using cap).
//   - Return a slice with the *same* raw_data as `cmds` (usually cmds[:new_len]).
//   - Do NOT return a stack-allocated or other external buffer: the host does not copy
//     and a returned external slice is use-after-return if it was stack memory.
// len(out) must be ≤ PLAN_MAX_BODY_CMDS; expansion may use cap(cmds) when the host
// passes Response._cmds[:count] (cap is PLAN_MAX_BODY_CMDS).
Body_Middleware :: #type proc(cmds: []Response_Cmd, user: rawptr) -> []Response_Cmd

// Identity: leave cmds unchanged.
body_mw_identity :: proc(cmds: []Response_Cmd, user: rawptr) -> []Response_Cmd {
	_ = user
	return cmds
}

// Drop empty Static/Bytes commands (len == 0). Compacts in place (prefix return).
// Toy transform to prove middleware can rewrite intent without touching the executor.
body_mw_drop_empty_static :: proc(cmds: []Response_Cmd, user: rawptr) -> []Response_Cmd {
	_ = user
	w := 0
	for c in cmds {
		if (c.kind == .Static || c.kind == .Bytes) && len(c.bytes) == 0 {
			continue
		}
		cmds[w] = c
		w += 1
	}
	return cmds[:w]
}

// Run Body_Middleware on cmds; return new length. cmds storage is rewritten in place.
// Empty out → 0. External (non-in-place) returns assert — see Body_Middleware contract.
body_middleware_apply :: proc(mw: Body_Middleware, user: rawptr, cmds: []Response_Cmd) -> int {
	if mw == nil || len(cmds) == 0 {
		return len(cmds)
	}
	out := mw(cmds, user)
	if len(out) == 0 {
		return 0
	}
	assert(len(out) <= PLAN_MAX_BODY_CMDS, "body middleware returned too many cmds")
	// Same base pointer only: rejects stack/external buffers (would be UAF if we copied after return).
	assert(raw_data(out) == raw_data(cmds), "body middleware must rewrite cmds in place (same raw_data)")
	return len(out)
}

// ---------------------------------------------------------------------------
// Execution plan (private transport vocabulary)
// ---------------------------------------------------------------------------

Exec_Op_Kind :: enum u8 {
	Write_Slice, // one contiguous buffer (today's pending_send)
	Writev, // gather: heading + N body views
	Sendfile, // fd region (after headers queued/sent)
	Copy_Into, // materialize source into staging (e.g. file read)
	Patch_CL, // fixed-width Content-Length patch (body_reserve lineage)
	Flush, // batch / TLS boundary
}

// Phase 0: ops describe policy outcome; buffer views filled when executor is wired.
Exec_Op :: struct {
	kind:        Exec_Op_Kind,
	// Writev: number of body iovecs (heading is implicit +1 when planned).
	iov_count:   u16,
	// Byte length of this op's payload when known (headers excluded unless sole Write_Slice).
	byte_len:    i64,
	// Sendfile / Copy_Into from file
	fd:          i32,
	file_offset: i64,
	file_length: i64,
	// Index into input cmd slice that sourced this op (-1 if synthetic / merged).
	cmd_index:   i32,
}

PLAN_MAX_OPS :: 8

// Fixed body-command budget on Response (Phase 1). Overflow asserts; no unbounded growth.
PLAN_MAX_BODY_CMDS :: 32

Plan_Result :: struct {
	ops:           [PLAN_MAX_OPS]Exec_Op,
	op_count:      int,
	// True when planner chose single contiguous materialize (Write_Slice of header+body).
	materialized:  bool,
	// Sum of known body lengths; -1 if any body has unknown length.
	total_body:    i64,
	// Body cmd count classified as in-memory (Static/Bytes) vs File.
	n_mem:         int,
	n_file:        int,
}

// ---------------------------------------------------------------------------
// Command constructors (intent helpers)
// ---------------------------------------------------------------------------

cmd_static :: proc(data: []u8) -> Response_Cmd {
	return Response_Cmd {
		kind  = .Static,
		flags = {.Borrowed, .Known_Length, .Replayable},
		bytes = data,
	}
}

// Owned temporary or arena bytes. Set owned=false for borrowed non-static data.
cmd_bytes :: proc(data: []u8, owned := true) -> Response_Cmd {
	flags: Body_Flags = {.Known_Length, .Replayable}
	if owned {
		flags += {.Owned}
	} else {
		flags += {.Borrowed}
	}
	return Response_Cmd {
		kind  = .Bytes,
		flags = flags,
		bytes = data,
	}
}

cmd_file :: proc(fd: i32, offset: i64, length: i64) -> Response_Cmd {
	flags: Body_Flags = {.Seekable, .Replayable}
	if length >= 0 {
		flags += {.Known_Length}
	}
	return Response_Cmd {
		kind   = .File,
		flags  = flags,
		fd     = fd,
		offset = offset,
		length = length,
	}
}

// Capabilities implied by a command (middleware should use this, not backend probes).
cmd_caps :: proc(c: Response_Cmd) -> Body_Flags {
	switch c.kind {
	case .Static:
		return {.Borrowed, .Known_Length, .Replayable}
	case .Bytes:
		return c.flags
	case .File:
		caps: Body_Flags = {.Seekable, .Replayable}
		if c.length >= 0 {
			caps += {.Known_Length}
		}
		// Prefer explicit flags if caller set extra bits.
		return caps | c.flags
	}
	return {}
}

cmd_known_length :: proc(c: Response_Cmd) -> (n: i64, ok: bool) {
	switch c.kind {
	case .Static, .Bytes:
		return i64(len(c.bytes)), true
	case .File:
		if c.length >= 0 {
			return c.length, true
		}
		return -1, false
	}
	return -1, false
}

// ---------------------------------------------------------------------------
// Planner policy (pure)
// ---------------------------------------------------------------------------

/*
plan_body turns body commands + constraints into an execution plan.

Does not format HTTP headings or touch sockets. Heading is assumed to be
prepended by the executor/materialize path as:
  - part of the single Write_Slice buffer, or
  - iovec[0] of Writev, or
  - a Write_Slice before Sendfile.

Policy (intended; Phase 3+ on the wire):
  1. Empty body            → Write_Slice (headers only)
  2. Memory only
       materialize if TLS | total ≤ copy_budget | iovecs insufficient
       else Writev (heading + each mem slice)
  3. Single file, no mem
       sendfile_ok && !tls → Write_Slice (headers) + Sendfile
       else                → Copy_Into + Write_Slice
  4. Mixed mem + file
       sendfile_ok && !tls && iovecs ok && no mem after File
         → Writev(header+mem prefix) + Sendfile
       else materialize all            → Write_Slice (preserves cmd order)
  5. Unknown length / too many ops     → Write_Slice (safe fallback)

Phase 0/1 wire path may ignore this and always materialize; tests lock the policy.
*/
plan_body :: proc(cmds: []Response_Cmd, ctx: Plan_Context) -> Plan_Result {
	r: Plan_Result
	r.total_body = 0
	r.op_count = 0
	r.materialized = false
	r.n_mem = 0
	r.n_file = 0

	unknown_len := false
	for c in cmds {
		switch c.kind {
		case .Static, .Bytes:
			r.n_mem += 1
		case .File:
			r.n_file += 1
		}
		if n, ok := cmd_known_length(c); ok {
			if r.total_body >= 0 {
				r.total_body += n
			}
		} else {
			unknown_len = true
			r.total_body = -1
		}
	}
	_ = unknown_len

	// Safe fallback helper: single contiguous send after materialize.
	materialize :: proc(r: ^Plan_Result, body_len: i64) {
		r.materialized = true
		r.ops[0] = Exec_Op {
			kind      = .Write_Slice,
			byte_len  = body_len,
			cmd_index = -1,
		}
		r.op_count = 1
	}

	push :: proc(r: ^Plan_Result, op: Exec_Op) -> bool {
		if r.op_count >= PLAN_MAX_OPS {
			return false
		}
		r.ops[r.op_count] = op
		r.op_count += 1
		return true
	}

	// (1) Empty
	if len(cmds) == 0 {
		materialize(&r, 0)
		return r
	}

	// Unknown length: cannot gather with Content-Length; safe path.
	if r.total_body < 0 {
		materialize(&r, -1)
		return r
	}

	// (2) Memory only
	if r.n_file == 0 && r.n_mem > 0 {
		// Need 1 slot for heading + one per body slice.
		need_iov := 1 + r.n_mem
		// preferred_copy_budget: if body is small enough, prefer one copy/send.
		prefer_copy := ctx.preferred_copy_budget > 0 && u32(r.total_body) <= ctx.preferred_copy_budget
		iov_ok := ctx.max_iovecs > 0 && need_iov <= int(ctx.max_iovecs)

		if ctx.tls || prefer_copy || !iov_ok {
			materialize(&r, r.total_body)
			return r
		}

		// Writev: one gather op (heading + body slices).
		if !push(&r, Exec_Op {
			kind      = .Writev,
			iov_count = u16(r.n_mem), // body iovecs; heading implicit
			byte_len  = r.total_body,
			cmd_index = -1,
		}) {
			materialize(&r, r.total_body)
		}
		return r
	}

	// (3) Single file, no in-memory body cmds
	if r.n_file == 1 && r.n_mem == 0 {
		c := cmds[0]
		// Find the file cmd (should be only one).
		fi := 0
		for c2, i in cmds {
			if c2.kind == .File {
				c = c2
				fi = i
				break
			}
		}

		if ctx.sendfile_ok && !ctx.tls {
			if !push(&r, Exec_Op {
				kind      = .Write_Slice,
				byte_len  = 0, // headers only
				cmd_index = -1,
			}) {
				materialize(&r, r.total_body)
				return r
			}
			if !push(&r, Exec_Op {
				kind        = .Sendfile,
				fd          = c.fd,
				file_offset = c.offset,
				file_length = c.length,
				byte_len    = c.length,
				cmd_index   = i32(fi),
			}) {
				// Should not happen with PLAN_MAX_OPS >= 2
				materialize(&r, r.total_body)
			}
			return r
		}

		// No sendfile: copy file into staging, then one write.
		if !push(&r, Exec_Op {
			kind        = .Copy_Into,
			fd          = c.fd,
			file_offset = c.offset,
			file_length = c.length,
			byte_len    = c.length,
			cmd_index   = i32(fi),
		}) {
			materialize(&r, r.total_body)
			return r
		}
		if !push(&r, Exec_Op {
			kind      = .Write_Slice,
			byte_len  = r.total_body,
			cmd_index = -1,
		}) {
			materialize(&r, r.total_body)
		}
		return r
	}

	// (4) Mixed memory + file
	if r.n_file >= 1 && r.n_mem >= 1 {
		// Only optimize the simple case: exactly one file with optional *prefix* mem.
		// Wire sends all mem then the file region — any non-empty mem *after* File
		// would reorder the body, so fall back to materialize (preserve cmd order).
		if r.n_file == 1 && ctx.sendfile_ok && !ctx.tls && !mem_follows_file(cmds) {
			need_iov := 1 + r.n_mem // heading + mem bodies; file is separate Sendfile
			iov_ok := ctx.max_iovecs > 0 && need_iov <= int(ctx.max_iovecs)
			if iov_ok {
				// Gather header + memory slices, then sendfile the file region.
				if !push(&r, Exec_Op {
					kind      = .Writev,
					iov_count = u16(r.n_mem),
					byte_len  = mem_total(cmds),
					cmd_index = -1,
				}) {
					materialize(&r, r.total_body)
					return r
				}
				for c, i in cmds {
					if c.kind == .File {
						if !push(&r, Exec_Op {
							kind        = .Sendfile,
							fd          = c.fd,
							file_offset = c.offset,
							file_length = c.length,
							byte_len    = c.length,
							cmd_index   = i32(i),
						}) {
							materialize(&r, r.total_body)
						}
						return r
					}
				}
			}
		}
		// Fallback: materialize everything
		materialize(&r, r.total_body)
		return r
	}

	// Multiple files or anything unexpected → safe path
	materialize(&r, r.total_body)
	return r
}

@(private = "file")
mem_total :: proc(cmds: []Response_Cmd) -> i64 {
	total: i64 = 0
	for c in cmds {
		#partial switch c.kind {
		case .Static, .Bytes:
			total += i64(len(c.bytes))
		}
	}
	return total
}

// True when a non-empty Static/Bytes cmd appears after a File cmd.
// Sendfile wire always streams file after all mem; that would reorder such sequences.
@(private = "file")
mem_follows_file :: proc(cmds: []Response_Cmd) -> bool {
	seen_file := false
	for c in cmds {
		#partial switch c.kind {
		case .File:
			seen_file = true
		case .Static, .Bytes:
			if seen_file && len(c.bytes) > 0 {
				return true
			}
		}
	}
	return false
}

// plan_exec_kinds fills out with the op kind sequence; returns count.
// Convenience for table tests.
plan_exec_kinds :: proc(cmds: []Response_Cmd, ctx: Plan_Context, out: []Exec_Op_Kind) -> int {
	r := plan_body(cmds, ctx)
	n := min(r.op_count, len(out))
	for i in 0 ..< n {
		out[i] = r.ops[i].kind
	}
	return n
}

// Force materialize-only plan (default wire path when plan_optimize is false).
// Always one Write_Slice; ignores Writev/Sendfile optimize policy.
plan_body_materialize_only :: proc(cmds: []Response_Cmd) -> Plan_Result {
	r: Plan_Result
	r.materialized = true
	r.total_body = 0
	for c in cmds {
		switch c.kind {
		case .Static, .Bytes:
			r.n_mem += 1
			// Once unknown, stay unknown (do not add further lengths).
			if r.total_body >= 0 {
				r.total_body += i64(len(c.bytes))
			}
		case .File:
			r.n_file += 1
			if c.length < 0 {
				r.total_body = -1
			} else if r.total_body >= 0 {
				r.total_body += c.length
			}
		}
	}
	r.ops[0] = Exec_Op {
		kind      = .Write_Slice,
		byte_len  = r.total_body,
		cmd_index = -1,
	}
	r.op_count = 1
	return r
}
