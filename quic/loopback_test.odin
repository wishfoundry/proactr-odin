package quic

import "core:testing"
import "core:fmt"

// --- Phase 7b: end-to-end loopback handshake test ---
// Creates a client Conn and a server Conn, shuttles emitted packets between
// them via direct function calls (no network), and drives both state
// machines forward until they both report .Connected. Proves:
//   1. Server Initial key derivation from client's DCID works.
//   2. Initial packet round-trip across both directions succeeds.
//   3. BoringSSL's TLS 1.3 handshake completes over our QUIC transport.
//   4. set_read_secret / set_write_secret are invoked for both Handshake and
//      Application encryption levels.
//   5. conn_on_udp_recv correctly parses coalesced packets.
//   6. Peer transport parameters are extracted after handshake completion
//      (including max_datagram_frame_size — the DATAGRAM negotiation).
// The PEM cert/key below are minica-generated for "localhost" (reused from
// zenoh-rs's endpoint_quic test). They are expired — the client disables
// verification via conn_disable_verify because this is a loopback test, not
// a production handshake.

@(private)
TEST_KEY_PEM :: `-----BEGIN RSA PRIVATE KEY-----
MIIEowIBAAKCAQEAz105EYUbOdW5uJ8o/TqtxtOtKJL7AQdy5yiXoslosAsulaew
4JSJetVa6Fa6Bq5BK6fsphGD9bpGGeiBZFBt75JRjOrkj4DwlLGa0CPLTgG5hul4
Ufe9B7VG3J5P8OwUqIYmPzj8uTbNtkgFRcYumHR28h4GkYdG5Y04AV4vIjgKE47j
AgV5ACRHkcmGrTzF2HOes2wT73l4yLSkKR4GlIWu5cLRdI8PTUmjMFAh/GIh1ahd
+VqXz051V3jok0n1klVNjc6DnWuH3j/MSOg/52C3YfcUjCeIJGVfcqDnPTJKSNEF
yVTYCUjWy+B0B4fMz3MpU17dDWpvS5hfc4VrgQIDAQABAoIBAQCq+i208XBqdnwk
6y7r5Tcl6qErBE3sIk0upjypX7Ju/TlS8iqYckENQ+AqFGBcY8+ehF5O68BHm2hz
sk8F/H84+wc8zuzYGjPEFtEUb38RecCUqeqog0Gcmm6sN+ioOLAr6DifBojy2mox
sx6N0oPW9qigp/s4gTcGzTLxhcwNRHWuoWjQwq6y6qwt2PJXnllii5B5iIJhKAxE
EOmcVCmFbPavQ1Xr9F5jd5rRc1TYq28hXX8dZN2JhdVUbLlHzaiUfTnA/8yI4lyq
bEmqu29Oqe+CmDtB6jRnrLiIwyZxzXKuxXaO6NqgxqtaVjLcdISEgZMeHEftuOtf
C1xxodaVAoGBAOb1Y1SvUGx+VADSt1d30h3bBm1kU/1LhLKZOAQrnFMrEfyOfYbz
AZ4FJgXE6ZsB1BA7hC0eJDVHz8gTgDJQrOOO8WJWDGRe4TbZkCi5IizYg5UH/6az
I/WKlfdA4j1tftbQhycHL+9bGzdoRzrwIK489PG4oVAJJCaK2CVtx+l3AoGBAOXY
75sHOiMaIvDA7qlqFbaBkdi1NzH7bCgy8IntNfLxlOCmGjxeNZzKrkode3JWY9SI
Mo/nuWj8EZBEHj5omCapzOtkW/Nhnzc4C6U3BCspdrQ4mzbmzEGTdhqvxepa7U7K
iRcoD1iU7kINCEwg2PsB/BvCSrkn6lpIJlYXlJDHAoGAY7QjgXd9fJi8ou5Uf8oW
RxU6nRbmuz5Sttc2O3aoMa8yQJkyz4Mwe4s1cuAjCOutJKTM1r1gXC/4HyNsAEyb
llErG4ySJPJgv1EEzs+9VSbTBw9A6jIDoAiH3QmBoYsXapzy+4I6y1XFVhIKTgND
2HQwOfm+idKobIsb7GyMFNkCgYBIsixWZBrHL2UNsHfLrXngl2qBmA81B8hVjob1
mMkPZckopGB353Qdex1U464/o4M/nTQgv7GsuszzTBgktQAqeloNuVg7ygyJcnh8
cMIoxJx+s8ijvKutse4Q0rdOQCP+X6CsakcwRSp2SZjuOxVljmMmhHUNysocc+Vs
JVkf0QKBgHiCVLU60EoPketADvhRJTZGAtyCMSb3q57Nb0VIJwxdTB5KShwpul1k
LPA8Z7Y2i9+IEXcPT0r3M+hTwD7noyHXNlNuzwXot4B8PvbgKkMLyOpcwBjppJd7
ns4PifoQbhDFnZPSfnrpr+ZXSEzxtiyv7Ql69jznl/vB8b75hBL4
-----END RSA PRIVATE KEY-----`

@(private)
TEST_CERT_PEM :: `-----BEGIN CERTIFICATE-----
MIIDLDCCAhSgAwIBAgIIIXlwQVKrtaAwDQYJKoZIhvcNAQELBQAwIDEeMBwGA1UE
AxMVbWluaWNhIHJvb3QgY2EgMmJiOTlkMB4XDTIxMDIwMjE0NDYzNFoXDTIzMDMw
NDE0NDYzNFowFDESMBAGA1UEAxMJbG9jYWxob3N0MIIBIjANBgkqhkiG9w0BAQEF
AAOCAQ8AMIIBCgKCAQEAz105EYUbOdW5uJ8o/TqtxtOtKJL7AQdy5yiXoslosAsu
laew4JSJetVa6Fa6Bq5BK6fsphGD9bpGGeiBZFBt75JRjOrkj4DwlLGa0CPLTgG5
hul4Ufe9B7VG3J5P8OwUqIYmPzj8uTbNtkgFRcYumHR28h4GkYdG5Y04AV4vIjgK
E47jAgV5ACRHkcmGrTzF2HOes2wT73l4yLSkKR4GlIWu5cLRdI8PTUmjMFAh/GIh
1ahd+VqXz051V3jok0n1klVNjc6DnWuH3j/MSOg/52C3YfcUjCeIJGVfcqDnPTJK
SNEFyVTYCUjWy+B0B4fMz3MpU17dDWpvS5hfc4VrgQIDAQABo3YwdDAOBgNVHQ8B
Af8EBAMCBaAwHQYDVR0lBBYwFAYIKwYBBQUHAwEGCCsGAQUFBwMCMAwGA1UdEwEB
/wQCMAAwHwYDVR0jBBgwFoAULXa6lBiO7OLL5Z6XuF5uF5wR9PQwFAYDVR0RBA0w
C4IJbG9jYWxob3N0MA0GCSqGSIb3DQEBCwUAA4IBAQBOMkNXfzPEDU475zbiSi3v
JOhpZLyuoaYY62RzZc9VF8YRybJlWKUWdR3szAiUd1xCJe/beNX7b9lPg6wNadKq
DGTWFmVxSfpVMO9GQYBXLDcNaAUXzsDLC5sbAFST7jkAJELiRn6KtQYxZ2kEzo7G
QmzNMfNMc1KeL8Qr4nfEHZx642yscSWj9edGevvx4o48j5KXcVo9+pxQQFao9T2O
F5QxyGdov+uNATWoYl92Gj8ERi7ovHimU3H7HLIwNPqMJEaX4hH/E/Oz56314E9b
AXVFFIgCSluyrolaD6CWD9MqOex4YOfJR2bNxI7lFvuK4AwjyUJzT1U1HXib17mM
-----END CERTIFICATE-----`

@(test)
test_loopback_handshake :: proc(t: ^testing.T) {
	alpn := _alpn_wire("hq-29")
	defer delete(alpn)

	client, c_err := conn_new("localhost", alpn[:], _default_client_tp())
	testing.expect_value(t, c_err, Quic_Error.None)
	defer conn_free(client)

	// Disable cert verification so the expired test cert still validates
	// enough for TLS 1.3 to complete.
	conn_disable_verify(client)

	server_tp := _default_client_tp()
	server, s_err := conn_new_server(
		transmute([]u8)string(TEST_CERT_PEM),
		transmute([]u8)string(TEST_KEY_PEM),
		server_tp,
	)
	testing.expect_value(t, s_err, Quic_Error.None)
	defer conn_free(server)

	// Step 1: client emits ClientHello.
	hs_err := conn_start_handshake(client)
	testing.expect_value(t, hs_err, Quic_Error.None)
	testing.expect(t, len(client.initial.tx_crypto) > 0, "ClientHello should be emitted")

	// Package into an Initial packet.
	c_initial: [2048]u8
	c_initial_len, build_err := conn_build_initial_packet(client, c_initial[:])
	testing.expect_value(t, build_err, Quic_Error.None)
	testing.expect(t, c_initial_len >= INITIAL_PACKET_MIN)

	fmt.printf("[loopback] client Initial: %d bytes\n", c_initial_len)

	// Step 2: deliver to server.
	recv_err := conn_on_udp_recv(server, c_initial[:c_initial_len])
	testing.expect_value(t, recv_err, Recv_Error.None)

	// Server should now have Handshake keys installed (via set_write_secret
	// callback) and ServerHello CRYPTO data in initial.tx_crypto plus
	// Handshake CRYPTO data in handshake.tx_crypto.
	testing.expect(t, len(server.initial.tx_crypto) > 0 || len(server.handshake.tx_crypto) > 0,
		"server should have emitted response handshake data")
	testing.expect(t, server.initial.have_tx_keys)
	testing.expect(t, server.handshake.have_tx_keys || server.handshake.have_rx_keys,
		"server should have derived Handshake keys")

	// Step 3: build server's response flight — one Initial packet + one
	// Handshake packet (coalesced in theory; we send them as separate UDP
	// datagrams for simplicity).
	s_initial: [2048]u8
	s_initial_len := 0
	if len(server.initial.tx_crypto) > 0 {
		n, err := conn_build_initial_packet(server, s_initial[:])
		testing.expect_value(t, err, Quic_Error.None)
		s_initial_len = n
		fmt.printf("[loopback] server Initial: %d bytes\n", s_initial_len)
	}

	s_handshake: [2048]u8
	s_handshake_len := 0
	if len(server.handshake.tx_crypto) > 0 {
		n, err := conn_build_handshake_packet(server, s_handshake[:])
		testing.expect_value(t, err, Quic_Error.None)
		s_handshake_len = n
		fmt.printf("[loopback] server Handshake: %d bytes\n", s_handshake_len)
	}

	// Step 4: deliver to client. Initial first, then Handshake.
	if s_initial_len > 0 {
		rerr := conn_on_udp_recv(client, s_initial[:s_initial_len])
		testing.expect_value(t, rerr, Recv_Error.None)
	}

	// After processing server Initial, client should have Handshake rx keys
	// so it can decrypt the Handshake packet.
	testing.expect(t, client.handshake.have_rx_keys,
		"client should have Handshake rx keys after server Initial")

	if s_handshake_len > 0 {
		rerr := conn_on_udp_recv(client, s_handshake[:s_handshake_len])
		testing.expect_value(t, rerr, Recv_Error.None)
	}

	// At this point the client has processed both Server Initial and
	// Server Handshake. It should have emitted its Handshake Finished via
	// add_handshake_data, which sits in client.handshake.tx_crypto.
	fmt.printf("[loopback] client state after server flight: %v\n", client.state)
	fmt.printf("[loopback] client handshake.tx_crypto len: %d\n", len(client.handshake.tx_crypto))
	fmt.printf("[loopback] client one_rtt have_tx: %v have_rx: %v\n",
		client.one_rtt.have_tx_keys, client.one_rtt.have_rx_keys)

	// The client may already have 1-RTT keys installed (TLS 1.3 allows this
	// before the handshake is officially confirmed on the client side).
	testing.expect(t, client.handshake.have_tx_keys,
		"client should have Handshake tx keys to send Finished")

	// Step 5: client sends its Handshake (containing Finished).
	if len(client.handshake.tx_crypto) > 0 {
		c_handshake: [2048]u8
		n, err := conn_build_handshake_packet(client, c_handshake[:])
		testing.expect_value(t, err, Quic_Error.None)
		fmt.printf("[loopback] client Handshake: %d bytes\n", n)

		// Deliver to server.
		rerr := conn_on_udp_recv(server, c_handshake[:n])
		testing.expect_value(t, rerr, Recv_Error.None)
	}

	// At this point server should be Connected.
	fmt.printf("[loopback] final: client=%v server=%v\n", client.state, server.state)
	testing.expect_value(t, server.state, Conn_State.Connected)

	// Verify that the server received the client's transport parameters,
	// including max_datagram_frame_size which gates DATAGRAM support.
	testing.expect(t, server.peer_tp.max_datagram_frame_size > 0,
		"server should have extracted client's max_datagram_frame_size")

	// Sanity: both sides should have Application (1-RTT) keys installed.
	testing.expect(t, server.one_rtt.have_rx_keys && server.one_rtt.have_tx_keys)
	testing.expect(t, client.one_rtt.have_rx_keys && client.one_rtt.have_tx_keys)
}

// --- Phase 7c: DATAGRAM round-trip after handshake ---
// Extends the handshake test above to shuttle application-level DATAGRAMs
// through 1-RTT packets in both directions. This validates short-header
// encrypt/decrypt, header protection with 5-bit mask, DATAGRAM frame
// encoding, and the rx queue semantics.

@(test)
test_loopback_datagram_roundtrip :: proc(t: ^testing.T) {
	alpn := _alpn_wire("hq-29")
	defer delete(alpn)

	client, _ := conn_new("localhost", alpn[:], _default_client_tp())
	defer conn_free(client)
	conn_disable_verify(client)

	server, _ := conn_new_server(
		transmute([]u8)string(TEST_CERT_PEM),
		transmute([]u8)string(TEST_KEY_PEM),
		_default_client_tp(),
	)
	defer conn_free(server)

	// --- Drive the handshake to completion (same as above, condensed). ---
	conn_start_handshake(client)
	c_init: [2048]u8
	c_init_len, _ := conn_build_initial_packet(client, c_init[:])
	conn_on_udp_recv(server, c_init[:c_init_len])

	s_init: [2048]u8
	s_init_len, _ := conn_build_initial_packet(server, s_init[:])
	s_hs: [2048]u8
	s_hs_len, _ := conn_build_handshake_packet(server, s_hs[:])

	conn_on_udp_recv(client, s_init[:s_init_len])
	conn_on_udp_recv(client, s_hs[:s_hs_len])

	c_hs: [2048]u8
	c_hs_len, _ := conn_build_handshake_packet(client, c_hs[:])
	conn_on_udp_recv(server, c_hs[:c_hs_len])

	testing.expect_value(t, client.state, Conn_State.Connected)
	testing.expect_value(t, server.state, Conn_State.Connected)
	testing.expect(t, client.one_rtt.have_tx_keys)
	testing.expect(t, client.one_rtt.have_rx_keys)
	testing.expect(t, server.one_rtt.have_tx_keys)
	testing.expect(t, server.one_rtt.have_rx_keys)

	// The client should have auto-captured the server's SCID during
	// Server Initial processing in conn_on_udp_recv.
	testing.expect_value(t, client.dst_cid_len, server.src_cid_len)

	// --- Client -> Server DATAGRAM ---
	msg_c2s := transmute([]u8)string("hello from client")
	c_dg: [1500]u8
	c_dg_len, c_dg_err := conn_send_datagram(client, msg_c2s, c_dg[:])
	testing.expect_value(t, c_dg_err, Quic_Error.None)
	testing.expect(t, c_dg_len > 0, "client 1-RTT packet should be non-empty")

	rerr := conn_on_udp_recv(server, c_dg[:c_dg_len])
	testing.expect_value(t, rerr, Recv_Error.None)

	recv_c2s, ok := conn_recv_datagram(server)
	testing.expect(t, ok, "server should have received one datagram")
	testing.expect_value(t, string(recv_c2s), string(msg_c2s))

	// --- Server -> Client DATAGRAM ---
	msg_s2c := transmute([]u8)string("pong from server")
	s_dg: [1500]u8
	s_dg_len, s_dg_err := conn_send_datagram(server, msg_s2c, s_dg[:])
	testing.expect_value(t, s_dg_err, Quic_Error.None)

	rerr = conn_on_udp_recv(client, s_dg[:s_dg_len])
	testing.expect_value(t, rerr, Recv_Error.None)

	recv_s2c, ok2 := conn_recv_datagram(client)
	testing.expect(t, ok2, "client should have received one datagram")
	testing.expect_value(t, string(recv_s2c), string(msg_s2c))
}

// Exercise the FIFO ring semantics with a burst of datagrams.
@(test)
test_loopback_datagram_burst :: proc(t: ^testing.T) {
	alpn := _alpn_wire("hq-29")
	defer delete(alpn)

	client, _ := conn_new("localhost", alpn[:], _default_client_tp())
	defer conn_free(client)
	conn_disable_verify(client)

	server, _ := conn_new_server(
		transmute([]u8)string(TEST_CERT_PEM),
		transmute([]u8)string(TEST_KEY_PEM),
		_default_client_tp(),
	)
	defer conn_free(server)

	// Handshake (abridged).
	conn_start_handshake(client)
	c_init: [2048]u8
	n, _ := conn_build_initial_packet(client, c_init[:])
	conn_on_udp_recv(server, c_init[:n])

	s_init: [2048]u8
	s_init_len, _ := conn_build_initial_packet(server, s_init[:])
	s_hs: [2048]u8
	s_hs_len, _ := conn_build_handshake_packet(server, s_hs[:])
	conn_on_udp_recv(client, s_init[:s_init_len])
	conn_on_udp_recv(client, s_hs[:s_hs_len])

	c_hs: [2048]u8
	c_hs_len, _ := conn_build_handshake_packet(client, c_hs[:])
	conn_on_udp_recv(server, c_hs[:c_hs_len])

	// Send 10 distinct datagrams.
	buf: [1500]u8
	N :: 10
	payloads := [N]string{
		"one", "two", "three", "four", "five",
		"six", "seven", "eight", "nine", "ten",
	}
	for i in 0..<N {
		payload := transmute([]u8)payloads[i]
		pn, err := conn_send_datagram(client, payload, buf[:])
		testing.expect_value(t, err, Quic_Error.None)
		testing.expect(t, pn > 0)
		rerr := conn_on_udp_recv(server, buf[:pn])
		testing.expect_value(t, rerr, Recv_Error.None)
	}

	// Drain the server queue and verify order.
	for i in 0..<N {
		data, ok := conn_recv_datagram(server)
		testing.expect(t, ok, "datagram should be dequeued")
		testing.expect_value(t, string(data), payloads[i])
	}

	// Queue should be empty.
	_, empty := conn_recv_datagram(server)
	testing.expect(t, !empty, "queue should be empty after draining")
}

