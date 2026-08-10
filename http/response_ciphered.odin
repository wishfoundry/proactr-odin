package http

// Ciphered H1 oneshot plain-split policy (heading vs full materialize).
//
// When a single borrowed Static/Bytes body is large enough, seal the heading
// from resp_buf and the body from the cmd view — avoids O(body) memcpy into
// resp_buf. Tiny bodies stay on Materialize_Full so one SSL_write/CQE turn
// keeps small-request RPS (split forces ≥2 seal/send turns).

// Minimum body size for Heading_Plus_Borrowed_Body.
// Split forces ≥2 SSL_write (heading part then body). Floor 0 regressed plain/s4k ~−27%
// (conv-all). Keep 8 KiB crossover so tiny stays one materialize+one seal; bulk still borrows.
TLS_PLAIN_SPLIT_MIN_BODY :: 8 * 1024

// pure-ish policy for ciphered oneshot arm after writev/sendfile fail.
Ciphered_Oneshot_Plan :: enum u8 {
	Materialize_Full, // classic heading+body materialize then seal
	Heading_Plus_Borrowed_Body, // heading in resp_buf, body view borrowed
}

// Returns Heading_Plus_Borrowed_Body only when: ciphered, TLS live, not h2,
// not stream, not HEAD, single Borrowed Static/Bytes cmd, body ≥ 8 KiB.
// Otherwise Materialize_Full (caller materializes as usual).
ciphered_oneshot_plan :: proc(r: ^Response, conn: ^Connection) -> Ciphered_Oneshot_Plan {
	if conn == nil ||
	   !conn.ciphered ||
	   conn.tls_ssl == nil ||
	   conn.h2_active ||
	   r._streaming ||
	   _response_is_head(conn) ||
	   r._cmd_count != 1 {
		return .Materialize_Full
	}
	c := r._cmds[0]
	// Lifetime: only .Borrowed (Static or cmd_bytes owned=false). .Owned Bytes
	// still materialize so stack/heap freed after respond cannot UAF.
	if !((c.kind == .Static || c.kind == .Bytes) &&
	     .Borrowed in c.flags &&
	     .Owned not_in c.flags) {
		return .Materialize_Full
	}
	if len(c.bytes) < TLS_PLAIN_SPLIT_MIN_BODY {
		return .Materialize_Full
	}
	return .Heading_Plus_Borrowed_Body
}

// Execute Heading_Plus_Borrowed_Body: format heading into resp_buf, set
// tls_plain_rest + tls_plain_body cursor, arm tls_host_flush_response.
// Caller must have checked ciphered_oneshot_plan == .Heading_Plus_Borrowed_Body.
// c is the single body cmd (typically r._cmds[0]).
response_send_ciphered_heading_body :: proc(r: ^Response, conn: ^Connection, c: Response_Cmd) {
	body_len := len(c.bytes)
	t0_build: u64
	when HTTP_PHASE_STATS {
		t0_build = phase_now()
	}
	hscratch: [512]byte
	hlen := _response_format_heading(r, body_len, hscratch[:])
	assert(hlen > 0 && hlen <= len(hscratch))
	if cap(r._buf.buf) < hlen {
		reserve(&r._buf.buf, hlen)
	}
	resize(&r._buf.buf, hlen)
	copy(r._buf.buf[0:hlen], hscratch[:hlen])
	r._heading_written = true
	when HTTP_PHASE_STATS {
		phase_add(0, 0, 0, 0, 0, phase_now() - t0_build, 0)
	}

	_conn_clear_exec(conn)
	conn.resp_buf = r._buf.buf
	conn.tls_plain_rest = r._buf.buf[:hlen]
	if body_len > 0 {
		conn.tls_plain_body = c.bytes
		conn.tls_plain_body_off = 0
	} else {
		conn.tls_plain_body = nil
		conn.tls_plain_body_off = 0
	}
	conn.tls_first_seal_pending = true // first_seal_pt instrument on first SSL_write
	// Heading-only assemble — do not count full-body materialize.
	tls_host_flush_response(conn)
}
