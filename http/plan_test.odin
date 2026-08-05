package http

/*
Table tests for plan_body policy (Phase 0).

These lock intended transport choices without wiring the executor.
Run: odin test http/ -all-packages  (from repo root), or:
     odin test http/
*/

import "core:bytes"
import "core:strings"
import "core:testing"

@(private = "file")
expect_kinds :: proc(t: ^testing.T, got: []Exec_Op_Kind, want: []Exec_Op_Kind, loc := #caller_location) {
	testing.expectf(
		t,
		len(got) == len(want),
		"op count: got %d want %d (%v vs %v)",
		len(got),
		len(want),
		got,
		want,
		loc = loc,
	)
	n := min(len(got), len(want))
	for i in 0 ..< n {
		testing.expectf(
			t,
			got[i] == want[i],
			"op[%d]: got %v want %v",
			i,
			got[i],
			want[i],
			loc = loc,
		)
	}
}

@(private = "file")
kinds_of :: proc(cmds: []Response_Cmd, ctx: Plan_Context, buf: []Exec_Op_Kind) -> []Exec_Op_Kind {
	n := plan_exec_kinds(cmds, ctx, buf)
	return buf[:n]
}

// Large enough that prefer_copy is false under PLAN_DEFAULT_COPY_BUDGET (4096).
@(private = "file")
_big_body: [5 * 1024]u8

@(private = "file")
_small_a: [16]u8
@(private = "file")
_small_b: [32]u8

@(test)
test_plan_empty_is_write_slice :: proc(t: ^testing.T) {
	ctx := plan_context_default()
	buf: [PLAN_MAX_OPS]Exec_Op_Kind
	got := kinds_of({}, ctx, buf[:])
	expect_kinds(t, got, { .Write_Slice })
	r := plan_body({}, ctx)
	testing.expect(t, r.materialized)
	testing.expect_value(t, r.total_body, i64(0))
}

@(test)
test_plan_small_static_prefers_materialize :: proc(t: ^testing.T) {
	// Under preferred_copy_budget → single Write_Slice (not Writev).
	ctx := plan_context_default()
	ctx.preferred_copy_budget = 4096
	cmds := []Response_Cmd{cmd_static(_small_a[:])}
	buf: [PLAN_MAX_OPS]Exec_Op_Kind
	got := kinds_of(cmds, ctx, buf[:])
	expect_kinds(t, got, { .Write_Slice })
	r := plan_body(cmds, ctx)
	testing.expect(t, r.materialized)
}

@(test)
test_plan_multi_static_writev_when_large :: proc(t: ^testing.T) {
	// Three large borrowed slices, no TLS, plenty of iovecs, over copy budget.
	ctx := plan_context_default()
	ctx.preferred_copy_budget = 4096
	ctx.max_iovecs = 64
	ctx.tls = false

	// 5KiB * 3 = 15KiB > 4096
	a := cmd_static(_big_body[:])
	b := cmd_static(_big_body[:])
	c := cmd_static(_big_body[:])
	cmds := []Response_Cmd{a, b, c}

	buf: [PLAN_MAX_OPS]Exec_Op_Kind
	got := kinds_of(cmds, ctx, buf[:])
	expect_kinds(t, got, { .Writev })

	r := plan_body(cmds, ctx)
	testing.expect(t, !r.materialized)
	testing.expect_value(t, r.ops[0].iov_count, u16(3))
	testing.expect_value(t, r.total_body, i64(3 * len(_big_body)))
}

@(test)
test_plan_multi_static_tls_forces_materialize :: proc(t: ^testing.T) {
	ctx := plan_context_default()
	ctx.preferred_copy_budget = 0 // disable size-based copy preference
	ctx.max_iovecs = 64
	ctx.tls = true

	cmds := []Response_Cmd {
		cmd_static(_big_body[:]),
		cmd_static(_big_body[:]),
	}
	buf: [PLAN_MAX_OPS]Exec_Op_Kind
	got := kinds_of(cmds, ctx, buf[:])
	expect_kinds(t, got, { .Write_Slice })
	testing.expect(t, plan_body(cmds, ctx).materialized)
}

@(test)
test_plan_iovec_budget_forces_materialize :: proc(t: ^testing.T) {
	ctx := plan_context_default()
	ctx.preferred_copy_budget = 0
	ctx.max_iovecs = 2 // heading + 1 body only; two bodies need 3
	ctx.tls = false

	cmds := []Response_Cmd {
		cmd_static(_big_body[:]),
		cmd_static(_big_body[:]),
	}
	buf: [PLAN_MAX_OPS]Exec_Op_Kind
	got := kinds_of(cmds, ctx, buf[:])
	expect_kinds(t, got, { .Write_Slice })
}

@(test)
test_plan_file_sendfile :: proc(t: ^testing.T) {
	ctx := plan_context_default()
	ctx.sendfile_ok = true
	ctx.tls = false

	cmds := []Response_Cmd{cmd_file(7, 0, 1_000_000)}
	buf: [PLAN_MAX_OPS]Exec_Op_Kind
	got := kinds_of(cmds, ctx, buf[:])
	expect_kinds(t, got, { .Write_Slice, .Sendfile })

	r := plan_body(cmds, ctx)
	testing.expect(t, !r.materialized)
	testing.expect_value(t, r.ops[1].fd, i32(7))
	testing.expect_value(t, r.ops[1].file_length, i64(1_000_000))
}

@(test)
test_plan_file_no_sendfile_is_copy_then_write :: proc(t: ^testing.T) {
	ctx := plan_context_default()
	ctx.sendfile_ok = false
	ctx.tls = false

	cmds := []Response_Cmd{cmd_file(3, 100, 50)}
	buf: [PLAN_MAX_OPS]Exec_Op_Kind
	got := kinds_of(cmds, ctx, buf[:])
	expect_kinds(t, got, { .Copy_Into, .Write_Slice })

	r := plan_body(cmds, ctx)
	testing.expect_value(t, r.ops[0].file_offset, i64(100))
	testing.expect_value(t, r.ops[0].file_length, i64(50))
}

@(test)
test_plan_file_tls_disables_sendfile :: proc(t: ^testing.T) {
	ctx := plan_context_default()
	ctx.sendfile_ok = true
	ctx.tls = true

	cmds := []Response_Cmd{cmd_file(1, 0, 10)}
	buf: [PLAN_MAX_OPS]Exec_Op_Kind
	got := kinds_of(cmds, ctx, buf[:])
	expect_kinds(t, got, { .Copy_Into, .Write_Slice })
}

@(test)
test_plan_mixed_mem_and_file_sendfile :: proc(t: ^testing.T) {
	ctx := plan_context_default()
	ctx.sendfile_ok = true
	ctx.tls = false
	ctx.max_iovecs = 16
	ctx.preferred_copy_budget = 0

	cmds := []Response_Cmd {
		cmd_static(_big_body[:]),
		cmd_file(9, 0, 4096),
	}
	buf: [PLAN_MAX_OPS]Exec_Op_Kind
	got := kinds_of(cmds, ctx, buf[:])
	expect_kinds(t, got, { .Writev, .Sendfile })
}

@(test)
test_plan_mixed_without_sendfile_materializes :: proc(t: ^testing.T) {
	ctx := plan_context_default()
	ctx.sendfile_ok = false
	ctx.preferred_copy_budget = 0

	cmds := []Response_Cmd {
		cmd_static(_big_body[:]),
		cmd_file(9, 0, 4096),
	}
	buf: [PLAN_MAX_OPS]Exec_Op_Kind
	got := kinds_of(cmds, ctx, buf[:])
	expect_kinds(t, got, { .Write_Slice })
	testing.expect(t, plan_body(cmds, ctx).materialized)
}

@(test)
test_plan_materialize_only_always_write_slice :: proc(t: ^testing.T) {
	// Phase 1 wire default: ignore optimize policy.
	cmds := []Response_Cmd {
		cmd_static(_big_body[:]),
		cmd_static(_big_body[:]),
		cmd_file(1, 0, 99),
	}
	r := plan_body_materialize_only(cmds)
	testing.expect_value(t, r.op_count, 1)
	testing.expect_value(t, r.ops[0].kind, Exec_Op_Kind.Write_Slice)
	testing.expect(t, r.materialized)
	testing.expect_value(t, r.total_body, i64(2 * len(_big_body) + 99))
}

@(test)
test_plan_materialize_only_unknown_length_stays_unknown :: proc(t: ^testing.T) {
	// Regression: once total_body is -1, later known lengths must not add into it
	// (previously File(-1) then Static corrupted total to -1+len).
	cmds := []Response_Cmd {
		cmd_file(1, 0, -1),
		cmd_static(_small_a[:]),
		cmd_file(2, 0, 50),
	}
	r := plan_body_materialize_only(cmds)
	testing.expect_value(t, r.total_body, i64(-1))
	testing.expect_value(t, r.n_file, 2)
	testing.expect_value(t, r.n_mem, 1)
	testing.expect(t, r.materialized)
}

@(test)
test_cmd_caps_static_and_file :: proc(t: ^testing.T) {
	s := cmd_static(_small_a[:])
	testing.expect(t, .Borrowed in cmd_caps(s))
	testing.expect(t, .Replayable in cmd_caps(s))
	testing.expect(t, .Known_Length in cmd_caps(s))
	testing.expect(t, !(.Seekable in cmd_caps(s)))

	f := cmd_file(0, 0, 10)
	testing.expect(t, .Seekable in cmd_caps(f))
	testing.expect(t, .Known_Length in cmd_caps(f))
	testing.expect(t, .Replayable in cmd_caps(f))

	owned := cmd_bytes(_small_b[:], true)
	testing.expect(t, .Owned in cmd_caps(owned))
	testing.expect(t, !(.Borrowed in cmd_caps(owned)))
}

@(test)
test_plan_bytes_and_static_same_memory_path :: proc(t: ^testing.T) {
	ctx := plan_context_default()
	ctx.preferred_copy_budget = 0
	ctx.max_iovecs = 16

	cmds := []Response_Cmd {
		cmd_static(_big_body[:]),
		cmd_bytes(_big_body[:], true),
	}
	buf: [PLAN_MAX_OPS]Exec_Op_Kind
	got := kinds_of(cmds, ctx, buf[:])
	expect_kinds(t, got, { .Writev })
}

// --- Phase 2: Handler_Profile, plan_context, body middleware -----------------

@(test)
test_plan_context_apply_profile_prefer_materialize :: proc(t: ^testing.T) {
	// prefer_materialize → huge copy budget forces materialize even for large multi-static.
	base := plan_context_default()
	base.preferred_copy_budget = 0
	base.max_iovecs = 64
	base.tls = false
	base.sendfile_ok = true

	profile := Handler_Profile {
		prefer_materialize = true,
	}
	ctx := plan_context_apply_profile(base, profile)
	testing.expect_value(t, ctx.preferred_copy_budget, max(u32))
	// prefer_sendfile is opt-in: zero/false clears sendfile_ok.
	testing.expect(t, !ctx.sendfile_ok)

	cmds := []Response_Cmd {
		cmd_static(_big_body[:]),
		cmd_static(_big_body[:]),
		cmd_static(_big_body[:]),
	}
	buf: [PLAN_MAX_OPS]Exec_Op_Kind
	got := kinds_of(cmds, ctx, buf[:])
	expect_kinds(t, got, { .Write_Slice })
	testing.expect(t, plan_body(cmds, ctx).materialized)
}

@(test)
test_plan_context_apply_profile_prefer_gather :: proc(t: ^testing.T) {
	// prefer_gather + copy_budget=0 disables size gate → Writev for multi large static.
	base := plan_context_default()
	base.preferred_copy_budget = PLAN_DEFAULT_COPY_BUDGET
	base.max_iovecs = 64
	base.tls = false

	profile := Handler_Profile {
		prefer_gather = true,
		copy_budget   = 0,
	}
	ctx := plan_context_apply_profile(base, profile)
	testing.expect_value(t, ctx.preferred_copy_budget, u32(0))

	cmds := []Response_Cmd {
		cmd_static(_big_body[:]),
		cmd_static(_big_body[:]),
	}
	buf: [PLAN_MAX_OPS]Exec_Op_Kind
	got := kinds_of(cmds, ctx, buf[:])
	expect_kinds(t, got, { .Writev })
}

@(test)
test_plan_context_apply_profile_prefer_sendfile :: proc(t: ^testing.T) {
	base := plan_context_default()
	base.sendfile_ok = true
	base.tls = false

	// Without prefer_sendfile → no Sendfile.
	ctx_off := plan_context_apply_profile(base, {})
	testing.expect(t, !ctx_off.sendfile_ok)

	// With prefer_sendfile → base capability preserved.
	ctx_on := plan_context_apply_profile(base, Handler_Profile{prefer_sendfile = true})
	testing.expect(t, ctx_on.sendfile_ok)

	cmds := []Response_Cmd{cmd_file(7, 0, 1_000_000)}
	buf: [PLAN_MAX_OPS]Exec_Op_Kind
	got := kinds_of(cmds, ctx_on, buf[:])
	expect_kinds(t, got, { .Write_Slice, .Sendfile })
}

@(test)
test_plan_context_prefer_sendfile_cannot_promote :: proc(t: ^testing.T) {
	// Server/platform said no: prefer_sendfile must not force sendfile_ok true.
	base := plan_context_default()
	base.sendfile_ok = false
	base.tls = false

	ctx := plan_context_apply_profile(base, Handler_Profile{prefer_sendfile = true})
	testing.expect(t, !ctx.sendfile_ok)

	cmds := []Response_Cmd{cmd_file(7, 0, 1_000_000)}
	buf: [PLAN_MAX_OPS]Exec_Op_Kind
	got := kinds_of(cmds, ctx, buf[:])
	// No sendfile → Copy_Into + Write_Slice path.
	expect_kinds(t, got, { .Copy_Into, .Write_Slice })
}

@(test)
test_plan_context_zero_profile_is_defaults :: proc(t: ^testing.T) {
	// Response with zero profile and no conn: server-like base + zero bias.
	// prefer_sendfile false → sendfile_ok false even if platform base was true.
	r: Response
	ctx := plan_context(&r)
	testing.expect_value(t, ctx.preferred_copy_budget, PLAN_DEFAULT_COPY_BUDGET)
	testing.expect_value(t, ctx.max_iovecs, PLAN_DEFAULT_MAX_IOVECS)
	testing.expect(t, !ctx.tls)
	testing.expect(t, !ctx.zero_copy_send)
	testing.expect(t, !ctx.sendfile_ok) // prefer_sendfile opt-in
}

@(test)
test_plan_context_profile_on_response :: proc(t: ^testing.T) {
	r: Response
	response_set_profile(&r, Handler_Profile{prefer_materialize = true})
	ctx := plan_context(&r)
	testing.expect_value(t, ctx.preferred_copy_budget, max(u32))

	// response_plan_preview uses profile-biased context.
	_response_append_cmd(&r, cmd_static(_big_body[:]))
	_response_append_cmd(&r, cmd_static(_big_body[:]))
	preview := response_plan_preview(&r)
	testing.expect(t, preview.materialized)
	testing.expect_value(t, preview.ops[0].kind, Exec_Op_Kind.Write_Slice)
}

@(test)
test_body_mw_drop_empty_static :: proc(t: ^testing.T) {
	empty: [0]u8
	a := cmd_static(_small_a[:])
	b := cmd_static(empty[:])
	c := cmd_bytes(_small_b[:], true)
	d := cmd_static(empty[:])
	cmds := []Response_Cmd{a, b, c, d}
	// Need a mutable buffer for in-place compact.
	buf: [4]Response_Cmd
	copy(buf[:], cmds)
	out := body_mw_drop_empty_static(buf[:], nil)
	testing.expect_value(t, len(out), 2)
	testing.expect_value(t, out[0].kind, Response_Cmd_Kind.Static)
	testing.expect_value(t, len(out[0].bytes), len(_small_a))
	testing.expect_value(t, out[1].kind, Response_Cmd_Kind.Bytes)
	testing.expect_value(t, len(out[1].bytes), len(_small_b))
}

@(test)
test_response_body_middleware_rewrites_cmds :: proc(t: ^testing.T) {
	r: Response
	empty: [0]u8
	_response_append_cmd(&r, cmd_static(empty[:]))
	_response_append_cmd(&r, cmd_static(_small_a[:]))
	_response_append_cmd(&r, cmd_static(empty[:]))
	testing.expect_value(t, r._cmd_count, 3)

	response_body_middleware(&r, body_mw_drop_empty_static, nil)
	_response_apply_body_middleware(&r)
	testing.expect_value(t, r._cmd_count, 1)
	testing.expect_value(t, r._cmds[0].kind, Response_Cmd_Kind.Static)
	testing.expect_value(t, len(r._cmds[0].bytes), len(_small_a))
}

@(test)
test_response_plan_preview_applies_middleware_snapshot :: proc(t: ^testing.T) {
	// Preview must see post-middleware cmds without mutating Response (send applies once).
	r: Response
	empty: [0]u8
	_response_append_cmd(&r, cmd_static(empty[:]))
	_response_append_cmd(&r, cmd_static(_small_a[:]))
	_response_append_cmd(&r, cmd_static(empty[:]))
	response_body_middleware(&r, body_mw_drop_empty_static, nil)

	preview := response_plan_preview(&r)
	testing.expect_value(t, preview.n_mem, 1)
	testing.expect_value(t, preview.total_body, i64(len(_small_a)))
	// Response cmds unchanged by preview.
	testing.expect_value(t, r._cmd_count, 3)
}

@(test)
test_body_mw_identity :: proc(t: ^testing.T) {
	cmds := []Response_Cmd{cmd_static(_small_a[:]), cmd_static(_small_b[:])}
	out := body_mw_identity(cmds, nil)
	testing.expect_value(t, len(out), 2)
	testing.expect(t, raw_data(out) == raw_data(cmds))
}

@(test)
test_body_middleware_apply_in_place :: proc(t: ^testing.T) {
	empty: [0]u8
	buf: [4]Response_Cmd
	buf[0] = cmd_static(empty[:])
	buf[1] = cmd_static(_small_a[:])
	buf[2] = cmd_static(empty[:])
	n := body_middleware_apply(body_mw_drop_empty_static, nil, buf[:3])
	testing.expect_value(t, n, 1)
	testing.expect_value(t, len(buf[0].bytes), len(_small_a))

	// nil mw leaves length alone.
	testing.expect_value(t, body_middleware_apply(nil, nil, buf[:1]), 1)
}

// --- Phase 3: multi-buffer exec queue advance + Writev wire policy ------------

@(test)
test_exec_queue_after_send_partial :: proc(t: ^testing.T) {
	// Partial send stays on the same buffer / index.
	a := [4]u8{1, 2, 3, 4}
	b := [2]u8{5, 6}
	bufs := [][]u8{a[:], b[:]}
	pending := bufs[0]
	new_p, new_i, finished := exec_queue_after_send(bufs, 0, 2, pending, 2)
	testing.expect(t, !finished)
	testing.expect_value(t, new_i, 0)
	testing.expect_value(t, len(new_p), 2)
	testing.expect_value(t, new_p[0], u8(3))
	testing.expect_value(t, new_p[1], u8(4))
}

@(test)
test_exec_queue_after_send_advance_and_finish :: proc(t: ^testing.T) {
	a := [3]u8{1, 2, 3}
	b := [2]u8{4, 5}
	c := [1]u8{6}
	bufs := [][]u8{a[:], b[:], c[:]}

	// Full first buffer → move to second.
	p1, i1, f1 := exec_queue_after_send(bufs, 0, 3, bufs[0], len(bufs[0]))
	testing.expect(t, !f1)
	testing.expect_value(t, i1, 1)
	testing.expect_value(t, len(p1), 2)
	testing.expect_value(t, p1[0], u8(4))

	// Full second → third.
	p2, i2, f2 := exec_queue_after_send(bufs, i1, 3, p1, len(p1))
	testing.expect(t, !f2)
	testing.expect_value(t, i2, 2)
	testing.expect_value(t, len(p2), 1)
	testing.expect_value(t, p2[0], u8(6))

	// Full last → finished.
	p3, i3, f3 := exec_queue_after_send(bufs, i2, 3, p2, len(p2))
	testing.expect(t, f3)
	testing.expect_value(t, i3, 3)
	testing.expect(t, p3 == nil)
}

@(test)
test_exec_queue_single_buffer_finish :: proc(t: ^testing.T) {
	// exec_n == 0 or single buffer full → finished (matches materialize host path using exec_n=0).
	a := [4]u8{1, 2, 3, 4}
	bufs := [][]u8{a[:]}
	_, _, f := exec_queue_after_send(bufs, 0, 1, a[:], 4)
	testing.expect(t, f)

	// exec_n == 0: treat as finished after full send of pending.
	_, _, f0 := exec_queue_after_send(bufs, 0, 0, a[:], 4)
	testing.expect(t, f0)
}

@(test)
test_exec_queue_skip_empty_and_zero_progress :: proc(t: ^testing.T) {
	// Empty mid-queue slots must be skipped (empty pending + unfinished → CQE hang).
	a := [2]u8{1, 2}
	empty: [0]u8
	c := [1]u8{9}
	bufs := [][]u8{a[:], empty[:], c[:]}

	p, i, f := exec_queue_after_send(bufs, 0, 3, bufs[0], len(bufs[0]))
	testing.expect(t, !f)
	testing.expect_value(t, i, 2)
	testing.expect_value(t, len(p), 1)
	testing.expect_value(t, p[0], u8(9))

	// Trailing empties → finished.
	bufs2 := [][]u8{a[:], empty[:], empty[:]}
	_, _, f2 := exec_queue_after_send(bufs2, 0, 3, bufs2[0], len(bufs2[0]))
	testing.expect(t, f2)

	// Zero progress → finished (caller must not resubmit spin).
	_, _, f0 := exec_queue_after_send(bufs, 0, 3, bufs[0], 0)
	testing.expect(t, f0)
	_, _, fneg := exec_queue_after_send(bufs, 0, 3, bufs[0], -1)
	testing.expect(t, fneg)
}

@(test)
test_plan_is_writev_wire_gate :: proc(t: ^testing.T) {
	// Multi large static → Writev and wire-eligible.
	ctx := plan_context_default()
	ctx.preferred_copy_budget = 0
	ctx.max_iovecs = 64
	cmds := []Response_Cmd {
		cmd_static(_big_body[:]),
		cmd_static(_big_body[:]),
		cmd_static(_big_body[:]),
	}
	r := plan_body(cmds, ctx)
	testing.expect(t, _plan_is_writev_wire(r))
	testing.expect_value(t, r.ops[0].iov_count, u16(3))

	// Materialize plan is not wire Writev.
	m := plan_body_materialize_only(cmds)
	testing.expect(t, !_plan_is_writev_wire(m))

	// Sendfile plan is not wire Writev (uses Phase 4 file path instead).
	ctx2 := plan_context_default()
	ctx2.sendfile_ok = true
	ctx2.tls = false
	sf := plan_body([]Response_Cmd{cmd_file(1, 0, 100)}, ctx2)
	testing.expect(t, !_plan_is_writev_wire(sf))
	testing.expect(t, _plan_is_sendfile_wire(sf))
}

@(test)
test_plan_is_sendfile_wire_gate :: proc(t: ^testing.T) {
	ctx := plan_context_default()
	ctx.sendfile_ok = true
	ctx.tls = false

	// Pure file → Write_Slice + Sendfile → wire-eligible.
	sf := plan_body([]Response_Cmd{cmd_file(7, 0, 1024)}, ctx)
	testing.expect(t, _plan_is_sendfile_wire(sf))
	testing.expect_value(t, sf.ops[0].kind, Exec_Op_Kind.Write_Slice)
	testing.expect_value(t, sf.ops[1].kind, Exec_Op_Kind.Sendfile)
	testing.expect_value(t, sf.ops[1].file_length, i64(1024))

	// No sendfile → Copy_Into + Write_Slice → not Sendfile wire.
	ctx_off := ctx
	ctx_off.sendfile_ok = false
	copy_plan := plan_body([]Response_Cmd{cmd_file(7, 0, 1024)}, ctx_off)
	testing.expect(t, !_plan_is_sendfile_wire(copy_plan))

	// Materialize-only never sendfile-wire.
	mat := plan_body_materialize_only([]Response_Cmd{cmd_file(7, 0, 1024)})
	testing.expect(t, !_plan_is_sendfile_wire(mat))

	// Mixed mem + file with sendfile → Writev + Sendfile → wire-eligible.
	mix := plan_body([]Response_Cmd{cmd_static(_big_body[:]), cmd_file(7, 0, 100)}, ctx)
	testing.expect(t, _plan_is_sendfile_wire(mix))
	testing.expect(t, !_plan_is_writev_wire(mix))
}

@(test)
test_file_send_after_pread_math :: proc(t: ^testing.T) {
	// Full chunk within remaining.
	off, rem, ok := file_send_after_pread(100, 1000, 256)
	testing.expect(t, ok)
	testing.expect_value(t, off, i64(356))
	testing.expect_value(t, rem, i64(744))

	// Exact remaining.
	off2, rem2, ok2 := file_send_after_pread(0, 64, 64)
	testing.expect(t, ok2)
	testing.expect_value(t, off2, i64(64))
	testing.expect_value(t, rem2, i64(0))

	// Short pread (got < want, got < remaining): progress, not error.
	off3, rem3, ok3 := file_send_after_pread(0, 1000, 100)
	testing.expect(t, ok3)
	testing.expect_value(t, off3, i64(100))
	testing.expect_value(t, rem3, i64(900))

	// Short pread leaving a final partial region.
	off4, rem4, ok4 := file_send_after_pread(900, 100, 40)
	testing.expect(t, ok4)
	testing.expect_value(t, off4, i64(940))
	testing.expect_value(t, rem4, i64(60))

	// Invalid: got 0, negative, or past remaining.
	_, _, ok0 := file_send_after_pread(0, 10, 0)
	testing.expect(t, !ok0)
	_, _, okn := file_send_after_pread(0, 10, -1)
	testing.expect(t, !okn)
	_, _, okx := file_send_after_pread(0, 10, 11)
	testing.expect(t, !okx)
	_, _, okr := file_send_after_pread(0, 0, 1)
	testing.expect(t, !okr)
}

@(test)
test_plan_mem_after_file_materializes :: proc(t: ^testing.T) {
	// File then Static would be reordered by Writev+Sendfile (mem always before file).
	// Policy must materialize to preserve cmd order on the wire.
	ctx := plan_context_default()
	ctx.sendfile_ok = true
	ctx.tls = false
	ctx.max_iovecs = 16
	ctx.preferred_copy_budget = 0

	// Prefix mem + file: optimize allowed.
	prefix := []Response_Cmd {
		cmd_static(_big_body[:]),
		cmd_file(9, 0, 4096),
	}
	testing.expect(t, _plan_is_sendfile_wire(plan_body(prefix, ctx)))

	// File then mem: must not Sendfile-wire.
	suffix := []Response_Cmd {
		cmd_file(9, 0, 4096),
		cmd_static(_big_body[:]),
	}
	suf := plan_body(suffix, ctx)
	testing.expect(t, suf.materialized)
	testing.expect(t, !_plan_is_sendfile_wire(suf))
	buf: [PLAN_MAX_OPS]Exec_Op_Kind
	expect_kinds(t, kinds_of(suffix, ctx, buf[:]), { .Write_Slice })

	// Interleaved: Static, File, Static → materialize.
	inter := []Response_Cmd {
		cmd_static(_small_a[:]),
		cmd_file(9, 0, 10),
		cmd_static(_small_b[:]),
	}
	ir := plan_body(inter, ctx)
	testing.expect(t, ir.materialized)
	testing.expect(t, !_plan_is_sendfile_wire(ir))

	// Empty Static after File is harmless (no wire bytes) — still optimize.
	empty: [0]u8
	empty_after := []Response_Cmd {
		cmd_file(9, 0, 100),
		cmd_static(empty[:]),
	}
	// n_mem includes empty; mem_follows_file ignores empty → Writev+Sendfile.
	ea := plan_body(empty_after, ctx)
	testing.expect(t, !ea.materialized)
	testing.expect(t, _plan_is_sendfile_wire(ea))
}

@(test)
test_cmds_mem_body_len :: proc(t: ^testing.T) {
	n, ok := _cmds_mem_body_len([]Response_Cmd {
		cmd_static(_small_a[:]),
		cmd_bytes(_small_b[:], true),
	})
	testing.expect(t, ok)
	testing.expect_value(t, n, len(_small_a) + len(_small_b))

	_, ok2 := _cmds_mem_body_len([]Response_Cmd {
		cmd_static(_small_a[:]),
		cmd_file(1, 0, 10),
	})
	testing.expect(t, !ok2)
}

// --- Phase 5: Response_Stream (not Response_Cmd / plan_body) -----------------

@(test)
test_http_chunk_framing :: proc(t: ^testing.T) {
	// Pure chunk framing used by stream_write / stream_end.
	b: bytes.Buffer
	_http_write_chunk(&b, transmute([]u8)string("ab"))
	_http_write_chunk(&b, transmute([]u8)string("xyz"))
	_http_write_chunk(&b, nil) // empty → no-op
	_http_write_chunk_end(&b)
	got := string(bytes.buffer_to_bytes(&b))
	testing.expect_value(t, got, "2\r\nab\r\n3\r\nxyz\r\n0\r\n\r\n")
	delete(b.buf)
}

@(test)
test_response_stream_chunked_body :: proc(t: ^testing.T) {
	// begin_stream + stream_write produce valid chunked framing after the heading.
	// Does not call stream_end (needs host worker); finishes with _http_write_chunk_end.
	r: Response
	headers_init(&r.headers, context.allocator)
	defer delete(r.headers._kv)

	r.status = .OK
	// Pre-set Date so heading format does not need thread-local server_date / td.
	headers_set_unsafe(&r.headers, "date", "Fri, 05 Feb 2023 09:01:10 GMT")
	headers_set_unsafe(&r.headers, "content-type", "text/event-stream")

	conn: Connection
	r._conn = &conn
	wire := make([dynamic]u8, 0, 1024, context.allocator)
	defer delete(wire)
	r._buf.buf = wire
	r._buf.buf.allocator = context.allocator

	s := response_begin_stream(&r)
	testing.expect(t, r._streaming)
	testing.expect(t, r._heading_written)
	testing.expect_value(t, r._cmd_count, 0)

	te, has_te := headers_get_unsafe(r.headers, "transfer-encoding")
	testing.expect(t, has_te)
	testing.expect_value(t, te, "chunked")

	stream_write(&s, transmute([]u8)string("hello"))
	stream_write(&s, transmute([]u8)string("world"))
	stream_flush(&s) // Phase 5 no-op
	_http_write_chunk_end(&r._buf)

	full := string(r._buf.buf[:])
	// Header block ends with \r\n\r\n; body is chunked.
	sep := strings.index(full, "\r\n\r\n")
	testing.expect(t, sep >= 0)
	headers := full[:sep]
	body := full[sep + 4:]
	testing.expect(t, strings.contains(headers, "transfer-encoding: chunked"))
	testing.expect_value(t, body, "5\r\nhello\r\n5\r\nworld\r\n0\r\n\r\n")
}

@(test)
test_response_stream_mutual_exclusion_flags :: proc(t: ^testing.T) {
	// Stream path sets flags that body cmd / reserve paths assert against.
	// (Assert-failure paths are not exercised here — would abort the process.)
	r: Response
	headers_init(&r.headers, context.allocator)
	defer delete(r.headers._kv)
	r.status = .OK
	headers_set_unsafe(&r.headers, "date", "Fri, 05 Feb 2023 09:01:10 GMT")
	conn: Connection
	r._conn = &conn
	wire := make([dynamic]u8, 0, 512, context.allocator)
	defer delete(wire)
	r._buf.buf = wire
	r._buf.buf.allocator = context.allocator

	// Before stream: cmds allowed.
	testing.expect(t, !r._streaming)
	_response_append_cmd(&r, cmd_static(_small_a[:]))
	testing.expect_value(t, r._cmd_count, 1)

	// Reset as if a new request, then begin stream.
	r._cmd_count = 0
	clear(&r._buf.buf)
	r._heading_written = false
	s := begin_stream(&r)
	testing.expect(t, r._streaming)
	testing.expect(t, r._heading_written)
	testing.expect(t, !r._stream_ended)
	testing.expect_value(t, r._cmd_count, 0)
	// stream_end would send; mark ended without host for flag check.
	_ = s
	r._stream_ended = true
	testing.expect(t, r._stream_ended)
}

@(test)
test_stream_not_counted_as_plan_body :: proc(t: ^testing.T) {
	// Empty cmds → plan_body is empty Write_Slice; stream is not a cmd kind.
	r := plan_body({}, plan_context_default())
	testing.expect(t, r.materialized)
	testing.expect_value(t, r.op_count, 1)
	// Response_Cmd_Kind has only Static/Bytes/File — no Stream kind (G5).
	testing.expect_value(t, int(max(Response_Cmd_Kind)), int(Response_Cmd_Kind.File))
}
