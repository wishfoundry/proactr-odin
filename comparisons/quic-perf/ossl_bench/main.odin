// Product quic (OpenSSL dynlib)
package main

import q "../../../quic"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"

BACKEND :: "quic-ossl"
DCID :: [8]u8{0x83, 0x94, 0xc8, 0xf0, 0x3e, 0x51, 0x57, 0x08}

TEST_KEY_PEM :: `-----BEGIN PRIVATE KEY-----
MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgUCNjpovqzJh1UZL1
HAZAdhNZrs9impeU6oDez9I+RmahRANCAASGgBJDLd1oXz0TDUDIEC2BG1F3COjw
3vZkFEKBgKzSFTPWiN//MyZyzcQDuGqebjjYYQ2JTuUTRqW0+J5/0taL
-----END PRIVATE KEY-----`
TEST_CERT_PEM :: `-----BEGIN CERTIFICATE-----
MIIBfTCCASOgAwIBAgIUXIHQ3XQXZBa+GYprkbYpGT2BjbIwCgYIKoZIzj0EAwIw
FDESMBAGA1UEAwwJbG9jYWxob3N0MB4XDTI2MDgxMTAxMDM1OVoXDTM2MDgwODAx
MDM1OVowFDESMBAGA1UEAwwJbG9jYWxob3N0MFkwEwYHKoZIzj0CAQYIKoZIzj0D
AQcDQgAEhoASQy3daF89Ew1AyBAtgRtRdwjo8N72ZBRCgYCs0hUz1ojf/zMmcs3E
A7hqnm442GENiU7lE0altPief9LWi6NTMFEwHQYDVR0OBBYEFHc48MNC6/zE1M1s
WpS02P6OYAX7MB8GA1UdIwQYMBaAFHc48MNC6/zE1M1sWpS02P6OYAX7MA8GA1Ud
EwEB/wQFMAMBAf8wCgYIKoZIzj0EAwIDSAAwRQIhAOXHl0KdERYbbmQdm9ZUZi6A
iIwS0TZgiFl7TN5WEPx+AiAKREupgA3TGMOn91ZlEovng++B1xUG/7soTze10z3K
1w==
-----END CERTIFICATE-----`

main :: proc() {
	packet_iters := 30000
	hs_iters := 80
	warmup_p := 2000
	warmup_h := 10
	args := os.args[1:]
	for i := 0; i < len(args); i += 1 {
		a := args[i]
		if strings.has_prefix(a, "-packet-iters=") {
			if v, ok := strconv.parse_int(a[14:]); ok do packet_iters = v
		} else if strings.has_prefix(a, "-hs-iters=") {
			if v, ok := strconv.parse_int(a[10:]); ok do hs_iters = v
		} else if strings.has_prefix(a, "-warmup-packet=") {
			if v, ok := strconv.parse_int(a[15:]); ok do warmup_p = v
		} else if strings.has_prefix(a, "-warmup-hs=") {
			if v, ok := strconv.parse_int(a[11:]); ok do warmup_h = v
		}
	}
	fmt.printf("# backend=%s\n", BACKEND)
	fmt.printf("name\titers\ttotal_ns\tns_per_op\tok\tnotes\n")

	{
		keys: q.Initial_Keys
		dcid := DCID
		if !q.derive_initial_keys(&keys, dcid[:]) { emit("pure_aead_seal_1200", packet_iters, 0, false); return }
		plain := make([]u8, 1200); defer delete(plain)
		for i in 0..<1200 do plain[i] = u8(i)
		out := make([]u8, 1216); defer delete(out)
		nonce: [12]u8; aad: [16]u8
		for i in 0..<warmup_p { nonce[0]=u8(i); _,_ = q.aead_seal(&keys.client, out, nonce[:], plain, aad[:]) }
		t0 := time.tick_now()
		for i in 0..<packet_iters {
			nonce[0]=u8(i)
			if _, ok := q.aead_seal(&keys.client, out, nonce[:], plain, aad[:]); !ok { emit("pure_aead_seal_1200", packet_iters, 0, false); return }
		}
		emit("pure_aead_seal_1200", packet_iters, time.duration_nanoseconds(time.tick_since(t0)), true)
		nonce={}
		n, ok := q.aead_seal(&keys.client, out, nonce[:], plain, aad[:])
		if !ok { emit("pure_aead_open_1200", packet_iters, 0, false); return }
		pt := make([]u8, 1200); defer delete(pt)
		for _ in 0..<warmup_p { _,_ = q.aead_open(&keys.client, pt, nonce[:], out[:n], aad[:]) }
		t0 = time.tick_now()
		for _ in 0..<packet_iters {
			if _, ook := q.aead_open(&keys.client, pt, nonce[:], out[:n], aad[:]); !ook { emit("pure_aead_open_1200", packet_iters, 0, false); return }
		}
		emit("pure_aead_open_1200", packet_iters, time.duration_nanoseconds(time.tick_since(t0)), true)
	}
	{
		keys: q.Initial_Keys; dcid := DCID
		_ = q.derive_initial_keys(&keys, dcid[:])
		scid := [8]u8{1,2,3,4,5,6,7,8}; plain: [1000]u8; out: [2048]u8
		for i in 0..<1000 do plain[i]=u8(i)
		for i in 0..<warmup_p { _,_ = q.encrypt_initial(out[:], dcid[:], scid[:], nil, u64(i), 4, plain[:], &keys.client) }
		t0 := time.tick_now()
		for i in 0..<packet_iters {
			if _, ok := q.encrypt_initial(out[:], dcid[:], scid[:], nil, u64(i), 4, plain[:], &keys.client); !ok { emit("initial_seal", packet_iters, 0, false); return }
		}
		emit("initial_seal", packet_iters, time.duration_nanoseconds(time.tick_since(t0)), true)
	}
	{
		for _ in 0..<warmup_h { if !loopback_once() { emit("loopback_handshake", hs_iters, 0, false); return } }
		t0 := time.tick_now()
		for _ in 0..<hs_iters { if !loopback_once() { emit("loopback_handshake", hs_iters, 0, false); return } }
		emit("loopback_handshake", hs_iters, time.duration_nanoseconds(time.tick_since(t0)), true)
	}
}

emit :: proc(name: string, iters: int, total: i64, ok: bool) {
	ns := f64(total) / f64(iters) if iters > 0 else 0
	fmt.printf("%s\t%d\t%d\t%.1f\t%d\t-\n", name, iters, total, ns, 1 if ok else 0)
}

tp :: proc() -> q.Transport_Params {
	return q.Transport_Params{
		max_idle_timeout = 30_000,
		max_udp_payload_size = 1472,
		initial_max_data = 10 * 1024 * 1024,
		max_datagram_frame_size = 65527,
		disable_active_migration = true,
		ack_delay_exponent = 3,
		max_ack_delay = 25,
		active_connection_id_limit = 2,
	}
}

loopback_once :: proc() -> bool {
	alpn := [6]u8{5, 'h', 'q', '-', '2', '9'}
	client, cerr := q.conn_new("localhost", alpn[:], tp())
	if cerr != .None || client == nil do return false
	defer q.conn_free(client)
	q.conn_disable_verify(client)
	server, serr := q.conn_new_server(
		transmute([]u8)string(TEST_CERT_PEM),
		transmute([]u8)string(TEST_KEY_PEM),
		tp(),
	)
	if serr != .None || server == nil do return false
	defer q.conn_free(server)
	if q.conn_start_handshake(client) != .None do return false
	c_init: [4096]u8
	cn, e := q.conn_build_initial_packet(client, c_init[:])
	if e != .None do return false
	if q.conn_on_udp_recv(server, c_init[:cn]) != .None do return false
	s_init: [4096]u8
	sin := 0
	if len(server.initial.tx_crypto) > 0 {
		n, er := q.conn_build_initial_packet(server, s_init[:])
		if er != .None do return false
		sin = n
	}
	s_hs: [4096]u8
	shn := 0
	if len(server.handshake.tx_crypto) > 0 {
		n, er := q.conn_build_handshake_packet(server, s_hs[:])
		if er != .None do return false
		shn = n
	}
	if sin > 0 && q.conn_on_udp_recv(client, s_init[:sin]) != .None do return false
	if shn > 0 && q.conn_on_udp_recv(client, s_hs[:shn]) != .None do return false
	if len(client.handshake.tx_crypto) > 0 {
		c_hs: [4096]u8
		n, er := q.conn_build_handshake_packet(client, c_hs[:])
		if er != .None do return false
		if q.conn_on_udp_recv(server, c_hs[:n]) != .None do return false
	}
	return client.state == .Connected && server.state == .Connected
}

