package quic

import "core:crypto"
import "core:fmt"
import "core:net"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

// End-to-end test for the Endpoint demux:
//   * Bind an Endpoint on 127.0.0.1:<random>
//   * Spawn a worker that calls endpoint_accept
//   * On the main thread, drive a client Conn through conn_connect
//   * Verify both sides reach .Connected and that the ALPN was captured

@(test)
test_endpoint_handshake :: proc(t: ^testing.T) {
	port := _pick_test_port()
	listen_addr := fmt.aprintf("127.0.0.1:%d", port)
	defer delete(listen_addr)

	server_tp := _default_client_tp()
	server_tp.initial_max_streams_bidi    = 1
	server_tp.initial_max_streams_uni     = 8
	server_tp.initial_max_stream_data_bidi_local  = 1 * 1024 * 1024
	server_tp.initial_max_stream_data_bidi_remote = 1 * 1024 * 1024
	server_tp.initial_max_stream_data_uni = 1 * 1024 * 1024

	ep, eerr := endpoint_new(
		listen_addr,
		transmute([]u8)string(TEST_CERT_PEM),
		transmute([]u8)string(TEST_KEY_PEM),
		server_tp,
	)
	if eerr != .None {
		testing.expectf(t, false, "endpoint_new failed: %v", eerr)
		return
	}
	defer endpoint_close(ep)

	// Acceptor worker.
	Worker :: struct {
		ep:       ^Endpoint,
		conn:     ^Conn,
		err:      Endpoint_Error,
		done:     sync.Sema,
	}
	worker := Worker{ep = ep}
	th := thread.create_and_start_with_data(&worker, proc(data: rawptr) {
		w := cast(^Worker)data
		w.conn, w.err = endpoint_accept(w.ep, 5 * time.Second)
		sync.sema_post(&w.done)
	})
	defer thread.destroy(th)

	// Give the acceptor time to wake up on recv_udp.
	time.sleep(20 * time.Millisecond)

	// Client side: ALPN list including zenoh-ms-mr to exercise multi-stream
	// negotiation. Server's _server_alpn_select_cb picks the first protocol
	// the client offers, so the ALPN ends up as zenoh-ms-mr.
	alpn_buf: [64]u8
	alpn := build_zenoh_alpn_wire(&alpn_buf)

	client_tp := _default_client_tp()
	client_tp.initial_max_streams_bidi    = 1
	client_tp.initial_max_streams_uni     = 8
	client_tp.initial_max_stream_data_bidi_local  = 1 * 1024 * 1024
	client_tp.initial_max_stream_data_bidi_remote = 1 * 1024 * 1024
	client_tp.initial_max_stream_data_uni = 1 * 1024 * 1024

	client, _ := conn_new("localhost", alpn, client_tp)
	defer conn_free(client)
	conn_disable_verify(client)

	endpoint := fmt.aprintf("127.0.0.1:%d", port)
	defer delete(endpoint)
	terr := conn_connect(client, endpoint, 5 * time.Second)
	testing.expectf(t, terr == .None, "client conn_connect failed: %v", terr)

	// Wait for the acceptor.
	if !sync.sema_wait_with_timeout(&worker.done, 5 * time.Second) {
		testing.expectf(t, false, "endpoint_accept timed out")
		return
	}
	if worker.err != .None {
		testing.expectf(t, false, "endpoint_accept error: %v", worker.err)
		return
	}
	defer conn_free(worker.conn)

	testing.expect_value(t, client.state, Conn_State.Connected)
	testing.expect_value(t, worker.conn.state, Conn_State.Connected)

	// ALPN got captured on the client (server captures on its own thread
	// inside endpoint_on_udp_recv).
	testing.expect(t, conn_alpn_is_multi_stream(client),
		"client should see multi-stream ALPN")
	testing.expect(t, conn_alpn_is_multi_stream(worker.conn),
		"server should see multi-stream ALPN")
}

@(private)
_pick_test_port :: proc() -> u16 {
	buf: [2]u8
	crypto.rand_bytes(buf[:])
	return 30000 + u16(buf[0]) * 100 + u16(buf[1]) % 100
}
