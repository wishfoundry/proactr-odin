// PR5 host: real mem-BIO TLS on proactr accept/recv/send path.
//
// Opaque SSL only (tls_server.Conn) — no SSL* leaves this module into handlers.
// Product I/O: rBIO fed by recv CT; wBIO drained to host_submit_send CT.
// Clear-H1 paths are unchanged when Server.tls_provider/tls_ctx are nil.
//
// Handshake: conn.tls_pipe.state = Handshake until SSL_accept OK → Open +
// connection_enable_ciphered (lightweight: plan_policy only; no seal_q/CT[2]).
// Response send (ciphered oneshot / stream / H2): single seal engine in
// tls_dual_ct.odin (tls_seal_window + tls_dual_ct_try_ahead) over Connection.dual_ct.
// Progressive Stream / SSE / WS: tls_host_stream_try_submit; stream_sent after CT CQE.
// Pure pipe Seal_SM remains the formal model; dual_ct is the live path.
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
// Live dual-CT slab size (plain seal window + TLS record overhead headroom).
TLS_CT_TX_DEFAULT :: TLS_CT_SLAB_DEFAULT

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
	// Cache wBIO once — product bulk drain uses bio_*_out_bio (peek-only, no BIO_read).
	wbio := tls_server.get_wbio(p, ssl)
	if wbio == nil {
		// Product OpenSSL always wires get_wbio after mem-BIO setup; nil → no peek-only path.
		log.errorf("TLS: get_wbio nil after setup_mem_bios fd=%v (peek drain unavailable)", conn.socket)
		tls_server.conn_free(p, ssl)
		return false
	}
	if !tls_server.bio_peek_supported(p) {
		log.errorf("TLS: bio peek unsupported fd=%v (product requires zero-copy wBIO drain)", conn.socket)
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
	// Second CT slab for seal∥send (Linux dual-CT). Darwin reactor: single residual
	// in tx only — skip hold alloc (PR-G / plan D3).
	hold: []u8
	when ODIN_OS != .Darwin {
		h, herr := make([]u8, TLS_CT_TX_DEFAULT, alloc)
		if herr != nil || h == nil {
			delete(rx, alloc)
			delete(tx, alloc)
			tls_server.conn_free(p, ssl)
			return false
		}
		hold = h
	}

	conn.tls_ssl = ssl
	conn.tls_wbio = wbio
	conn.tls_first_seal_pending = false
	conn.tls_ct_rx = rx
	conn.dual_ct = Dual_Ct {
		tx   = tx,
		hold = hold,
	}
	conn.tls_ct_recv_inflight = false
	tls_plain_clear(conn)
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
	conn.tls_wbio = nil // owned by SSL; invalid after conn_free
	conn.tls_first_seal_pending = false
	alloc := context.allocator
	if conn.server != nil {
		alloc = conn.server.conn_allocator
	}
	if conn.tls_ct_rx != nil {
		delete(conn.tls_ct_rx, alloc)
		conn.tls_ct_rx = nil
	}
	dual_ct_free_slabs(&conn.dual_ct, alloc)
	tls_plain_clear(conn)
	conn.tls_hs_send = false
	conn.tls_stream_plain_n = 0
	conn.tls_ct_recv_inflight = false
	// Seal_q / CT double-buffer (Open path).
	connection_disable_ciphered(conn)
}

// ---------------------------------------------------------------------------
// Recv arm (CT into tls_ct_rx)
// ---------------------------------------------------------------------------

// tls_host_arm_recv arms CT RECV into tls_ct_rx.
// Idempotent: if CT RECV is already outstanding, returns true without re-arm
// (second EV_ADD would replace udata and orphan the prior interest).
// Darwin P5: native reactor EVFILT_READ; Linux: proactr submit_recv.
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
	when ODIN_OS == .Darwin {
		if !reactor_host_arm_recv(conn, conn.tls_ct_rx) {
			log.errorf("TLS: reactor arm CT recv failed fd=%v", conn.socket)
			return false
		}
		return true
	} else {
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

// Dual-CT submit / seal_dst / drain / promote live in tls_dual_ct.odin.

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
			// Drain CT if any. Darwin: always reactor residual path (P4b) via try_drain_out.
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
// Send complete (handshake / H2 / stream / oneshot CQE)
// ---------------------------------------------------------------------------

// tls_host_on_send_complete: after a full CT buffer was delivered on the wire.
// Handshake: re-drive accept. Progressive stream/session: advance plain, reflush, hangup arm.
// Oneshot response: more CT / next plain window / clean.
// Returns true if handled (caller must not run clear-H1 finish path).
@(private)
tls_host_on_send_complete :: proc(conn: ^Connection) -> bool {
	if conn == nil || conn.tls_ssl == nil {
		return false
	}

	// Residual WRITE CQE (Darwin EVFILT_WRITE or Linux io_uring submit_send+reactor_h1):
	// single residual region — continue flush law (HS / H2 / oneshot demux inside
	// reactor_on_send_complete). No dual-CT promote; CQE not charged as soft_cq.
	when ODIN_OS == .Darwin || ODIN_OS == .Linux {
		if conn.reactor_h1 {
			return reactor_on_send_complete(conn)
		}
	}

	hs := conn.tls_hs_send
	conn.tls_hs_send = false
	conn.wire.pending_send = nil

	if hs || conn.tls_pipe.state == .Handshake {
		// Dual-CT (Linux): promote any CT stashed during HS send before re-entering handshake.
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
	// Linux dual-CT promote path; Darwin residual already handled above.
	if conn.h2_active {
		return h2_host_on_send_complete(conn)
	}

	// PR6 progressive stream / long-lived session: do NOT clean_request_loop mid-session.
	if tls_host_stream_long_lived(conn) {
		p := conn.server.tls_provider
		ssl := conn.tls_ssl
		d := &conn.dual_ct

		// Which slab just completed (send_is_hold still valid — promote clears it).
		was_hold := d.send_is_hold
		slab_plain := was_hold ? d.hold_plain_n : d.tx_plain_n
		if was_hold {
			d.hold_plain_n = 0
		} else {
			d.tx_plain_n = 0
		}
		// Legacy / residual-deferred single field: if no per-slab plain, use it.
		if slab_plain == 0 && conn.tls_stream_plain_n > 0 {
			slab_plain = conn.tls_stream_plain_n
			conn.tls_stream_plain_n = 0
		}

		// 1. More CT still in wBIO from the same plain seal → drain (do not advance yet).
		if tls_server.bio_pending_out(p, ssl) > 0 {
			// Defer this slab's plain until residual CT is fully delivered.
			conn.tls_stream_plain_n += slab_plain
			if !tls_host_try_drain_out(conn, hs = false) {
				if _conn_wire_in_flight(conn) {
					tls_dual_ct_try_ahead(conn, .Stream)
				}
				return true
			}
			if _conn_wire_in_flight(conn) {
				tls_dual_ct_try_ahead(conn, .Stream)
				return true
			}
			// Drained without submit — fall through with deferred plain in tls_stream_plain_n.
			slab_plain = 0
		}

		// 2. Ready residual CT of the same seal (plain_n == 0 on ready slab) — promote
		//    before advancing so multi-record split across slabs stays ordered.
		other_plain := was_hold ? d.tx_plain_n : d.hold_plain_n
		other_ready := was_hold ? d.tx_ready_n : d.hold_n
		if other_ready > 0 && other_plain == 0 {
			conn.tls_stream_plain_n += slab_plain
			if tls_host_promote_hold(conn) {
				tls_dual_ct_try_ahead(conn, .Stream)
				return true
			}
			slab_plain = 0
		}

		// 3. Full CT for this seal delivered: advance stream_sent by this slab + deferred.
		adv := slab_plain + conn.tls_stream_plain_n
		if adv > 0 {
			conn.slot.stream_sent += adv
			conn.tls_stream_plain_n = 0
		}

		// 4. Promote dual-CT ahead-seal (ready slab with its own plain_n > 0).
		if tls_host_promote_hold(conn) {
			tls_dual_ct_try_ahead(conn, .Stream)
			return true
		}

		// 5. Compact delivered prefix when useful.
		_stream_compact_delivered(conn)

		// 6. Session backpressure relief.
		if conn.slot.session != nil {
			_session_on_writable(conn)
		}

		// 7. More plain / flush_pending / ending → seal next window.
		more := len(conn.resp_buf) > tls_host_stream_plain_off(conn)
		if more || conn.slot.stream_flush_pending || conn.slot.stream_ending {
			conn.slot.stream_flush_pending = false
			if more || conn.slot.stream_ending {
				tls_host_stream_try_submit(conn)
				return true
			}
		}

		// 8. Ending and all plain sent (and no pending slab plain) → finish.
		if conn.slot.stream_ending &&
		   conn.slot.stream_sent >= len(conn.resp_buf) &&
		   d.tx_plain_n == 0 &&
		   d.hold_plain_n == 0 &&
		   conn.tls_stream_plain_n == 0 {
			_stream_finish(conn)
			return true
		}

		// 9. Mid-session idle: arm CT recv for peer close (hangup path).
		_session_arm_hangup_watch(conn)
		return true
	}

	if conn.ciphered || conn.tls_pipe.state == .Open {
		// Dual-CT (Linux): if a slab was filled during flight, promote immediately.
		// Darwin reactor residual already handled at top of this proc.
		if tls_host_promote_hold(conn) {
			// New send armed — seal further into free slab.
			tls_dual_ct_try_ahead(conn, .Oneshot)
			return true
		}
		// Oneshot: continue windowed response flush (or residual / ready CT).
		if tls_plain_total_remaining(conn) > 0 ||
		   dual_ct_has_ready(conn.dual_ct) ||
		   tls_server.bio_pending_out(conn.server.tls_provider, conn.tls_ssl) > 0 {
			tls_host_flush_response(conn)
			return true
		}
		// Fully done.
		tls_plain_clear(conn)
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
