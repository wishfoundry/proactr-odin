// Pure unit tests for pipe POD + seal∥send physics (Plan A R4–PR5).
// No OpenSSL, no sockets, no ring — laws + mock-seal bulk sim only.
// Run: odin test http -o:none
package http

import "core:testing"

// ---------------------------------------------------------------------------
// Constants sanity
// ---------------------------------------------------------------------------

@(test)
test_pipe_pod_constants :: proc(t: ^testing.T) {
	testing.expect_value(t, PULL_WINDOW_DEFAULT, 64 * 1024)
	testing.expect_value(t, TLS_SEAL_WINDOW_DEFAULT, 256 * 1024)
	testing.expect_value(t, PIPE_MAX_WRITE_UNIT_DEFAULT, TLS_SEAL_WINDOW_DEFAULT)
	testing.expect_value(t, TLS_RECORD_PLAIN, 16 * 1024)
	testing.expect_value(t, TLS_RECORD_BATCH_TARGET, 4)
	testing.expect_value(t, CT_SLOTS, 2)
	testing.expect_value(t, CT_SLAB_SIZE, PULL_WINDOW_DEFAULT)
	testing.expect_value(t, TLS_CT_SLAB_DEFAULT, TLS_SEAL_WINDOW_DEFAULT + 16 * 1024)
	testing.expect_value(t, PT_HIGH_WATER_DEFAULT, 128 * 1024)
	testing.expect_value(t, PT_HIGH_WATER_TLS_DEFAULT, 2 * TLS_SEAL_WINDOW_DEFAULT)
	testing.expect_value(t, CT_HIGH_WATER_DEFAULT, 128 * 1024)
	testing.expect_value(t, RX_HOLD_CAP, 16 * 1024)
	testing.expect_value(t, SEAL_Q_CAP, 32)
	testing.expect_value(t, SEAL_N_MAX, CT_SLOTS)
	testing.expect_value(t, FIREHOSE_PEAK_MULT, 4)
	// Batch target ≈ PULL_WINDOW when records are TLS_RECORD_PLAIN
	testing.expect_value(t, TLS_RECORD_BATCH_TARGET * TLS_RECORD_PLAIN, PULL_WINDOW_DEFAULT)
}

// ---------------------------------------------------------------------------
// Conn_Caps orthogonal (defined in plan.odin; part of pipe caps story)
// ---------------------------------------------------------------------------

@(test)
test_conn_caps_orthogonal :: proc(t: ^testing.T) {
	caps: Conn_Caps
	caps += {.Ciphered, .Multiplex}
	testing.expect(t, .Ciphered in caps)
	testing.expect(t, .Multiplex in caps)
	testing.expect(t, .Sendfile_Possible not_in caps)
	testing.expect(t, .Zero_Copy_Send not_in caps)
	// Clear H1-ish: sendfile possible without cipher
	clear_caps: Conn_Caps = {.Sendfile_Possible}
	testing.expect(t, .Ciphered not_in clear_caps)
	testing.expect(t, .Sendfile_Possible in clear_caps)
}

// ---------------------------------------------------------------------------
// pt_admit / pt_release high-water
// ---------------------------------------------------------------------------

@(test)
test_pt_admit_under_high_water :: proc(t: ^testing.T) {
	pt: Conn_Pt_Ring
	pt_ring_init(&pt, 128)
	testing.expect(t, pt_admit(&pt, 64))
	testing.expect_value(t, pt.admitted, u32(64))
	testing.expect(t, pt_admit(&pt, 64))
	testing.expect_value(t, pt.admitted, u32(128))
}

@(test)
test_pt_admit_rejects_over_high_water :: proc(t: ^testing.T) {
	pt: Conn_Pt_Ring
	pt_ring_init(&pt, 100)
	testing.expect(t, pt_admit(&pt, 60))
	// 60+50 = 110 > 100
	testing.expect(t, !pt_admit(&pt, 50))
	testing.expect_value(t, pt.admitted, u32(60)) // unchanged on reject
	// exact fill still ok
	testing.expect(t, pt_admit(&pt, 40))
	testing.expect_value(t, pt.admitted, u32(100))
	// one more byte fails
	testing.expect(t, !pt_admit(&pt, 1))
}

@(test)
test_pt_admit_zero_need :: proc(t: ^testing.T) {
	pt: Conn_Pt_Ring
	pt_ring_init(&pt, 10)
	testing.expect(t, pt_admit(&pt, 0))
	testing.expect_value(t, pt.admitted, u32(0))
}

@(test)
test_pt_release :: proc(t: ^testing.T) {
	pt: Conn_Pt_Ring
	pt_ring_init(&pt, PT_HIGH_WATER_DEFAULT)
	testing.expect(t, pt_admit(&pt, 1000))
	pt_release(&pt, 400)
	testing.expect_value(t, pt.admitted, u32(600))
	pt_release(&pt, 600)
	testing.expect_value(t, pt.admitted, u32(0))
	// over-release floors at 0
	pt_release(&pt, 10)
	testing.expect_value(t, pt.admitted, u32(0))
}

@(test)
test_pt_ring_init_default_hw :: proc(t: ^testing.T) {
	pt: Conn_Pt_Ring
	pt_ring_init(&pt) // 0 → default
	testing.expect_value(t, pt.high_water, u32(PT_HIGH_WATER_DEFAULT))
	testing.expect_value(t, pt.admitted, u32(0))
}

// ---------------------------------------------------------------------------
// Dual CT high-water
// ---------------------------------------------------------------------------

@(test)
test_ct_admit_under_high_water :: proc(t: ^testing.T) {
	pipe: Tls_Pipe
	tls_pipe_init(&pipe)
	testing.expect(t, ct_admit(&pipe, 64 * 1024))
	testing.expect_value(t, pipe.ct_bytes_held, u32(64 * 1024))
	testing.expect(t, ct_admit(&pipe, 64 * 1024))
	testing.expect_value(t, pipe.ct_bytes_held, u32(CT_HIGH_WATER_DEFAULT))
	// one more byte over HW
	testing.expect(t, !ct_admit(&pipe, 1))
	testing.expect_value(t, pipe.ct_bytes_held, u32(CT_HIGH_WATER_DEFAULT))
	ct_release(&pipe, 64 * 1024)
	testing.expect_value(t, pipe.ct_bytes_held, u32(64 * 1024))
	testing.expect(t, ct_admit(&pipe, 64 * 1024))
}

@(test)
test_ct_admit_metered_hw_hit :: proc(t: ^testing.T) {
	pipe: Tls_Pipe
	tls_pipe_init(&pipe)
	m: Pipe_Meters
	testing.expect(t, ct_admit_metered(&pipe, CT_HIGH_WATER_DEFAULT, &m))
	testing.expect_value(t, m.peak_ct_held, u32(CT_HIGH_WATER_DEFAULT))
	testing.expect(t, !ct_admit_metered(&pipe, 1, &m))
	testing.expect_value(t, m.ct_hw_hits, u64(1))
}

// ---------------------------------------------------------------------------
// seal_n max 2
// ---------------------------------------------------------------------------

@(test)
test_seal_n_max_two :: proc(t: ^testing.T) {
	n: u8 = 0
	testing.expect(t, seal_n_try_inc(&n))
	testing.expect_value(t, n, u8(1))
	testing.expect(t, seal_n_try_inc(&n))
	testing.expect_value(t, n, u8(2))
	// third seal refused (CT_SLOTS / SEAL_N_MAX)
	testing.expect(t, !seal_n_try_inc(&n))
	testing.expect_value(t, n, u8(2))
	testing.expect(t, seal_n_try_dec(&n))
	testing.expect_value(t, n, u8(1))
	testing.expect(t, seal_n_try_dec(&n))
	testing.expect_value(t, n, u8(0))
	testing.expect(t, !seal_n_try_dec(&n))
}

@(test)
test_wire_conn_seal_n_field :: proc(t: ^testing.T) {
	wc: Wire_Conn_State
	wire_conn_init(&wc)
	testing.expect(t, seal_n_try_inc(&wc.seal_n))
	testing.expect(t, seal_n_try_inc(&wc.seal_n))
	testing.expect(t, !seal_n_try_inc(&wc.seal_n))
	testing.expect_value(t, wc.seal_n, u8(SEAL_N_MAX))
}

// ---------------------------------------------------------------------------
// seal_q push / gen-checked pop / remove_gen
// Queue storage is Seal_Queue (stack in tests; deferred alloc on Connection).
// ---------------------------------------------------------------------------

@(private = "file")
_su :: proc(gen: u32, idx: u16, frame: u32 = 0, is_ct: bool = false) -> Seal_Unit {
	return Seal_Unit {
		slot_gen = gen,
		slot_idx = idx,
		frame_id = frame,
		bytes    = nil,
		is_ct    = is_ct,
	}
}

@(test)
test_seal_q_push_and_full :: proc(t: ^testing.T) {
	q: Seal_Queue
	for i in 0 ..< SEAL_Q_CAP {
		ok := seal_q_push(&q, _su(1, u16(i % 4)))
		testing.expect(t, ok)
	}
	testing.expect_value(t, q.len, SEAL_Q_CAP)
	// full → refuse (backpressure; never silent drop of caller unit)
	testing.expect(t, !seal_q_push(&q, _su(1, 0)))
	testing.expect_value(t, q.len, SEAL_Q_CAP)
}

@(test)
test_seal_q_pop_gen_checked_match :: proc(t: ^testing.T) {
	q: Seal_Queue
	testing.expect(t, seal_q_push(&q, _su(5, 0, 1)))
	testing.expect(t, seal_q_push(&q, _su(7, 1, 2)))
	live := []u32{5, 7} // slot 0 gen 5, slot 1 gen 7
	u, ok := seal_q_pop_gen_checked(&q, live)
	testing.expect(t, ok)
	testing.expect_value(t, u.slot_gen, u32(5))
	testing.expect_value(t, u.slot_idx, u16(0))
	testing.expect_value(t, u.frame_id, u32(1))
	u2, ok2 := seal_q_pop_gen_checked(&q, live)
	testing.expect(t, ok2)
	testing.expect_value(t, u2.slot_gen, u32(7))
	testing.expect_value(t, q.len, 0)
	_, ok3 := seal_q_pop_gen_checked(&q, live)
	testing.expect(t, !ok3)
}

@(test)
test_seal_q_pop_gen_checked_skips_mismatch :: proc(t: ^testing.T) {
	q: Seal_Queue
	// stale unit for slot 0 (gen 1, live is 2) then live unit
	testing.expect(t, seal_q_push(&q, _su(1, 0)))
	testing.expect(t, seal_q_push(&q, _su(9, 1)))
	live := []u32{2, 9} // slot 0 bumped → mismatch on first
	u, ok := seal_q_pop_gen_checked(&q, live)
	testing.expect(t, ok)
	testing.expect_value(t, u.slot_gen, u32(9))
	testing.expect_value(t, u.slot_idx, u16(1))
	testing.expect_value(t, q.len, 0)
}

@(test)
test_seal_q_pop_gen_checked_all_stale :: proc(t: ^testing.T) {
	q: Seal_Queue
	testing.expect(t, seal_q_push(&q, _su(1, 0)))
	testing.expect(t, seal_q_push(&q, _su(1, 0)))
	live := []u32{99}
	_, ok := seal_q_pop_gen_checked(&q, live)
	testing.expect(t, !ok)
	testing.expect_value(t, q.len, 0)
}

@(test)
test_seal_q_remove_gen_stream_abort :: proc(t: ^testing.T) {
	q: Seal_Queue
	// two units for gen=3 (aborting stream), one for gen=8 (live other stream)
	testing.expect(t, seal_q_push(&q, _su(3, 0, 10)))
	testing.expect(t, seal_q_push(&q, _su(8, 1, 20)))
	testing.expect(t, seal_q_push(&q, _su(3, 0, 11)))
	testing.expect(t, seal_q_push(&q, _su(8, 1, 21)))
	n := seal_q_remove_gen(&q, 3)
	testing.expect_value(t, n, 2)
	testing.expect_value(t, q.len, 2)
	testing.expect_value(t, q.units[0].slot_gen, u32(8))
	testing.expect_value(t, q.units[0].frame_id, u32(20))
	testing.expect_value(t, q.units[1].slot_gen, u32(8))
	testing.expect_value(t, q.units[1].frame_id, u32(21))
	// removing absent gen is no-op
	testing.expect_value(t, seal_q_remove_gen(&q, 3), 0)
	testing.expect_value(t, q.len, 2)
}

@(test)
test_seal_q_remove_gen_all :: proc(t: ^testing.T) {
	q: Seal_Queue
	testing.expect(t, seal_q_push(&q, _su(1, 0)))
	testing.expect(t, seal_q_push(&q, _su(1, 0)))
	testing.expect_value(t, seal_q_remove_gen(&q, 1), 2)
	testing.expect_value(t, q.len, 0)
}

// ---------------------------------------------------------------------------
// wire_conn Seal_Queue enable / disable
// ---------------------------------------------------------------------------

@(test)
test_wire_conn_enable_disable_seal_q :: proc(t: ^testing.T) {
	wc: Wire_Conn_State
	wire_conn_init(&wc)
	testing.expect(t, wc.q == nil)
	testing.expect(t, wire_conn_enable_seal_q(&wc))
	testing.expect(t, wc.q != nil)
	// idempotent
	q1 := wc.q
	testing.expect(t, wire_conn_enable_seal_q(&wc))
	testing.expect(t, wc.q == q1)
	// usable queue
	testing.expect(t, seal_q_push(wc.q, _su(1, 0)))
	testing.expect_value(t, wc.q.len, 1)
	wire_conn_disable_seal_q(&wc)
	testing.expect(t, wc.q == nil)
	// double disable is safe
	wire_conn_disable_seal_q(&wc)
}

@(test)
test_connection_enable_disable_ciphered :: proc(t: ^testing.T) {
	// Lightweight enable: ciphered + plan_policy only; no seal_q / CT[2] zombie.
	c: Connection
	pt_ring_init(&c.pt)
	wire_conn_init(&c.wire_conn)
	tls_pipe_init(&c.tls_pipe)
	testing.expect(t, !c.ciphered)
	testing.expect(t, c.wire_conn.q == nil)
	testing.expect(t, connection_enable_ciphered(&c))
	testing.expect(t, c.ciphered)
	testing.expect(t, c.wire_conn.q == nil)
	testing.expect(t, c.tls_pipe.bufs == nil)
	testing.expect_value(t, c.pt.high_water, u32(PT_HIGH_WATER_TLS_DEFAULT))
	// plan_policy max_write_unit for ciphered path (= live TLS seal window)
	pol := plan_policy_for(&c)
	testing.expect(t, pol.ciphered)
	testing.expect(t, !pol.sendfile_ok)
	testing.expect_value(t, pol.max_write_unit, u32(PIPE_MAX_WRITE_UNIT_DEFAULT))
	testing.expect_value(t, pol.max_write_unit, u32(TLS_SEAL_WINDOW_DEFAULT))
	// disable clears flag (no bags to free)
	connection_disable_ciphered(&c)
	testing.expect(t, !c.ciphered)
	testing.expect(t, c.wire_conn.q == nil)
	testing.expect(t, c.tls_pipe.bufs == nil)
	// destroy-style double disable is safe
	connection_disable_ciphered(&c)
}

@(test)
test_connection_enable_ciphered_pipe_sm :: proc(t: ^testing.T) {
	// Full SM bags for pure seal∥send / future live pipe (not live oneshot path).
	c: Connection
	pt_ring_init(&c.pt)
	wire_conn_init(&c.wire_conn)
	tls_pipe_init(&c.tls_pipe)
	testing.expect(t, connection_enable_ciphered_pipe_sm(&c))
	testing.expect(t, c.ciphered)
	testing.expect(t, c.wire_conn.q != nil)
	testing.expect(t, c.tls_pipe.bufs != nil)
	// idempotent
	testing.expect(t, connection_enable_ciphered_pipe_sm(&c))
	connection_disable_ciphered(&c)
	testing.expect(t, !c.ciphered)
	testing.expect(t, c.wire_conn.q == nil)
	testing.expect(t, c.tls_pipe.bufs == nil)
}

// ---------------------------------------------------------------------------
// Tls_Pipe skeleton + CT buffers
// ---------------------------------------------------------------------------

@(test)
test_tls_pipe_init_skeleton :: proc(t: ^testing.T) {
	pipe: Tls_Pipe
	tls_pipe_init(&pipe)
	testing.expect_value(t, pipe.state, Tls_Pipe_State.Handshake)
	testing.expect_value(t, pipe.seal_sm, Seal_SM.Idle)
	testing.expect_value(t, pipe.seal_n, u8(0))
	testing.expect_value(t, pipe.ct_bytes_held, u32(0))
	testing.expect_value(t, pipe.ct_high_water, u32(CT_HIGH_WATER_DEFAULT))
	testing.expect(t, !pipe.sock_send_inflight)
	testing.expect(t, pipe.bufs == nil)
	// size is POD-only (no pointer-sized engine field required)
	testing.expect(t, size_of(Tls_Pipe) > 0)
}

@(test)
test_tls_pipe_alloc_free_buffers :: proc(t: ^testing.T) {
	pipe: Tls_Pipe
	tls_pipe_init(&pipe)
	testing.expect(t, tls_pipe_alloc_buffers(&pipe))
	testing.expect(t, pipe.bufs != nil)
	for i in 0 ..< CT_SLOTS {
		testing.expect_value(t, len(pipe.bufs.ct[i]), CT_SLAB_SIZE)
		testing.expect_value(t, pipe.bufs.ct_own[i], Ct_Slot_Own.Free)
	}
	// idempotent
	b1 := pipe.bufs
	testing.expect(t, tls_pipe_alloc_buffers(&pipe))
	testing.expect(t, pipe.bufs == b1)
	tls_pipe_free_buffers(&pipe)
	testing.expect(t, pipe.bufs == nil)
	testing.expect_value(t, pipe.ct_bytes_held, u32(0))
	// free nil is safe
	tls_pipe_free_buffers(&pipe)
}

@(test)
test_seal_sm_variants :: proc(t: ^testing.T) {
	// Compile-time presence of normative states
	sm: Seal_SM = .Idle
	sm = .Sealing
	sm = .Send_Armed
	sm = .Send_And_Sealed
	testing.expect_value(t, sm, Seal_SM.Send_And_Sealed)
}

// ---------------------------------------------------------------------------
// Mock seal∥send driver
// ---------------------------------------------------------------------------

@(test)
test_pipe_seal_step_identity :: proc(t: ^testing.T) {
	pipe: Tls_Pipe
	pt: Conn_Pt_Ring
	tls_pipe_init(&pipe)
	pt_ring_init(&pt)
	testing.expect(t, tls_pipe_alloc_buffers(&pipe))
	defer tls_pipe_free_buffers(&pipe)

	// Produce one PULL_WINDOW of PT
	pt_src: [PULL_WINDOW_DEFAULT]u8
	for i in 0 ..< len(pt_src) {
		pt_src[i] = u8(i & 0xff)
	}
	testing.expect(t, pt_admit(&pt, u32(len(pt_src))))

	m: Pipe_Meters
	r := pipe_seal_step(&pipe, pt_src[:], mock_cipher_seal_identity, nil, &m)
	testing.expect_value(t, r.reason, Pipe_Seal_Reason.Ok)
	testing.expect_value(t, r.pt_used, u32(len(pt_src)))
	testing.expect_value(t, len(r.ct_view), len(pt_src))
	testing.expect(t, r.ct_view[0] == pt_src[0] && r.ct_view[255] == pt_src[255])
	testing.expect_value(t, pipe.seal_n, u8(1))
	testing.expect_value(t, pipe.ct_bytes_held, u32(len(pt_src)))
	testing.expect_value(t, pipe.seal_sm, Seal_SM.Sealing)
	testing.expect_value(t, m.seal_units, u64(1))
	testing.expect_value(t, m.peak_ct_held, u32(len(pt_src)))

	// Mark send + complete → recycle CT, release PT
	testing.expect(t, pipe_mark_send(&pipe, r.slot, &m))
	testing.expect(t, pipe.sock_send_inflight)
	testing.expect_value(t, pipe.seal_sm, Seal_SM.Send_Armed)
	testing.expect_value(t, m.ct_sends, u64(1))
	// second mark refused while inflight
	testing.expect(t, !pipe_mark_send(&pipe, r.slot, &m))

	pt_rel := pipe_on_send_complete(&pipe, &pt, r.slot, &m)
	testing.expect_value(t, pt_rel, u32(len(pt_src)))
	testing.expect_value(t, pt.admitted, u32(0))
	testing.expect_value(t, pipe.seal_n, u8(0))
	testing.expect_value(t, pipe.ct_bytes_held, u32(0))
	testing.expect(t, !pipe.sock_send_inflight)
	testing.expect_value(t, pipe.seal_sm, Seal_SM.Idle)
}

@(test)
test_pipe_seal_step_pause_reasons :: proc(t: ^testing.T) {
	pipe: Tls_Pipe
	tls_pipe_init(&pipe)
	// no bufs
	r0 := pipe_seal_step(&pipe, []u8{1}, mock_cipher_seal_identity)
	testing.expect_value(t, r0.reason, Pipe_Seal_Reason.No_Bufs)

	testing.expect(t, tls_pipe_alloc_buffers(&pipe))
	defer tls_pipe_free_buffers(&pipe)

	r1 := pipe_seal_step(&pipe, nil, mock_cipher_seal_identity)
	testing.expect_value(t, r1.reason, Pipe_Seal_Reason.No_Pt)

	// Fill both CT slots then third seal → Seal_N_Full or No_Free_Ct
	buf: [1024]u8
	for i in 0 ..< CT_SLOTS {
		r := pipe_seal_step(&pipe, buf[:], mock_cipher_seal_identity)
		testing.expect_value(t, r.reason, Pipe_Seal_Reason.Ok)
	}
	r2 := pipe_seal_step(&pipe, buf[:], mock_cipher_seal_identity)
	testing.expect(t, r2.reason == .Seal_N_Full || r2.reason == .No_Free_Ct)

	// Drain one
	slot := u8(0)
	if pipe.bufs.ct_own[0] == .Sealing {
		slot = 0
	} else {
		slot = 1
	}
	testing.expect(t, pipe_mark_send(&pipe, slot))
	_ = pipe_on_send_complete(&pipe, nil, slot)

	// Force CT_HW: fill held to high-water then refuse
	pipe.ct_bytes_held = pipe.ct_high_water
	// reset owns so we have a free slot and seal_n room for the HW check path
	// After one complete: seal_n=1, one Free one Sealing
	// Release the remaining sealed without send to free seal_n
	for i in 0 ..< CT_SLOTS {
		if pipe.bufs.ct_own[i] == .Sealing {
			// manual recycle for test setup
			ct_n := pipe.bufs.ct_len[i]
			pipe.bufs.ct_own[i] = .Free
			pipe.bufs.ct_len[i] = 0
			pipe.bufs.ct_pt_len[i] = 0
			_ = seal_n_try_dec(&pipe.seal_n)
			// don't double-release CT held — we forced held above
			_ = ct_n
		}
	}
	pipe.ct_bytes_held = pipe.ct_high_water
	pipe.seal_n = 0
	m: Pipe_Meters
	r3 := pipe_seal_step(&pipe, buf[:], mock_cipher_seal_identity, nil, &m)
	testing.expect_value(t, r3.reason, Pipe_Seal_Reason.Ct_Hw)
	testing.expect(t, m.ct_hw_hits >= 1)
}

@(test)
test_pipe_seal_send_parallel_two_slots :: proc(t: ^testing.T) {
	// Seal∥send: seal second CT while first is in sock send (seal_n=2).
	pipe: Tls_Pipe
	pt: Conn_Pt_Ring
	tls_pipe_init(&pipe)
	pt_ring_init(&pt)
	testing.expect(t, tls_pipe_alloc_buffers(&pipe))
	defer tls_pipe_free_buffers(&pipe)

	a: [1024]u8
	b: [1024]u8
	for i in 0 ..< 1024 {
		a[i] = 0xaa
		b[i] = 0xbb
	}
	testing.expect(t, pt_admit(&pt, 1024))
	r1 := pipe_seal_step(&pipe, a[:], mock_cipher_seal_identity)
	testing.expect_value(t, r1.reason, Pipe_Seal_Reason.Ok)
	testing.expect(t, pipe_mark_send(&pipe, r1.slot))
	testing.expect_value(t, pipe.seal_sm, Seal_SM.Send_Armed)

	testing.expect(t, pt_admit(&pt, 1024))
	r2 := pipe_seal_step(&pipe, b[:], mock_cipher_seal_identity)
	testing.expect_value(t, r2.reason, Pipe_Seal_Reason.Ok)
	testing.expect(t, r2.slot != r1.slot)
	testing.expect_value(t, pipe.seal_n, u8(2))
	testing.expect_value(t, pipe.seal_sm, Seal_SM.Send_And_Sealed)
	// cannot mark second while first inflight
	testing.expect(t, !pipe_mark_send(&pipe, r2.slot))

	// complete first → can arm second
	_ = pipe_on_send_complete(&pipe, &pt, r1.slot)
	testing.expect_value(t, pt.admitted, u32(1024)) // only first released
	testing.expect(t, !pipe.sock_send_inflight)
	testing.expect_value(t, pipe.seal_sm, Seal_SM.Sealing)
	testing.expect(t, pipe_mark_send(&pipe, r2.slot))
	_ = pipe_on_send_complete(&pipe, &pt, r2.slot)
	testing.expect_value(t, pt.admitted, u32(0))
	testing.expect_value(t, pipe.seal_n, u8(0))
	testing.expect_value(t, pipe.seal_sm, Seal_SM.Idle)
}

// ---------------------------------------------------------------------------
// Firehose detector
// ---------------------------------------------------------------------------

@(test)
test_firehose_fail_detector :: proc(t: ^testing.T) {
	m: Pipe_Meters
	testing.expect(t, !firehose_fail(&m))
	// under 4× HW
	m.peak_pt_admitted = 4 * PT_HIGH_WATER_DEFAULT // equal is NOT fail (strict >)
	m.peak_ct_held = 4 * CT_HIGH_WATER_DEFAULT
	testing.expect(t, !firehose_fail(&m))
	// over PT
	m.peak_pt_admitted = 4 * PT_HIGH_WATER_DEFAULT + 1
	testing.expect(t, firehose_fail(&m))
	m.peak_pt_admitted = 0
	m.peak_ct_held = 4 * CT_HIGH_WATER_DEFAULT + 1
	testing.expect(t, firehose_fail(&m))
}

// ---------------------------------------------------------------------------
// Pure bulk simulator — O(window) path (4 MiB body, dual HW, firehose CI)
// ---------------------------------------------------------------------------

// ε slab slack: peaks may touch HW exactly; allow one extra PULL_WINDOW only if
// design admits a transient (we assert ≤ HW for well-behaved path).
FIREHOSE_SIM_BODY :: 4 * 1024 * 1024

// Run well-behaved bulk: admit ≤ PT_HW, seal, mark send, complete, release.
// Returns meters after draining full body.
@(private = "file")
_pipe_bulk_sim_windowed :: proc(body_len: int) -> (meters: Pipe_Meters, ok: bool) {
	pipe: Tls_Pipe
	pt: Conn_Pt_Ring
	tls_pipe_init(&pipe)
	pt_ring_init(&pt)
	if !tls_pipe_alloc_buffers(&pipe) {
		return {}, false
	}
	defer tls_pipe_free_buffers(&pipe)

	// Staging: up to CT_SLOTS windows of PT (held until send complete).
	// Each admitted chunk copies into a staging slot until CT recycles.
	Staging :: struct {
		buf:  [CT_SLAB_SIZE]u8,
		len:  u32,
		used: bool, // admitted and not yet sealed
	}
	staging: [CT_SLOTS]Staging
	// Map CT slot → staging index that provided PT (for correctness only)
	// After seal, PT is still admitted until on_send_complete.

	remaining := body_len
	fill_byte: u8 = 0
	m: Pipe_Meters

	// Pending sealed-not-sent is on pipe; we just drive the SM.
	steps := 0
	max_steps := body_len / 1024 + 1024 // safety

	for (remaining > 0 || pt.admitted > 0 || pipe.seal_n > 0) && steps < max_steps {
		steps += 1
		progress := false

		// 1) Produce into free staging under PT_HW (never admit more than HW).
		for si in 0 ..< CT_SLOTS {
			if remaining <= 0 {
				break
			}
			if staging[si].used {
				continue
			}
			want := PULL_WINDOW_DEFAULT
			if remaining < want {
				want = remaining
			}
			if !pt_admit_metered(&pt, u32(want), &m) {
				// hit PT_HW — wait for release
				break
			}
			for j in 0 ..< want {
				staging[si].buf[j] = fill_byte
				fill_byte += 1
			}
			staging[si].len = u32(want)
			staging[si].used = true
			remaining -= want
			progress = true
		}

		// 2) Seal any used staging into free CT under CT_HW / seal_n.
		for si in 0 ..< CT_SLOTS {
			if !staging[si].used {
				continue
			}
			r := pipe_seal_step(
				&pipe,
				staging[si].buf[:staging[si].len],
				mock_cipher_seal_identity,
				nil,
				&m,
			)
			if r.reason != .Ok {
				// CT_HW / seal_n full / no free CT — try complete first
				break
			}
			// PT still held until send complete; staging buffer free for next admit.
			staging[si].used = false
			staging[si].len = 0
			progress = true
		}

		// 3) Arm send if socket free and a CT is Sealing.
		if !pipe.sock_send_inflight {
			ready := pipe_find_ready_ct(&pipe)
			if ready >= 0 {
				if pipe_mark_send(&pipe, u8(ready), &m) {
					progress = true
				}
			}
		}

		// 4) Simulate instant CQE for inflight send.
		if pipe.sock_send_inflight {
			send_slot := pipe.ct_send_idx
			_ = pipe_on_send_complete(&pipe, &pt, send_slot, &m)
			progress = true
		}

		if !progress {
			// Deadlock check — should not happen under dual HW + dual CT.
			break
		}
	}

	ok = remaining == 0 && pt.admitted == 0 && pipe.seal_n == 0 && !pipe.sock_send_inflight
	return m, ok
}

@(test)
test_pipe_bulk_sim_4mib_windowed_no_firehose :: proc(t: ^testing.T) {
	// 4 MiB body through PULL_WINDOW chunks: peaks must stay O(window).
	m, ok := _pipe_bulk_sim_windowed(FIREHOSE_SIM_BODY)
	testing.expect(t, ok)
	// peak PT ≤ PT_HIGH_WATER (+ε slab). Well-behaved path: ≤ HW exactly.
	testing.expect(t, m.peak_pt_admitted <= PT_HIGH_WATER_DEFAULT)
	// peak CT ≤ CT_HIGH_WATER (+ε)
	testing.expect(t, m.peak_ct_held <= CT_HIGH_WATER_DEFAULT)
	testing.expect(t, !firehose_fail(&m))
	// Actually moved data: seal units and sends ≈ body / window
	expect_units := u64(FIREHOSE_SIM_BODY / PULL_WINDOW_DEFAULT)
	testing.expect_value(t, m.seal_units, expect_units)
	testing.expect_value(t, m.ct_sends, expect_units)
	// Peaks should be meaningful (not zero). Measured on 4 MiB body:
	// peak_pt = peak_ct = 128 KiB (= dual slot × PULL_WINDOW = HW).
	testing.expect_value(t, m.peak_pt_admitted, u32(PT_HIGH_WATER_DEFAULT))
	testing.expect_value(t, m.peak_ct_held, u32(CT_HIGH_WATER_DEFAULT))
}

@(test)
test_pipe_bulk_sim_deliberate_firehose :: proc(t: ^testing.T) {
	// Deliberately admit all 4 MiB without dual-HW (proves detector works).
	pt: Conn_Pt_Ring
	// Unbounded for this anti-pattern test (bypass high_water via huge HW).
	pt_ring_init(&pt, u32(FIREHOSE_SIM_BODY))
	m: Pipe_Meters

	// Admit entire body at once (firehose produce).
	testing.expect(t, pt_admit_metered(&pt, u32(FIREHOSE_SIM_BODY), &m))
	testing.expect_value(t, m.peak_pt_admitted, u32(FIREHOSE_SIM_BODY))
	// 4 MiB > 4 * 128 KiB (512 KiB)
	testing.expect(t, firehose_fail(&m))

	// Same for CT: hold 4 MiB "sealed" without CT_HW.
	pipe: Tls_Pipe
	tls_pipe_init(&pipe)
	// Raise CT HW so admit succeeds (anti-pattern path measures peak, not refuse).
	pipe.ct_high_water = u32(FIREHOSE_SIM_BODY)
	testing.expect(t, ct_admit_metered(&pipe, u32(FIREHOSE_SIM_BODY), &m))
	testing.expect_value(t, m.peak_ct_held, u32(FIREHOSE_SIM_BODY))
	testing.expect(t, firehose_fail(&m))
}

// ---------------------------------------------------------------------------
// Connection embeds Plan A pipe bags; alloc-path init zeros pt high_water
// ---------------------------------------------------------------------------

@(test)
test_connection_pipe_bags_init :: proc(t: ^testing.T) {
	// Same init sequence as conn_alloc / connection_destroy (no ring/socket needed).
	c: Connection
	pt_ring_init(&c.pt)
	wire_conn_init(&c.wire_conn)
	tls_pipe_init(&c.tls_pipe)
	testing.expect_value(t, c.pt.high_water, u32(PT_HIGH_WATER_DEFAULT))
	testing.expect_value(t, c.pt.admitted, u32(0))
	// SEAL_Q deferred: clear-H1 Connection embeds thin Wire_Conn_State, q nil
	testing.expect(t, c.wire_conn.q == nil)
	testing.expect(t, !c.wire_conn.sock_send_inflight)
	testing.expect_value(t, c.tls_pipe.state, Tls_Pipe_State.Handshake)
	testing.expect_value(t, c.tls_pipe.seal_sm, Seal_SM.Idle)
	testing.expect(t, c.tls_pipe.bufs == nil)
	// Fields are resident on Connection (compile-time layout check)
	testing.expect(t, size_of(Connection) > size_of(Wire_State))
	_ = c.wire // clear-H1 still owns Wire_State; pipe bags not yet driving it
}

// Wire_Conn_State must stay thin: full SEAL_Q_CAP storage is Seal_Queue, not
// embedded on every free-list Connection (was ~1304 B; budget < 64 B).
@(test)
test_wire_conn_state_size_budget :: proc(t: ^testing.T) {
	testing.expect(t, size_of(Wire_Conn_State) < 64)
	// Queue storage itself remains the large bag when allocated
	testing.expect(t, size_of(Seal_Queue) > size_of(Wire_Conn_State))
	testing.expect(t, size_of(Seal_Queue) >= SEAL_Q_CAP * size_of(Seal_Unit))
}
