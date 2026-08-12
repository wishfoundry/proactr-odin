package quic

import "core:testing"
import "core:time"

// Exhaustive suite: fills coverage gaps beyond frame/codec/unit tests.
// Uses _make_pair / _drive_handshake from integration_test.odin.
// Areas:
//   • Bulk stream transfer with ACK pumping (cwnd must grow)
//   • Multi-stream concurrent transfer
//   • Stream FIN + empty FIN
//   • Connection-level + stream-level flow control under load
//   • Reordering on the wire (out-of-order packets)
//   • Many sequential transfers (leak / state reset)
//   • Handshake rate smoke (timed, non-failing bound)

// Shuttle: deliver all pending packets both ways until idle (ACK pump).

@(private)
_shuttle_once :: proc(a, b: ^Conn, pkt: []u8) -> (moved: bool) {
	// Prefer stream/ACK packets; also Initial/Handshake leftovers after HS.
	n, _, err := conn_build_stream_packet(a, pkt)
	if err == .None && n > 0 {
		_ = conn_on_udp_recv(b, pkt[:n])
		return true
	}
	// Handshake residual (rare post-connect).
	if len(a.handshake.tx_crypto) > 0 {
		hn, herr := conn_build_handshake_packet(a, pkt)
		if herr == .None && hn > 0 {
			_ = conn_on_udp_recv(b, pkt[:hn])
			return true
		}
	}
	return false
}

// Pump until neither side has pending stream data, owed ACKs, or progress.
@(private)
_shuttle_until_idle :: proc(client, server: ^Conn, max_iters := 100_000) -> int {
	pkt: [2048]u8
	iters := 0
	stall := 0
	for iters < max_iters {
		moved := false
		if _shuttle_once(client, server, pkt[:]) do moved = true
		if _shuttle_once(server, client, pkt[:]) do moved = true
		iters += 1
		if moved {
			stall = 0
			continue
		}
		stall += 1
		// Two idle rounds: nothing left to send either way.
		if stall >= 2 do break
	}
	return iters
}

// Transfer `size` bytes client→server on stream 0 with full ACK pumping.
@(private)
_bulk_transfer_c2s :: proc(
	client, server: ^Conn,
	size: int,
) -> (
	ok: bool,
	elapsed: time.Duration,
	got: int,
) {
	if client.state != .Connected || server.state != .Connected do return false, 0, 0

	// Large windows so flow control is not the limiter under test (CC still is
	// until ACKs free in-flight — shuttle handles that).
	cs := conn_open_stream(client)
	if cs == nil do return false, 0, 0
	cs.tx_peer_max_data = u64(max(size*2, int(DEFAULT_STREAM_WINDOW)))
	client.tx_peer_max_data = u64(max(size*2, int(DEFAULT_CONN_WINDOW)))
	// Server receive window
	if ss := conn_get_or_open_stream(server, 0); ss != nil {
		ss.rx_our_max_data = u64(max(size*2, int(DEFAULT_STREAM_WINDOW)))
	}
	server.rx_our_max_data = u64(max(size*2, int(DEFAULT_CONN_WINDOW)))

	payload := make([]u8, size)
	defer delete(payload)
	for i in 0 ..< size {
		payload[i] = u8((i * 131) & 0xff)
	}

	start := time.tick_now()
	stream_write(cs, payload)
	stream_close_send(cs)
	client.stats.stream_bytes_written += u64(size)

	// Interleave: build client packets, deliver, pump server ACKs, read.
	recv_buf := make([]u8, min(size, 256*1024))
	defer delete(recv_buf)
	got = 0
	pkt: [2048]u8
	safety := 0
	max_safety := size / 100 + 10_000
	for got < size && safety < max_safety {
		safety += 1
		// Client emit as many packets as budget allows this turn.
		for _ in 0 ..< 32 {
			n, sent, err := conn_build_stream_packet(client, pkt[:])
			if err != .None || n == 0 do break
			_ = sent
			if conn_on_udp_recv(server, pkt[:n]) != .None do return false, 0, got
			// Immediate reverse: server ACKs / MAX_DATA.
			sn, _, _ := conn_build_stream_packet(server, pkt[:])
			if sn > 0 {
				if conn_on_udp_recv(client, pkt[:sn]) != .None do return false, 0, got
			}
		}
		// Drain any remaining reverse traffic.
		_ = _shuttle_until_idle(client, server, 64)

		ss := conn_get_stream(server, 0)
		if ss == nil do continue
		for {
			n, rok := stream_read(ss, recv_buf[:])
			if n <= 0 {
				_ = rok
				break
			}
			// Verify pattern on a sample of bytes.
			base := got
			for i in 0 ..< n {
				want := u8(((base + i) * 131) & 0xff)
				if recv_buf[i] != want {
					return false, 0, got
				}
			}
			got += n
			server.stats.stream_bytes_read += u64(n)
		}
	}
	elapsed = time.tick_diff(start, time.tick_now())
	ok = got == size
	return
}

// Tests

@(test)
test_suite_bulk_64kib_with_ack_pump :: proc(t: ^testing.T) {
	client, server, pok := _make_pair()
	testing.expect(t, pok)
	defer conn_free(client)
	defer conn_free(server)
	testing.expect(t, _drive_handshake(client, server))

	ok, _, got := _bulk_transfer_c2s(client, server, 64 * 1024)
	testing.expect(t, ok, "64 KiB bulk transfer should complete with ACK pump")
	testing.expect_value(t, got, 64 * 1024)
}

@(test)
test_suite_bulk_1mib_with_ack_pump :: proc(t: ^testing.T) {
	client, server, pok := _make_pair()
	testing.expect(t, pok)
	defer conn_free(client)
	defer conn_free(server)
	testing.expect(t, _drive_handshake(client, server))

	ok, elapsed, got := _bulk_transfer_c2s(client, server, 1 << 20)
	testing.expect(t, ok, "1 MiB bulk transfer should complete")
	testing.expect_value(t, got, 1 << 20)
	// Sanity: should finish in under 30s even on slow CI.
	testing.expect(t, elapsed < 30 * time.Second, "1 MiB took too long")
}

@(test)
test_suite_bulk_4mib_with_ack_pump :: proc(t: ^testing.T) {
	client, server, pok := _make_pair()
	testing.expect(t, pok)
	defer conn_free(client)
	defer conn_free(server)
	testing.expect(t, _drive_handshake(client, server))

	ok, elapsed, got := _bulk_transfer_c2s(client, server, 4 << 20)
	testing.expect(t, ok, "4 MiB bulk transfer should complete")
	testing.expect_value(t, got, 4 << 20)
	testing.expect(t, elapsed < 60 * time.Second, "4 MiB took too long")
}

@(test)
test_suite_bidirectional_bulk :: proc(t: ^testing.T) {
	client, server, pok := _make_pair()
	testing.expect(t, pok)
	defer conn_free(client)
	defer conn_free(server)
	testing.expect(t, _drive_handshake(client, server))

	// Client → server 64 KiB on stream 0.
	ok1, _, g1 := _bulk_transfer_c2s(client, server, 64 * 1024)
	testing.expect(t, ok1)
	testing.expect_value(t, g1, 64 * 1024)

	// Server → client on same stream (bidi): open server send on stream 0.
	ss := conn_get_stream(server, 0)
	testing.expect(t, ss != nil)
	ss.tx_peer_max_data = DEFAULT_STREAM_WINDOW
	server.tx_peer_max_data = DEFAULT_CONN_WINDOW
	cs := conn_get_stream(client, 0)
	testing.expect(t, cs != nil)
	cs.rx_our_max_data = DEFAULT_STREAM_WINDOW

	msg := make([]u8, 32 * 1024)
	defer delete(msg)
	for i in 0 ..< len(msg) do msg[i] = u8(i & 0xff)
	stream_write(ss, msg)
	stream_close_send(ss)

	pkt: [2048]u8
	got := 0
	recv := make([]u8, 32 * 1024)
	defer delete(recv)
	for _ in 0 ..< 10_000 {
		n, _, err := conn_build_stream_packet(server, pkt[:])
		if err == .None && n > 0 {
			_ = conn_on_udp_recv(client, pkt[:n])
			cn, _, _ := conn_build_stream_packet(client, pkt[:])
			if cn > 0 do _ = conn_on_udp_recv(server, pkt[:cn])
		}
		rn, _ := stream_read(cs, recv[got:])
		got += rn
		if got >= len(msg) do break
		if n == 0 && rn == 0 {
			_ = _shuttle_until_idle(client, server, 8)
		}
	}
	testing.expect_value(t, got, len(msg))
}

@(test)
test_suite_multistream_parallel_small :: proc(t: ^testing.T) {
	// Open several client-initiated bidi streams and send a short message on each.
	client, server, pok := _make_pair()
	testing.expect(t, pok)
	defer conn_free(client)
	defer conn_free(server)
	testing.expect(t, _drive_handshake(client, server))

	// Client bidi ids: 0, 4, 8, 12
	N :: 4
	streams: [N]^Stream
	for i in 0 ..< N {
		id := u64(i * 4)
		s := conn_get_or_open_stream(client, id)
		testing.expect(t, s != nil)
		s.tx_peer_max_data = DEFAULT_STREAM_WINDOW
		streams[i] = s
		msg := transmute([]u8)string("stream-payload")
		// Unique last byte
		payload := make([]u8, len(msg)+1)
		defer delete(payload)
		copy(payload, msg)
		payload[len(msg)] = u8(i)
		stream_write(s, payload)
		stream_close_send(s)
	}

	_ = _shuttle_until_idle(client, server, 50_000)

	for i in 0 ..< N {
		id := u64(i * 4)
		ss := conn_get_stream(server, id)
		testing.expect(t, ss != nil, "server should have stream")
		buf: [32]u8
		n, _ := stream_read(ss, buf[:])
		testing.expect(t, n >= 14)
		testing.expect_value(t, buf[n-1], u8(i))
	}
}

@(test)
test_suite_empty_stream_fin_only :: proc(t: ^testing.T) {
	client, server, pok := _make_pair()
	testing.expect(t, pok)
	defer conn_free(client)
	defer conn_free(server)
	testing.expect(t, _drive_handshake(client, server))

	cs := conn_open_stream(client)
	cs.tx_peer_max_data = DEFAULT_STREAM_WINDOW
	stream_close_send(cs) // FIN with no data

	pkt: [2048]u8
	n, sent, err := conn_build_stream_packet(client, pkt[:])
	testing.expect_value(t, err, Quic_Error.None)
	testing.expect(t, n > 0, "should emit FIN-only STREAM frame")
	testing.expect_value(t, sent, 0)
	testing.expect(t, cs.tx_fin_sent)
	// FIN-only must enter loss recovery so a lost empty FIN can retransmit.
	testing.expect(t, len(client.loss_sent) >= 1, "FIN-only packet in loss log")
	testing.expect(t, client.loss_sent[0].ack_eliciting)
	testing.expect(t, len(client.loss_sent[0].stream_ranges) >= 1)
	testing.expect(t, client.loss_sent[0].stream_ranges[0].fin)

	_ = conn_on_udp_recv(server, pkt[:n])
	ss := conn_get_stream(server, 0)
	testing.expect(t, ss != nil)
	fin_off, has_fin := ss.rx_fin_offset.?
	testing.expect(t, has_fin, "server must observe FIN")
	testing.expect_value(t, fin_off, u64(0))
	testing.expect(t, ss.rx_closed, "empty FIN closes recv half")
	buf: [8]u8
	rn, rok := stream_read(ss, buf[:])
	testing.expect_value(t, rn, 0)
	testing.expect(t, !rok, "stream_read reports closed after empty FIN")
}

// Lost empty FIN must be retransmitted after PTO (clear tx_fin_sent on requeue).
@(test)
test_suite_empty_stream_fin_retransmit_on_pto :: proc(t: ^testing.T) {
	client, server, pok := _make_pair()
	testing.expect(t, pok)
	defer conn_free(client)
	defer conn_free(server)
	testing.expect(t, _drive_handshake(client, server))

	cs := conn_open_stream(client)
	cs.tx_peer_max_data = DEFAULT_STREAM_WINDOW
	stream_close_send(cs)

	// Known PTO: seed RTT so pto_duration is deterministic.
	client.cc.srtt = 50 * time.Millisecond
	client.cc.rttvar = 25 * time.Millisecond
	client.cc.min_rtt = 50 * time.Millisecond
	t0 := time.now()
	client.clock = t0

	pkt: [2048]u8
	n, sent, err := conn_build_stream_packet(client, pkt[:])
	testing.expect_value(t, err, Quic_Error.None)
	testing.expect(t, n > 0 && sent == 0)
	testing.expect(t, cs.tx_fin_sent)
	testing.expect_value(t, len(client.loss_sent), 1)

	// *** SIMULATE LOSS: do not deliver the FIN-only packet. ***
	pto_ns := pto_duration(&client.cc, 0)
	client.clock = time.time_add(t0, pto_ns + time.Millisecond)
	fired := loss_check_pto(client)
	testing.expect(t, fired, "PTO should fire")
	testing.expect(t, !cs.tx_fin_sent, "FIN must be re-eligible after loss requeue")

	rt_n, rt_sent, rt_err := conn_build_stream_packet(client, pkt[:])
	testing.expect_value(t, rt_err, Quic_Error.None)
	testing.expect(t, rt_n > 0, "retransmit FIN-only packet")
	testing.expect_value(t, rt_sent, 0)
	testing.expect(t, cs.tx_fin_sent)

	_ = conn_on_udp_recv(server, pkt[:rt_n])
	ss := conn_get_stream(server, 0)
	testing.expect(t, ss != nil)
	_, has_fin := ss.rx_fin_offset.?
	testing.expect(t, has_fin, "server observes retransmitted FIN")
	testing.expect(t, ss.rx_closed)

	client.clock = {}
}

@(test)
test_suite_packet_reorder_delivery :: proc(t: ^testing.T) {
	// Send two packets; deliver second before first; receiver must reassemble.
	client, server, pok := _make_pair()
	testing.expect(t, pok)
	defer conn_free(client)
	defer conn_free(server)
	testing.expect(t, _drive_handshake(client, server))

	cs := conn_open_stream(client)
	cs.tx_peer_max_data = DEFAULT_STREAM_WINDOW
	// Two chunks large enough to force separate packets.
	a := make([]u8, 1000)
	b := make([]u8, 1000)
	defer delete(a)
	defer delete(b)
	for i in 0 ..< 1000 {
		a[i] = 0xAA
		b[i] = 0xBB
	}
	stream_write(cs, a)
	stream_write(cs, b)

	pkt1: [2048]u8
	pkt2: [2048]u8
	n1, s1, e1 := conn_build_stream_packet(client, pkt1[:])
	testing.expect_value(t, e1, Quic_Error.None)
	testing.expect(t, n1 > 0 && s1 > 0)
	n2, s2, e2 := conn_build_stream_packet(client, pkt2[:])
	testing.expect_value(t, e2, Quic_Error.None)
	testing.expect(t, n2 > 0 && s2 > 0)

	// Reorder: deliver pkt2 first.
	_ = conn_on_udp_recv(server, pkt2[:n2])
	ss := conn_get_stream(server, 0)
	testing.expect(t, ss != nil)
	// Should not deliver BB before AA (gap).
	buf: [2048]u8
	n_early, _ := stream_read(ss, buf[:])
	// Either 0 (held as fragment) or only if first packet was actually second offset
	// — first packet has offset 0, second has higher offset, so early read must be 0.
	testing.expect_value(t, n_early, 0)

	_ = conn_on_udp_recv(server, pkt1[:n1])
	n_full, _ := stream_read(ss, buf[:])
	testing.expect(t, n_full >= 1000)
	// First delivered bytes should be 0xAA from packet 1.
	testing.expect_value(t, buf[0], u8(0xAA))
}

@(test)
test_suite_many_sequential_transfers :: proc(t: ^testing.T) {
	// 10 handshakes × 16 KiB transfer — leak / state hygiene under odin test tracker.
	for round in 0 ..< 10 {
		client, server, pok := _make_pair()
		testing.expect(t, pok)
		testing.expect(t, _drive_handshake(client, server))
		ok, _, got := _bulk_transfer_c2s(client, server, 16 * 1024)
		testing.expect(t, ok)
		testing.expect_value(t, got, 16 * 1024)
		conn_free(client)
		conn_free(server)
		_ = round
	}
}

@(test)
test_suite_handshake_rate_smoke :: proc(t: ^testing.T) {
	// Timed: 50 handshakes; soft bound so CI doesn't flake, documents baseline.
	N :: 50
	start := time.tick_now()
	for i in 0 ..< N {
		client, server, pok := _make_pair()
		testing.expect(t, pok)
		testing.expect(t, _drive_handshake(client, server))
		conn_free(client)
		conn_free(server)
		_ = i
	}
	elapsed := time.tick_diff(start, time.tick_now())
	// Extremely loose: > 1 hs/s. Real targets live in comparisons/quic-bench.
	testing.expect(t, elapsed < 50 * time.Second)
	_ = elapsed
}

@(test)
test_suite_cc_blocks_without_ack_then_resumes :: proc(t: ^testing.T) {
	// Without ACKs, cwnd fills and send_budget hits 0; after ACK pump, more data sends.
	client, server, pok := _make_pair()
	testing.expect(t, pok)
	defer conn_free(client)
	defer conn_free(server)
	testing.expect(t, _drive_handshake(client, server))

	cs := conn_open_stream(client)
	cs.tx_peer_max_data = 10 << 20
	client.tx_peer_max_data = 10 << 20
	// Write more than initial cwnd (~10–15 KiB).
	big := make([]u8, 64 * 1024)
	defer delete(big)
	stream_write(cs, big)

	pkt: [2048]u8
	sent_total := 0
	// Send without delivering ACKs back to client.
	for _ in 0 ..< 64 {
		n, s, err := conn_build_stream_packet(client, pkt[:])
		if err != .None || n == 0 do break
		sent_total += s
		_ = conn_on_udp_recv(server, pkt[:n])
		// Deliberately do NOT send server ACK packets to client.
	}
	testing.expect(t, sent_total > 0)
	testing.expect(t, sent_total < len(big), "should stall before full write without ACKs")
	// Budget exhausted (cwnd full) once we can't make progress without ACKs.
	budget_after := send_budget(&client.cc)
	testing.expect(t, budget_after == 0 || sent_total < 20 * 1024,
		"cwnd should constrain unacked bulk")

	stalled_at := sent_total

	// Pump ACKs both ways, then client should send more of the buffered payload.
	for _ in 0 ..< 512 {
		// Server → client ACKs
		sn, _, _ := conn_build_stream_packet(server, pkt[:])
		if sn > 0 do _ = conn_on_udp_recv(client, pkt[:sn])
		// Client → server data
		n, s, err := conn_build_stream_packet(client, pkt[:])
		if err != .None || n == 0 do continue
		sent_total += s
		_ = conn_on_udp_recv(server, pkt[:n])
	}
	testing.expect(t, sent_total > stalled_at,
		"ACK pump should free in-flight and allow more stream data")
}
