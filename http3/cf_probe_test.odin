package http3

// Live-network interop probe (off by default): brings up h3 against a real
// server and traces SETTINGS exchange + one GET at stream/frame granularity.
// Run with:
//   odin test http3 -define:ODIN_TEST_NAMES=http3.test_cf_h3_probe \
//     -define:H3_NET_PROBE=true [-define:H3_PROBE_HOST=host]

import "core:fmt"
import "core:net"
import "core:testing"
import "core:time"

import "../qpack"
import "../quic"

NET_PROBE :: #config(H3_NET_PROBE, false)
PROBE_HOST :: #config(H3_PROBE_HOST, "cloudflare-quic.com")

when NET_PROBE {
	@(test)
	test_cf_h3_probe :: proc(t: ^testing.T) {
		host := PROBE_HOST
		alpn := [3]u8{2, 'h', '3'}
		params := quic.Transport_Params {
			max_idle_timeout                    = 30_000,
			max_udp_payload_size                = 1472,
			initial_max_data                    = 10 * 1024 * 1024,
			initial_max_stream_data_bidi_local  = 1 * 1024 * 1024,
			initial_max_stream_data_bidi_remote = 1 * 1024 * 1024,
			initial_max_stream_data_uni         = 1 * 1024 * 1024,
			initial_max_streams_bidi            = 16,
			initial_max_streams_uni             = 16,
			ack_delay_exponent                  = 3,
			max_ack_delay                       = 25,
			active_connection_id_limit          = 2,
		}
		conn, _ := quic.conn_new(host, alpn[:], params) // verification ON — real host, real cert
		cerr := quic.conn_connect(conn, fmt.tprintf("%s:443", host))
		fmt.printfln("connect err=%v state=%v", cerr, conn.state)
		if cerr != .None do return
		net.set_blocking(conn.socket, false)

		h3: Http3_Connection
		if e := h3_conn_init(&h3, conn, false, DEFAULT_SETTINGS); e != .None {
			fmt.printfln("h3_conn_init err=%v", e)
			return
		}

		deadline := time.time_add(time.now(), 6 * time.Second)
		last_report := i64(0)
		for time.diff(time.now(), deadline) > 0 {
			pump_quic_send(conn)
			got := pump_quic_recv(conn)
			perr := h3_conn_process(&h3)
			if got > 0 || perr != .None {
				fmt.printfln(
					"recv=%d process=%v settings=%v streams=%d sframes_rx=%d pkts_rx=%d dropped=%d dec_fail=%d state=%v",
					got, perr, h3.peer_settings_received, len(conn.streams),
					conn.stats.stream_frames_received, conn.stats.packets_decrypted,
					conn.stats.packets_dropped, conn.stats.packets_decrypt_failed, conn.state,
				)
				for id, s in conn.streams {
					fmt.printfln("   stream %d: rx=%d tx_buffered=%d", id, len(s.rx_delivered), len(s.tx_buffered))
				}
			}
			if conn.state == .Closing {
				fmt.printfln(
					"CONNECTION_CLOSE code=0x%x app=%v reason=%q",
					conn.peer_close_code, conn.peer_close_is_app,
					string(conn.peer_close_reason[:conn.peer_close_reason_len]),
				)
				return
			}
			if h3.peer_settings_received do break
			_ = last_report
			time.sleep(2 * time.Millisecond)
		}
		if !h3.peer_settings_received {
			fmt.println("TIMEOUT waiting for peer settings")
			return
		}
		fmt.println("PEER SETTINGS RECEIVED — sending GET /")

		req_headers := [4]qpack.Header{
			{name = ":method", value = "GET"}, {name = ":scheme", value = "https"},
			{":authority", host}, {name = ":path", value = "/"},
		}
		rs, se := h3_send_request(&h3, req_headers[:], nil)
		fmt.printfln("h3_send_request err=%v stream=%d", se, rs)
		if se != .None do return

		req_deadline := time.time_add(time.now(), 6 * time.Second)
		ticks := 0
		for time.diff(time.now(), req_deadline) > 0 {
			pump_quic_send(conn)
			got := pump_quic_recv(conn)
			perr := h3_conn_process(&h3)
			if got > 0 {
				s, sok := conn.streams[u64(rs)]
				rxlen, txpend, txoff, txmax := -1, -1, u64(0), u64(0)
				if sok {
					rxlen = len(s.rx_delivered)
						txpend = len(s.tx_buffered)
					txoff = s.tx_next_offset
					txmax = s.tx_peer_max_data
				}
				fmt.printfln(
					"recv=%d process=%v req[rx=%d txpend=%d txoff=%d txmax=%d] sf_tx=%d sf_rx=%d sbytes_rx=%d pkts=%d state=%v",
					got, perr, rxlen, txpend, txoff, txmax,
					conn.stats.stream_frames_sent, conn.stats.stream_frames_received,
					conn.stats.stream_bytes_received, conn.stats.packets_decrypted, conn.state,
				)
			}
			if conn.state == .Closing {
				fmt.printfln(
					"CONNECTION_CLOSE code=0x%x app=%v reason=%q",
					conn.peer_close_code, conn.peer_close_is_app,
					string(conn.peer_close_reason[:conn.peer_close_reason_len]),
				)
				return
			}
			if hs, b, done := h3_response(&h3, rs); done {
				fmt.printfln("RESPONSE: %d headers, %d body bytes", len(hs), len(b))
				for hh in hs[:min(len(hs), 6)] do fmt.printfln("   %s: %s", hh.name, hh.value)
				return
			}
			ticks += 1
			time.sleep(2 * time.Millisecond)
		}
		fmt.println("TIMEOUT waiting for response")
	}
}
