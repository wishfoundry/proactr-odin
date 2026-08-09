// PR5 host: real mem-BIO TLS on proactr accept/recv/send path.
//
// Opaque SSL only (tls_server.Conn) — no SSL* leaves this module into handlers.
// Product I/O: rBIO fed by recv CT; wBIO drained to host_submit_send CT.
// Clear-H1 paths are unchanged when Server.tls_provider/tls_ctx are nil.
//
// Handshake: conn.tls_pipe.state = Handshake until SSL_accept OK → Open +
// connection_enable_ciphered (lightweight: plan_policy only; no seal_q/CT[2]).
// Response send (ciphered oneshot): windowed SSL_write + CT drain across CQEs
// (tls_plain_rest cursor). Progressive Stream / SSE / WS: tls_host_stream_try_submit +
// stream_sent / tls_stream_plain_n (same wire engine as clear; no plain-send bypass).
// Live dual-CT seal∥send (PR5.1): while one CT sock send is in flight, seal the next
// plain window into tls_ct_hold (second slab) so CQE can submit without re-encrypting
// from scratch. Pure pipe Seal_SM remains the formal model; this is the live path.
package http

import "core:c"
import "core:log"
import "core:mem/virtual"
import "core:net"
import "core:sync"

import proactr "../proactr"
import tls_server "../tls_server"

// ---------------------------------------------------------------------------
// Server TLS context lifecycle
// ---------------------------------------------------------------------------

// server_tls_init loads default OpenSSL provider + shared SSL_CTX from PEMs.
// Returns false if provider missing, ctx/PEM fail — caller must clear PEMs / stay clear-H1.
@(private)
server_tls_init :: proc(s: ^Server) -> bool {
	if s == nil {
		return false
	}
	if len(s.opts.tls_cert_pem) == 0 || len(s.opts.tls_key_pem) == 0 {
		return false
	}
	// Already live (idempotent listen retry).
	if s.tls_provider != nil && s.tls_ctx != nil {
		return true
	}

	p := tls_server.default_provider()
	if p == nil {
		log.error("TLS PEMs set but OpenSSL dynlib provider failed to load — TLS off, clear-H1 only")
		return false
	}

	ctx := tls_server.ctx_new(p)
	if ctx == nil {
		log.error("TLS: SSL_CTX_new failed — TLS off, clear-H1 only")
		return false
	}
	if !tls_server.ctx_load_pem(p, ctx, s.opts.tls_cert_pem, s.opts.tls_key_pem) {
		log.error("TLS: cert/key PEM load failed — TLS off, clear-H1 only")
		tls_server.ctx_free(p, ctx)
		return false
	}
	// ALPN: prefer h2, fallback http/1.1 (engineering dual-stack; not product H2 framing).
	tls_server.ctx_set_alpn_select_cb(p, ctx, tls_server.alpn_select_h2_or_http11, nil)

	s.tls_provider = p
	s.tls_ctx = ctx
	log.infof("TLS: shared SSL_CTX ready (provider=%s, ALPN h2|http/1.1)", p.name)
	return true
}

// server_tls_destroy frees shared SSL_CTX. Does not unload process default provider.
@(private)
server_tls_destroy :: proc(s: ^Server) {
	if s == nil {
		return
	}
	if s.tls_provider != nil && s.tls_ctx != nil {
		tls_server.ctx_free(s.tls_provider, s.tls_ctx)
	}
	s.tls_ctx = nil
	// Provider may be process-global default_provider(); do not destroy here.
	s.tls_provider = nil
}

// server_tls_wanted reports whether opts requested TLS (PEMs present).
@(private)
server_tls_wanted :: proc(s: ^Server) -> bool {
	return s != nil && len(s.opts.tls_cert_pem) > 0 && len(s.opts.tls_key_pem) > 0
}

// server_tls_live reports whether accept path should create per-conn SSL.
@(private)
server_tls_live :: proc(s: ^Server) -> bool {
	return s != nil && s.tls_provider != nil && s.tls_ctx != nil
}

// ---------------------------------------------------------------------------
// Per-connection TLS setup / teardown
// ---------------------------------------------------------------------------

// TLS_CT_RX_DEFAULT / TX: network ciphertext windows (not app-visible).
TLS_CT_RX_DEFAULT :: 16 * 1024
TLS_CT_TX_DEFAULT :: CT_SLAB_SIZE // one pull window of CT room

// tls_host_on_accept: after conn_alloc + nonblocking fd. Creates SSL + mem-BIOs.
// On success: tls_pipe = Handshake; does NOT enable ciphered yet.
// Caller must arm CT recv (tls_host_arm_recv) and must NOT start clear parse yet.
@(private)
tls_host_on_accept :: proc(conn: ^Connection) -> bool {
	if conn == nil || conn.server == nil {
		return false
	}
	s := conn.server
	if !server_tls_live(s) {
		return false
	}
	p := s.tls_provider
	ssl := tls_server.conn_new(p, s.tls_ctx)
	if ssl == nil {
		log.errorf("TLS: SSL_new failed fd=%v", conn.socket)
		return false
	}
	if !tls_server.setup_mem_bios(p, ssl) {
		log.errorf("TLS: setup_mem_bios failed fd=%v", conn.socket)
		tls_server.conn_free(p, ssl)
		return false
	}
	// Accepting server; partial write for windowed response seal.
	_ = tls_server.set_mode(
		p,
		ssl,
		tls_server.SSL_MODE_ENABLE_PARTIAL_WRITE | tls_server.SSL_MODE_ACCEPT_MOVING_WRITE_BUFFER,
	)
	tls_server.set_accept_state(p, ssl)

	// CT I/O scratch (conn_allocator; freed on destroy).
	rx_n := s.opts.recv_buf_size
	if rx_n <= 0 {
		rx_n = TLS_CT_RX_DEFAULT
	}
	alloc := s.conn_allocator
	rx, rerr := make([]u8, rx_n, alloc)
	if rerr != nil || rx == nil {
		tls_server.conn_free(p, ssl)
		return false
	}
	tx, terr := make([]u8, TLS_CT_TX_DEFAULT, alloc)
	if terr != nil || tx == nil {
		delete(rx, alloc)
		tls_server.conn_free(p, ssl)
		return false
	}
	// Second CT slab for seal∥send (hold next encrypt while primary sends).
	hold, herr := make([]u8, TLS_CT_TX_DEFAULT, alloc)
	if herr != nil || hold == nil {
		delete(rx, alloc)
		delete(tx, alloc)
		tls_server.conn_free(p, ssl)
		return false
	}

	conn.tls_ssl = ssl
	conn.tls_ct_rx = rx
	conn.tls_ct_tx = tx
	conn.tls_ct_hold = hold
	conn.tls_ct_tx_ready_n = 0
	conn.tls_ct_hold_n = 0
	conn.tls_send_is_hold = false
	conn.tls_ct_recv_inflight = false
	conn.tls_plain_rest = nil
	conn.tls_hs_send = false
	conn.tls_stream_plain_n = 0
	tls_pipe_init(&conn.tls_pipe) // Handshake / Idle
	conn.ciphered = false
	return true
}

// tls_host_conn_destroy: best-effort SSL_shutdown + free SSL + CT scratch.
// Safe if never TLS. Called from connection_destroy.
@(private)
tls_host_conn_destroy :: proc(conn: ^Connection) {
	if conn == nil {
		return
	}
	p: ^tls_server.Provider
	if conn.server != nil {
		p = conn.server.tls_provider
	}
	if conn.tls_ssl != nil {
		if p != nil {
			_ = tls_server.shutdown(p, conn.tls_ssl)
			tls_server.conn_free(p, conn.tls_ssl)
		}
		conn.tls_ssl = nil
	}
	alloc := context.allocator
	if conn.server != nil {
		alloc = conn.server.conn_allocator
	}
	if conn.tls_ct_rx != nil {
		delete(conn.tls_ct_rx, alloc)
		conn.tls_ct_rx = nil
	}
	if conn.tls_ct_tx != nil {
		delete(conn.tls_ct_tx, alloc)
		conn.tls_ct_tx = nil
	}
	if conn.tls_ct_hold != nil {
		delete(conn.tls_ct_hold, alloc)
		conn.tls_ct_hold = nil
	}
	conn.tls_ct_tx_ready_n = 0
	conn.tls_ct_hold_n = 0
	conn.tls_send_is_hold = false
	conn.tls_plain_rest = nil
	conn.tls_hs_send = false
	conn.tls_stream_plain_n = 0
	conn.tls_ct_recv_inflight = false
	// Seal_q / CT double-buffer (Open path).
	connection_disable_ciphered(conn)
}

// ---------------------------------------------------------------------------
// Recv arm (CT into tls_ct_rx)
// ---------------------------------------------------------------------------

// tls_host_arm_recv submits pointer RECV into tls_ct_rx.
// Idempotent: if CT RECV is already outstanding, returns true without re-submit
// (second EV_ADD on kqueue would replace udata and orphan the prior Recv op).
@(private)
tls_host_arm_recv :: proc(conn: ^Connection) -> bool {
	if conn == nil || conn.state >= .Closing {
		return false
	}
	if conn.tls_ct_recv_inflight {
		return true // already armed — single-flight ownership
	}
	assert_has_td()
	if conn.tls_ssl == nil || len(conn.tls_ct_rx) == 0 {
		return false
	}
	_, err := proactr.submit_recv(
		&td.ring,
		i32(conn.socket),
		conn.tls_ct_rx,
		conn,
		conn.fixed_idx,
	)
	if err != .None {
		log.errorf("TLS: submit_recv CT failed fd=%v err=%v", conn.socket, err)
		return false
	}
	conn.tls_ct_recv_inflight = true
	return true
}

// ---------------------------------------------------------------------------
// host_on_recv entry (ciphertext)
// ---------------------------------------------------------------------------

// tls_host_session_client_gone: peer hangup on long-lived stream/session (metrics + abort).
@(private)
tls_host_session_client_gone :: proc(conn: ^Connection) {
	if conn == nil {
		return
	}
	if conn.slot.session != nil {
		sync.atomic_add(&session_metrics_client_gone, 1)
		_session_drive(conn, Session_Event{kind = .Client_Gone})
		if conn.slot.session != nil {
			_session_abort(conn)
		}
		return
	}
	if conn.slot.stream_open {
		connection_close(conn)
		return
	}
	connection_close(conn)
}

// tls_host_on_recv: feed CT → drive Handshake or Open SSL_read → scanner.
// Caller has already filtered close_on_io / stream PIN and cleared tls_ct_recv_inflight
// (host_on_recv) for this CQE so re-arm is safe.
@(private)
tls_host_on_recv :: proc(conn: ^Connection, result: i32) {
	if conn == nil || conn.tls_ssl == nil {
		return
	}
	// Defensive: if called without host_on_recv clear (tests / future paths).
	conn.tls_ct_recv_inflight = false
	if conn.state >= .Closing {
		return
	}
	if result < 0 {
		log.debugf("TLS recv error fd=%v res=%d", conn.socket, result)
		if conn.h2_active {
			connection_close(conn)
			return
		}
		if conn.slot.session != nil || conn.slot.stream_open {
			tls_host_session_client_gone(conn)
		} else {
			connection_close(conn)
		}
		return
	}
	if result == 0 {
		// Peer closed TCP.
		if conn.h2_active {
			connection_close(conn)
			return
		}
		if conn.slot.session != nil || conn.slot.stream_open {
			tls_host_session_client_gone(conn)
			return
		}
		if conn.tls_pipe.state == .Open {
			// Deliver EOF to scanner if a parse is live.
			if conn.scanner.callback != nil {
				scanner_on_bytes(&conn.scanner, 0, true)
			} else {
				connection_close(conn)
			}
		} else {
			connection_close(conn)
		}
		return
	}

	p := conn.server.tls_provider
	ssl := conn.tls_ssl
	n := int(result)
	if n > len(conn.tls_ct_rx) {
		n = len(conn.tls_ct_rx)
	}
	w := tls_server.bio_write_net(p, ssl, conn.tls_ct_rx[:n])
	if w < 0 {
		log.debugf("TLS bio_write_net fail fd=%v", conn.socket)
		if conn.slot.session != nil || conn.slot.stream_open {
			tls_host_session_client_gone(conn)
		} else {
			connection_close(conn)
		}
		return
	}

	switch conn.tls_pipe.state {
	case .Handshake:
		tls_host_drive_handshake(conn)
	case .Open:
		// PR8 H2 eng: feed PT to http2 engine (not H1 scanner).
		if conn.h2_active {
			h2_host_on_ct_ready(conn)
			return
		}
		// Long-lived stream/session: hangup watch (close_notify / discard PT).
		if conn.slot.stream_open || conn.slot.session != nil {
			tls_host_stream_ct_recv(conn)
		} else {
			// Decrypt into scanner free window (or re-arm CT if WANT_READ).
			tls_host_open_decrypt_or_arm(conn)
		}
	case .Closing, .Closed:
		connection_close(conn)
	}
}

// tls_host_stream_ct_recv: CT arrived while progressive stream/session is live.
// Probe close_notify / unexpected PT; resume seal if flush pending; else hangup arm.
@(private)
tls_host_stream_ct_recv :: proc(conn: ^Connection) {
	if conn == nil || conn.tls_ssl == nil {
		return
	}
	if conn.state >= .Closing {
		return
	}
	// Small probe window — SSE/WS v1 is send-oriented (no inbound frame parse).
	probe: [512]u8
	n_pt := tls_host_ssl_read_burst(conn, probe[:])
	if conn.state >= .Closing {
		return
	}
	if n_pt > 0 {
		// Unexpected client app data while session/stream owns wire → Client_Gone.
		tls_host_session_client_gone(conn)
		return
	}
	if conn.slot.session == nil && !conn.slot.stream_open {
		return
	}
	// Resume progressive seal if plain remains or WANT_READ unblocked a write.
	more := len(conn.resp_buf) > conn.slot.stream_sent ||
		conn.tls_stream_plain_n > 0 ||
		conn.slot.stream_flush_pending ||
		conn.slot.stream_ending
	if more && !_conn_wire_in_flight(conn) {
		conn.slot.stream_flush_pending = false
		tls_host_stream_try_submit(conn)
		return
	}
	// Still live and idle: re-arm CT recv hangup watch.
	_session_arm_hangup_watch(conn)
}

// ---------------------------------------------------------------------------
// Handshake drive
// ---------------------------------------------------------------------------

@(private)
tls_host_drive_handshake :: proc(conn: ^Connection) {
	if conn == nil || conn.tls_ssl == nil {
		return
	}
	p := conn.server.tls_provider
	ssl := conn.tls_ssl

	for {
		if conn.state >= .Closing {
			return
		}
		// Prefer draining outbound HS records before accept when socket free.
		if tls_server.bio_pending_out(p, ssl) > 0 {
			if !tls_host_try_drain_out(conn, hs = true) {
				return // send inflight or closed
			}
			// If still pending after a full drain attempt that submitted, wait CQE.
			if _conn_wire_in_flight(conn) {
				return
			}
		}

		ret := tls_server.accept(p, ssl)
		if ret == 1 {
			// Handshake complete → Open.
			conn.tls_pipe.state = .Open
			if !connection_enable_ciphered(conn) {
				log.errorf("TLS: connection_enable_ciphered failed fd=%v", conn.socket)
				connection_close(conn)
				return
			}
			// Final HS flight records (if any).
			if !tls_host_try_drain_out(conn, hs = true) {
				return
			}
			if _conn_wire_in_flight(conn) {
				// Open HTTP after HS CT CQE (tls_host_on_send_complete).
				return
			}
			tls_host_open_start_protocol(conn)
			return
		}

		ge := tls_server.get_error(p, ssl, ret)
		if ge == p.ERROR_WANT_READ {
			if tls_server.bio_pending_out(p, ssl) > 0 {
				if !tls_host_try_drain_out(conn, hs = true) {
					return
				}
				if _conn_wire_in_flight(conn) {
					return
				}
			}
			if !tls_host_arm_recv(conn) {
				connection_close(conn)
			}
			return
		}
		if ge == p.ERROR_WANT_WRITE {
			if !tls_host_try_drain_out(conn, hs = true) {
				return
			}
			if _conn_wire_in_flight(conn) {
				return
			}
			// Drained; loop accept again.
			continue
		}
		log.debugf("TLS handshake error fd=%v ret=%d ge=%d", conn.socket, ret, ge)
		connection_close(conn)
		return
	}
}

// Submit ciphertext from a slab. Marks which slab is in flight; clears that slab's ready len.
@(private)
tls_host_submit_ct :: proc(conn: ^Connection, buf: []u8, n: int, hs: bool) -> bool {
	if conn == nil || n <= 0 || len(buf) < n {
		return false
	}
	is_hold := len(conn.tls_ct_hold) > 0 && raw_data(buf) == raw_data(conn.tls_ct_hold)
	conn.wire.pending_send = buf[:n]
	conn.tls_hs_send = hs
	conn.tls_send_is_hold = is_hold
	if is_hold {
		conn.tls_ct_hold_n = 0
	} else {
		conn.tls_ct_tx_ready_n = 0
	}
	if err := host_submit_send(conn); err != .None {
		_wire_fail(conn, "TLS submit_send CT failed: %v", err)
		return false
	}
	return true
}

// Free slab for sealing while a send may be in flight (not ready, not sending).
@(private)
tls_host_seal_dst_for_ahead :: proc(conn: ^Connection) -> (dst: []u8, mark_hold: bool) {
	if conn == nil || !_conn_wire_in_flight(conn) {
		return nil, false
	}
	// Prefer filling whichever slab is free.
	if conn.tls_send_is_hold {
		// Hold is sending → seal into primary if free.
		if conn.tls_ct_tx_ready_n == 0 && len(conn.tls_ct_tx) > 0 {
			return conn.tls_ct_tx, false
		}
		return nil, false
	}
	// Primary is sending → seal into hold if free.
	if conn.tls_ct_hold_n == 0 && len(conn.tls_ct_hold) > 0 {
		return conn.tls_ct_hold, true
	}
	return nil, false
}

// Drain wBIO into free slab; if sock free submit immediately, else mark ready.
// Returns false if connection closed or send armed (caller must wait CQE).
// Returns true if idle (no CT pending / nothing submitted).
@(private)
tls_host_try_drain_out :: proc(conn: ^Connection, hs: bool) -> bool {
	if conn == nil || conn.tls_ssl == nil {
		return true
	}
	if conn.state >= .Closing {
		return false
	}
	p := conn.server.tls_provider
	ssl := conn.tls_ssl
	pending := tls_server.bio_pending_out(p, ssl)
	if pending <= 0 {
		return true
	}

	dst: []u8
	mark_hold := false
	if !_conn_wire_in_flight(conn) {
		// Prefer submitting via primary.
		if conn.tls_ct_tx_ready_n == 0 && len(conn.tls_ct_tx) > 0 {
			dst = conn.tls_ct_tx
		} else if conn.tls_ct_hold_n == 0 && len(conn.tls_ct_hold) > 0 {
			dst = conn.tls_ct_hold
			mark_hold = true
		} else {
			return true
		}
	} else {
		dst, mark_hold = tls_host_seal_dst_for_ahead(conn)
		if len(dst) == 0 {
			return false // both busy
		}
	}
	n := tls_server.bio_read_net(p, ssl, dst)
	if n <= 0 {
		return true
	}
	tls_metrics_note_ct(conn.server, u64(n))
	tls_metrics_inc_seal(conn.server)
	path_metrics_note_ct_send(u64(n))

	if _conn_wire_in_flight(conn) {
		if mark_hold {
			conn.tls_ct_hold_n = n
		} else {
			conn.tls_ct_tx_ready_n = n
		}
		return false
	}
	if !tls_host_submit_ct(conn, dst, n, hs) {
		return false
	}
	return false // wait CQE
}

// After sock send CQE: submit any ready CT (hold preferred, then primary).
// Returns true if a new send was armed.
@(private)
tls_host_promote_hold :: proc(conn: ^Connection) -> bool {
	if conn == nil {
		return false
	}
	conn.tls_send_is_hold = false
	conn.wire.pending_send = nil
	// Prefer hold then primary ready.
	if conn.tls_ct_hold_n > 0 && len(conn.tls_ct_hold) > 0 {
		n := conn.tls_ct_hold_n
		return tls_host_submit_ct(conn, conn.tls_ct_hold, n, hs = false)
	}
	if conn.tls_ct_tx_ready_n > 0 && len(conn.tls_ct_tx) > 0 {
		n := conn.tls_ct_tx_ready_n
		return tls_host_submit_ct(conn, conn.tls_ct_tx, n, hs = false)
	}
	return false
}

// ---------------------------------------------------------------------------
// Open: start HTTP parse + decrypt path
// ---------------------------------------------------------------------------

// tls_host_open_start_protocol: after handshake Open, branch on negotiated ALPN.
// h2 → engineering unary H2 host; http/1.1 or empty → H1 scanner path.
@(private)
tls_host_open_start_protocol :: proc(conn: ^Connection) {
	if conn == nil || conn.state >= .Closing {
		return
	}
	p: ^tls_server.Provider
	if conn.server != nil {
		p = conn.server.tls_provider
	}
	if tls_server.alpn_is_h2(p, conn.tls_ssl) {
		h2_host_on_open(conn)
		return
	}
	tls_host_open_start_http(conn)
}

// tls_host_open_start_http begins the clear-H1 request cycle over the ciphered pipe.
@(private)
tls_host_open_start_http :: proc(conn: ^Connection) {
	if conn == nil || conn.state >= .Closing {
		return
	}
	// Same entry as clear accept path after handshake.
	conn_handle_reqs(conn)
}

// tls_host_open_decrypt_or_arm: SSL_read PT into scanner free window → scanner_on_bytes.
// On WANT_READ with no PT: arm CT recv.
@(private)
tls_host_open_decrypt_or_arm :: proc(conn: ^Connection) {
	if conn == nil || conn.tls_ssl == nil || conn.tls_pipe.state != .Open {
		return
	}
	if conn.state >= .Closing {
		return
	}
	// Ensure temp arena for parse.
	if conn.temp_slot < 0 {
		_ = conn_temp_attach(conn)
	}
	context.temp_allocator = virtual.arena_allocator(&conn.temp_allocator)

	// Free window in scanner.
	s := &conn.scanner
	free_n := len(s.buf) - s.end
	if free_n <= 0 {
		// Compact / grow path is scanner's job; arm CT only if callback set.
		if s.callback != nil {
			// Let scanner_scan compact on next call; try inject 0 progress via re-arm.
			if !tls_host_arm_recv(conn) {
				connection_close(conn)
			}
		}
		return
	}
	dst := s.buf[s.end:len(s.buf)]
	n_pt := tls_host_ssl_read_burst(conn, dst)
	if n_pt > 0 {
		scanner_on_bytes(s, n_pt, false)
		return
	}
	// No PT: check error class from last read (ssl_read_burst returns 0 for WANT_*).
	// WANT_READ → arm CT; ZERO_RETURN handled inside burst via sentinel -1? use explicit.
	// Re-probe with zero-size is awkward; arm CT when Open and no PT.
	if !tls_host_arm_recv(conn) {
		connection_close(conn)
	}
}

// tls_host_ssl_read_burst: loop SSL_read into dst until WANT_* / error / full.
// Returns plaintext bytes written. On ZERO_RETURN / hard error: closes or EOF via side effect.
// WANT_* returns 0 without closing.
@(private)
tls_host_ssl_read_burst :: proc(conn: ^Connection, dst: []u8) -> int {
	if conn == nil || conn.tls_ssl == nil || len(dst) == 0 {
		return 0
	}
	p := conn.server.tls_provider
	ssl := conn.tls_ssl
	total := 0
	for total < len(dst) {
		ret := tls_server.read(p, ssl, raw_data(dst[total:]), c.int(len(dst) - total))
		if ret > 0 {
			total += int(ret)
			continue
		}
		ge := tls_server.get_error(p, ssl, ret)
		if ge == p.ERROR_WANT_READ {
			break
		}
		if ge == p.ERROR_WANT_WRITE {
			// Drain handshake/reneg CT if any.
			_ = tls_host_try_drain_out(conn, hs = false)
			break
		}
		if ge == p.ERROR_ZERO_RETURN {
			// Clean TLS close. If we got some PT, return it first; else EOF.
			if total > 0 {
				return total
			}
			// Long-lived stream/session: same metrics as clear stream send error.
			if conn.slot.session != nil || conn.slot.stream_open {
				tls_host_session_client_gone(conn)
				return 0
			}
			if conn.scanner.callback != nil {
				scanner_on_bytes(&conn.scanner, 0, true)
			} else {
				connection_close(conn)
			}
			return 0
		}
		// Hard error.
		log.debugf("TLS SSL_read error fd=%v ret=%d ge=%d", conn.socket, ret, ge)
		if conn.slot.session != nil || conn.slot.stream_open {
			tls_host_session_client_gone(conn)
		} else {
			connection_close(conn)
		}
		return 0
	}
	return total
}

// tls_host_try_ssl_read_into: used by host_submit_recv when ciphered Open.
// Writes PT into buf (scanner free window). Returns n>0, or 0 for need-CT / error handled.
@(private)
tls_host_try_ssl_read_into :: proc(conn: ^Connection, buf: []u8) -> int {
	return tls_host_ssl_read_burst(conn, buf)
}

// ---------------------------------------------------------------------------
// Send path (ciphered response + handshake CT complete)
// ---------------------------------------------------------------------------

// tls_host_stream_long_lived: progressive stream / session owns the wire.
// CT send complete must not call clean_request_loop mid-session.
@(private)
tls_host_stream_long_lived :: proc(conn: ^Connection) -> bool {
	return conn != nil && (conn.slot.stream_open || conn.slot.session != nil)
}

// tls_host_stream_try_submit: progressive SSE/WS over TLS H1.
// Encrypts plain from resp_buf[stream_sent:] via SSL_write (no stream_pool slabs),
// drains wBIO CT into tls_ct_tx + host_submit_send (.Send — completion hits
// tls_host_on_send_complete). CQE advances stream_sent by tls_stream_plain_n.
@(private)
tls_host_stream_try_submit :: proc(conn: ^Connection) {
	if conn == nil || conn.state >= .Closing {
		return
	}
	if conn.tls_ssl == nil {
		// Ciphered flag without SSL: cannot seal — mark pending for later.
		conn.slot.stream_flush_pending = true
		return
	}

	// Keep resp_buf synced from response binding when present.
	r := &conn.slot.res
	if r._buf.buf != nil {
		conn.resp_buf = r._buf.buf
	}

	// Wire already in flight (CT partial or prior seal): reflush after CQE.
	if _conn_wire_in_flight(conn) {
		conn.slot.stream_flush_pending = true
		return
	}

	p := conn.server.tls_provider
	ssl := conn.tls_ssl

	// Prefer draining residual CT from a prior SSL_write before sealing more plain.
	if tls_server.bio_pending_out(p, ssl) > 0 {
		if !tls_host_try_drain_out(conn, hs = false) {
			return
		}
		if _conn_wire_in_flight(conn) {
			return
		}
	}

	unsent := len(conn.resp_buf) - conn.slot.stream_sent
	if unsent <= 0 {
		if conn.slot.stream_ending {
			_stream_finish(conn)
		} else {
			// Mid-session idle: arm CT recv for peer close/hangup.
			_session_arm_hangup_watch(conn)
		}
		return
	}

	conn.slot.stream_open = true
	conn.slot.stream_flush_pending = false

	// First flush: on_respond once (same as clear path).
	if !conn.slot.stream_respond_fired {
		conn.slot.stream_respond_fired = true
		_response_fire_respond_hooks(r)
	}

	// Plain window: min(unsent, PULL_WINDOW_DEFAULT) from resp_buf[stream_sent:].
	// Encrypt from resp_buf view — do not copy into stream_pool slabs.
	win := unsent
	if win > PULL_WINDOW_DEFAULT {
		win = PULL_WINDOW_DEFAULT
	}
	plain := conn.resp_buf[conn.slot.stream_sent:][:win]

	ret := tls_server.write(p, ssl, raw_data(plain), c.int(win))
	if ret <= 0 {
		ge := tls_server.get_error(p, ssl, ret)
		if ge == p.ERROR_WANT_WRITE {
			// Drain CT then retry seal on next CQE / immediately if idle.
			if !tls_host_try_drain_out(conn, hs = false) {
				conn.slot.stream_flush_pending = true
				return
			}
			if !_conn_wire_in_flight(conn) {
				tls_host_stream_try_submit(conn)
			} else {
				conn.slot.stream_flush_pending = true
			}
			return
		}
		if ge == p.ERROR_WANT_READ {
			// Rare for server write: arm CT recv; seal resumes after decrypt path.
			conn.slot.stream_flush_pending = true
			if td != nil && !tls_host_arm_recv(conn) {
				tls_host_session_client_gone(conn)
			}
			return
		}
		log.debugf("TLS stream SSL_write error fd=%v ret=%d ge=%d", conn.socket, ret, ge)
		tls_host_session_client_gone(conn)
		return
	}

	consumed := int(ret)
	if consumed > win {
		consumed = win
	}
	// Remember plain sealed so CQE can advance stream_sent after full CT delivery.
	conn.tls_stream_plain_n = consumed

	pending := tls_server.bio_pending_out(p, ssl)
	if pending <= 0 {
		// Sealed but no CT yet (internal buffer) — advance plain cursor and continue.
		conn.slot.stream_sent += consumed
		conn.tls_stream_plain_n = 0
		_stream_compact_delivered(conn)
		if conn.slot.session != nil {
			_session_on_writable(conn)
		}
		// Recurse while idle and more plain / ending.
		more := len(conn.resp_buf) > conn.slot.stream_sent
		if more || conn.slot.stream_ending {
			tls_host_stream_try_submit(conn)
		} else {
			_session_arm_hangup_watch(conn)
		}
		return
	}

	n := tls_server.bio_read_net(p, ssl, conn.tls_ct_tx)
	if n <= 0 {
		// Fail-closed (CQ-M2): pending was > 0 but drain failed — do not advance
		// stream_sent (would desync plain vs peer / drop CT still in wBIO).
		log.debugf(
			"TLS stream bio_read_net fail after SSL_write fd=%v n=%d plain=%d",
			conn.socket,
			n,
			consumed,
		)
		conn.tls_stream_plain_n = 0
		tls_host_session_client_gone(conn)
		return
	}

	tls_metrics_note_ct(conn.server, u64(n))
	tls_metrics_inc_seal(conn.server)

	// Explicitly inactive multi-op queue so a prior path cannot leak exec_n.
	conn.wire.exec_i = 0
	conn.wire.exec_n = 0
	conn.wire.pending_send = conn.tls_ct_tx[:n]
	conn.tls_hs_send = false
	// host_submit_send sets wire.kind = .Send — do NOT set .Stream so completion
	// hits tls_host_on_send_complete via _host_on_wire_send.
	if err := host_submit_send(conn); err != .None {
		conn.wire.pending_send = nil
		conn.tls_stream_plain_n = 0
		// Same Client_Gone path as CQE send error when session owns the wire.
		if conn.slot.session != nil {
			sync.atomic_add(&session_metrics_client_gone, 1)
			_session_drive(conn, Session_Event{kind = .Client_Gone})
		}
		_wire_fail(conn, "TLS stream submit_send CT failed: %v", err)
	}
}

// Seal one oneshot plain window into OpenSSL; drain CT into dst (tx or hold).
// Returns (n_ct, pt_consumed, sealed_ok). n_ct==0 may still mean progress (buffered).
@(private)
tls_host_seal_oneshot_window :: proc(conn: ^Connection, dst: []u8) -> (n_ct: int, pt_n: int, ok: bool) {
	if conn == nil || conn.tls_ssl == nil || len(dst) == 0 {
		return 0, 0, false
	}
	if len(conn.tls_plain_rest) == 0 {
		return 0, 0, true
	}
	p := conn.server.tls_provider
	ssl := conn.tls_ssl
	win := len(conn.tls_plain_rest)
	if win > PULL_WINDOW_DEFAULT {
		win = PULL_WINDOW_DEFAULT
	}
	if !pt_admit(&conn.pt, u32(win)) {
		win = int(min(u32(win), TLS_RECORD_PLAIN))
		if win == 0 || !pt_admit(&conn.pt, u32(win)) {
			return 0, 0, false
		}
	}
	tls_metrics_note_pt(conn.server, u64(conn.pt.admitted))

	ret := tls_server.write(p, ssl, raw_data(conn.tls_plain_rest[:win]), c.int(win))
	if ret <= 0 {
		pt_release(&conn.pt, u32(win))
		ge := tls_server.get_error(p, ssl, ret)
		if ge == p.ERROR_WANT_WRITE {
			// Caller drains / waits.
			return 0, 0, true
		}
		if ge == p.ERROR_WANT_READ {
			_ = tls_host_arm_recv(conn)
			return 0, 0, true
		}
		log.debugf("TLS SSL_write error fd=%v ret=%d ge=%d", conn.socket, ret, ge)
		return 0, 0, false
	}
	consumed := int(ret)
	if consumed > win {
		consumed = win
	}
	if consumed < win {
		pt_release(&conn.pt, u32(win - consumed))
	}
	conn.tls_plain_rest = conn.tls_plain_rest[consumed:]
	path_metrics_note_ssl_write(u64(consumed))
	sync.atomic_add(&path_seal_calls, 1)

	pending := tls_server.bio_pending_out(p, ssl)
	if pending <= 0 {
		pt_release(&conn.pt, u32(consumed))
		return 0, consumed, true
	}
	n := tls_server.bio_read_net(p, ssl, dst)
	if n <= 0 {
		pt_release(&conn.pt, u32(consumed))
		return 0, consumed, true
	}
	tls_metrics_note_ct(conn.server, u64(n))
	tls_metrics_inc_seal(conn.server)
	path_metrics_note_ct_send(u64(n))
	pt_release(&conn.pt, u32(consumed))
	return n, consumed, true
}

// While sock send is in flight, seal next oneshot window into the free CT slab.
@(private)
tls_host_try_seal_hold_oneshot :: proc(conn: ^Connection) {
	if conn == nil || len(conn.tls_plain_rest) == 0 {
		return
	}
	dst, mark_hold := tls_host_seal_dst_for_ahead(conn)
	if len(dst) == 0 {
		return
	}
	n_ct, _, ok := tls_host_seal_oneshot_window(conn, dst)
	if !ok {
		connection_close(conn)
		return
	}
	if n_ct > 0 {
		if mark_hold {
			conn.tls_ct_hold_n = n_ct
		} else {
			conn.tls_ct_tx_ready_n = n_ct
		}
	}
}

// tls_host_flush_response: window plain → SSL_write → drain CT → submit (dual-CT).
// Multi-CQE: tls_plain_rest holds remaining plain. While send inflight, seals into hold.
@(private)
tls_host_flush_response :: proc(conn: ^Connection) {
	if conn == nil || conn.tls_ssl == nil {
		return
	}
	if conn.state >= .Closing {
		return
	}

	// Live dual-CT: keep encrypting into free slab while a CT send is on the wire.
	if _conn_wire_in_flight(conn) {
		// Residual wBIO → free slab if any.
		if tls_server.bio_pending_out(conn.server.tls_provider, conn.tls_ssl) > 0 {
			_ = tls_host_try_drain_out(conn, hs = false)
		}
		tls_host_try_seal_hold_oneshot(conn)
		return
	}

	p := conn.server.tls_provider
	ssl := conn.tls_ssl

	// Ordering: promote already-sealed CT before draining newer wBIO residual
	// (CRITIC C2 — residual-before-promote reorders records).
	if conn.tls_ct_hold_n > 0 || conn.tls_ct_tx_ready_n > 0 {
		if tls_host_promote_hold(conn) {
			tls_host_try_seal_hold_oneshot(conn)
			return
		}
	}

	// Drain residual CT from prior SSL_write into free slab / submit.
	if tls_server.bio_pending_out(p, ssl) > 0 {
		if !tls_host_try_drain_out(conn, hs = false) {
			if _conn_wire_in_flight(conn) {
				tls_host_try_seal_hold_oneshot(conn)
			}
			return
		}
		if _conn_wire_in_flight(conn) {
			tls_host_try_seal_hold_oneshot(conn)
			return
		}
	}

	if len(conn.tls_plain_rest) == 0 {
		conn.tls_plain_rest = nil
		if conn.pt.admitted > 0 {
			pt_release(&conn.pt, conn.pt.admitted)
		}
		path_metrics_note_req()
		clean_request_loop(conn)
		return
	}

	dst := conn.tls_ct_tx
	if len(dst) == 0 {
		return
	}
	n_ct, _, ok := tls_host_seal_oneshot_window(conn, dst)
	if !ok {
		if conn.pt.admitted > 0 {
			// seal failed hard
		}
		log.errorf("TLS: PT high-water refuse or SSL_write fail fd=%v admitted=%d", conn.socket, conn.pt.admitted)
		connection_close(conn)
		return
	}
	if n_ct <= 0 {
		// Buffered / WANT — drain or continue.
		if tls_server.bio_pending_out(p, ssl) > 0 {
			_ = tls_host_try_drain_out(conn, hs = false)
			if _conn_wire_in_flight(conn) {
				tls_host_try_seal_hold_oneshot(conn)
				return
			}
		}
		if len(conn.tls_plain_rest) > 0 && !_conn_wire_in_flight(conn) {
			tls_host_flush_response(conn)
			return
		}
		if len(conn.tls_plain_rest) == 0 {
			path_metrics_note_req()
			clean_request_loop(conn)
		}
		return
	}

	if len(conn.tls_plain_rest) == 0 {
		path_metrics_note_req()
	}
	if !tls_host_submit_ct(conn, dst, n_ct, hs = false) {
		return
	}
	// Dual-CT: immediately seal next window into hold while send is armed.
	tls_host_try_seal_hold_oneshot(conn)
}

// tls_host_on_send_complete: after a full CT buffer was delivered on the wire.
// Handshake: re-drive accept. Progressive stream/session: advance plain, reflush, hangup arm.
// Oneshot response: more CT / next plain window / clean.
// Returns true if handled (caller must not run clear-H1 finish path).
@(private)
tls_host_on_send_complete :: proc(conn: ^Connection) -> bool {
	if conn == nil || conn.tls_ssl == nil {
		return false
	}
	hs := conn.tls_hs_send
	conn.tls_hs_send = false
	conn.wire.pending_send = nil

	if hs || conn.tls_pipe.state == .Handshake {
		// Dual-CT: promote any CT stashed during HS send before re-entering handshake.
		if tls_host_promote_hold(conn) {
			return true
		}
		// More HS CT or continue accept.
		if conn.tls_pipe.state == .Handshake {
			tls_host_drive_handshake(conn)
			return true
		}
		// Open but HS flight was last: start protocol if not yet.
		if conn.tls_pipe.state == .Open && conn.state == .New {
			// Promote ready CT first (ordering), then residual wBIO.
			if tls_host_promote_hold(conn) {
				return true
			}
			if tls_server.bio_pending_out(conn.server.tls_provider, conn.tls_ssl) > 0 {
				if !tls_host_try_drain_out(conn, hs = true) {
					return true
				}
				if _conn_wire_in_flight(conn) {
					return true
				}
			}
			tls_host_open_start_protocol(conn)
			return true
		}
	}

	// PR8 H2 eng: continue windowed frame flush; duplex re-arm CT recv.
	if conn.h2_active {
		return h2_host_on_send_complete(conn)
	}

	// PR6 progressive stream / long-lived session: do NOT clean_request_loop mid-session.
	if tls_host_stream_long_lived(conn) {
		p := conn.server.tls_provider
		ssl := conn.tls_ssl

		// Dual-CT: promote any ready slab before residual drain (ordering).
		if tls_host_promote_hold(conn) {
			return true
		}

		// 1. More CT still in wBIO from the same plain seal → drain and submit.
		if tls_server.bio_pending_out(p, ssl) > 0 {
			if !tls_host_try_drain_out(conn, hs = false) {
				return true
			}
			if _conn_wire_in_flight(conn) {
				return true
			}
			// Drained without submit (empty read) — fall through to advance plain.
		}

		// 2. Full CT for current seal delivered: advance stream_sent.
		if conn.tls_stream_plain_n > 0 {
			conn.slot.stream_sent += conn.tls_stream_plain_n
			conn.tls_stream_plain_n = 0
		}

		// 3. Compact delivered prefix when useful.
		_stream_compact_delivered(conn)

		// 4. Session backpressure relief.
		if conn.slot.session != nil {
			_session_on_writable(conn)
		}

		// 5. More plain / flush_pending / ending → seal next window.
		more := len(conn.resp_buf) > conn.slot.stream_sent
		if more || conn.slot.stream_flush_pending || conn.slot.stream_ending {
			conn.slot.stream_flush_pending = false
			if more || conn.slot.stream_ending {
				tls_host_stream_try_submit(conn)
				return true
			}
		}

		// 6. Ending and all plain sent → finish (clean via _stream_finish).
		if conn.slot.stream_ending && conn.slot.stream_sent >= len(conn.resp_buf) {
			_stream_finish(conn)
			return true
		}

		// 7. Mid-session idle: arm CT recv for peer close (hangup path).
		_session_arm_hangup_watch(conn)
		return true
	}

	if conn.ciphered || conn.tls_pipe.state == .Open {
		// Dual-CT: if a slab was filled during flight, promote immediately.
		if tls_host_promote_hold(conn) {
			// New send armed — seal further into free slab.
			tls_host_try_seal_hold_oneshot(conn)
			return true
		}
		// Oneshot: continue windowed response flush (or residual / ready CT).
		if len(conn.tls_plain_rest) > 0 ||
		   conn.tls_ct_hold_n > 0 ||
		   conn.tls_ct_tx_ready_n > 0 ||
		   tls_server.bio_pending_out(conn.server.tls_provider, conn.tls_ssl) > 0 {
			tls_host_flush_response(conn)
			return true
		}
		// Fully done.
		clean_request_loop(conn)
		return true
	}
	return false
}

// ---------------------------------------------------------------------------
// Metrics (server atomics)
// ---------------------------------------------------------------------------

@(private)
tls_metrics_note_pt :: proc(s: ^Server, pt: u64) {
	if s == nil || pt == 0 {
		return
	}
	for {
		old := atomic_load(&s.tls_peak_pt)
		if pt <= old {
			return
		}
		_, ok := sync.atomic_compare_exchange_strong(&s.tls_peak_pt.raw, old, pt)
		if ok {
			return
		}
	}
}

@(private)
tls_metrics_note_ct :: proc(s: ^Server, ct: u64) {
	if s == nil || ct == 0 {
		return
	}
	for {
		old := atomic_load(&s.tls_peak_ct)
		if ct <= old {
			return
		}
		_, ok := sync.atomic_compare_exchange_strong(&s.tls_peak_ct.raw, old, ct)
		if ok {
			return
		}
	}
}

@(private)
tls_metrics_inc_seal :: proc(s: ^Server) {
	if s == nil {
		return
	}
	sync.atomic_add(&s.tls_seal_units.raw, 1)
}

// ---------------------------------------------------------------------------
// Public convenience
// ---------------------------------------------------------------------------

// listen_and_serve_tls sets PEM material on opts then listen_and_serve.
// PEMs are in-memory slices (caller retains ownership for process life).
// If OpenSSL cannot load or PEMs are invalid, listen logs and serves clear-H1 only.
listen_and_serve_tls :: proc(
	s: ^Server,
	h: Handler,
	endpoint: net.Endpoint = Default_Endpoint,
	cert_pem: []u8 = nil,
	key_pem: []u8 = nil,
	opts: Server_Opts = Default_Server_Opts,
) -> (err: proactr.Error) {
	o := opts
	o.tls_cert_pem = cert_pem
	o.tls_key_pem = key_pem
	return listen_and_serve(s, h, endpoint, o)
}
