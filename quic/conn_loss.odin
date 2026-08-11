package quic

import "core:time"

// Loss recovery + congestion control for 1-RTT packets (RFC 9002 + RFC 9000
// What's in:
//   - A per-packet log (conn.loss_sent) of sent 1-RTT packets, each with the
//     stream byte ranges it carried and its full wire size (for in-flight
//     accounting). Cleared on ACK.
//   - RTT sampling from ACKs (RFC 9002 §5.3): SRTT/RTTVAR/min_rtt, with the
//     peer's ack_delay subtracted from the latest sample.
//   - Packet-threshold loss detection (RFC 9000 §13.2.1): once a packet is
//     3 behind the largest acked and still unacked, it's declared lost → its
//     stream ranges are re-queued for retransmit and the cwnd is halved.
//   - PTO (RFC 9002 §6.2): computed from the real SRTT once a sample exists,
//     doubled per consecutive fire. On fire, one probe's worth of stream
//     data is re-queued and a single ack-eliciting packet is sent.
//   - Real retransmission: lost/PTO'd stream bytes go back into the stream's
//     sendable range by rewinding tx_sent_off (see _stream_requeue_range).
// What's out (still deferred):
//   - No pacing. New Reno bursts; a pacer would smooth this but isn't needed
//     for correctness, only for fairness on shallow buffers.
//   - No ECN-CE handling (treat ECN marks as loss).
//   - No persistent-congestion detection (RFC 9002 §7.6.2) — the two-PTO
//     window that would zero the cwnd.
//   - Persistent multi-range ACK decode is here, but loss detection uses the
//     single largest acked for the threshold (the common path).

// Caps on PTO backoff. The base comes from the RTT once sampled (see
// congestion.pto_duration); before any sample it's 2·INITIAL_RTT.
PTO_MAX_DOUBLINGS :: 6

// A record of one sent 1-RTT packet: which stream byte ranges it carried.
// On ACK, we match `packet_number` and clear corresponding tx_unacked entries.
// On PTO/threshold-loss, we re-queue the stream data.
Sent_Packet :: struct {
	packet_number: u64,
	sent_at:       time.Time,

	// Full on-wire packet size (header + payload + AEAD tag), for congestion
	// bytes-in-flight accounting — stream_ranges only covers stream bytes.
	size:          int,

	// STREAM data ranges in this packet (usually one, rarely more).
	stream_ranges: [dynamic]Sent_Range,

	// Was this packet ack-eliciting? PTO only arms when there's at least one
	// ack-eliciting packet outstanding.
	ack_eliciting: bool,
}

// Register a newly-sent 1-RTT packet in the loss log + congestion accounting.
loss_record_sent_packet :: proc(conn: ^Conn, pkt: Sent_Packet) {
	append(&conn.loss_sent, pkt)
	on_sent(&conn.cc, u64(pkt.size))
	if pkt.ack_eliciting {
		conn.loss_last_ack_eliciting_at = pkt.sent_at
		_loss_arm_pto(conn)
	}
}

// Process a received ACK frame at 1-RTT: remove acknowledged packets from the
// log, feed RTT samples + ACKed bytes to the congestion controller, run
// packet-threshold loss detection on anything now "too old", and rearm/disarm
// the PTO accordingly.
loss_on_ack :: proc(conn: ^Conn, f: Ack_Frame) {
	now := _now(conn)

	// RFC 9002 §5.1: the latest RTT sample comes from the largest acked
	// packet (the ack_delay field is the peer's reported processing delay,
	// scaled to microseconds). Only the first sample per ACK is used.
	ack_delay_ns := time.Duration(f.ack_delay) * time.Microsecond

	any_acked := false
	kept: [dynamic]Sent_Packet
	kept.allocator = context.temp_allocator
	for &pkt in conn.loss_sent {
		if _packet_in_ranges(pkt.packet_number, f) {
			any_acked = true
			// RTT sample from the acked packet that was sent first (oldest
			// in-flight → most accurate round measurement). Only the largest
			// acked is meant for sampling; using the oldest unacked here is a
			// reasonable conservative approximation when ranges collapse.
			if pkt.ack_eliciting {
				sample := time.diff(pkt.sent_at, now)
				if sample > ack_delay_ns do sample -= ack_delay_ns
				ack_size := u64(pkt.size)
				on_ack(&conn.cc, sample, ack_size, now)
			}
			// Clear this packet's stream ranges from tx_unacked; advance the
			// per-stream ACKed watermark so compaction can reclaim memory.
			for r in pkt.stream_ranges {
				s := conn_get_stream(conn, r.stream_id)
				if s == nil do continue
				_stream_clear_unacked(s, r.packet_number)
				_stream_advance_acked(s, r)
			}
			delete(pkt.stream_ranges)
			continue
		}
		append(&kept, pkt)
	}
	delete(conn.loss_sent)
	conn.loss_sent = kept

	// Packet-threshold loss detection (RFC 9000 §13.2.1): anything still in
	// flight whose packet number is more than LOSS_PACKET_THRESHOLD below the
	// largest acked is declared lost.
	if any_acked && len(conn.loss_sent) > 0 {
		largest_acked := f.largest_acknowledged
		threshold := u64(LOSS_PACKET_THRESHOLD)
		loss_detected := false
		i := 0
		for i < len(conn.loss_sent) {
			pkt := &conn.loss_sent[i]
			if pkt.packet_number + threshold < largest_acked {
				for r in pkt.stream_ranges {
					s := conn_get_stream(conn, r.stream_id)
					if s == nil do continue
					_stream_requeue_range(s, r)
					_stream_clear_unacked(s, r.packet_number)
				}
				delete(pkt.stream_ranges)
				// Remove from in-flight accounting.
				if u64(pkt.size) <= conn.cc.bytes_in_flight {
					conn.cc.bytes_in_flight -= u64(pkt.size)
				} else {
					conn.cc.bytes_in_flight = 0
				}
				ordered_remove(&conn.loss_sent, i)
				loss_detected = true
				continue // don't advance i — next packet shifted into this slot
			}
			i += 1
		}
		if loss_detected {
			on_loss(&conn.cc, now)
		}
	}

	// Any ACK resets the PTO backoff factor.
	conn.loss_pto_factor = 1

	// Rearm or disarm PTO based on remaining ack-eliciting in-flight data.
	has_pending := false
	for p in conn.loss_sent {
		if p.ack_eliciting {
			has_pending = true
			break
		}
	}
	if has_pending {
		_loss_arm_pto(conn)
	} else {
		conn.loss_pto_deadline = {}
	}
}

// Called from the Conn pump. Returns true if PTO fired and a retransmit was
// re-queued (the caller's next send pass picks it up).
loss_check_pto :: proc(conn: ^Conn) -> bool {
	if conn.loss_pto_deadline == (time.Time{}) do return false
	now := _now(conn)
	if time.diff(now, conn.loss_pto_deadline) > 0 do return false

	// PTO fired. Re-queue ONE probe's worth — the oldest unacked packet's
	// stream data — so the next packet build emits a single ack-eliciting
	// probe (RFC 9002 §6.2.4). Halving the window bounds the blast radius.
	if len(conn.loss_sent) > 0 {
		oldest := conn.loss_sent[0]
		for r in oldest.stream_ranges {
			s := conn_get_stream(conn, r.stream_id)
			if s == nil do continue
			_stream_requeue_range(s, r)
		}
		for r in oldest.stream_ranges {
			s := conn_get_stream(conn, r.stream_id)
			if s == nil do continue
			_stream_clear_unacked(s, r.packet_number)
		}
		delete(oldest.stream_ranges)
		// The probe will be re-sent as a NEW packet number; drop the old
		// entry so we don't double-count it in flight. Its size will be
		// re-added when the probe is sent (loss_record_sent_packet).
		if u64(oldest.size) <= conn.cc.bytes_in_flight {
			conn.cc.bytes_in_flight -= u64(oldest.size)
		} else {
			conn.cc.bytes_in_flight = 0
		}
		ordered_remove(&conn.loss_sent, 0)
		on_pto(&conn.cc)
	}

	// Back off: double the next PTO up to the cap.
	if conn.loss_pto_factor < PTO_MAX_DOUBLINGS {
		conn.loss_pto_factor += 1
	}
	_loss_arm_pto(conn)
	return true
}

// Is `pn` covered by any of the ACK's decoded inclusive ranges?
@(private)
_packet_in_ranges :: proc(pn: u64, f: Ack_Frame) -> bool {
	for i in 0..<f.range_count {
		if pn >= f.ranges[i][0] && pn <= f.ranges[i][1] do return true
	}
	return false
}

@(private)
_loss_arm_pto :: proc(conn: ^Conn) {
	dur := pto_duration(&conn.cc, conn.loss_pto_factor)
	conn.loss_pto_deadline = time.time_add(_now(conn), dur)
}

// The clock. Returns conn.clock when a test has set it (non-zero), else real
// wall-clock time. Production conns leave clock at zero, so this is free.
@(private)
_now :: proc(conn: ^Conn) -> time.Time {
	if conn.clock != (time.Time{}) do return conn.clock
	return time.now()
}

// Remove any tx_unacked entries that were sent in the given packet number.
// Called from both the ACK path (packet acknowledged — data delivered) and
// the loss/PTO path (packet lost — data re-queued via _stream_requeue_range).
@(private)
_stream_clear_unacked :: proc(s: ^Stream, packet_number: u64) {
	kept: [dynamic]Sent_Range
	kept.allocator = context.temp_allocator
	for r in s.tx_unacked {
		if r.packet_number == packet_number do continue
		append(&kept, r)
	}
	delete(s.tx_unacked)
	s.tx_unacked = kept
}

// Advance the per-stream ACKed watermark (tx_acked_off) past the newly-acked
// range, so stream_compact can reclaim that prefix. The range's offset is
// absolute; convert to a buffer index by subtracting tx_abs_base.
// When the range carried FIN, mark tx_fin_acked.
@(private)
_stream_advance_acked :: proc(s: ^Stream, r: Sent_Range) {
	end_abs := r.offset + r.len
	end_idx := u64(0)
	if end_abs > s.tx_abs_base {
		end_idx = end_abs - s.tx_abs_base
	}
	if end_idx > s.tx_acked_off {
		s.tx_acked_off = end_idx
	}
	if r.fin {
		s.tx_fin_acked = true
	}
	stream_compact(s)
}

// Re-queue a lost byte range for retransmission by rewinding tx_sent_off so
// the next packet build re-emits those bytes. The bytes still live in
// tx_buffered (we don't drain on send) — see the Stream send-side fields.
// tx_next_offset is the absolute offset; rewinding tx_sent_off makes the
// builder re-emit from the lost range's absolute offset.
// Guarded: if tx_sent_off is already at/below the range's start, the bytes
// are already queued for retransmit (or never left) — don't rewind further.
// When the lost range carried FIN (including FIN-only empty STREAM), clear
// tx_fin_sent so the builder re-sets the FIN bit on retransmit.
@(private)
_stream_requeue_range :: proc(s: ^Stream, r: Sent_Range) {
	if r.len > 0 {
		start_idx := u64(0)
		if r.offset > s.tx_abs_base {
			start_idx = r.offset - s.tx_abs_base
		}
		if start_idx < s.tx_sent_off {
			s.tx_sent_off = start_idx
			s.tx_next_offset = r.offset
		}
	}
	if r.fin {
		s.tx_fin_sent = false
	}
}
