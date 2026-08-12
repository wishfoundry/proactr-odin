// quic — QUIC transport (RFC 9000/9001).
// Mostly library core (frames, crypto, streams, loss). Conn may carry optional
package quic

import "base:runtime"
import "core:c"
import "core:net"
import "core:strings"
import "core:time"

// Connection state machine.
// Client/server QUIC connection lifecycle: OpenSSL setup, quic-tls callback
// wiring, and the handshake driver (CRYPTO FIFO + SSL_do_handshake).

Conn_State :: enum {
	Idle,
	Handshaking,
	Connected,
	Closing,
	Closed,
}

// Per-encryption-level crypto state.
Crypto_Level :: struct {
	have_rx_keys: bool,
	have_tx_keys: bool,
	rx_keys:      Packet_Keys,
	tx_keys:      Packet_Keys,

	// Outgoing CRYPTO frame buffer — OpenSSL crypto_send appends here via
	// the quic-tls callback; we drain it into packets on build_*.
	tx_crypto:        [dynamic]u8,
	tx_crypto_offset: u64, // running offset for CRYPTO frame headers

	// Everything sent at this level, kept for PTO retransmission ([0,
	// len) of the level's crypto stream). UDP gives no delivery guarantee:
	// lose the ClientHello or Finished and the handshake silently dies
	// without this. Freed via _crypto_level_discard once the level retires.
	flight:      [dynamic]u8,
	last_tx_at:  time.Time,
	pto_count:   u32, // backoff exponent; reset when the level makes progress

	// Incoming CRYPTO frame reassembly. Simplified: we assume in-order
	// delivery (true under no loss for TLS 1.3, which is what we target first).
	rx_crypto_offset: u64,
}

// Per-space packet number state (RFC 9000 §12.3).
Pn_Space :: struct {
	next_tx_pn:   u64,
	largest_rx_pn: u64,
	ack_elicited: bool,
	has_rx:       bool,

	// Received packet numbers as merged inclusive [start, end] ranges,
	// ascending. ACK frames must report everything we've received — acking
	// only `largest` makes a bursty peer treat the rest as lost and
	// retransmit forever. 16 ranges is plenty (1 when nothing is reordered);
	// overflow drops the oldest, which the peer has long stopped caring about.
	rx_ranges:      [16][2]u64,
	rx_range_count: int,
}

// `flight` mirrors the level's full sent crypto stream [0, len). On PTO the
// whole (small: ClientHello / Finished) flight is re-queued at offset 0 — far
// simpler than per-packet range tracking, and a duplicate CRYPTO range is
// harmless to the peer (§9 of RFC 9001: receivers reassemble by offset).

PTO_BASE :: 250 * time.Millisecond
PTO_MAX_RETRIES :: 6

// Record the suffix of `data` (about to go on the wire at the level's current
// offset) that the flight buffer doesn't hold yet. Retransmits re-send bytes
// already recorded and append nothing.
@(private)
_crypto_level_record_flight :: proc(lvl: ^Crypto_Level, data: []u8) {
	start := int(lvl.tx_crypto_offset)
	if start + len(data) > len(lvl.flight) {
		append(&lvl.flight, ..data[len(lvl.flight) - start:])
	}
	lvl.last_tx_at = time.now()
}

// Re-queue the level's full flight (plus anything still pending) for
// re-sending from offset 0.
@(private)
_crypto_level_requeue :: proc(lvl: ^Crypto_Level) {
	if len(lvl.flight) == 0 do return
	pending_len := len(lvl.tx_crypto)
	if pending_len > 0 {
		// tx_crypto holds the unsent tail [tx_crypto_offset, ...); flight
		// holds the sent head — concatenating restores the stream from 0.
		tail := make([]u8, pending_len, context.temp_allocator)
		copy(tail, lvl.tx_crypto[:])
		clear(&lvl.tx_crypto)
		append(&lvl.tx_crypto, ..lvl.flight[:])
		append(&lvl.tx_crypto, ..tail)
	} else {
		append(&lvl.tx_crypto, ..lvl.flight[:])
	}
	lvl.tx_crypto_offset = 0
}

// The level is confirmed delivered (or superseded) — drop retransmit state.
@(private)
_crypto_level_discard :: proc(lvl: ^Crypto_Level) {
	delete(lvl.flight)
	lvl.flight = nil
	lvl.pto_count = 0
}

// Re-queue any handshake-phase flight the peer has gone quiet on. Call from a
// pump/connect loop; returns true when something was re-queued (the caller's
// next send pass picks it up). Cheap no-op when nothing is owed.
conn_pto_check :: proc(conn: ^Conn) -> (retransmitted: bool) {
	now := time.now()

	// Initial retires once Handshake keys exist (the peer necessarily
	// processed our ClientHello to get there).
	if conn.handshake.have_rx_keys {
		if conn.initial.flight != nil do _crypto_level_discard(&conn.initial)
	} else if len(conn.initial.flight) > 0 && conn.initial.pto_count < PTO_MAX_RETRIES {
		if time.diff(conn.initial.last_tx_at, now) > PTO_BASE * time.Duration(1 << conn.initial.pto_count) {
			_crypto_level_requeue(&conn.initial)
			conn.initial.pto_count += 1
			retransmitted = true
		}
	}

	// Handshake retires on HANDSHAKE_DONE (client — proves Finished landed);
	// a server retires it on reaching Connected (the client's Finished only
	// exists because our flight got through).
	handshake_confirmed := conn.handshake_done_received || (conn.is_server && conn.state == .Connected)
	if handshake_confirmed {
		if conn.handshake.flight != nil do _crypto_level_discard(&conn.handshake)
	} else if len(conn.handshake.flight) > 0 && conn.handshake.pto_count < PTO_MAX_RETRIES {
		if time.diff(conn.handshake.last_tx_at, now) > PTO_BASE * time.Duration(1 << conn.handshake.pto_count) {
			_crypto_level_requeue(&conn.handshake)
			conn.handshake.pto_count += 1
			retransmitted = true
		}
	}
	return
}

// Merge `pn` into the space's received ranges (insert / extend / join).
@(private)
_pn_space_record_rx :: proc(s: ^Pn_Space, pn: u64) {
	n := s.rx_range_count
	i := 0
	for ; i < n; i += 1 {
		r := &s.rx_ranges[i]
		if pn + 1 < r[0] do break // strictly below this range, not adjacent
		if pn <= r[1] + 1 {       // contained, or extends this range either way
			if pn < r[0] do r[0] = pn
			if pn > r[1] do r[1] = pn
			// The extension may have bridged the gap to the next range.
			if i + 1 < n && s.rx_ranges[i + 1][0] <= r[1] + 1 {
				if s.rx_ranges[i + 1][1] > r[1] do r[1] = s.rx_ranges[i + 1][1]
				for j := i + 1; j + 1 < n; j += 1 do s.rx_ranges[j] = s.rx_ranges[j + 1]
				s.rx_range_count -= 1
			}
			return
		}
	}
	if n == len(s.rx_ranges) {
		if i == 0 do return // older than everything tracked — already ACKed eras
		for j := 0; j + 1 < n; j += 1 do s.rx_ranges[j] = s.rx_ranges[j + 1]
		n -= 1
		i -= 1
	}
	for j := n; j > i; j -= 1 do s.rx_ranges[j] = s.rx_ranges[j - 1]
	s.rx_ranges[i] = {pn, pn}
	s.rx_range_count = n + 1
}

// Opaque zenoh-rs-compatible connection.
Conn :: struct {
	// UDP transport.
	socket:        net.UDP_Socket,
	remote:        net.Endpoint,
	udp_connected: bool, // true after conn_udp_connect(); changes send path from sendto→send
	socket_owned:  bool, // true for client conns; false when an Endpoint multiplexes one socket across many Conns

	// Connection IDs.
	src_cid:     [20]u8,
	src_cid_len: int,
	dst_cid:     [20]u8, // peer's choice; for our first Initial we pick this too
	dst_cid_len: int,

	// TLS (OpenSSL SSL* / SSL_CTX* as rawptr via dynlib).
	tls:     rawptr,
	tls_ctx: rawptr,
	// When true, tls_ctx is process-shared — do not SSL_CTX_free on conn_free.
	tls_ctx_shared: bool,

	// OSSL_DISPATCH table must outlive SSL (pointer passed to set_quic_tls_cbs).
	quic_dispatch: [7]OSSL_DISPATCH,

	// Pull-model CRYPTO FIFO for OpenSSL crypto_recv_rcd / release_rcd.
	tls_fifo: Crypto_Fifo,

	// Current write encryption level for crypto_send (init = Initial).
	tx_level: Encryption_Level,

	// Local TP wire encoding owned on Conn (never stack into OpenSSL).
	local_tp_wire:     [512]u8,
	local_tp_wire_len: int,

	// Peer transport params received via got_transport_params callback.
	peer_tp_received: bool,

	// Pending CONNECTION_CLOSE to drain into outbound packets (C12).
	has_pending_close:         bool,
	pending_close_code:        u64,
	pending_close_reason:      [64]u8,
	pending_close_reason_len:  int,

	// Initial keys (derived once from the first-flight DCID).
	// CTXs are shared with initial.rx_keys / initial.tx_keys after install.
	initial_keys: Initial_Keys,

	// Per-level state.
	initial:   Crypto_Level,
	handshake: Crypto_Level,
	one_rtt:   Crypto_Level,

	// Packet number spaces.
	pn_initial:   Pn_Space,
	pn_handshake: Pn_Space,
	pn_one_rtt:   Pn_Space,

	// Local transport params we send to the peer.
	local_tp: Transport_Params,
	// Peer transport params received in TLS extension.
	peer_tp: Transport_Params,

	// Overall state.
	state:     Conn_State,
	is_server: bool,

	// Why the peer closed us (CONNECTION_CLOSE), for diagnostics.
	peer_close_code:       u64,
	peer_close_is_app:     bool,
	peer_close_reason:     [128]u8,
	peer_close_reason_len: int,

	// HANDSHAKE_DONE received (client): the Finished flight is confirmed
	// delivered and Handshake-level PTO retransmission can stop.
	handshake_done_received: bool,

	// Retry (client): the server's address-validation token, echoed in every
	// Initial we send after the Retry. At most one Retry is honored.
	retry_token:    [dynamic]u8,
	retry_received: bool,

	// Bounded FIFO of received DATAGRAM payloads. Each slot owns a copy
	// of the datagram bytes so the caller can consume them at its own pace.
	rx_datagrams:      [16][1500]u8,
	rx_datagram_lens:  [16]int,
	rx_datagrams_head: int, // next pop slot
	rx_datagrams_count: int,

	// Stream registry, keyed by 62-bit stream ID. In single-stream
	// (zenoh-mr) mode only id 0 (client-initiated bidi) is present. In
	// multi-stream modes (zenoh-ms / zenoh-ms-mr) id 0 is the control
	// stream and additional client/server-initiated unidirectional
	// streams get added on conn_open_uni / first inbound STREAM frame.
	streams: map[u64]^Stream,

	// ALPN protocol selected by the TLS handshake. Copied from OpenSSL
	// after HS completes. Empty if HS not done or no ALPN negotiated.
	alpn_negotiated:     [16]u8,
	alpn_negotiated_len: int,

	// Connection-level flow control (RFC 9000 §4.1).
	// tx side: peer's advertised MAX_DATA budget caps the total bytes we
	//   may send across all streams. tx_data_sent is the running sum.
	// rx side: rx_our_max_data is the cap we've advertised to the peer.
	//   rx_data_received is the running sum of bytes we've seen on all
	//   streams; when it crosses half the advertised limit we bump
	//   rx_our_max_data and emit a MAX_DATA frame.
	tx_peer_max_data:   u64,
	tx_data_sent:       u64,
	rx_our_max_data:    u64,
	rx_data_received:   u64,
	rx_max_data_pending: bool, // true when an outbound MAX_DATA update is owed

	// Next stream ID we'll assign when opening a locally-initiated
	// unidirectional stream. RFC 9000 §2.1 reserves the low bit pattern:
	// client-uni IDs are 4n+2, server-uni IDs are 4n+3. Initialized once
	// per role on first conn_open_uni call.
	next_local_uni_id: u64,
	next_local_uni_id_inited: bool,

	// Same, for locally-initiated bidirectional streams (HTTP/3 requests).
	// client-bidi IDs are 4n+0, server-bidi IDs are 4n+1.
	next_local_bidi_id: u64,
	next_local_bidi_id_inited: bool,

	// Inbound MAX_STREAMS bookkeeping. `rx_uni_count` is the running
	// total of peer-initiated uni streams we've seen so far; when it
	// crosses half of `rx_uni_max_advertised` we bump the advertised
	// limit and arm a MAX_STREAMS_UNI frame for the next packet.
	rx_uni_count:           u64,
	rx_uni_max_advertised:  u64,
	rx_max_streams_uni_pending: bool,

	stats: Conn_Stats,

	loss_sent:                 [dynamic]Sent_Packet, // 1-RTT packets we've sent, awaiting ACK
	loss_pto_deadline:         time.Time,             // next PTO expiry; zero value = disarmed
	loss_pto_factor:           int,                   // exponent on the base PTO (resets on any ACK)
	loss_last_ack_eliciting_at: time.Time,            // when the most recent ack-eliciting 1-RTT was sent

	cc: Congestion,

	// Zero value = use real wall-clock time.now(). Set to a non-zero time in
	// tests to drive loss_check_pto / PTO deterministically. No runtime cost
	// in production (the _now helper short-circuits when this is zero).
	clock: time.Time,

	// Odin context captured at conn_new / conn_new_server for C callbacks
	// (P-WOW-5). OpenSSL invokes quic-tls cbs without an Odin context.
	odin_ctx: runtime.Context,

	// Lightweight HS / drive counters (P-WOW-8).
	do_hs_calls:     u32,
	tls_drive_calls: u32,
}

// Server ALPN selector — picks the first protocol in the client's list.
// Wire format: [len][proto][len][proto]...  (length-prefixed byte strings)
@(private)
_server_alpn_select_cb :: proc "c" (
	s:       rawptr,
	out:     ^[^]u8,
	out_len: ^u8,
	in_data: [^]u8,
	in_len:  c.uint,
	arg:     rawptr,
) -> c.int {
	context = runtime.default_context()
	if in_len < 1 do return SSL_TLSEXT_ERR_NOACK
	first_len := in_data[0]
	if c.uint(first_len) + 1 > in_len do return SSL_TLSEXT_ERR_NOACK
	out^ = &in_data[1]
	out_len^ = first_len
	return SSL_TLSEXT_ERR_OK
}

@(private)
_conn_from_ssl :: proc(s: rawptr) -> ^Conn {
	if s == nil || !os_ensure() do return nil
	return cast(^Conn)g_os.SSL_get_app_data(s)
}

@(private)
_level_for :: proc(conn: ^Conn, level: Encryption_Level) -> ^Crypto_Level {
	switch level {
	case .Initial:     return &conn.initial
	case .Handshake:   return &conn.handshake
	case .Application: return &conn.one_rtt
	case .Early_Data:  return nil // 0-RTT off
	}
	return nil
}

// Queue a transport CONNECTION_CLOSE (type 0x1c) for the next outbound packet.
conn_queue_connection_close :: proc(conn: ^Conn, error_code: u64, reason: string) {
	if conn == nil do return
	conn.has_pending_close = true
	conn.pending_close_code = error_code
	n := min(len(reason), len(conn.pending_close_reason))
	copy(conn.pending_close_reason[:n], reason[:n])
	conn.pending_close_reason_len = n
	conn.state = .Closing
}

// Take (and clear) a pending close for encoding into a packet. Returns false if none.
conn_take_pending_close :: proc(conn: ^Conn) -> (code: u64, reason: []u8, ok: bool) {
	if conn == nil || !conn.has_pending_close do return 0, nil, false
	code = conn.pending_close_code
	reason = conn.pending_close_reason[:conn.pending_close_reason_len]
	conn.has_pending_close = false
	return code, reason, true
}


Quic_Error :: enum {
	None,
	SSL_Ctx_Failed,
	SSL_New_Failed,
	Set_Quic_Method_Failed,
	Set_Hostname_Failed,
	Set_Alpn_Failed,
	Set_Transport_Params_Failed,
	Handshake_Failed,
	Derive_Keys_Failed,
	Encrypt_Failed,
	No_Root_Store, // no system CA bundle found; use conn_disable_verify to opt out
}

SSL_FILETYPE_PEM :: 1

// Try the well-known system CA bundle locations. Returns true once any loads.
// Process-wide client SSL_CTX: lean TLS1.3 + system roots loaded once.
// Per-conn only SSL_new (major HS wall win vs reloading CA bundle every dial).
@(private)
g_client_ssl_ctx: rawptr
@(private)
g_client_ssl_ctx_ok: bool

@(private)
_client_ssl_ctx_get :: proc() -> (ctx: rawptr, err: Quic_Error) {
	if g_client_ssl_ctx_ok && g_client_ssl_ctx != nil {
		return g_client_ssl_ctx, .None
	}
	if !os_ensure() do return nil, .SSL_Ctx_Failed
	ctx = g_os.SSL_CTX_new(g_os.TLS_client_method())
	if ctx == nil do return nil, .SSL_Ctx_Failed
	SSL_CTX_set_min_proto_version(ctx, TLS1_3_VERSION)
	SSL_CTX_set_max_proto_version(ctx, TLS1_3_VERSION)
	ssl_ctx_apply_lean_tls13(ctx)
	if !load_system_roots(ctx) {
		g_os.SSL_CTX_free(ctx)
		return nil, .No_Root_Store
	}
	g_client_ssl_ctx = ctx
	g_client_ssl_ctx_ok = true
	return ctx, .None
}

load_system_roots :: proc(ctx: rawptr) -> bool {
	if !os_ensure() || ctx == nil do return false
	CANDIDATES :: [?]cstring{
		"/etc/ssl/cert.pem",                  // macOS / BSD
		"/etc/ssl/certs/ca-certificates.crt", // Debian / Ubuntu / Alpine
		"/etc/pki/tls/certs/ca-bundle.crt",   // Fedora / RHEL
		"/etc/ssl/ca-bundle.pem",             // openSUSE
	}
	for path in CANDIDATES {
		if g_os.SSL_CTX_load_verify_locations(ctx, path, nil) == 1 do return true
	}
	return false
}

// Disable peer certificate verification. Only for test / loopback use —
// never invoke this on a production client.
conn_disable_verify :: proc(conn: ^Conn) {
	if !os_ensure() || conn == nil do return
	// Per-SSL: conn.tls copied the CTX's verify mode at SSL_new, so the
	// CTX-level call alone would not affect this connection.
	g_os.SSL_set_verify(conn.tls, SSL_VERIFY_NONE, nil)
	if g_os.SSL_CTX_set_verify != nil {
		g_os.SSL_CTX_set_verify(conn.tls_ctx, SSL_VERIFY_NONE, nil)
	}
}

// Load the CA certificate for verifying the peer's cert chain.
conn_load_verify_locations :: proc(conn: ^Conn, ca_file: string) -> bool {
	if !os_ensure() || conn == nil do return false
	ca := strings.clone_to_cstring(ca_file, context.temp_allocator)
	return g_os.SSL_CTX_load_verify_locations(conn.tls_ctx, ca, nil) == 1
}

// Load our own client certificate + private key for mTLS. Uses the SSL
// object (not the CTX) because conn_new already called SSL_new — and
// SSL_new snapshots the CTX, so later CTX modifications are invisible
// to the SSL object.
conn_load_client_cert :: proc(conn: ^Conn, cert_file: string, key_file: string) -> bool {
	if !os_ensure() || conn == nil do return false
	if g_os.SSL_use_certificate_file == nil || g_os.SSL_use_PrivateKey_file == nil do return false
	cert_c := strings.clone_to_cstring(cert_file, context.temp_allocator)
	key_c := strings.clone_to_cstring(key_file, context.temp_allocator)
	if g_os.SSL_use_certificate_file(conn.tls, cert_c, SSL_FILETYPE_PEM) != 1 do return false
	if g_os.SSL_use_PrivateKey_file(conn.tls, key_c, SSL_FILETYPE_PEM) != 1 do return false
	if g_os.SSL_check_private_key != nil {
		return g_os.SSL_check_private_key(conn.tls) == 1
	}
	return true
}

// Allocate and initialize a new Conn. Creates OpenSSL SSL_CTX/SSL objects,
// installs quic-tls callbacks, and derives Initial keys from a fresh random
// DCID. Caller must eventually call conn_free.
conn_new :: proc(
	server_name: string,
	alpn:        []u8, // wire-format ALPN list (1-byte length prefix per protocol)
	local_tp:    Transport_Params,
	allocator := context.allocator,
) -> (conn: ^Conn, err: Quic_Error) {
	if !os_ensure() {
		return nil, .SSL_Ctx_Failed
	}

	conn = new(Conn, allocator)
	conn.odin_ctx = context
	conn.state = .Idle
	conn.local_tp = local_tp
	conn.tx_level = .Initial
	// Advertised inbound connection-level limit — caller's TP is what we
	// promised on the wire, so honor that here too.
	conn.rx_our_max_data       = local_tp.initial_max_data
	conn.rx_uni_max_advertised = local_tp.initial_max_streams_uni

	// Shared client SSL_CTX (roots + lean TLS1.3 once per process).
	shared_ctx, cerr := _client_ssl_ctx_get()
	if cerr != .None {
		free(conn, allocator)
		return nil, cerr
	}
	conn.tls_ctx = shared_ctx
	conn.tls_ctx_shared = true

	conn.tls = g_os.SSL_new(conn.tls_ctx)
	if conn.tls == nil {
		// Do not free shared CTX.
		conn.tls_ctx = nil
		free(conn, allocator)
		return nil, .SSL_New_Failed
	}

	// Wire up callback -> Conn linkage (app_data + dispatch arg).
	_ = g_os.SSL_set_app_data(conn.tls, rawptr(conn))

	if !configure_quic_tls(conn, conn.tls) {
		_conn_destroy_ssl(conn)
		free(conn, allocator)
		return nil, .Set_Quic_Method_Failed
	}

	// 0-RTT off (C2).
	_ = g_os.SSL_set_quic_tls_early_data_enabled(conn.tls, 0)

	g_os.SSL_set_connect_state(conn.tls)

	// SNI — required by real-world servers. OpenSSL copies the name
	// internally, so the temp cstring is fine. Skip IP literals (RFC 6066 §3).
	is_hostname := len(server_name) > 0 && net.parse_address(server_name) == nil
	if is_hostname {
		sn := strings.clone_to_cstring(server_name, context.temp_allocator)
		if SSL_set_tlsext_host_name(conn.tls, sn) != 1 {
			_conn_destroy_ssl(conn)
			free(conn, allocator)
			return nil, .SSL_New_Failed
		}
	}

	// Certificate verification — ON by default for clients (roots on shared CTX).
	g_os.SSL_set_verify(conn.tls, SSL_VERIFY_PEER, nil)
	if is_hostname && g_os.SSL_set1_host != nil {
		sn := strings.clone_to_cstring(server_name, context.temp_allocator)
		if g_os.SSL_set1_host(conn.tls, sn) != 1 {
			_conn_destroy_ssl(conn)
			free(conn, allocator)
			return nil, .SSL_New_Failed
		}
	}

	// ALPN (OpenSSL returns 0 on success — historical quirk).
	if len(alpn) > 0 {
		if g_os.SSL_set_alpn_protos(conn.tls, raw_data(alpn), c.uint(len(alpn))) != 0 {
			_conn_destroy_ssl(conn)
			free(conn, allocator)
			return nil, .Set_Alpn_Failed
		}
	}

	// Connection IDs.
	rand_bytes(conn.src_cid[:8])
	conn.src_cid_len = 8
	rand_bytes(conn.dst_cid[:8])
	conn.dst_cid_len = 8

	// Advertise initial_source_cid in our transport params — required for
	// clients per RFC 9000 §18.2.
	conn.local_tp.initial_source_cid = conn.src_cid[:conn.src_cid_len]

	// Encode into Conn-owned buffer (C5) and attach.
	tp_len := transport_params_encode(conn.local_tp_wire[:], &conn.local_tp)
	if tp_len < 0 {
		_conn_destroy_ssl(conn)
		free(conn, allocator)
		return nil, .Set_Transport_Params_Failed
	}
	conn.local_tp_wire_len = tp_len
	if g_os.SSL_set_quic_tls_transport_params(conn.tls, &conn.local_tp_wire[0], c.size_t(tp_len)) != 1 {
		_conn_destroy_ssl(conn)
		free(conn, allocator)
		return nil, .Set_Transport_Params_Failed
	}

	// Derive Initial keys from our chosen DCID (§5.2).
	if !derive_initial_keys(&conn.initial_keys, conn.dst_cid[:conn.dst_cid_len]) {
		_conn_destroy_ssl(conn)
		free(conn, allocator)
		return nil, .Derive_Keys_Failed
	}
	// Both directions' Initial keys are known up-front (share CTXs with level).
	conn.initial.rx_keys = conn.initial_keys.server
	conn.initial.tx_keys = conn.initial_keys.client
	conn.initial.have_rx_keys = true
	conn.initial.have_tx_keys = true

	// Pre-size CRYPTO send buffers so mid-HS appends don't reallocate (P-WOW-4).
	_conn_reserve_tx_crypto(conn)

	return conn, .None
}

// Server-side variant used by the loopback test. Creates an SSL_CTX in
// TLS 1.3 server mode configured with a PEM-encoded cert and private key,
// then installs quic-tls callbacks. The Initial keys are derived later, once
// we see the client's DCID in the first received packet.
conn_new_server :: proc(
	cert_pem: []u8,
	key_pem:  []u8,
	local_tp: Transport_Params,
	allocator := context.allocator,
) -> (conn: ^Conn, err: Quic_Error) {
	if !os_ensure() {
		return nil, .SSL_Ctx_Failed
	}

	conn = new(Conn, allocator)
	conn.odin_ctx = context
	conn.state = .Idle
	conn.local_tp = local_tp
	conn.tx_level = .Initial
	// Advertised inbound connection-level limit — caller's TP is what we
	// promised on the wire, so honor that here too.
	conn.rx_our_max_data       = local_tp.initial_max_data
	conn.rx_uni_max_advertised = local_tp.initial_max_streams_uni

	// Cache server SSL_CTX by PEM content (loopback/HS benches reuse same PEMs).
	srv_ctx, shared := _server_ssl_ctx_get(cert_pem, key_pem)
	if srv_ctx == nil {
		free(conn, allocator)
		return nil, .SSL_Ctx_Failed
	}
	conn.tls_ctx = srv_ctx
	conn.tls_ctx_shared = shared

	conn.tls = g_os.SSL_new(conn.tls_ctx)
	if conn.tls == nil {
		if !shared do g_os.SSL_CTX_free(conn.tls_ctx)
		conn.tls_ctx = nil
		free(conn, allocator)
		return nil, .SSL_New_Failed
	}

	_ = g_os.SSL_set_app_data(conn.tls, rawptr(conn))

	if !configure_quic_tls(conn, conn.tls) {
		_conn_destroy_ssl(conn)
		free(conn, allocator)
		return nil, .Set_Quic_Method_Failed
	}

	_ = g_os.SSL_set_quic_tls_early_data_enabled(conn.tls, 0)

	g_os.SSL_set_accept_state(conn.tls)
	conn.is_server = true

	rand_bytes(conn.src_cid[:8])
	conn.src_cid_len = 8
	conn.local_tp.initial_source_cid = conn.src_cid[:conn.src_cid_len]

	tp_len := transport_params_encode(conn.local_tp_wire[:], &conn.local_tp)
	if tp_len < 0 {
		_conn_destroy_ssl(conn)
		free(conn, allocator)
		return nil, .Set_Transport_Params_Failed
	}
	conn.local_tp_wire_len = tp_len
	if g_os.SSL_set_quic_tls_transport_params(conn.tls, &conn.local_tp_wire[0], c.size_t(tp_len)) != 1 {
		_conn_destroy_ssl(conn)
		free(conn, allocator)
		return nil, .Set_Transport_Params_Failed
	}

	// Pre-size CRYPTO send buffers so mid-HS appends don't reallocate (P-WOW-4).
	_conn_reserve_tx_crypto(conn)

	return conn, .None
}

@(private)
_conn_reserve_tx_crypto :: proc(conn: ^Conn) {
	if conn == nil do return
	reserve(&conn.initial.tx_crypto, 16384)
	reserve(&conn.handshake.tx_crypto, 16384)
	reserve(&conn.one_rtt.tx_crypto, 16384)
}

// Install the client's chosen DCID as the server's Initial key derivation
// source. Called after parsing the first received Initial packet.
conn_server_install_dcid :: proc(conn: ^Conn, client_dcid: []u8) -> bool {
	if len(client_dcid) == 0 || len(client_dcid) > 20 do return false
	copy(conn.dst_cid[:], client_dcid)
	conn.dst_cid_len = len(client_dcid)

	if !derive_initial_keys(&conn.initial_keys, client_dcid) do return false
	// Server's RX uses client_initial; TX uses server_initial.
	conn.initial.rx_keys = conn.initial_keys.client
	conn.initial.tx_keys = conn.initial_keys.server
	conn.initial.have_rx_keys = true
	conn.initial.have_tx_keys = true
	return true
}

// One-slot server CTX cache for identical PEM pairs (tests / single-cert hosts).
@(private)
g_server_ssl_ctx:      rawptr
@(private)
g_server_ssl_ctx_fp:   u64

@(private)
_pem_fp :: proc(cert_pem, key_pem: []u8) -> u64 {
	h: u64 = 14695981039346656037 // FNV offset
	for b in cert_pem {
		h ~= u64(b)
		h *= 1099511628211
	}
	h ~= u64(len(key_pem))
	for b in key_pem {
		h ~= u64(b)
		h *= 1099511628211
	}
	return h
}

@(private)
_server_ssl_ctx_get :: proc(cert_pem, key_pem: []u8) -> (ctx: rawptr, shared: bool) {
	if !os_ensure() do return nil, false
	fp := _pem_fp(cert_pem, key_pem)
	if g_server_ssl_ctx != nil && g_server_ssl_ctx_fp == fp {
		return g_server_ssl_ctx, true
	}
	ctx = g_os.SSL_CTX_new(g_os.TLS_server_method())
	if ctx == nil do return nil, false
	SSL_CTX_set_min_proto_version(ctx, TLS1_3_VERSION)
	SSL_CTX_set_max_proto_version(ctx, TLS1_3_VERSION)
	ssl_ctx_apply_lean_tls13(ctx)
	g_os.SSL_CTX_set_alpn_select_cb(ctx, rawptr(_server_alpn_select_cb), nil)
	if !_load_cert_from_pem(ctx, cert_pem) || !_load_key_from_pem(ctx, key_pem) {
		g_os.SSL_CTX_free(ctx)
		return nil, false
	}
	// Replace cache.
	if g_server_ssl_ctx != nil {
		g_os.SSL_CTX_free(g_server_ssl_ctx)
	}
	g_server_ssl_ctx = ctx
	g_server_ssl_ctx_fp = fp
	return ctx, true
}

@(private)
_load_cert_from_pem :: proc(ctx: rawptr, pem: []u8) -> bool {
	if !os_ensure() || ctx == nil do return false
	bio := g_os.BIO_new_mem_buf(raw_data(pem), c.int(len(pem)))
	if bio == nil do return false
	defer g_os.BIO_free(bio)

	cert := g_os.PEM_read_bio_X509(bio, nil, nil, nil)
	if cert == nil do return false
	defer g_os.X509_free(cert)

	return g_os.SSL_CTX_use_certificate(ctx, cert) == 1
}

@(private)
_load_key_from_pem :: proc(ctx: rawptr, pem: []u8) -> bool {
	if !os_ensure() || ctx == nil do return false
	bio := g_os.BIO_new_mem_buf(raw_data(pem), c.int(len(pem)))
	if bio == nil do return false
	defer g_os.BIO_free(bio)

	pkey := g_os.PEM_read_bio_PrivateKey(bio, nil, nil, nil)
	if pkey == nil do return false
	defer g_os.EVP_PKEY_free(pkey)

	return g_os.SSL_CTX_use_PrivateKey(ctx, pkey) == 1
}

conn_free :: proc(conn: ^Conn, allocator := context.allocator) {
	if conn == nil do return
	_conn_destroy_ssl(conn)
	delete(conn.initial.tx_crypto)
	delete(conn.handshake.tx_crypto)
	delete(conn.one_rtt.tx_crypto)
	delete(conn.initial.flight)
	delete(conn.handshake.flight)
	delete(conn.one_rtt.flight)
	delete(conn.retry_token)
	for pkt in conn.loss_sent {
		delete(pkt.stream_ranges)
	}
	delete(conn.loss_sent)
	for _, s in conn.streams {
		stream_free(s, allocator)
	}
	delete(conn.streams)
	free(conn, allocator)
}

// Free order (C4 / §4.2): null app_data → SSL_free → FIFO → Packet_Keys CTXs.
@(private)
_conn_destroy_ssl :: proc(conn: ^Conn) {
	if !os_ensure() {
		conn.tls = nil
		conn.tls_ctx = nil
		return
	}
	if conn.tls != nil {
		// Disconnect Conn from SSL so late release_rcd is a no-op.
		_ = g_os.SSL_set_app_data(conn.tls, nil)
		g_os.SSL_free(conn.tls)
		conn.tls = nil
	}
	if conn.tls_ctx != nil {
		if !conn.tls_ctx_shared {
			g_os.SSL_CTX_free(conn.tls_ctx)
		}
		conn.tls_ctx = nil
		conn.tls_ctx_shared = false
	}
	crypto_fifo_free(&conn.tls_fifo)
	_conn_clear_packet_keys(conn)
}

// Free long-lived AEAD/HP CTXs. initial_keys shares CTXs with initial level
// after install — free level keys first, then zero initial_keys without free.
@(private)
_conn_clear_packet_keys :: proc(conn: ^Conn) {
	packet_keys_clear_crypto(&conn.initial.rx_keys)
	packet_keys_clear_crypto(&conn.initial.tx_keys)
	packet_keys_clear_crypto(&conn.handshake.rx_keys)
	packet_keys_clear_crypto(&conn.handshake.tx_keys)
	packet_keys_clear_crypto(&conn.one_rtt.rx_keys)
	packet_keys_clear_crypto(&conn.one_rtt.tx_keys)
	// Shared with initial level — pointers already freed; wipe only.
	conn.initial_keys = {}
}

// Start the handshake. Invokes SSL_do_handshake via tls_drive with an empty
// FIFO; crypto_send emits ClientHello into Initial tx_crypto.
// Call conn_build_initial_packet to turn pending CRYPTO into a wire packet.
conn_start_handshake :: proc(conn: ^Conn) -> Quic_Error {
	if conn.state != .Idle do return .Handshake_Failed
	conn.state = .Handshaking
	conn.tx_level = .Initial

	if !tls_drive(conn) {
		return .Handshake_Failed
	}
	return .None
}

// Build an Initial packet from whatever CRYPTO data is pending in conn.initial.tx_crypto.
// The packet is padded with PADDING frames so that the UDP datagram reaches
// the RFC 9000 §14.1 minimum of 1200 bytes. Returns bytes written to `out`.
// After this call, conn.initial.tx_crypto is cleared (bytes are "in flight").
// A full implementation would keep them buffered for PTO retransmit; phase 7a
// skips that for the single-packet happy path.
conn_build_initial_packet :: proc(conn: ^Conn, out: []u8) -> (n: int, err: Quic_Error) {
	if !conn.initial.have_tx_keys do return 0, .Derive_Keys_Failed

	// ACK-only packets matter here: until the client ACKs, the server is
	// amplification-limited (§8.1, 3× received bytes) and a multi-datagram
	// first flight (real-world cert chains) stalls without them.
	send_ack := conn.pn_initial.ack_elicited && conn.pn_initial.has_rx
	send_close := conn.has_pending_close
	if len(conn.initial.tx_crypto) == 0 && !send_ack && !send_close do return 0, .None

	// Build the plaintext payload: [ACK] + CRYPTO + [CONNECTION_CLOSE] + PADDING.
	// OpenSSL ClientHello + TPs can exceed 1200 B; use a larger slab and pad
	// client packets so the UDP datagram still meets §14.1.
	INITIAL_PLAINTEXT_MAX :: 4096
	plaintext: [INITIAL_PLAINTEXT_MAX]u8
	pos := 0

	if send_ack {
		w := encode_ack_from_space(plaintext[pos:], &conn.pn_initial, 0)
		if w < 0 do return 0, .Encrypt_Failed
		pos += w
		conn.pn_initial.ack_elicited = false
	}

	// CRYPTO frame with everything pending in tx_crypto.
	// Cap to remaining room; leftover stays in tx_crypto for the next packet.
	crypto_data := conn.initial.tx_crypto[:]
	crypto_sent := 0
	if len(crypto_data) > 0 {
		// Frame header worst-case ~1+8+8; leave room for optional close.
		room := INITIAL_PLAINTEXT_MAX - pos - 64
		if room < 1 do return 0, .Encrypt_Failed
		chunk := crypto_data
		if len(chunk) > room do chunk = chunk[:room]
		w := encode_crypto(plaintext[pos:], conn.initial.tx_crypto_offset, chunk)
		if w < 0 do return 0, .Encrypt_Failed
		pos += w
		_crypto_level_record_flight(&conn.initial, chunk)
		conn.initial.tx_crypto_offset += u64(len(chunk))
		crypto_sent = len(chunk)
	}

	// Drain pending TLS/transport CONNECTION_CLOSE (C12).
	if code, reason, ok_close := conn_take_pending_close(conn); ok_close {
		w := encode_connection_close(plaintext[pos:], code, 0, reason)
		if w < 0 do return 0, .Encrypt_Failed
		pos += w
	}

	// Client Initial: pad plaintext so the sealed packet is ≥ 1200 (§14.1).
	// PADDING frames are 0x00 — buffer already zeroed past `pos`.
	pt_len := pos
	if !conn.is_server && pt_len < INITIAL_PACKET_MIN {
		pt_len = INITIAL_PACKET_MIN
	}
	if pt_len == 0 do pt_len = pos
	if pt_len > INITIAL_PLAINTEXT_MAX do return 0, .Encrypt_Failed
	plaintext_view := plaintext[:pt_len]

	// Pick a packet number and encode/encrypt.
	pn := conn.pn_initial.next_tx_pn
	conn.pn_initial.next_tx_pn += 1

	packet_len, ok := encrypt_initial(
		out,
		conn.dst_cid[:conn.dst_cid_len],
		conn.src_cid[:conn.src_cid_len],
		conn.retry_token[:], // empty until a Retry supplies one
		pn,
		4, // pn_len — 4 bytes for deterministic header size
		plaintext_view,
		&conn.initial.tx_keys,
	)
	if !ok do return 0, .Encrypt_Failed

	// Consume the CRYPTO bytes we sent; leave any overflow for next packet.
	if crypto_sent > 0 {
		if crypto_sent >= len(conn.initial.tx_crypto) {
			clear(&conn.initial.tx_crypto)
		} else {
			copy(conn.initial.tx_crypto[:], conn.initial.tx_crypto[crypto_sent:])
			resize(&conn.initial.tx_crypto, len(conn.initial.tx_crypto) - crypto_sent)
		}
	}

	return packet_len, .None
}
