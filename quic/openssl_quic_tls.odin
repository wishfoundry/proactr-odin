// OpenSSL 3.5+ quic-tls callbacks: CRYPTO FIFO, OSSL_DISPATCH, tls_drive.
package quic

import "base:runtime"
import "core:c"

Encryption_Level :: enum u8 {
	Initial     = 0,
	Early_Data  = 1, // never installed (early_data disabled)
	Handshake   = 2,
	Application = 3,
}

CRYPTO_CHUNK_SIZE :: 4096

// Fixed-size slab for the TLS pull-model CRYPTO FIFO. Never realloc while a
// recv_rcd pointer is outstanding (C4).
Crypto_Chunk :: struct {
	next: ^Crypto_Chunk,
	data: [CRYPTO_CHUNK_SIZE]u8,
	len:  int, // bytes valid in data[0..len)
	pos:  int, // next unread index
}

Crypto_Fifo :: struct {
	head:       ^Crypto_Chunk,
	tail:       ^Crypto_Chunk,
	rcd_active: bool,
	rcd_bytes:  c.size_t, // size last returned by recv_rcd
	// Free-list of recycled slabs (cap FIFO_FREE_MAX) to avoid malloc mid-HS.
	free_head:  ^Crypto_Chunk,
	free_count: int,
}

FIFO_FREE_MAX :: 8

// FIFO slabs use the heap allocator always so C callbacks and Odin call sites
// free with the same backend (independent of test tracking allocators).
@(private)
_fifo_alloc :: proc(f: ^Crypto_Fifo) -> ^Crypto_Chunk {
	if f != nil && f.free_head != nil {
		chunk := f.free_head
		f.free_head = chunk.next
		f.free_count -= 1
		chunk.next = nil
		chunk.len = 0
		chunk.pos = 0
		return chunk
	}
	return new(Crypto_Chunk, runtime.heap_allocator())
}

@(private)
_fifo_free_chunk :: proc(f: ^Crypto_Fifo, chunk: ^Crypto_Chunk) {
	if chunk == nil do return
	if f != nil && f.free_count < FIFO_FREE_MAX {
		chunk.next = f.free_head
		chunk.len = 0
		chunk.pos = 0
		f.free_head = chunk
		f.free_count += 1
		return
	}
	free(chunk, runtime.heap_allocator())
}

@(private)
_fifo_free_chunk_hard :: proc(chunk: ^Crypto_Chunk) {
	if chunk != nil {
		free(chunk, runtime.heap_allocator())
	}
}

crypto_fifo_append :: proc(f: ^Crypto_Fifo, data: []u8) -> bool {
	if f == nil do return false
	remaining := data
	for len(remaining) > 0 {
		if f.tail == nil || f.tail.len >= CRYPTO_CHUNK_SIZE {
			chunk := _fifo_alloc(f)
			if chunk == nil do return false
			if f.tail == nil {
				f.head = chunk
				f.tail = chunk
			} else {
				f.tail.next = chunk
				f.tail = chunk
			}
		}
		space := CRYPTO_CHUNK_SIZE - f.tail.len
		n := min(space, len(remaining))
		copy(f.tail.data[f.tail.len:], remaining[:n])
		f.tail.len += n
		remaining = remaining[n:]
	}
	return true
}

crypto_fifo_recv_rcd :: proc(f: ^Crypto_Fifo, buf: ^[^]u8, bytes_read: ^c.size_t) -> bool {
	if f == nil || buf == nil || bytes_read == nil do return false
	if f.rcd_active do return false // only one outstanding record
	// Skip exhausted head slabs.
	for f.head != nil && f.head.pos >= f.head.len {
		next := f.head.next
		_fifo_free_chunk(f, f.head)
		f.head = next
		if f.head == nil do f.tail = nil
	}
	if f.head == nil || f.head.pos >= f.head.len {
		buf^ = nil
		bytes_read^ = 0
		f.rcd_active = false
		f.rcd_bytes = 0
		return true
	}
	avail := f.head.len - f.head.pos
	buf^ = cast([^]u8)&f.head.data[f.head.pos]
	bytes_read^ = c.size_t(avail)
	f.rcd_active = true
	f.rcd_bytes = c.size_t(avail)
	return true
}

crypto_fifo_release_rcd :: proc(f: ^Crypto_Fifo, bytes_read: c.size_t) -> bool {
	if f == nil do return false
	if !f.rcd_active {
		// No-op if SSL freed while Conn still live, or double release.
		return true
	}
	// OpenSSL contract: bytes_read equals the previous buffer size.
	_ = bytes_read
	if f.head == nil {
		f.rcd_active = false
		f.rcd_bytes = 0
		return true
	}
	f.head.pos += int(f.rcd_bytes)
	f.rcd_active = false
	f.rcd_bytes = 0
	// Recycle fully consumed slabs.
	for f.head != nil && f.head.pos >= f.head.len {
		next := f.head.next
		_fifo_free_chunk(f, f.head)
		f.head = next
		if f.head == nil do f.tail = nil
	}
	return true
}

// Free all active slabs and the free-list (called from conn_free).
crypto_fifo_free :: proc(f: ^Crypto_Fifo) {
	if f == nil do return
	for f.head != nil {
		next := f.head.next
		_fifo_free_chunk_hard(f.head)
		f.head = next
	}
	f.tail = nil
	for f.free_head != nil {
		next := f.free_head.next
		_fifo_free_chunk_hard(f.free_head)
		f.free_head = next
	}
	f.free_count = 0
	f.rcd_active = false
	f.rcd_bytes = 0
}

// Map OSSL_RECORD_PROTECTION_LEVEL_* → Encryption_Level.
@(private)
_map_prot_level :: proc(prot_level: u32) -> (Encryption_Level, bool) {
	switch prot_level {
	case OSSL_RECORD_PROTECTION_LEVEL_NONE:
		return .Initial, true
	case OSSL_RECORD_PROTECTION_LEVEL_EARLY:
		return .Early_Data, true
	case OSSL_RECORD_PROTECTION_LEVEL_HANDSHAKE:
		return .Handshake, true
	case OSSL_RECORD_PROTECTION_LEVEL_APPLICATION:
		return .Application, true
	}
	return .Initial, false
}


@(private)
_ossl_crypto_send :: proc "c" (
	ssl:      rawptr,
	buf:      [^]u8,
	buf_len:  c.size_t,
	consumed: ^c.size_t,
	arg:      rawptr,
) -> c.int {
	// P-WOW-5: prefer Conn's captured Odin context (must assign context
	// unconditionally for proc "c" analysis).
	context = runtime.default_context()
	conn := cast(^Conn)arg
	if conn != nil do context = conn.odin_ctx
	if conn == nil do return 0
	if consumed != nil do consumed^ = 0
	lvl := _level_for(conn, conn.tx_level)
	if lvl == nil do return 0
	if buf_len > 0 && buf != nil {
		append(&lvl.tx_crypto, ..buf[:buf_len])
	}
	if consumed != nil do consumed^ = buf_len
	return 1
}

@(private)
_ossl_crypto_recv_rcd :: proc "c" (
	ssl:        rawptr,
	buf:        ^[^]u8,
	bytes_read: ^c.size_t,
	arg:        rawptr,
) -> c.int {
	context = runtime.default_context()
	conn := cast(^Conn)arg
	if conn != nil do context = conn.odin_ctx
	if conn == nil do return 0
	if !crypto_fifo_recv_rcd(&conn.tls_fifo, buf, bytes_read) do return 0
	return 1
}

@(private)
_ossl_crypto_release_rcd :: proc "c" (
	ssl:        rawptr,
	bytes_read: c.size_t,
	arg:        rawptr,
) -> c.int {
	context = runtime.default_context()
	conn := cast(^Conn)arg
	if conn != nil do context = conn.odin_ctx
	if conn == nil do return 1 // free-order: late release is no-op
	if !crypto_fifo_release_rcd(&conn.tls_fifo, bytes_read) do return 0
	return 1
}

@(private)
_ossl_yield_secret :: proc "c" (
	ssl:        rawptr,
	prot_level: u32,
	direction:  c.int,
	secret:     [^]u8,
	secret_len: c.size_t,
	arg:        rawptr,
) -> c.int {
	context = runtime.default_context()
	conn := cast(^Conn)arg
	if conn != nil do context = conn.odin_ctx
	if conn == nil do return 0

	// EARLY: install nothing (0-RTT disabled). NONE: Initial keys are DCID-derived.
	if prot_level == OSSL_RECORD_PROTECTION_LEVEL_EARLY ||
	   prot_level == OSSL_RECORD_PROTECTION_LEVEL_NONE {
		return 1
	}

	level, ok_level := _map_prot_level(prot_level)
	if !ok_level do return 0
	lvl := _level_for(conn, level)
	if lvl == nil do return 0

	cipher := g_os.SSL_get_current_cipher(ssl)
	if cipher == nil do return 0
	suite_id := u16(g_os.SSL_CIPHER_get_id(cipher) & 0xffff)
	key_len, sha384, kind, ok_suite := suite_params(suite_id)
	if !ok_suite do return 0 // fail closed — no AES-128 silent fallback
	if int(secret_len) != (48 if sha384 else 32) do return 0

	sec := secret[:secret_len]
	if direction == 0 {
		// Read (RX) keys.
		if !derive_packet_keys(&lvl.rx_keys, sec, key_len, sha384, kind) do return 0
		lvl.have_rx_keys = true
	} else if direction == 1 {
		// Write (TX) keys.
		if !derive_packet_keys(&lvl.tx_keys, sec, key_len, sha384, kind) do return 0
		lvl.have_tx_keys = true
		conn.tx_level = level
	} else {
		return 0
	}
	return 1
}

@(private)
_ossl_got_transport_params :: proc "c" (
	ssl:        rawptr,
	params:     [^]u8,
	params_len: c.size_t,
	arg:        rawptr,
) -> c.int {
	context = runtime.default_context()
	conn := cast(^Conn)arg
	if conn != nil do context = conn.odin_ctx
	if conn == nil do return 0
	if params_len == 0 || params == nil do return 0
	if !transport_params_decode(params[:params_len], &conn.peer_tp) do return 0
	conn.peer_tp_received = true
	// Adopt the peer's advertised connection-level limit as our initial
	// send budget. The peer may bump it later via MAX_DATA frames.
	if conn.peer_tp.initial_max_data > conn.tx_peer_max_data {
		conn.tx_peer_max_data = conn.peer_tp.initial_max_data
	}
	return 1
}

@(private)
_ossl_alert :: proc "c" (
	ssl:        rawptr,
	alert_code: u8,
	arg:        rawptr,
) -> c.int {
	context = runtime.default_context()
	conn := cast(^Conn)arg
	if conn != nil do context = conn.odin_ctx
	if conn == nil do return 0
	// CRYPTO_ERROR = 0x100 + TLS alert (RFC 9000 §20.1).
	conn_queue_connection_close(conn, 0x100 + u64(alert_code), "tls")
	return 1
}

// Build the OSSL_DISPATCH table on conn and register with SSL_set_quic_tls_cbs.
configure_quic_tls :: proc(conn: ^Conn, ssl: rawptr) -> bool {
	if conn == nil || ssl == nil || !os_ensure() do return false
	conn.quic_dispatch[0] = {OSSL_FUNC_SSL_QUIC_TLS_CRYPTO_SEND, rawptr(_ossl_crypto_send)}
	conn.quic_dispatch[1] = {OSSL_FUNC_SSL_QUIC_TLS_CRYPTO_RECV_RCD, rawptr(_ossl_crypto_recv_rcd)}
	conn.quic_dispatch[2] = {OSSL_FUNC_SSL_QUIC_TLS_CRYPTO_RELEASE_RCD, rawptr(_ossl_crypto_release_rcd)}
	conn.quic_dispatch[3] = {OSSL_FUNC_SSL_QUIC_TLS_YIELD_SECRET, rawptr(_ossl_yield_secret)}
	conn.quic_dispatch[4] = {OSSL_FUNC_SSL_QUIC_TLS_GOT_TRANSPORT_PARAMS, rawptr(_ossl_got_transport_params)}
	conn.quic_dispatch[5] = {OSSL_FUNC_SSL_QUIC_TLS_ALERT, rawptr(_ossl_alert)}
	conn.quic_dispatch[6] = {0, nil}
	return g_os.SSL_set_quic_tls_cbs(ssl, &conn.quic_dispatch[0], rawptr(conn)) == 1
}

// Drive SSL_do_handshake until WANT_READ/WRITE or complete.
// SSL_read(nil,0) only when handshake just completed this drive, or when
// already Connected (post-HS residual drain). Skip on early HS WANT_READ paths.
tls_drive :: proc(conn: ^Conn) -> bool {
	if conn == nil || conn.tls == nil || !os_ensure() do return false

	conn.tls_drive_calls += 1
	hs_just_completed := false

	if conn.state != .Connected {
		for {
			conn.do_hs_calls += 1
			rv := g_os.SSL_do_handshake(conn.tls)
			if rv == 1 {
				// C5: peer transport params required at Connected.
				if !conn.peer_tp_received {
					conn_queue_connection_close(conn, 0x100 + 40, "missing transport params")
					return false
				}
				conn.state = .Connected
				hs_just_completed = true
				conn_capture_alpn(conn)
				if conn.cc.max_datagram_size == 0 {
					congestion_init(&conn.cc, 1200)
				}
				break
			}
			err := g_os.SSL_get_error(conn.tls, rv)
			if err == SSL_ERROR_WANT_READ || err == SSL_ERROR_WANT_WRITE {
				break
			}
			// Fail closed.
			if !conn.has_pending_close {
				conn_queue_connection_close(conn, 0x100 + 40, "handshake_failure")
			}
			_print_ssl_error()
			conn.state = .Closing
			return false
		}
	}

	// Drain residual / post-HS only when HS just completed or already Connected.
	// Early Handshaking WANT_READ paths skip SSL_read (P-WOW-2).
	if hs_just_completed || conn.state == .Connected {
		rr := g_os.SSL_read(conn.tls, nil, 0)
		if rr < 0 {
			err := g_os.SSL_get_error(conn.tls, rr)
			if err == SSL_ERROR_SSL {
				if !conn.has_pending_close {
					conn_queue_connection_close(conn, 0x100 + 40, "tls_read")
				}
				_print_ssl_error()
				conn.state = .Closing
				return false
			}
		}
	}
	return true
}
