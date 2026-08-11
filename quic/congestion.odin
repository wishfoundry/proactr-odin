package quic

// New Reno congestion control (RFC 9002 §7 + §B) for 1-RTT stream data.
// This is the missing piece that made the stack unsafe on the public
// internet: before this file existed, conn_build_stream_packet gated only on
// flow control and would send as fast as the application produced data —
// congestion collapse on a lossy path. New Reno is the minimum deployable
// algorithm: a congestion window, slow-start / congestion-avoidance, fast
// recovery on detected loss, and a PTO that halves the window.
// Scope (deliberately deferred): pacing, ECN-CE handling, persistent
// congestion detection, and BBR. What's here is enough to not fall over.
// The struct is self-contained and its procs are pure-ish (no I/O, no
// sockets) so the accounting can be unit-tested directly — see
// congestion_test.odin.

import "core:time"

// --- Constants (RFC 9002 §7) -------------------------------------------------
// All in bytes. kInitialWindow and kMinimumWindow scale with the path MTU;
// callers pass a max_datagram_size (typically 1200 for IPv6 / 1472 for IPv4)
// to congestion_init.

// Granularity floor for the PTO computation (RFC 9002 §6.2.1, "kGranularity").
GRANULARITY :: 1 * time.Millisecond

// RTT used before any sample exists (RFC 9002 §6.2.2, "kInitialRtt" = 333ms).
INITIAL_RTT :: 333 * time.Millisecond

// Packet-number reordering threshold (RFC 9000 §13.2.1). A packet still
// unacked once 3 later packets are acked is declared lost.
LOSS_PACKET_THRESHOLD :: 3

Congestion :: struct {
	// Round-trip-time estimates (RFC 9002 §5.3). All zero until the first
	// ACK; PTO falls back to INITIAL_RTT until then.
	latest_rtt:      time.Duration, // most recent RTT sample
	srtt:            time.Duration, // smoothed RTT
	rttvar:          time.Duration, // RTT variation
	min_rtt:         time.Duration, // min over the connection lifetime
	have_rtt_sample: bool,

	// Window state. cwnd is the byte budget for data in flight; the send
	// path gates `to_send` against (cwnd - bytes_in_flight).
	cwnd:            u64,
	ssthresh:        u64,            // slow-start threshold; max u64 = stay in slow start
	bytes_in_flight: u64,

	// Recovery window (RFC 9002 §7.3.2). Once a loss is detected the cwnd is
	// halved and stays frozen until one RTT elapses (recovery_start + srtt);
	// growth resumes only after. PTO probes don't grow the window.
	recovery_start:  time.Time,      // zero value = not in recovery

	max_datagram_size: u64,          // captured at init for window bounds
}

// kInitialWindow :: 10 * max_datagram_size, capped so a tiny MTU doesn't
// starve slow start (RFC 9002 §7.2: min(10·MDS, max(2·MDS, 14720))).
congestion_initial_window :: proc(max_datagram_size: u64) -> u64 {
	iw := 10 * max_datagram_size
	floor := 2 * max_datagram_size
	if floor < 14720 do floor = 14720
	if iw < floor do iw = floor
	return iw
}

// kMinimumWindow :: 2 * max_datagram_size (RFC 9002 §7.2). The cwnd never
// drops below this on loss.
congestion_minimum_window :: proc(max_datagram_size: u64) -> u64 {
	return 2 * max_datagram_size
}

congestion_init :: proc(c: ^Congestion, max_datagram_size: u64) {
	c^ = {
		max_datagram_size = max_datagram_size,
		cwnd              = congestion_initial_window(max_datagram_size),
		ssthresh          = u64(0xffff_ffff_ffff_ffff), // "infinite" — stay in slow start
	}
}

// How many bytes the send path may put in a new packet right now.
send_budget :: proc(c: ^Congestion) -> u64 {
	if c.bytes_in_flight >= c.cwnd do return 0
	return c.cwnd - c.bytes_in_flight
}

// A packet of `size` bytes was just sent. Bumps in-flight accounting. Called
// from the packet builder alongside loss_record_sent_packet.
on_sent :: proc(c: ^Congestion, size: u64) {
	c.bytes_in_flight += size
}

// Record one ACKed packet. `rtt_sample` is the raw RTT for this packet
// (now - sent_at), already corrected for the peer's ack_delay by the caller.
// `acked_size` is the full on-wire size of the acked packet, for in-flight
// accounting. Grows the window per slow-start / congestion-avoidance and
// clears recovery once an RTT has elapsed (RFC 9002 §7).
on_ack :: proc(c: ^Congestion, rtt_sample: time.Duration, acked_size: u64, now: time.Time) {
	// In-flight accounting: the acked packet is no longer outstanding.
	if acked_size >= c.bytes_in_flight {
		c.bytes_in_flight = 0
	} else {
		c.bytes_in_flight -= acked_size
	}

	_update_rtt(c, rtt_sample)

	// In recovery, the window is frozen — don't grow on ACKs from the round
	// that detected loss. Exit once one (smoothed) RTT elapses.
	if _in_recovery(c, now) do return

	if c.cwnd < c.ssthresh {
		// Slow start: double per RTT ≈ +1 byte per acked byte (RFC 9002 §7.3.1).
		c.cwnd += acked_size
	} else {
		// Congestion avoidance: ~+1 MSS per RTT ≈ acked_size·MDS/cwnd per ACK
		// (RFC 9002 §7.3.3).
		c.cwnd += acked_size * c.max_datagram_size / c.cwnd
	}
}

// Loss detected (packet-threshold or PTO). Halve the window, set ssthresh to
// the new cwnd, and enter recovery for one RTT (RFC 9002 §7.3.2).
on_loss :: proc(c: ^Congestion, now: time.Time) {
	// Only enter recovery if we weren't already in it — multiple losses in
	// the same round don't compound the reduction.
	if !_in_recovery(c, now) {
		c.ssthresh = max(c.cwnd / 2, congestion_minimum_window(c.max_datagram_size))
		c.cwnd = c.ssthresh
		c.recovery_start = now
	}
}

// PTO fired (RFC 9002 §6.2.4). The window halves to minimum; the caller
// sends exactly one probe (accounted via on_sent for that probe's size).
// We don't enter the recovery *state* here — PTO is a probe, not a loss
// confirmation — but we shrink the window so a persistent black hole
// doesn't keep blasting packets.
on_pto :: proc(c: ^Congestion) {
	c.cwnd = max(c.cwnd / 2, congestion_minimum_window(c.max_datagram_size))
}

// Compute the probe timeout (RFC 9002 §6.2.1): smoothed_rtt + max(4·rttvar,
// granularity), multiplied by 2^factor. Returns INITIAL_RTT-based value
// before any sample exists.
pto_duration :: proc(c: ^Congestion, factor: int) -> time.Duration {
	if !c.have_rtt_sample {
		// Pre-sample: 2·INITIAL_RTT (RFC 9002 §6.2.2), doubled per backoff.
		base: time.Duration = 2 * INITIAL_RTT
		for _ in 0..<factor do base *= 2
		return base
	}
	var_delay := 4 * c.rttvar
	if var_delay < GRANULARITY do var_delay = GRANULARITY
	base := c.srtt + var_delay
	for _ in 0..<factor do base *= 2
	return base
}

// Is the connection currently in its post-loss recovery round?
_in_recovery :: proc(c: ^Congestion, now: time.Time) -> bool {
	if c.recovery_start == (time.Time{}) do return false
	// One smoothed RTT since the loss detection.
	return time.diff(c.recovery_start, now) < c.srtt
}

// EWMA update per RFC 9002 §5.3. The first sample seeds srtt/rttvar/min_rtt;
// subsequent samples follow the standard SRTT = 7/8·SRTT + 1/8·latest and
// rttvar = 3/4·rttvar + 1/4·|SRTT − latest|.
@(private)
_update_rtt :: proc(c: ^Congestion, sample: time.Duration) {
	c.latest_rtt = sample
	if !c.have_rtt_sample {
		c.srtt = sample
		c.rttvar = sample / 2
		c.min_rtt = sample
		c.have_rtt_sample = true
		return
	}
	if sample < c.min_rtt do c.min_rtt = sample
	// 7/8 and 3/4 via integer math on Duration (nanoseconds).
	c.rttvar = (3 * c.rttvar + abs_diff(c.srtt, sample)) / 4
	c.srtt = (7 * c.srtt + sample) / 8
}

// |a - b| for time.Duration (no built-in abs on it).
abs_diff :: proc(a, b: time.Duration) -> time.Duration {
	if a > b do return a - b
	return b - a
}
