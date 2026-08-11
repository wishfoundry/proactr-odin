package quic

import "core:testing"
import "core:time"

// Direct unit tests for the New Reno accounting — no sockets, no timers.
// These follow flow_control_test.odin's philosophy: poke the CC fields and
// call the procs directly so assertions stay close to the state mutations.

@(test)
test_cc_init :: proc(t: ^testing.T) {
	cc: Congestion
	congestion_init(&cc, 1200)
	testing.expect_value(t, cc.max_datagram_size, u64(1200))
	testing.expect_value(t, cc.cwnd, congestion_initial_window(1200))
	testing.expect(t, cc.ssthresh == u64(0xffff_ffff_ffff_ffff), "ssthresh should be 'infinite' at init")
	testing.expect_value(t, cc.bytes_in_flight, u64(0))
	testing.expect(t, !cc.have_rtt_sample, "no RTT sample at init")
}

@(test)
test_cc_initial_window_floor :: proc(t: ^testing.T) {
	// RFC 9002 §7.2: IW must be at least max(2·MDS, 14720) so a tiny MTU
	// doesn't starve slow start.
	iw := congestion_initial_window(100)
	testing.expect(t, iw >= 14720, "IW floored at 14720 for tiny MTU")
}

@(test)
test_cc_send_budget :: proc(t: ^testing.T) {
	cc: Congestion
	congestion_init(&cc, 1200)
	iw := cc.cwnd
	testing.expect_value(t, send_budget(&cc), iw)
	on_sent(&cc, 500)
	testing.expect_value(t, send_budget(&cc), iw - 500)
	on_sent(&cc, iw) // over-fill on purpose
	testing.expect_value(t, send_budget(&cc), u64(0))
}

@(test)
test_cc_slow_start :: proc(t: ^testing.T) {
	// Each ACK in slow start grows cwnd by acked_size → ~doubles per RTT.
	cc: Congestion
	congestion_init(&cc, 1200)
	iw := cc.cwnd
	now := time.Time{}
	on_ack(&cc, 50 * time.Millisecond, 1200, now)
	testing.expect_value(t, cc.cwnd, iw + 1200)
	on_ack(&cc, 50 * time.Millisecond, 1200, now)
	testing.expect_value(t, cc.cwnd, iw + 2400)
}

@(test)
test_cc_rtt_first_sample_seeds :: proc(t: ^testing.T) {
	cc: Congestion
	congestion_init(&cc, 1200)
	now := time.Time{}
	on_ack(&cc, 40 * time.Millisecond, 100, now)
	testing.expect_value(t, cc.srtt, 40 * time.Millisecond)
	testing.expect_value(t, cc.rttvar, 20 * time.Millisecond) // sample/2
	testing.expect_value(t, cc.min_rtt, 40 * time.Millisecond)
	testing.expect(t, cc.have_rtt_sample, "first sample sets the flag")
}

@(test)
test_cc_loss_halves_and_enters_recovery :: proc(t: ^testing.T) {
	cc: Congestion
	congestion_init(&cc, 1200)
	cc.cwnd = 20000
	now := time.Time{}
	on_loss(&cc, now)
	expected := max(u64(20000 / 2), congestion_minimum_window(1200))
	testing.expect_value(t, cc.cwnd, expected)
	testing.expect_value(t, cc.ssthresh, expected)
	testing.expect_value(t, cc.recovery_start, now)
}

@(test)
test_cc_recovery_freezes_growth :: proc(t: ^testing.T) {
	// In recovery, an ACK must not grow the window even if we're below
	// ssthresh (the round that contained the loss is frozen).
	cc: Congestion
	congestion_init(&cc, 1200)
	cc.cwnd = 20000
	cc.ssthresh = 40000 // still in slow-start regime, would normally grow
	seed_rtt(&cc, 50 * time.Millisecond)
	// Use a non-zero base time — the zero time.Time is the "disarmed" sentinel
	// for recovery_start, so a loss at T=0 wouldn't read back as "in recovery".
	now := time.now()
	on_loss(&cc, now) // recovery_start = now, srtt = 50ms; cwnd→10000, ssthresh→10000
	frozen := cc.cwnd
	testing.expect_value(t, frozen, u64(10000))
	// ACK within the recovery round (< srtt elapsed) — no growth.
	on_ack(&cc, 50 * time.Millisecond, 1200, now)
	testing.expect_value(t, cc.cwnd, frozen)
	// Advance time past one RTT — recovery exits. cwnd == ssthresh now, so
	// congestion avoidance applies: +acked·MDS/cwnd = +1200·1200/10000 = +144.
	later := time.time_add(now, 60 * time.Millisecond)
	on_ack(&cc, 50 * time.Millisecond, 1200, later)
	testing.expect_value(t, cc.cwnd, frozen + 144)
}

@(test)
test_cc_pto_halves :: proc(t: ^testing.T) {
	cc: Congestion
	congestion_init(&cc, 1200)
	cc.cwnd = 20000
	on_pto(&cc)
	min_w := congestion_minimum_window(1200)
	testing.expect_value(t, cc.cwnd, max(u64(20000 / 2), min_w))
}

@(test)
test_cc_pto_duration_no_sample :: proc(t: ^testing.T) {
	cc: Congestion
	congestion_init(&cc, 1200)
	// Pre-sample: 2·INITIAL_RTT = 666ms.
	testing.expect_value(t, pto_duration(&cc, 0), 2 * INITIAL_RTT)
	// Backoff doubles it.
	testing.expect_value(t, pto_duration(&cc, 1), 4 * INITIAL_RTT)
}

@(test)
test_cc_pto_duration_with_sample :: proc(t: ^testing.T) {
	cc: Congestion
	congestion_init(&cc, 1200)
	seed_rtt(&cc, 100 * time.Millisecond)
	// srtt=100ms, rttvar=50ms → 4·rttvar=200ms > granularity.
	// pto = srtt + 4·rttvar = 300ms.
	testing.expect_value(t, pto_duration(&cc, 0), 300 * time.Millisecond)
}

@(test)
test_cc_ack_releases_in_flight :: proc(t: ^testing.T) {
	cc: Congestion
	congestion_init(&cc, 1200)
	on_sent(&cc, 1000)
	on_sent(&cc, 800)
	testing.expect_value(t, cc.bytes_in_flight, u64(1800))
	now := time.Time{}
	on_ack(&cc, 50 * time.Millisecond, 1000, now)
	testing.expect_value(t, cc.bytes_in_flight, u64(800))
}

@(private = "file")
seed_rtt :: proc(cc: ^Congestion, rtt: time.Duration) {
	// Seed srtt/rttvar/min_rtt so recovery/PTO duration math has real values.
	cc.srtt = rtt
	cc.rttvar = rtt / 2
	cc.min_rtt = rtt
	cc.have_rtt_sample = true
}
