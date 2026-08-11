package quic

// Live-network interop probe (off by default): traces a real-internet QUIC
// handshake datagram by datagram. Found the missing-SNI close (0x128) and the
// single-packet-ACK retransmit storm. Run with:
//   odin test quic -define:ODIN_TEST_NAMES=quic.test_cf_probe \
//     -define:QUIC_NET_PROBE=true [-define:QUIC_PROBE_HOST=host]

import "core:fmt"
import "core:net"
import "core:testing"
import "core:time"

NET_PROBE :: #config(QUIC_NET_PROBE, false)
PROBE_HOST :: #config(QUIC_PROBE_HOST, "cloudflare-quic.com")

when NET_PROBE {
	@(test)
	test_cf_probe :: proc(t: ^testing.T) {
		host := PROBE_HOST
		alpn := [3]u8{2, 'h', '3'}
		params := Transport_Params {
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
		conn, _ := conn_new(host, alpn[:], params) // verification ON — real host, real cert

		ep, _, ok := conn_parse_endpoint(fmt.tprintf("%s:443", host))
		if !ok {
			fmt.println("resolve failed")
			return
		}
		fmt.printfln("resolved %v", ep)

		sock, serr := net.make_unbound_udp_socket(net.family_from_endpoint(ep))
		if serr != nil do return
		conn.socket = sock
		conn.remote = ep
		conn.socket_owned = true
		net.set_blocking(sock, false)

		if hs := conn_start_handshake(conn); hs != .None {
			fmt.printfln("start_handshake err=%v", hs)
			return
		}
		if terr := _send_pending_initial(conn); terr != .None {
			fmt.printfln("send initial err=%v", terr)
			return
		}
		fmt.println("-> Initial sent")

		deadline := time.time_add(time.now(), 6 * time.Second)
		buf: [4096]u8
		for conn.state != .Connected && time.diff(time.now(), deadline) > 0 {
			n, _, rerr := net.recv_udp(sock, buf[:])
			if rerr != nil || n == 0 {
				time.sleep(2 * time.Millisecond)
				continue
			}
			fmt.printfln("<- datagram %d bytes (first=%02x)", n, buf[0])
			rerr2 := conn_on_udp_recv(conn, buf[:n])
			fmt.printfln(
				"   recv err=%v state=%v hs_rx_keys=%v 1rtt_rx_keys=%v dropped=%d decrypted=%d decrypt_failed=%d init_txc=%d hs_txc=%d",
				rerr2, conn.state, conn.handshake.have_rx_keys, conn.one_rtt.have_rx_keys,
				conn.stats.packets_dropped, conn.stats.packets_decrypted,
				conn.stats.packets_decrypt_failed,
				len(conn.initial.tx_crypto), len(conn.handshake.tx_crypto),
			)
			if terr := _send_pending_initial(conn); terr != .None do fmt.printfln("   send init err=%v", terr)
			if terr := _send_pending_handshake(conn); terr != .None do fmt.printfln("   send hs err=%v", terr)
		}
		fmt.printfln("final state=%v sent=%d", conn.state, conn.stats.udp_packets_sent)
		if conn.state == .Closing {
			fmt.printfln(
				"CONNECTION_CLOSE code=0x%x app=%v reason=%q",
				conn.peer_close_code, conn.peer_close_is_app,
				string(conn.peer_close_reason[:conn.peer_close_reason_len]),
			)
		}
	}
}
