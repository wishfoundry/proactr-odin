package http

/*
Response command buffer + transport planner (experiment).

Phase 1–2 wire: handlers emit Response_Cmd via body_* helpers; optional body
middleware rewrites cmds; response_send still calls plan_body_materialize_only
and copies heading+body into resp_buf for a single Write_Slice (pending_send).
Optimize policy (Writev/Sendfile) is available via plan_body / response_plan_preview
but not yet on the wire — see Phase 3–4.

See docs/RESPONSE_COMMAND_PLANNER.md.

Intent (handlers / middleware)  →  Response_Cmd[]
Policy (this file)              →  Plan_Result / Exec_Op[]
Mechanism (executor / proactr)  →  syscalls  (wire: materialize only)
*/

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

// Handler-side bias over Plan_Context (POD). Zero value = no bias (server defaults).
// Applied by plan_context / plan_context_apply_profile (same rules as comparisons/plan plan_ctx_for).
Handler_Profile :: struct {
	prefer_materialize: bool, // force huge copy budget → plan_body materializes memory bodies
	prefer_gather:      bool, // use copy_budget for size gate (0 → disable size-based copy preference)
	prefer_sendfile:    bool, // AND with platform sendfile_ok for plan_body Sendfile choice
	copy_budget:        u32,  // with prefer_gather: preferred_copy_budget (0 disables size gate)
}

// Apply Handler_Profile bias onto a base Plan_Context (filled from server/conn).
// Order matches comparisons/plan/server: prefer_gather first, prefer_materialize wins if both set.
// sendfile_ok becomes base.sendfile_ok && profile.prefer_sendfile (opt-in).
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
// Should compact in place into the input slice when possible and return a subslice
// of cmds (or a new slice the host will copy back into Response._cmds).
Body_Middleware :: #type proc(cmds: []Response_Cmd, user: rawptr) -> []Response_Cmd

// Identity: leave cmds unchanged.
body_mw_identity :: proc(cmds: []Response_Cmd, user: rawptr) -> []Response_Cmd {
	_ = user
	return cmds
}

// Drop empty Static/Bytes commands (len == 0). Compacts in place.
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
       sendfile_ok && !tls && iovecs ok → Writev(header+mem) + Sendfile
       else materialize all            → Write_Slice
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
		// Only optimize the simple case: exactly one file (common: static prefix + file).
		if r.n_file == 1 && ctx.sendfile_ok && !ctx.tls {
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

// Force materialize-only plan (Phase 1 wire default used by response_send).
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
