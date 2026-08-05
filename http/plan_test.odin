package http

/*
Table tests for plan_body policy (Phase 0).

These lock intended transport choices without wiring the executor.
Run: odin test http/ -all-packages  (from repo root), or:
     odin test http/
*/

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
test_body_mw_identity :: proc(t: ^testing.T) {
	cmds := []Response_Cmd{cmd_static(_small_a[:]), cmd_static(_small_b[:])}
	out := body_mw_identity(cmds, nil)
	testing.expect_value(t, len(out), 2)
	testing.expect(t, raw_data(out) == raw_data(cmds))
}
