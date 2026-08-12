package http

/*
Table tests for plan_body policy (Phase 0).

These lock intended transport choices without wiring the executor.
Run: odin test http/ -all-packages  (from repo root), or:
     odin test http/
*/

import "core:bytes"
import "core:reflect"
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
kinds_of :: proc(cmds: []Response_Cmd, ctx: Plan_Policy, buf: []Exec_Op_Kind) -> []Exec_Op_Kind {
	n := plan_exec_kinds(cmds, ctx, buf)
	return buf[:n]
}

@(private = "file")
kinds_contain :: proc(kinds: []Exec_Op_Kind, k: Exec_Op_Kind) -> bool {
	for g in kinds {
		if g == k {
			return true
		}
	}
	return false
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
	ctx := plan_policy_default()
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
	ctx := plan_policy_default()
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
	// Three large borrowed slices, clear path, plenty of iovecs, over copy budget.
	ctx := plan_policy_default()
	ctx.preferred_copy_budget = 4096
	ctx.max_iovecs = 64
	ctx.ciphered = false

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
test_plan_multi_static_ciphered_forces_materialize :: proc(t: ^testing.T) {
	// Cipher path: no gather/sendfile (was tls).
	ctx := plan_policy_default()
	ctx.preferred_copy_budget = 0 // disable size-based copy preference
	ctx.max_iovecs = 64
	ctx.ciphered = true

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
	ctx := plan_policy_default()
	ctx.preferred_copy_budget = 0
	ctx.max_iovecs = 2 // heading + 1 body only; two bodies need 3
	ctx.ciphered = false

	cmds := []Response_Cmd {
		cmd_static(_big_body[:]),
		cmd_static(_big_body[:]),
	}
	buf: [PLAN_MAX_OPS]Exec_Op_Kind
	got := kinds_of(cmds, ctx, buf[:])
	expect_kinds(t, got, { .Write_Slice })
}

@(test)
test_plan_max_write_unit_forces_materialize :: proc(t: ^testing.T) {
	// max_write_unit > 0 and total_body > unit → materialize on mem path (v0).
	// 0 = ignore (default); large multi-static would otherwise Writev.
	ctx := plan_policy_default()
	ctx.preferred_copy_budget = 0
	ctx.max_iovecs = 64
	ctx.ciphered = false
	ctx.max_write_unit = u32(len(_big_body)) // one slice fits; two exceed

	cmds := []Response_Cmd {
		cmd_static(_big_body[:]),
		cmd_static(_big_body[:]),
	}
	buf: [PLAN_MAX_OPS]Exec_Op_Kind
	got := kinds_of(cmds, ctx, buf[:])
	expect_kinds(t, got, { .Write_Slice })
	testing.expect(t, plan_body(cmds, ctx).materialized)

	// Unit large enough for both → Writev again.
	ctx.max_write_unit = u32(2 * len(_big_body))
	got2 := kinds_of(cmds, ctx, buf[:])
	expect_kinds(t, got2, { .Writev })

	// max_write_unit does not block clear Sendfile (OS windows file path).
	ctx.max_write_unit = 1
	ctx.sendfile_ok = true
	sf := plan_body([]Response_Cmd{cmd_file(1, 0, 1_000_000)}, ctx)
	testing.expect(t, _plan_is_sendfile_wire(sf))
}

@(test)
test_plan_file_sendfile :: proc(t: ^testing.T) {
	ctx := plan_policy_default()
	ctx.sendfile_ok = true
	ctx.ciphered = false

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
	ctx := plan_policy_default()
	ctx.sendfile_ok = false
	ctx.ciphered = false

	cmds := []Response_Cmd{cmd_file(3, 100, 50)}
	buf: [PLAN_MAX_OPS]Exec_Op_Kind
	got := kinds_of(cmds, ctx, buf[:])
	expect_kinds(t, got, { .Copy_Into, .Write_Slice })

	r := plan_body(cmds, ctx)
	testing.expect_value(t, r.ops[0].file_offset, i64(100))
	testing.expect_value(t, r.ops[0].file_length, i64(50))
}

@(test)
test_plan_file_ciphered_disables_sendfile :: proc(t: ^testing.T) {
	// sendfile_ok && ciphered → still Copy_Into (no kernel sendfile under cipher).
	ctx := plan_policy_default()
	ctx.sendfile_ok = true
	ctx.ciphered = true

	cmds := []Response_Cmd{cmd_file(1, 0, 10)}
	buf: [PLAN_MAX_OPS]Exec_Op_Kind
	got := kinds_of(cmds, ctx, buf[:])
	expect_kinds(t, got, { .Copy_Into, .Write_Slice })
}

@(test)
test_plan_mixed_mem_and_file_sendfile :: proc(t: ^testing.T) {
	ctx := plan_policy_default()
	ctx.sendfile_ok = true
	ctx.ciphered = false
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
	ctx := plan_policy_default()
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
	ctx := plan_policy_default()
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

// E0.8 — pure plan_body policy table (Plan A R4 merge-blocker gate)
// File+ciphered → no Sendfile; gather only on clear path; max_write_unit coalesce.
// Host meters (ciphered, max_iovecs) live on Plan_Policy / Plan_Host only.

@(test)
test_e0_8_plan_body_policy_table :: proc(t: ^testing.T) {
	// Table cases 1–6: File / mem / max_write_unit under ciphered + sendfile_ok knobs.
	// Case name is the gate statement; expect_kinds is the full op sequence.

	file_cmds := []Response_Cmd{cmd_file(7, 0, 1_000_000)}
	mem_cmds := []Response_Cmd {
		cmd_static(_big_body[:]),
		cmd_static(_big_body[:]),
		cmd_static(_big_body[:]),
	}
	// 15 KiB > PLAN_DEFAULT_COPY_BUDGET so size gate does not force materialize alone.
	testing.expect(t, i64(3 * len(_big_body)) > i64(PLAN_DEFAULT_COPY_BUDGET))

	// 1. File + ciphered=true → never Sendfile (Copy_Into / materialize path only).
	{
		ctx := plan_policy_default()
		ctx.sendfile_ok = true
		ctx.ciphered = true
		buf: [PLAN_MAX_OPS]Exec_Op_Kind
		got := kinds_of(file_cmds, ctx, buf[:])
		testing.expectf(t, !kinds_contain(got, .Sendfile), "case1 ciphered file must not Sendfile: %v", got)
		expect_kinds(t, got, { .Copy_Into, .Write_Slice })
		testing.expect(t, !plan_body(file_cmds, ctx).materialized) // Copy_Into path, not full materialize
	}

	// 2. File + sendfile_ok=true + ciphered=false → Sendfile present.
	{
		ctx := plan_policy_default()
		ctx.sendfile_ok = true
		ctx.ciphered = false
		buf: [PLAN_MAX_OPS]Exec_Op_Kind
		got := kinds_of(file_cmds, ctx, buf[:])
		testing.expectf(t, kinds_contain(got, .Sendfile), "case2 clear sendfile_ok must Sendfile: %v", got)
		expect_kinds(t, got, { .Write_Slice, .Sendfile })
	}

	// 3. File + sendfile_ok=false + ciphered=false → no Sendfile.
	{
		ctx := plan_policy_default()
		ctx.sendfile_ok = false
		ctx.ciphered = false
		buf: [PLAN_MAX_OPS]Exec_Op_Kind
		got := kinds_of(file_cmds, ctx, buf[:])
		testing.expectf(t, !kinds_contain(got, .Sendfile), "case3 !sendfile_ok must not Sendfile: %v", got)
		expect_kinds(t, got, { .Copy_Into, .Write_Slice })
	}

	// 4. Memory bodies + ciphered=true → no Writev (materialize).
	{
		ctx := plan_policy_default()
		ctx.preferred_copy_budget = 0
		ctx.max_iovecs = 64
		ctx.ciphered = true
		buf: [PLAN_MAX_OPS]Exec_Op_Kind
		got := kinds_of(mem_cmds, ctx, buf[:])
		testing.expectf(t, !kinds_contain(got, .Writev), "case4 ciphered mem must not Writev: %v", got)
		expect_kinds(t, got, { .Write_Slice })
		testing.expect(t, plan_body(mem_cmds, ctx).materialized)
	}

	// 5. Memory + ciphered=false + large max_iovecs + copy budget under total → Writev.
	//    (preferred_copy_budget high enough as a default size gate, but body exceeds it.)
	{
		ctx := plan_policy_default()
		ctx.preferred_copy_budget = PLAN_DEFAULT_COPY_BUDGET // 4096; total 15KiB > budget
		ctx.max_iovecs = 64
		ctx.ciphered = false
		buf: [PLAN_MAX_OPS]Exec_Op_Kind
		got := kinds_of(mem_cmds, ctx, buf[:])
		testing.expectf(t, kinds_contain(got, .Writev), "case5 clear gather path must Writev: %v", got)
		expect_kinds(t, got, { .Writev })
		testing.expect(t, !plan_body(mem_cmds, ctx).materialized)
	}

	// 6. max_write_unit > 0 and body larger → materialize (mem path).
	{
		ctx := plan_policy_default()
		ctx.preferred_copy_budget = 0
		ctx.max_iovecs = 64
		ctx.ciphered = false
		ctx.max_write_unit = u32(len(_big_body)) // one slice fits; three exceed
		buf: [PLAN_MAX_OPS]Exec_Op_Kind
		got := kinds_of(mem_cmds, ctx, buf[:])
		testing.expectf(t, !kinds_contain(got, .Writev), "case6 over max_write_unit must materialize: %v", got)
		expect_kinds(t, got, { .Write_Slice })
		testing.expect(t, plan_body(mem_cmds, ctx).materialized)
	}
}

@(test)
test_e0_8_conn_caps_plan_host_sendfile_path :: proc(t: ^testing.T) {
	// Case 7: Conn_Caps / plan_host_from_caps
	//   Ciphered → plan_host.ciphered true → plan_body never Sendfile even if sendfile_ok.
	//   Sendfile_Possible without Ciphered → host clear; policy filled correctly allows Sendfile.

	// Ciphered bit forces host.ciphered.
	host_ciph := plan_host_from_caps({.Ciphered, .Sendfile_Possible})
	testing.expect(t, host_ciph.ciphered)
	// Public sendfile_ok still true if platform would allow, but ciphered kills Sendfile.
	ctx_pub := plan_context_default()
	ctx_pub.sendfile_ok = true
	pol_ciph := plan_policy_from(ctx_pub, host_ciph)
	testing.expect(t, pol_ciph.ciphered)
	testing.expect(t, pol_ciph.sendfile_ok) // public flag may still be true
	file_cmds := []Response_Cmd{cmd_file(3, 0, 4096)}
	buf: [PLAN_MAX_OPS]Exec_Op_Kind
	got_ciph := kinds_of(file_cmds, pol_ciph, buf[:])
	testing.expectf(
		t,
		!kinds_contain(got_ciph, .Sendfile),
		"Ciphered host must not Sendfile even with sendfile_ok: %v",
		got_ciph,
	)
	expect_kinds(t, got_ciph, { .Copy_Into, .Write_Slice })

	// Clear path: Sendfile_Possible without Ciphered → ciphered false; fill policy for Sendfile.
	host_clear := plan_host_from_caps({.Sendfile_Possible, .Zero_Copy_Send})
	testing.expect(t, !host_clear.ciphered)
	ctx_clear := Plan_Context {
		sendfile_ok           = true, // live fill: !ciphered && H1 && platform
		preferred_copy_budget = PLAN_DEFAULT_COPY_BUDGET,
		max_write_unit        = 0,
		zero_copy_send        = true,
	}
	pol_clear := plan_policy_from(ctx_clear, host_clear)
	testing.expect(t, !pol_clear.ciphered)
	testing.expect(t, pol_clear.sendfile_ok)
	got_clear := kinds_of(file_cmds, pol_clear, buf[:])
	testing.expectf(t, kinds_contain(got_clear, .Sendfile), "clear Sendfile_Possible policy must Sendfile: %v", got_clear)
	expect_kinds(t, got_clear, { .Write_Slice, .Sendfile })
}

@(test)
test_e0_8_plan_context_public_four_fields_only :: proc(t: ^testing.T) {
	// Case 8: Public Plan_Context has only 4 fields — plan_context() does not expose max_iovecs.
	names := reflect.struct_field_names(Plan_Context)
	testing.expect_value(t, len(names), 4)
	// Exact public four (order is struct declaration order).
	testing.expect_value(t, names[0], "sendfile_ok")
	testing.expect_value(t, names[1], "preferred_copy_budget")
	testing.expect_value(t, names[2], "max_write_unit")
	testing.expect_value(t, names[3], "zero_copy_send")
	for n in names {
		testing.expectf(t, n != "max_iovecs", "Plan_Context must not expose max_iovecs")
		testing.expectf(t, n != "ciphered", "Plan_Context must not expose ciphered")
		testing.expectf(t, n != "fixed_files", "Plan_Context must not expose fixed_files")
		testing.expectf(t, n != "output_ring_free", "Plan_Context must not expose output_ring_free")
		testing.expectf(t, n != "sqe_budget", "Plan_Context must not expose sqe_budget")
	}

	// plan_context(res) returns public four only; host meters only on plan_policy.
	r: Response
	pub := plan_context(&r)
	testing.expect_value(t, pub.preferred_copy_budget, PLAN_DEFAULT_COPY_BUDGET)
	testing.expect_value(t, pub.max_write_unit, u32(0))
	testing.expect(t, !pub.sendfile_ok)
	testing.expect(t, !pub.zero_copy_send)
	// size: public surface smaller than full policy (host meters extra).
	testing.expect(t, size_of(Plan_Context) < size_of(Plan_Policy))
	pol := plan_policy(&r)
	testing.expect_value(t, pol.max_iovecs, PLAN_DEFAULT_MAX_IOVECS)
	// Projecting policy → public drops host meters.
	back := plan_policy_context(pol)
	testing.expect_value(t, back.preferred_copy_budget, pub.preferred_copy_budget)
	testing.expect_value(t, back.max_write_unit, pub.max_write_unit)
	testing.expect_value(t, back.sendfile_ok, pub.sendfile_ok)
	testing.expect_value(t, back.zero_copy_send, pub.zero_copy_send)
}


@(test)
test_plan_context_public_is_four_fields :: proc(t: ^testing.T) {
	// Public Plan_Context is exactly four semantic fields (no host meters).
	// E0.8 case 8 (reflect) is test_e0_8_plan_context_public_four_fields_only.
	ctx := plan_context_default()
	testing.expect_value(t, ctx.preferred_copy_budget, PLAN_DEFAULT_COPY_BUDGET)
	testing.expect_value(t, ctx.max_write_unit, u32(0))
	testing.expect(t, !ctx.sendfile_ok)
	testing.expect(t, !ctx.zero_copy_send)
	// Host meters live on Plan_Policy / Plan_Host only.
	host := plan_host_default()
	testing.expect_value(t, host.max_iovecs, PLAN_DEFAULT_MAX_IOVECS)
	testing.expect(t, !host.ciphered)
	testing.expect(t, !host.fixed_files)
	p := plan_policy_from(ctx, host)
	testing.expect_value(t, p.max_iovecs, PLAN_DEFAULT_MAX_IOVECS)
	testing.expect_value(t, plan_policy_context(p).preferred_copy_budget, PLAN_DEFAULT_COPY_BUDGET)
}

@(test)
test_plan_context_apply_profile_prefer_materialize :: proc(t: ^testing.T) {
	// prefer_materialize → huge copy budget forces materialize even for large multi-static.
	base := plan_policy_default()
	base.preferred_copy_budget = 0
	base.max_iovecs = 64
	base.ciphered = false
	base.sendfile_ok = true

	profile := Handler_Profile {
		prefer_materialize = true,
	}
	ctx := plan_policy_apply_profile(base, profile)
	testing.expect_value(t, ctx.preferred_copy_budget, max(u32))
	// prefer_materialize always clears sendfile_ok.
	testing.expect(t, !ctx.sendfile_ok)
	// Host meters pass through.
	testing.expect_value(t, ctx.max_iovecs, u16(64))
	testing.expect(t, !ctx.ciphered)

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
	base := plan_policy_default()
	base.preferred_copy_budget = PLAN_DEFAULT_COPY_BUDGET
	base.max_iovecs = 64
	base.ciphered = false

	profile := Handler_Profile {
		prefer_gather = true,
		copy_budget   = 0,
	}
	ctx := plan_policy_apply_profile(base, profile)
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
	base := plan_policy_default()
	base.sendfile_ok = true
	base.ciphered = false

	// Without optimize and without prefer_sendfile → no Sendfile (conservative).
	ctx_off := plan_policy_apply_profile(base, {}, false)
	testing.expect(t, !ctx_off.sendfile_ok)

	// prefer_sendfile alone enables when base allows (per-route opt-in).
	ctx_on := plan_policy_apply_profile(base, Handler_Profile{prefer_sendfile = true}, false)
	testing.expect(t, ctx_on.sendfile_ok)

	// plan_optimize / optimize=true keeps base sendfile without prefer_sendfile.
	ctx_opt := plan_policy_apply_profile(base, {}, true)
	testing.expect(t, ctx_opt.sendfile_ok)

	cmds := []Response_Cmd{cmd_file(7, 0, 1_000_000)}
	buf: [PLAN_MAX_OPS]Exec_Op_Kind
	got := kinds_of(cmds, ctx_opt, buf[:])
	expect_kinds(t, got, { .Write_Slice, .Sendfile })
}

@(test)
test_plan_context_optimize_allows_sendfile_without_prefer :: proc(t: ^testing.T) {
	// Server plan_optimize path: zero profile still gets Sendfile when base allows.
	base := plan_policy_default()
	base.sendfile_ok = true
	base.ciphered = false
	ctx := plan_policy_apply_profile(base, {}, true)
	testing.expect(t, ctx.sendfile_ok)
	cmds := []Response_Cmd{cmd_file(7, 0, 1_000_000)}
	buf: [PLAN_MAX_OPS]Exec_Op_Kind
	got := kinds_of(cmds, ctx, buf[:])
	expect_kinds(t, got, { .Write_Slice, .Sendfile })
}

@(test)
test_plan_context_prefer_sendfile_cannot_promote :: proc(t: ^testing.T) {
	// Server/platform said no: prefer_sendfile must not force sendfile_ok true.
	base := plan_policy_default()
	base.sendfile_ok = false
	base.ciphered = false

	ctx := plan_policy_apply_profile(base, Handler_Profile{prefer_sendfile = true})
	testing.expect(t, !ctx.sendfile_ok)

	cmds := []Response_Cmd{cmd_file(7, 0, 1_000_000)}
	buf: [PLAN_MAX_OPS]Exec_Op_Kind
	got := kinds_of(cmds, ctx, buf[:])
	// No sendfile → Copy_Into + Write_Slice path.
	expect_kinds(t, got, { .Copy_Into, .Write_Slice })
}

@(test)
test_plan_context_apply_profile_public_only :: proc(t: ^testing.T) {
	// plan_context_apply_profile biases four-field Plan_Context only.
	base := plan_context_default()
	base.sendfile_ok = true
	base.preferred_copy_budget = PLAN_DEFAULT_COPY_BUDGET
	ctx := plan_context_apply_profile(base, Handler_Profile{prefer_gather = true, copy_budget = 0}, false)
	testing.expect_value(t, ctx.preferred_copy_budget, u32(0))
	testing.expect(t, ctx.sendfile_ok) // prefer_gather soft-opens sendfile
	ctx_mat := plan_context_apply_profile(base, Handler_Profile{prefer_materialize = true})
	testing.expect_value(t, ctx_mat.preferred_copy_budget, max(u32))
	testing.expect(t, !ctx_mat.sendfile_ok)
}

@(test)
test_plan_context_zero_profile_is_defaults :: proc(t: ^testing.T) {
	// Response with zero profile and no conn: no optimize wire → sendfile stays off
	// even if platform base would allow (no plan_optimize / prefer_*).
	// plan_context returns public four only.
	r: Response
	ctx := plan_context(&r)
	testing.expect_value(t, ctx.preferred_copy_budget, PLAN_DEFAULT_COPY_BUDGET)
	testing.expect_value(t, ctx.max_write_unit, u32(0))
	testing.expect(t, !ctx.zero_copy_send)
	testing.expect(t, !ctx.sendfile_ok)
	// Full policy still carries host defaults (not on public Plan_Context).
	pol := plan_policy(&r)
	testing.expect_value(t, pol.max_iovecs, PLAN_DEFAULT_MAX_IOVECS)
	testing.expect(t, !pol.ciphered)
	testing.expect(t, !pol.fixed_files)
	testing.expect(t, !pol.sendfile_ok)
}

@(test)
test_plan_context_profile_on_response :: proc(t: ^testing.T) {
	r: Response
	response_set_profile(&r, Handler_Profile{prefer_materialize = true})
	ctx := plan_context(&r)
	testing.expect_value(t, ctx.preferred_copy_budget, max(u32))

	// response_plan_preview uses profile-biased policy (plan_body).
	_response_append_cmd(&r, cmd_static(_big_body[:]))
	_response_append_cmd(&r, cmd_static(_big_body[:]))
	preview := response_plan_preview(&r)
	testing.expect(t, preview.materialized)
	testing.expect_value(t, preview.ops[0].kind, Exec_Op_Kind.Write_Slice)
}

@(test)
test_plan_host_from_caps_ciphered :: proc(t: ^testing.T) {
	// Conn_Caps fill helper: Ciphered bit → host.ciphered.
	h := plan_host_from_caps({.Ciphered, .Sendfile_Possible})
	testing.expect(t, h.ciphered)
	testing.expect_value(t, h.max_iovecs, PLAN_DEFAULT_MAX_IOVECS)
	h2 := plan_host_from_caps({.Sendfile_Possible, .Zero_Copy_Send})
	testing.expect(t, !h2.ciphered)
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

// Single host mutator: _conn_advance_exec_bufs (WRITEV short writes and multi_send).

@(test)
test_conn_advance_exec_bufs_partial_within_first :: proc(t: ^testing.T) {
	// Partial send stays on the same buffer / index (slice remainder).
	conn: Connection
	a := [4]u8{1, 2, 3, 4}
	b := [2]u8{5, 6}
	conn.wire.exec_bufs[0] = a[:]
	conn.wire.exec_bufs[1] = b[:]
	conn.wire.exec_n = 2
	conn.wire.exec_i = 0

	remain := _conn_advance_exec_bufs(&conn, 2)
	testing.expect(t, remain)
	testing.expect_value(t, conn.wire.exec_i, 0)
	testing.expect_value(t, len(conn.wire.exec_bufs[0]), 2)
	testing.expect_value(t, conn.wire.exec_bufs[0][0], u8(3))
	testing.expect_value(t, conn.wire.exec_bufs[0][1], u8(4))
}

@(test)
test_conn_advance_exec_bufs_advance_and_finish :: proc(t: ^testing.T) {
	conn: Connection
	a := [3]u8{1, 2, 3}
	b := [2]u8{4, 5}
	c := [1]u8{6}
	conn.wire.exec_bufs[0] = a[:]
	conn.wire.exec_bufs[1] = b[:]
	conn.wire.exec_bufs[2] = c[:]
	conn.wire.exec_n = 3
	conn.wire.exec_i = 0

	// Full first buffer → move to second.
	remain1 := _conn_advance_exec_bufs(&conn, len(a))
	testing.expect(t, remain1)
	testing.expect_value(t, conn.wire.exec_i, 1)
	testing.expect_value(t, len(conn.wire.exec_bufs[1]), 2)
	testing.expect_value(t, conn.wire.exec_bufs[1][0], u8(4))

	// Full second → third.
	remain2 := _conn_advance_exec_bufs(&conn, 2)
	testing.expect(t, remain2)
	testing.expect_value(t, conn.wire.exec_i, 2)
	testing.expect_value(t, len(conn.wire.exec_bufs[2]), 1)
	testing.expect_value(t, conn.wire.exec_bufs[2][0], u8(6))

	// Full last → finished.
	remain3 := _conn_advance_exec_bufs(&conn, 1)
	testing.expect(t, !remain3)
	testing.expect(t, conn.wire.exec_i >= conn.wire.exec_n)
}

@(test)
test_conn_advance_exec_bufs_single_and_empty_n :: proc(t: ^testing.T) {
	// Single buffer full → finished.
	conn: Connection
	a := [4]u8{1, 2, 3, 4}
	conn.wire.exec_bufs[0] = a[:]
	conn.wire.exec_n = 1
	conn.wire.exec_i = 0
	remain := _conn_advance_exec_bufs(&conn, 4)
	testing.expect(t, !remain)

	// exec_n == 0: no mem queue — advance leaves "no remain" for i>=n.
	conn2: Connection
	conn2.wire.exec_n = 0
	conn2.wire.exec_i = 0
	remain0 := _conn_advance_exec_bufs(&conn2, 4)
	testing.expect(t, !remain0)
}

@(test)
test_conn_advance_exec_bufs_skip_empty_and_zero_progress :: proc(t: ^testing.T) {
	// Empty mid-queue slots must be skipped (empty pending + unfinished → CQE hang).
	conn: Connection
	a := [2]u8{1, 2}
	empty: [0]u8
	c := [1]u8{9}
	conn.wire.exec_bufs[0] = a[:]
	conn.wire.exec_bufs[1] = empty[:]
	conn.wire.exec_bufs[2] = c[:]
	conn.wire.exec_n = 3
	conn.wire.exec_i = 0

	remain := _conn_advance_exec_bufs(&conn, len(a))
	testing.expect(t, remain)
	testing.expect_value(t, conn.wire.exec_i, 2)
	testing.expect_value(t, len(conn.wire.exec_bufs[2]), 1)
	testing.expect_value(t, conn.wire.exec_bufs[2][0], u8(9))

	// Trailing empties → finished.
	conn2: Connection
	conn2.wire.exec_bufs[0] = a[:]
	conn2.wire.exec_bufs[1] = empty[:]
	conn2.wire.exec_bufs[2] = empty[:]
	conn2.wire.exec_n = 3
	conn2.wire.exec_i = 0
	remain2 := _conn_advance_exec_bufs(&conn2, len(a))
	testing.expect(t, !remain2)

	// Zero / negative progress: do not spin (caller fails closed on zero-progress CQE).
	// With sent<=0, remain reports whether queue still has slots from exec_i.
	conn3 := conn
	conn3.wire.exec_i = 0
	conn3.wire.exec_bufs[0] = a[:]
	conn3.wire.exec_bufs[1] = empty[:]
	conn3.wire.exec_bufs[2] = c[:]
	conn3.wire.exec_n = 3
	remain0 := _conn_advance_exec_bufs(&conn3, 0)
	testing.expect(t, remain0) // queue still has work; host_on_wire fails closed on result==0
	remain_neg := _conn_advance_exec_bufs(&conn3, -1)
	testing.expect(t, remain_neg)
}

@(test)
test_plan_is_writev_wire_gate :: proc(t: ^testing.T) {
	// Multi large static → Writev and wire-eligible.
	ctx := plan_policy_default()
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
	ctx2 := plan_policy_default()
	ctx2.sendfile_ok = true
	ctx2.ciphered = false
	sf := plan_body([]Response_Cmd{cmd_file(1, 0, 100)}, ctx2)
	testing.expect(t, !_plan_is_writev_wire(sf))
	testing.expect(t, _plan_is_sendfile_wire(sf))
}

@(test)
test_plan_is_sendfile_wire_gate :: proc(t: ^testing.T) {
	ctx := plan_policy_default()
	ctx.sendfile_ok = true
	ctx.ciphered = false

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
test_conn_advance_exec_bufs_partial :: proc(t: ^testing.T) {
	// Single mem queue: three segments; short write into the middle of buf1.
	conn: Connection
	a := [4]u8{1, 2, 3, 4}
	b := [6]u8{5, 6, 7, 8, 9, 10}
	c := [3]u8{11, 12, 13}
	conn.wire.exec_bufs[0] = a[:]
	conn.wire.exec_bufs[1] = b[:]
	conn.wire.exec_bufs[2] = c[:]
	conn.wire.exec_n = 3
	conn.wire.exec_i = 0

	// Consume all of a (4) + 2 of b → remain b[2:] + c.
	remain := _conn_advance_exec_bufs(&conn, 6)
	testing.expect(t, remain)
	testing.expect_value(t, conn.wire.exec_i, 1)
	testing.expect_value(t, len(conn.wire.exec_bufs[1]), 4) // 6-2 left of b
	testing.expect_value(t, len(conn.wire.exec_bufs[2]), 3)

	// Finish rest in one go.
	remain2 := _conn_advance_exec_bufs(&conn, 4+3)
	testing.expect(t, !remain2)
	testing.expect(t, conn.wire.exec_i >= conn.wire.exec_n)
}

@(test)
test_conn_wire_in_flight :: proc(t: ^testing.T) {
	conn: Connection
	testing.expect(t, !_conn_wire_in_flight(&conn))

	// pending_send alone is not in-flight; wire.kind must be set by submit.
	pending := [2]u8{1, 2}
	conn.wire.pending_send = pending[:]
	testing.expect(t, !_conn_wire_in_flight(&conn))
	conn.wire.pending_send = nil

	conn.wire.kind = .Send
	testing.expect(t, _conn_wire_in_flight(&conn))
	conn.wire.kind = .None

	conn.wire.kind = .Writev
	testing.expect(t, _conn_wire_in_flight(&conn))
	conn.wire.kind = .None

	conn.wire.kind = .Sendfile
	testing.expect(t, _conn_wire_in_flight(&conn))
	conn.wire.kind = .None
	testing.expect(t, !_conn_wire_in_flight(&conn))
}

@(test)
test_conn_arm_and_clear_mem_queue :: proc(t: ^testing.T) {
	conn: Connection
	conn.wire.file_send_fd = 7
	conn.wire.file_send_remaining = 100
	h := [3]u8{1, 2, 3}
	b1 := [2]u8{4, 5}
	bodies := [][]u8{b1[:]}
	ok := _conn_arm_mem_queue(&conn, h[:], bodies)
	testing.expect(t, ok)
	testing.expect_value(t, conn.wire.exec_n, 2)
	testing.expect_value(t, conn.wire.exec_i, 0)
	testing.expect_value(t, len(conn.wire.exec_bufs[0]), 3)
	testing.expect_value(t, len(conn.wire.exec_bufs[1]), 2)

	// clear mem preserves file_send_* and kind
	conn.wire.kind = .Writev
	_conn_clear_mem_queue(&conn)
	testing.expect_value(t, conn.wire.exec_n, 0)
	testing.expect(t, conn.wire.pending_send == nil)
	testing.expect_value(t, conn.wire.kind, Wire_Kind.Writev)
	testing.expect_value(t, conn.wire.file_send_fd, i32(7))
	testing.expect_value(t, conn.wire.file_send_remaining, i64(100))

	// empty arm
	conn2: Connection
	testing.expect(t, !_conn_arm_mem_queue(&conn2, nil, nil))
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
	ctx := plan_policy_default()
	ctx.sendfile_ok = true
	ctx.ciphered = false
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
	// Poison: wrong TE + CL must not appear on the wire after begin_stream.
	headers_set_unsafe(&r.headers, "transfer-encoding", "identity")
	headers_set_unsafe(&r.headers, "content-length", "999")

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
	// CL must be stripped so keep-alive parsers cannot prefer it over TE.
	testing.expect(t, !headers_has_unsafe(r.headers, "content-length"))

	stream_write(&s, transmute([]u8)string("hello"))
	stream_write(&s, nil) // empty write is no-op (must not emit mid-stream 0-chunk terminator)
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
	testing.expect(t, !strings.contains(headers, "content-length"))
	testing.expect(t, !strings.contains(headers, "identity"))
	testing.expect_value(t, body, "5\r\nhello\r\n5\r\nworld\r\n0\r\n\r\n")
}

@(test)
test_response_stream_head_strip_keeps_heading :: proc(t: ^testing.T) {
	// HEAD uses the same stream build path; strip drops chunked body, keeps TE heading.
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

	s := response_begin_stream(&r)
	stream_write(&s, transmute([]u8)string("event: x\n\n"))
	_http_write_chunk_end(&r._buf)
	// Simulate response_send_got_body HEAD branch.
	_response_strip_body_keep_heading(&r)
	got := string(r._buf.buf[:])
	testing.expect(t, strings.has_suffix(got, "\r\n\r\n"))
	testing.expect(t, strings.contains(got, "transfer-encoding: chunked"))
	// No chunk framing after header block.
	sep := strings.index(got, "\r\n\r\n")
	testing.expect(t, sep >= 0)
	testing.expect_value(t, len(got), sep + 4)
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
	r := plan_body({}, plan_policy_default())
	testing.expect(t, r.materialized)
	testing.expect_value(t, r.op_count, 1)
	// Response_Cmd_Kind has only Static/Bytes/File — no Stream kind (G5).
	testing.expect_value(t, int(max(Response_Cmd_Kind)), int(Response_Cmd_Kind.File))
}
